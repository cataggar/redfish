//! `StreamWire` — HTTP/1.1 over a stream the caller already opened.
//!
//! The caller supplies a reader and a writer and nothing else. Where they
//! came from is not this file's business: a TCP socket, a TLS session over
//! one, an SSH `direct-tcpip` channel, or a pair of buffers in a test. That
//! is the whole point -- connecting and, if TLS is wanted, deciding what to
//! trust, both belong to whoever knows the answer.
//!
//! ## What it speaks
//!
//! HTTP/1.1, persistent by default, with `Content-Length` and chunked
//! transfer encoding in both directions. It is not a general-purpose client
//! and does not try to be; it is the subset DSP0266 needs.
//!
//! `Accept-Encoding: identity` is sent on every request and no response
//! content coding is decoded. A BMC on the other end of a tunnel is not a
//! bandwidth problem, and refusing the encodings is cheaper and far less
//! error-prone than decoding them.
//!
//! ## Connection lifetime
//!
//! The stream is borrowed, and reconnecting is the caller's job. When the
//! peer signals `Connection: close`, or the stream ends, the wire is marked
//! spent and every later call fails with `error.ConnectionClosed` rather
//! than writing a request into a socket that is gone. The caller re-opens
//! its transport and makes a new `StreamWire`.
//!
//! This is deliberate. The caller built the tunnel and is the only thing
//! that knows how to rebuild it, what that costs, and whether it should.
//!
//! ## Buffer sizes
//!
//! The status line and each header line are read with
//! `Reader.takeDelimiterExclusive`, so the reader's buffer has to be at
//! least as long as the longest line the service sends, plus one.
//! `min_read_buffer` is a size no Redfish service should exceed; a smaller
//! buffer surfaces as `error.HeaderTooLong` rather than as a hang.

const std = @import("std");

const core = @import("redfish_core");

const wire_mod = @import("wire.zig");

const Exchange = wire_mod.Exchange;
const Header = core.bmc.Header;
const RawResponse = core.bmc.RawResponse;
const Wire = wire_mod.Wire;

/// A reader buffer smaller than this cannot be relied on to hold a status or
/// header line. Not enforced -- a service that stays well under it works with
/// less -- but it is the size at which `HeaderTooLong` stops being a risk.
pub const min_read_buffer = 16 << 10;

pub const Error = error{
    /// The peer closed the connection, or said it would. The wire is spent;
    /// re-open the transport and make a new one.
    ConnectionClosed,
    /// The status line was not `HTTP/1.x <code> ...`.
    InvalidStatusLine,
    /// A header line had no `:`, or a chunk size was not hexadecimal.
    InvalidHeader,
    /// A chunk-size line was not hexadecimal, or chunk framing was broken.
    InvalidChunk,
    /// A status or header line was longer than the reader's buffer.
    HeaderTooLong,
    /// The response body exceeded `Exchange.max_response_bytes`.
    ResponseTooLarge,
    /// A streamed request body declared a `Content-Length` it did not
    /// deliver. Sending it anyway would produce a malformed request.
    UploadLengthMismatch,
    /// The response declared a content coding, which this wire does not
    /// decode and did not ask for.
    UnexpectedContentEncoding,
};

