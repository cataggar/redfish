//! `HttpBmc` — a `BmcTransport` over `std.http.Client`.
//!
//! Handles the parts of DSP0266's protocol chapter that are the same for
//! every request: the `OData-Version` header, credentials, conditional
//! request headers, redirect following, and reading the response into the
//! operation's arena.
//!
//! Redirects are followed here rather than by `std.http.Client`, because
//! every hop has to go back through `Endpoint.resolve` and its same-origin
//! check. A service that redirects a credentialed request off its own origin
//! gets an error, not a request.

const std = @import("std");

const core = @import("redfish_core");

const cache_mod = @import("cache.zig");
const credentials_mod = @import("credentials.zig");
const endpoint_mod = @import("endpoint.zig");

const CacheSettings = cache_mod.CacheSettings;
const CachedResponse = cache_mod.CachedResponse;
const Credentials = credentials_mod.Credentials;
const Endpoint = endpoint_mod.Endpoint;
const Header = core.bmc.Header;
const RawRequest = core.bmc.RawRequest;
const RawResponse = core.bmc.RawResponse;
const RedfishError = core.redfish_error.RedfishError;
const ResponseCache = cache_mod.ResponseCache;

/// Detail about a failed request.
///
/// Zig errors carry no payload, so a caller that wants the service's own
/// explanation attaches one of these to the connection first:
///
/// ```zig
/// var diagnostics: Diagnostics = .init(gpa);
/// defer diagnostics.deinit();
/// bmc.diagnostics = &diagnostics;
///
/// const chassis = core.bmc.get(Chassis, gpa, bmc.asTransport(), id) catch |err| {
///     std.log.err("{s}: {f}", .{ @errorName(err), diagnostics });
///     return err;
/// };
/// ```
///
/// The captured body is copied into the diagnostics' own allocator, so it
/// outlives the operation arena that is unwound on the way out.
pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    /// Status of the most recent response, or 0 if there has not been one.
    status: u16 = 0,
    /// The response body, when the request failed and carried one.
    body: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.clear();
        self.* = undefined;
    }

    pub fn clear(self: *Diagnostics) void {
        if (self.body) |body| self.gpa.free(body);
        self.body = null;
        self.status = 0;
    }

    fn record(self: *Diagnostics, status: u16, body: []const u8) void {
        self.clear();
        self.status = status;
        // A diagnostic that cannot allocate is not worth failing the request
        // over; the status alone is still useful.
        self.body = self.gpa.dupe(u8, body) catch null;
    }

    /// The captured body decoded as a Redfish error, or null when there was
    /// no body or it was not one.
    ///
    /// The result borrows `arena`.
    pub fn redfishError(self: Diagnostics, arena: std.mem.Allocator) ?RedfishError {
        return RedfishError.parseLeaky(arena, self.body orelse return null);
    }

    /// Renders the status and, when the body is a Redfish error, its code and
    /// messages. Falls back to the raw body, truncated.
    pub fn format(self: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("HTTP {d}", .{self.status});
        const body = self.body orelse return;

        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        if (RedfishError.parseLeaky(fba.allocator(), body)) |parsed| {
            if (parsed.@"error".code.len != 0) return w.print(" — {f}", .{parsed});
        }

        const max = 512;
        if (body.len <= max) return w.print(" — {s}", .{body});
        try w.print(" — {s}… ({d} bytes)", .{ body[0..max], body.len });
    }
};