pub const StreamWire = struct {
    wire: Wire = .{ .roundTripFn = &roundTripImpl },
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    /// Cleared once the peer closes, or announces that it will.
    usable: bool = true,

    /// Borrows both halves of an already-connected stream. Neither is closed
    /// by this type.
    pub fn init(reader: *std.Io.Reader, writer: *std.Io.Writer) StreamWire {
        return .{ .reader = reader, .writer = writer };
    }

    /// The interface to hand to `HttpBmc.initWire`.
    pub fn asWire(self: *StreamWire) *Wire {
        return &self.wire;
    }

    fn roundTripImpl(
        w: *Wire,
        arena: std.mem.Allocator,
        exchange: Exchange,
    ) anyerror!RawResponse {
        const self: *StreamWire = @fieldParentPtr("wire", w);
        if (!self.usable) return Error.ConnectionClosed;

        // A failure mid-exchange leaves the stream at an unknown offset, so
        // it can never be trusted for a second request. Only a clean round
        // trip clears this.
        errdefer self.usable = false;

        try self.sendRequest(exchange);
        return self.readResponse(arena, exchange);
    }

    fn sendRequest(self: *StreamWire, exchange: Exchange) !void {
        const w = self.writer;

        try w.print("{s} ", .{exchange.method.token()});
        try exchange.uri.writeToStream(w, .{ .path = true, .query = true });
        try w.writeAll(" HTTP/1.1\r\n");

        try w.writeAll("Host: ");
        try exchange.uri.host.?.formatHost(w);
        if (exchange.uri.port) |port| {
            if (port != defaultPort(exchange.uri.scheme)) try w.print(":{d}", .{port});
        }
        try w.writeAll("\r\n");

        // Nothing here decodes a content coding, so nothing here asks for one.
        try w.writeAll("Accept-Encoding: identity\r\n");

        for (exchange.headers) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        const body = exchange.body;
        if (!body.isEmpty()) {
            try w.print("Content-Type: {s}\r\n", .{exchange.content_type});
        }

        switch (body) {
            .bytes => |bytes| {
                if (bytes.len != 0) try w.print("Content-Length: {d}\r\n", .{bytes.len});
                try w.writeAll("\r\n");
                try w.writeAll(bytes);
            },
            .stream => |source| {
                // A known length is worth declaring: chunked transfer
                // encoding on a firmware push is what several BMCs reject.
                if (source.len) |len| {
                    try w.print("Content-Length: {d}\r\n\r\n", .{len});
                    const written = try source.reader.streamRemaining(w);
                    if (written != len) return Error.UploadLengthMismatch;
                } else {
                    try w.writeAll("Transfer-Encoding: chunked\r\n\r\n");
                    try writeChunked(w, source.reader);
                }
            },
        }

        try w.flush();
    }

    /// Copies `source` out as chunks, then writes the terminating one.
    fn writeChunked(w: *std.Io.Writer, source: *std.Io.Reader) !void {
        var buffer: [16 << 10]u8 = undefined;
        while (true) {
            // Short reads are how end of stream arrives here, not an error.
            const n = try source.readSliceShort(&buffer);
            if (n == 0) break;
            try w.print("{x}\r\n", .{n});
            try w.writeAll(buffer[0..n]);
            try w.writeAll("\r\n");
        }
        try w.writeAll("0\r\n\r\n");
    }

    fn readResponse(
        self: *StreamWire,
        arena: std.mem.Allocator,
        exchange: Exchange,
    ) !RawResponse {
        const status = try self.readStatusLine();

        var entries: std.ArrayList(Header) = .empty;
        var content_length: ?u64 = null;
        var chunked = false;
        var close_requested = false;

        while (true) {
            const line = try self.takeLine();
            if (line.len == 0) break;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return Error.InvalidHeader;
            const name = line[0..colon];
            if (name.len == 0) return Error.InvalidHeader;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(u64, value, 10) catch return Error.InvalidHeader;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // Only the final coding matters for framing, and `chunked`
                // is the only one that can be it.
                chunked = std.ascii.endsWithIgnoreCase(value, "chunked");
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.eqlIgnoreCase(value, "close")) close_requested = true;
            } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
                if (!std.ascii.eqlIgnoreCase(value, "identity")) {
                    return Error.UnexpectedContentEncoding;
                }
            }

            // The line points into the reader's buffer, which the next read
            // invalidates.
            try entries.append(arena, .{
                .name = try arena.dupe(u8, name),
                .value = try arena.dupe(u8, value),
            });
        }

        const body = try self.readBody(arena, .{
            .status = status,
            .method = exchange.method,
            .content_length = content_length,
            .chunked = chunked,
            .max_response_bytes = exchange.max_response_bytes,
        });

        // Announced after the body is read, so the response is still
        // delivered; only the next request fails.
        if (close_requested) self.usable = false;

        return .{
            .status = status,
            .headers = .{ .entries = try entries.toOwnedSlice(arena) },
            .body = body,
        };
    }

    fn readStatusLine(self: *StreamWire) !u16 {
        const line = self.takeLine() catch |err| switch (err) {
            // Nothing at all came back, which is what a peer that closed an
            // idle connection between requests looks like.
            error.EndOfStream => return Error.ConnectionClosed,
            else => |e| return e,
        };
        if (!std.ascii.startsWithIgnoreCase(line, "HTTP/1.")) return Error.InvalidStatusLine;
        if (line.len < "HTTP/1.1 200".len) return Error.InvalidStatusLine;
        const rest = line["HTTP/1.1".len..];
        const trimmed = std.mem.trimStart(u8, rest, " ");
        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        return std.fmt.parseInt(u16, trimmed[0..end], 10) catch Error.InvalidStatusLine;
    }

    /// One CRLF-terminated line, without its terminator.
    ///
    /// `takeDelimiterInclusive` rather than the exclusive form, because the
    /// exclusive one leaves the delimiter in the stream: the next line would
    /// then start with the previous line's `\n` and read as empty.
    fn takeLine(self: *StreamWire) ![]const u8 {
        const line = self.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return Error.HeaderTooLong,
            else => |e| return e,
        };
        // Tolerate a bare LF: some BMC firmware sends one, and rejecting the
        // response would help nobody.
        const body = line[0 .. line.len - 1];
        return if (std.mem.endsWith(u8, body, "\r")) body[0 .. body.len - 1] else body;
    }

    const BodyFraming = struct {
        status: u16,
        method: core.bmc.Method,
        content_length: ?u64,
        chunked: bool,
        max_response_bytes: usize,
    };

    fn readBody(
        self: *StreamWire,
        arena: std.mem.Allocator,
        framing: BodyFraming,
    ) ![]const u8 {
        // RFC 9112 §6.3: these carry no body however they are framed.
        if (framing.status == 204 or framing.status == 304 or
            (framing.status >= 100 and framing.status < 200))
        {
            return &.{};
        }

        if (framing.chunked) return self.readChunkedBody(arena, framing.max_response_bytes);

        if (framing.content_length) |len| {
            if (len > framing.max_response_bytes) return Error.ResponseTooLarge;
            const buffer = try arena.alloc(u8, @intCast(len));
            self.reader.readSliceAll(buffer) catch |err| switch (err) {
                error.EndOfStream => return Error.ConnectionClosed,
                else => |e| return e,
            };
            return buffer;
        }

        // No framing at all means the body runs to end of stream, which also
        // means the connection cannot be reused.
        self.usable = false;
        return self.reader.allocRemaining(arena, .limited(framing.max_response_bytes)) catch |err| {
            return switch (err) {
                error.StreamTooLong => Error.ResponseTooLarge,
                else => |e| e,
            };
        };
    }

    fn readChunkedBody(
        self: *StreamWire,
        arena: std.mem.Allocator,
        max_response_bytes: usize,
    ) ![]const u8 {
        var body: std.ArrayList(u8) = .empty;
        while (true) {
            const size_line = try self.takeLine();
            // A chunk size may carry extensions after a `;`.
            const semicolon = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
            const digits = std.mem.trim(u8, size_line[0..semicolon], " \t");
            const size = std.fmt.parseInt(usize, digits, 16) catch return Error.InvalidChunk;

            if (size == 0) break;
            if (body.items.len + size > max_response_bytes) return Error.ResponseTooLarge;

            const start = body.items.len;
            try body.resize(arena, start + size);
            self.reader.readSliceAll(body.items[start..]) catch |err| switch (err) {
                error.EndOfStream => return Error.ConnectionClosed,
                else => |e| return e,
            };

            // The CRLF that ends the chunk.
            const terminator = try self.takeLine();
            if (terminator.len != 0) return Error.InvalidChunk;
        }

        // Trailers, then the blank line that ends them.
        while (true) {
            const line = try self.takeLine();
            if (line.len == 0) break;
        }

        return body.toOwnedSlice(arena);
    }
};

fn defaultPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    return null;
}

const testing = std.testing;

/// Drives a `StreamWire` against a scripted response, and hands back what the
/// wire wrote so the request can be asserted on.
const Fixture = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    out: [8 << 10]u8 = undefined,
    wire: StreamWire = undefined,

    fn init(self: *Fixture, response: []const u8) void {
        self.reader = .fixed(response);
        self.writer = .fixed(&self.out);
        self.wire = .init(&self.reader, &self.writer);
    }

    fn written(self: *Fixture) []const u8 {
        return self.writer.buffered();
    }
};

fn get(uri: []const u8) !Exchange {
    return .{
        .uri = try std.Uri.parse(uri),
        .method = .get,
        .body = .empty,
        .headers = &.{},
        .content_type = "application/json",
        .max_response_bytes = 1 << 20,
    };
}

test "a Content-Length response is read exactly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 17\r\n" ++
            "\r\n" ++
            "{\"Id\":\"RootSvc\"}\n",
    );

    const response = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    );

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("{\"Id\":\"RootSvc\"}\n", response.body);
    try testing.expectEqualStrings("application/json", response.header("Content-Type").?);
    try testing.expect(fixture.wire.usable);
}

test "the request is origin-form with a Host header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 204 No Content\r\n\r\n");

    var exchange = try get("https://bmc.example/redfish/v1/Chassis?$expand=.");
    exchange.headers = &.{.{ .name = "OData-Version", .value = "4.0" }};
    _ = try fixture.wire.asWire().roundTrip(arena.allocator(), exchange);

    const sent = fixture.written();
    try testing.expect(std.mem.startsWith(
        u8,
        sent,
        "GET /redfish/v1/Chassis?$expand=. HTTP/1.1\r\n",
    ));
    try testing.expect(std.mem.indexOf(u8, sent, "Host: bmc.example\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "OData-Version: 4.0\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Accept-Encoding: identity\r\n") != null);
    // No body, so nothing describing one.
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Type:") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Length:") == null);
}