/// A Redfish connection over HTTP.
///
/// Borrows the `std.http.Client`, so one client's connection pool can back
/// several BMCs. It also borrows `base_url`, `credentials`, and
/// `extra_headers`; all of them must outlive the connection.
pub const HttpBmc = struct {
    transport: core.bmc.BmcTransport = .{
        .sendFn = &sendImpl,
        .streamFn = &streamImpl,
        .authenticateFn = &authenticateImpl,
    },
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    endpoint: Endpoint,
    credentials: Credentials,
    extra_headers: []const Header,
    max_response_bytes: usize,
    max_redirects: u8,
    cache: ResponseCache,
    diagnostics: ?*Diagnostics = null,

    pub const Options = struct {
        credentials: Credentials = .anonymous,
        /// Headers added to every request, after the transport's own.
        /// Borrowed.
        extra_headers: []const Header = &.{},
        /// Cap on a response body. A BMC that streams an unbounded body
        /// should not be able to exhaust the client's memory.
        max_response_bytes: usize = 16 << 20,
        /// Redirects to follow. Every hop is re-checked for same-origin.
        max_redirects: u8 = 5,
        /// How many responses to keep for conditional revalidation. Set
        /// `.disabled` to send no `If-None-Match` at all.
        cache: CacheSettings = .default,
    };

    pub const InitError = Endpoint.ParseError;

    pub fn init(
        gpa: std.mem.Allocator,
        client: *std.http.Client,
        base_url: []const u8,
        options: Options,
    ) InitError!HttpBmc {
        return .{
            .gpa = gpa,
            .client = client,
            .endpoint = try Endpoint.parse(base_url),
            .credentials = options.credentials,
            .extra_headers = options.extra_headers,
            .max_response_bytes = options.max_response_bytes,
            .max_redirects = options.max_redirects,
            .cache = .init(gpa, options.cache),
        };
    }

    pub fn deinit(self: *HttpBmc) void {
        self.cache.deinit();
        self.* = undefined;
    }

    /// The interface to hand to `core.bmc`'s typed operations.
    pub fn asTransport(self: *HttpBmc) *core.bmc.BmcTransport {
        return &self.transport;
    }

    /// `BmcTransport.authenticate`: adopt a session token, or revert to
    /// anonymous when dropping one.
    ///
    /// Reverting to anonymous rather than to the Basic credentials the
    /// connection started with is deliberate. Those were the credentials used
    /// to *obtain* the session; continuing to send them after logout would
    /// leave the connection authenticated by a route the caller just asked to
    /// leave, and hide the logout from anyone reading the wire.
    fn authenticateImpl(t: *core.bmc.BmcTransport, token: ?[]const u8) anyerror!void {
        const self: *HttpBmc = @fieldParentPtr("transport", t);
        self.credentials = if (token) |value| .initToken(value) else .anonymous;
    }

    /// Switch credentials, normally from Basic to the token returned by
    /// session creation.
    pub fn setCredentials(self: *HttpBmc, value: Credentials) void {
        self.credentials = value;
    }

    /// Adopt the token and log-out URI from a `createSession` result.
    ///
    /// The token is borrowed from the session response, so the `Owned` value
    /// it came from has to outlive this connection's use of it.
    pub fn adoptSession(self: *HttpBmc, token: []const u8) void {
        self.setCredentials(.initToken(token));
    }

    pub const SendError = error{
        /// More redirects than `max_redirects`, or a redirect with no
        /// `Location` to follow.
        TooManyRedirects,
        /// The response body exceeded `max_response_bytes`.
        ResponseTooLarge,
        /// A redirect that must preserve the body was answered to a request
        /// whose body is a stream. A stream is consumed as it is sent and
        /// cannot be replayed, so the request is not repeatable.
        StreamNotReplayable,
        /// A streamed body declared a `Content-Length` it did not deliver.
        /// Sending it anyway would produce a malformed request.
        UploadLengthMismatch,
        /// The service answered `304 Not Modified` to a conditional request
        /// this transport did not make. A BMC that does this cannot be
        /// cached against, because there is no body to serve.
        UnexpectedNotModified,
    };

    fn sendImpl(
        t: *core.bmc.BmcTransport,
        arena: std.mem.Allocator,
        request: RawRequest,
    ) anyerror!RawResponse {
        const self: *HttpBmc = @fieldParentPtr("transport", t);
        if (self.diagnostics) |diagnostics| diagnostics.clear();

        var reference = request.uri;
        var method = request.method;
        var body = request.body;

        var hop: u8 = 0;
        while (true) : (hop += 1) {
            if (hop > self.max_redirects) return SendError.TooManyRedirects;

            const uri = try self.endpoint.resolve(arena, reference);
            const response = try self.exchange(arena, uri, method, body, request);

            const redirect = redirectTo(response) orelse {
                if (self.diagnostics) |diagnostics| {
                    if (!response.isSuccess()) diagnostics.record(response.status, response.body);
                }
                return response;
            };

            // RFC 9110: 301, 302, and 303 turn a non-HEAD request into a GET
            // and drop the body. 307 and 308 preserve both.
            if (response.status != 307 and response.status != 308) {
                method = .get;
                body = .empty;
            } else if (body == .stream) {
                return SendError.StreamNotReplayable;
            }
            reference = redirect;
        }
    }

    /// One hop, with the response cache in front of it.
    ///
    /// The cache is consulted for a `GET` the caller did not already make
    /// conditional: a caller-supplied `If-None-Match` means the caller wants
    /// to see the `304` itself (that is what `core.bmc.getIfNoneMatch` is
    /// for), and answering it from here would hide it.
    fn exchange(
        self: *HttpBmc,
        arena: std.mem.Allocator,
        uri: std.Uri,
        method: core.bmc.Method,
        body: core.bmc.RequestBody,
        request: RawRequest,
    ) anyerror!RawResponse {
        const cacheable = method == .get and
            request.if_none_match == null and
            self.cache.isEnabled();
        if (!cacheable) return self.roundTrip(arena, uri, method, body, request, null);

        // The key is the resolved absolute URI, so a `$expand` of a resource
        // and the plain read of it stay apart, and a relative and an absolute
        // reference to the same resource come together.
        const key = try std.fmt.allocPrint(arena, "{f}", .{uri});
        const cached = self.cache.lookup(key);

        const conditional: ?[]const u8 = if (cached) |entry| entry.etag else null;
        const response = try self.roundTrip(arena, uri, method, body, request, conditional);

        if (response.status == 304) {
            const entry = cached orelse return SendError.UnexpectedNotModified;
            return revalidated(arena, response, entry);
        }

        if (response.status == 200) {
            // Without an `ETag` there is nothing to revalidate against later,
            // so there is no point keeping the body.
            if (response.header("ETag")) |etag| self.cache.store(key, etag, response.body);
        }
        return response;
    }

    /// Turns a `304` into the `200` the caller would have received, using the
    /// body the last `200` left behind.
    fn revalidated(
        arena: std.mem.Allocator,
        response: RawResponse,
        entry: CachedResponse,
    ) std.mem.Allocator.Error!RawResponse {
        var entries: std.ArrayList(Header) = .empty;
        for (response.headers.entries) |header| {
            // These described the `304`'s absent body, not the one about to
            // be substituted for it, so carrying them over would misdescribe
            // the response.
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) continue;
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Encoding")) continue;
            try entries.append(arena, header);
        }
        // RFC 9110 requires a `304` to carry the `ETag` that matched, but a
        // BMC that omits it must not produce a body with no `ETag` beside it.
        if (response.header("ETag") == null) {
            try entries.append(arena, .{ .name = "ETag", .value = entry.etag });
        }
        return .{
            .status = 200,
            .headers = .{ .entries = try entries.toOwnedSlice(arena) },
            // The cache may drop this entry on any later store, so the copy
            // the caller sees has to be its own.
            .body = try arena.dupe(u8, entry.body),
        };
    }

    /// One request/response exchange, with no redirect or cache handling.
    fn roundTrip(
        self: *HttpBmc,
        arena: std.mem.Allocator,
        uri: std.Uri,
        method: core.bmc.Method,
        body: core.bmc.RequestBody,
        request: RawRequest,
        conditional: ?[]const u8,
    ) anyerror!RawResponse {
        var headers: std.ArrayList(std.http.Header) = .empty;
        // DSP0266 requires this on every request.
        try headers.append(arena, .{ .name = "OData-Version", .value = "4.0" });
        if (request.if_match) |etag| {
            try headers.append(arena, .{ .name = "If-Match", .value = etag.value });
        }
        if (request.if_none_match orelse
            (if (conditional) |value| core.ODataETag.init(value) else null)) |etag|
        {
            try headers.append(arena, .{ .name = "If-None-Match", .value = etag.value });
        }
        for (self.extra_headers) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }
        for (request.headers) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }

        // `std.http.Client.Request.privileged_headers` is only consulted when
        // the client follows a redirect itself, and is never written to the
        // wire, so credentials go in `extra_headers`. Leaking them across an
        // origin is prevented a layer up: `sendImpl` re-resolves every hop
        // through `Endpoint.resolve`, which refuses to leave the origin at all.
        if (try self.credentials.header(arena)) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }

        var http_request = try self.client.request(toStdMethod(method), uri, .{
            // Redirects are followed by `sendImpl`, which re-checks the
            // origin on every hop.
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
            .headers = .{
                .content_type = if (body.isEmpty()) .omit else .{ .override = request.content_type },
                .accept_encoding = .default,
            },
        });
        defer http_request.deinit();

        try sendBody(&http_request, body);

        var response = try http_request.receiveHead(&.{});
        const status: u16 = @intFromEnum(response.head.status);

        var entries: std.ArrayList(Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            try entries.append(arena, .{
                .name = try arena.dupe(u8, header.name),
                .value = try arena.dupe(u8, header.value),
            });
        }

        return .{
            .status = status,
            .headers = .{ .entries = try entries.toOwnedSlice(arena) },
            .body = try self.readBody(arena, &response),
        };
    }

    /// Writes the request body, whether it is in memory or arriving from a
    /// reader.
    fn sendBody(
        http_request: *std.http.Client.Request,
        body: core.bmc.RequestBody,
    ) anyerror!void {
        switch (body) {
            .bytes => |bytes| {
                if (bytes.len == 0) return http_request.sendBodiless();
                http_request.transfer_encoding = .{ .content_length = bytes.len };
                var writer = try http_request.sendBodyUnflushed(&.{});
                try writer.writer.writeAll(bytes);
                try writer.end();
                try http_request.connection.?.flush();
            },
            .stream => |source| {
                // A known length is worth declaring: chunked transfer
                // encoding on a firmware push is what several BMCs reject.
                http_request.transfer_encoding = if (source.len) |len|
                    .{ .content_length = len }
                else
                    .chunked;

                var chunk_buffer: [16 << 10]u8 = undefined;
                var writer = try http_request.sendBodyUnflushed(&chunk_buffer);
                const written = try source.reader.streamRemaining(&writer.writer);
                if (source.len) |len| {
                    if (written != len) return SendError.UploadLengthMismatch;
                }
                try writer.end();
                try http_request.connection.?.flush();
            },
        }
    }

    fn readBody(
        self: *HttpBmc,
        arena: std.mem.Allocator,
        response: *std.http.Client.Response,
    ) anyerror![]const u8 {
        var transfer_buffer: [4096]u8 = undefined;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };

        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            decompress_buffer,
        );

        return reader.allocRemaining(arena, .limited(self.max_response_bytes)) catch |err| {
            return switch (err) {
                error.StreamTooLong => SendError.ResponseTooLarge,
                error.ReadFailed => response.bodyErr() orelse err,
                else => err,
            };
        };
    }

    fn streamImpl(
        t: *core.bmc.BmcTransport,
        uri: []const u8,
    ) anyerror!core.bmc.EventStream {
        const self: *HttpBmc = @fieldParentPtr("transport", t);
        if (self.diagnostics) |diagnostics| diagnostics.clear();

        const session = try EventSession.open(self, uri);
        return .{
            .reader = session.body,
            .context = session,
            .closeFn = &EventSession.closeImpl,
        };
    }
};

/// A `text/event-stream` held open.
///
/// An event stream outlives the call that opened it, so unlike every other
/// request it cannot keep its HTTP state on the stack or in the operation
/// arena. `std.http.Client.Response` points at its `Request`, and the body
/// reader points at buffers belonging to both, so all of it lives here, at a
/// stable address, until `close`.
const EventSession = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    body: *std.Io.Reader,
    transfer_buffer: [4096]u8 = undefined,
    decompress: std.http.Decompress = undefined,
    stream: core.bmc.EventStream = undefined,

    /// How much of a failed subscription's body to keep for diagnostics.
    const error_body_limit = 64 << 10;

    fn open(bmc: *HttpBmc, reference: []const u8) !*EventSession {
        const self = try bmc.gpa.create(EventSession);
        errdefer bmc.gpa.destroy(self);

        self.* = .{
            .gpa = bmc.gpa,
            .arena = .init(bmc.gpa),
            .request = undefined,
            .response = undefined,
            .body = undefined,
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        var target = reference;

        var hop: u8 = 0;
        while (true) : (hop += 1) {
            if (hop > bmc.max_redirects) return HttpBmc.SendError.TooManyRedirects;

            // Same-origin is re-checked on every hop, exactly as `sendImpl`
            // does: a subscription is credentialed too.
            const uri = try bmc.endpoint.resolve(arena, target);
            const head = try self.send(bmc, arena, uri);

            if (head.status.class() == .redirect) {
                target = head.location orelse return HttpBmc.SendError.TooManyRedirects;
                self.request.deinit();
                continue;
            }

            // Initializing the body stream invalidates every pointer in the
            // response head, so nothing may be read out of it past this line.
            self.body = self.response.readerDecompressing(
                &self.transfer_buffer,
                &self.decompress,
                &.{},
            );

            if (head.status.class() != .success) {
                if (bmc.diagnostics) |diagnostics| {
                    const body = self.body.allocRemaining(arena, .limited(error_body_limit)) catch
                        &.{};
                    diagnostics.record(@intFromEnum(head.status), body);
                }
                self.request.deinit();
                return core.bmc.statusError(@intFromEnum(head.status)) orelse
                    core.bmc.Error.UnexpectedStatus;
            }
            return self;
        }
    }

    /// What `open` needs off the response head, copied out before the body
    /// stream invalidates it.
    const Head = struct {
        status: std.http.Status,
        location: ?[]const u8,
    };

    /// One request, leaving `request` and `response` live.
    fn send(
        self: *EventSession,
        bmc: *HttpBmc,
        arena: std.mem.Allocator,
        uri: std.Uri,
    ) !Head {
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(arena, .{ .name = "OData-Version", .value = "4.0" });
        // `std.http.Client.Request.Headers` has no `accept`, so the media
        // type this whole call is about goes in as an extra header.
        try headers.append(arena, .{ .name = "Accept", .value = "text/event-stream" });
        for (bmc.extra_headers) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }
        if (try bmc.credentials.header(arena)) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }

        self.request = try bmc.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
            .headers = .{
                .accept_encoding = .omit,
                .content_type = .omit,
            },
        });
        errdefer self.request.deinit();

        try self.request.sendBodiless();
        self.response = try self.request.receiveHead(&.{});
        return .{
            .status = self.response.head.status,
            .location = if (self.response.head.location) |location|
                try arena.dupe(u8, location)
            else
                null,
        };
    }

    fn closeImpl(stream: *core.bmc.EventStream) void {
        const self: *EventSession = @ptrCast(@alignCast(stream.context.?));
        self.request.deinit();
        self.arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// The `Location` of a redirect response, or null when the response is not
/// one we follow.
fn redirectTo(response: RawResponse) ?[]const u8 {
    return switch (response.status) {
        301, 302, 303, 307, 308 => response.header("Location"),
        else => null,
    };
}

fn toStdMethod(method: core.bmc.Method) std.http.Method {
    return switch (method) {
        .get => .GET,
        .post => .POST,
        .patch => .PATCH,
        .put => .PUT,
        .delete => .DELETE,
    };
}

const testing = std.testing;

test "Diagnostics starts empty" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try testing.expectEqual(@as(u16, 0), diagnostics.status);
    try testing.expectEqual(@as(?[]u8, null), diagnostics.body);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("HTTP 0", try std.fmt.bufPrint(&buf, "{f}", .{diagnostics}));
}