test "a non-default port appears in Host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 204 No Content\r\n\r\n");
    _ = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://127.0.0.1:8132/redfish/v1"),
    );

    try testing.expect(std.mem.indexOf(u8, fixture.written(), "Host: 127.0.0.1:8132\r\n") != null);
}

test "a body is sent with its length and content type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

    var exchange = try get("https://bmc.example/redfish/v1/Sessions");
    exchange.method = .post;
    exchange.body = .{ .bytes = "{\"UserName\":\"root\"}" };
    _ = try fixture.wire.asWire().roundTrip(arena.allocator(), exchange);

    const sent = fixture.written();
    try testing.expect(std.mem.startsWith(u8, sent, "POST /redfish/v1/Sessions HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Length: 19\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, sent, "\r\n\r\n{\"UserName\":\"root\"}"));
}

test "a chunked response is reassembled, trailers and all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n" ++
            "6;ext=1\r\n world\r\n" ++
            "0\r\n" ++
            "X-Trailer: ignored\r\n" ++
            "\r\n",
    );

    const response = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    );

    try testing.expectEqualStrings("hello world", response.body);
    try testing.expect(fixture.wire.usable);
}

test "204 and 304 have no body however they are framed" {
    for ([_][]const u8{
        "HTTP/1.1 204 No Content\r\n\r\n",
        "HTTP/1.1 304 Not Modified\r\nETag: \"abc\"\r\n\r\n",
    }) |script| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        var fixture: Fixture = undefined;
        fixture.init(script);
        const response = try fixture.wire.asWire().roundTrip(
            arena.allocator(),
            try get("https://bmc.example/redfish/v1"),
        );
        try testing.expectEqual(@as(usize, 0), response.body.len);
    }
}

test "the connection is reused across requests" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}" ++
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n[1,2]",
    );

    const first = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    );
    try testing.expectEqualStrings("{}", first.body);

    const second = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1/Chassis"),
    );
    try testing.expectEqualStrings("[1,2]", second.body);
    try testing.expect(fixture.wire.usable);
}

test "Connection: close spends the wire after delivering the response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
    );

    const response = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    );
    try testing.expectEqualStrings("{}", response.body);
    try testing.expect(!fixture.wire.usable);

    try testing.expectError(Error.ConnectionClosed, fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    ));
}

test "a closed stream is reported as such, not as a parse failure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("");

    try testing.expectError(Error.ConnectionClosed, fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    ));
}

test "a truncated body is a closed connection, not a short read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 32\r\n\r\nshort");

    try testing.expectError(Error.ConnectionClosed, fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    ));
}

test "a body over the cap is refused rather than allocated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n");

    var exchange = try get("https://bmc.example/redfish/v1");
    exchange.max_response_bytes = 16;
    try testing.expectError(
        Error.ResponseTooLarge,
        fixture.wire.asWire().roundTrip(arena.allocator(), exchange),
    );
}

test "a content coding that was not asked for is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}");

    try testing.expectError(
        Error.UnexpectedContentEncoding,
        fixture.wire.asWire().roundTrip(arena.allocator(), try get("https://bmc.example/redfish/v1")),
    );
}

test "a garbled status line is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("ICY 200 OK\r\n\r\n");

    try testing.expectError(
        Error.InvalidStatusLine,
        fixture.wire.asWire().roundTrip(arena.allocator(), try get("https://bmc.example/redfish/v1")),
    );
}

test "a failed exchange spends the wire, because the offset is unknown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\r\nnot-a-header\r\n\r\n");

    try testing.expectError(
        Error.InvalidHeader,
        fixture.wire.asWire().roundTrip(arena.allocator(), try get("https://bmc.example/redfish/v1")),
    );
    try testing.expect(!fixture.wire.usable);
}

test "a bare LF between headers is tolerated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var fixture: Fixture = undefined;
    fixture.init("HTTP/1.1 200 OK\nContent-Length: 2\n\n{}");

    const response = try fixture.wire.asWire().roundTrip(
        arena.allocator(),
        try get("https://bmc.example/redfish/v1"),
    );
    try testing.expectEqualStrings("{}", response.body);
}