test "Diagnostics owns its copy of the body" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const body = try testing.allocator.dupe(u8, "{\"error\":{\"code\":\"Base.1.0.X\"}}");
    diagnostics.record(400, body);
    testing.allocator.free(body);

    try testing.expectEqual(@as(u16, 400), diagnostics.status);
    try testing.expectEqualStrings("{\"error\":{\"code\":\"Base.1.0.X\"}}", diagnostics.body.?);
}

test "Diagnostics decodes a captured Redfish error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    diagnostics.record(400,
        \\{"error":{"code":"Base.1.0.PropertyValueNotInList",
        \\"message":"The value Red is not in the list.",
        \\"@Message.ExtendedInfo":[{"MessageId":"Base.1.0.PropertyValueNotInList",
        \\"Resolution":"Choose a value from the list."}]}}
    );

    const parsed = diagnostics.redfishError(arena.allocator()).?;
    try testing.expectEqualStrings("PropertyValueNotInList", parsed.codeName());
    try testing.expectEqual(@as(usize, 1), parsed.extendedInfo().len);

    var buf: [512]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diagnostics});
    try testing.expect(std.mem.startsWith(u8, rendered, "HTTP 400 — Base.1.0.PropertyValueNotInList"));
}

test "Diagnostics falls back to the raw body" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    diagnostics.record(502, "<html>Bad Gateway</html>");

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "HTTP 502 — <html>Bad Gateway</html>",
        try std.fmt.bufPrint(&buf, "{f}", .{diagnostics}),
    );
}

test "Diagnostics truncates a very long body" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const body = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    diagnostics.record(500, body);

    var buf: [1024]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diagnostics});
    try testing.expect(std.mem.endsWith(u8, rendered, "… (2000 bytes)"));
    try testing.expect(rendered.len < 600);
}

test "clear releases the captured body" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    diagnostics.record(404, "{}");
    diagnostics.clear();
    try testing.expectEqual(@as(u16, 0), diagnostics.status);
    try testing.expectEqual(@as(?[]u8, null), diagnostics.body);

    // Recording twice must not leak the first body.
    diagnostics.record(404, "first");
    diagnostics.record(500, "second");
    try testing.expectEqualStrings("second", diagnostics.body.?);
}

test "init rejects a base URL that is not a usable origin" {
    var client: std.http.Client = undefined;
    try testing.expectError(
        Endpoint.ParseError.UnsupportedScheme,
        HttpBmc.init(testing.allocator, &client, "ftp://bmc.example", .{}),
    );
}

test "methods map onto std.http" {
    try testing.expectEqual(std.http.Method.GET, toStdMethod(.get));
    try testing.expectEqual(std.http.Method.POST, toStdMethod(.post));
    try testing.expectEqual(std.http.Method.PATCH, toStdMethod(.patch));
    try testing.expectEqual(std.http.Method.PUT, toStdMethod(.put));
    try testing.expectEqual(std.http.Method.DELETE, toStdMethod(.delete));
}

test "only redirect statuses with a Location are followed" {
    const location: []const Header = &.{.{ .name = "Location", .value = "/redfish/v1/" }};

    for ([_]u16{ 301, 302, 303, 307, 308 }) |status| {
        try testing.expectEqualStrings(
            "/redfish/v1/",
            redirectTo(.{ .status = status, .headers = .{ .entries = location } }).?,
        );
    }
    for ([_]u16{ 200, 201, 204, 304, 400, 404, 500 }) |status| {
        try testing.expectEqual(
            @as(?[]const u8, null),
            redirectTo(.{ .status = status, .headers = .{ .entries = location } }),
        );
    }
    // A redirect with nowhere to go is not followed.
    try testing.expectEqual(@as(?[]const u8, null), redirectTo(.{ .status = 302 }));
}
