//! Integration tests for `HttpBmc` against a real loopback `std.http.Server`.
//!
//! `transport.zig`'s own tests cover the pieces that can be checked without a
//! socket. These drive the whole path — `std.http.Client`, a TCP connection,
//! and a server that speaks HTTP/1.1 — so that header emission, body framing,
//! status mapping, and redirect handling are verified against the wire rather
//! than against a stub.
//!
//! This file is test-only; nothing here is exported from the module root.

const std = @import("std");
const native_os = @import("builtin").os.tag;

const core = @import("redfish_core");

const transport = @import("transport.zig");
const Endpoint = @import("endpoint.zig").Endpoint;
const HttpBmc = transport.HttpBmc;

const testing = std.testing;

/// A canned response for the fixture to serve.
const Reply = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    /// Sent as `Content-Type` when the body or `chunks` is non-empty.
    content_type: []const u8 = "application/json",
    /// When non-empty, the body is sent chunked, one chunk per entry, each
    /// flushed on its own. This is how a service delivers an event stream.
    chunks: []const []const u8 = &.{},
};

/// A request as the fixture saw it on the wire.
const Recorded = struct {
    method: std.http.Method,
    target: []u8,
    headers: []std.http.Header,
    body: []u8,

    fn header(self: Recorded, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn deinit(self: Recorded, gpa: std.mem.Allocator) void {
        for (self.headers) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.value);
        }
        gpa.free(self.headers);
        gpa.free(self.target);
        gpa.free(self.body);
    }
};

/// A single-threaded HTTP server bound to a loopback port, serving a fixed
/// script of replies and recording every request it received.
///
/// Heap-allocated because the `std.Io.Threaded` it owns is handed out by
/// pointer and so must not move.
const Fixture = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    server: std.Io.net.Server,
    port: u16,
    thread: std.Thread,
    replies: []const Reply,
    /// Written only by the server thread. The test thread reads entries below
    /// `recorded_count`, whose release/acquire pairing publishes them.
    recorded: std.ArrayList(Recorded) = .empty,
    recorded_count: std.atomic.Value(usize) = .init(0),
    /// Exchanges the server thread has finished, successfully or not.
    served: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    base_url: [32]u8 = undefined,
    base_url_len: usize = 0,

    fn start(gpa: std.mem.Allocator, replies: []const Reply) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{}),
            .server = undefined,
            .port = 0,
            .thread = undefined,
            .replies = replies,
        };
        errdefer self.threaded.deinit();

        const io = self.threaded.io();
        self.server, self.port = try listenLoopback(io);
        errdefer self.server.deinit(io);

        const rendered = try std.fmt.bufPrint(&self.base_url, "http://127.0.0.1:{d}", .{self.port});
        self.base_url_len = rendered.len;

        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn baseUrl(self: *const Fixture) []const u8 {
        return self.base_url[0..self.base_url_len];
    }

    /// Joins the server thread, unblocking it first if the test used fewer
    /// requests than the script had replies for. Without the poke, a test that
    /// asserts an early failure would hang here forever.
    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        while (!self.finished()) {
            var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
            const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch break;
            stream.close(io);
            std.Thread.yield() catch {};
        }
        self.thread.join();

        self.server.deinit(io);
        for (self.recorded.items) |entry| entry.deinit(self.gpa);
        self.recorded.deinit(self.gpa);
        self.threaded.deinit();

        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn finished(self: *Fixture) bool {
        return self.served.load(.acquire) >= self.replies.len;
    }

    fn requestCount(self: *Fixture) usize {
        return self.recorded_count.load(.acquire);
    }

    fn request(self: *Fixture, index: usize) Recorded {
        std.debug.assert(index < self.requestCount());
        return self.recorded.items[index];
    }

    fn serve(self: *Fixture) void {
        for (self.replies) |reply| {
            self.serveOne(reply) catch |err| {
                // A connection closed by `deinit`'s poke is expected; anything
                // else is reported to the test through `failure`.
                if (self.failure == null and err != error.HttpConnectionClosing) {
                    self.failure = err;
                }
            };
            _ = self.served.fetchAdd(1, .release);
        }
    }

    fn serveOne(self: *Fixture, reply: Reply) !void {
        const io = self.threaded.io();

        const stream = try self.server.accept(io);
        defer stream.close(io);

        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [16 * 1024]u8 = undefined;
        var stream_reader = stream.reader(io, &recv_buffer);
        var stream_writer = stream.writer(io, &send_buffer);

        var http_server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
        var http_request = try http_server.receiveHead();

        try self.record(&http_request);

        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.gpa);
        if (reply.body.len != 0 or reply.chunks.len != 0) {
            try extra.append(self.gpa, .{ .name = "Content-Type", .value = reply.content_type });
        }
        try extra.appendSlice(self.gpa, reply.headers);

        if (reply.chunks.len != 0) {
            var body_buffer: [4096]u8 = undefined;
            var body = try http_request.respondStreaming(&body_buffer, .{
                .respond_options = .{
                    .status = reply.status,
                    .extra_headers = extra.items,
                    .keep_alive = false,
                },
            });
            for (reply.chunks) |chunk| {
                try body.writer.writeAll(chunk);
                try body.flush();
            }
            try body.end();
            try stream_writer.interface.flush();
            return;
        }

        try http_request.respond(reply.body, .{
            .status = reply.status,
            .extra_headers = extra.items,
            // One connection per exchange keeps the script and the accept loop
            // in step.
            .keep_alive = false,
        });
    }

    fn record(self: *Fixture, http_request: *std.http.Server.Request) !void {
        var headers: std.ArrayList(std.http.Header) = .empty;
        errdefer headers.deinit(self.gpa);

        var it = http_request.iterateHeaders();
        while (it.next()) |header| {
            try headers.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, header.name),
                .value = try self.gpa.dupe(u8, header.value),
            });
        }

        const method = http_request.head.method;
        const target = try self.gpa.dupe(u8, http_request.head.target);
        errdefer self.gpa.free(target);

        var body_buffer: [16 * 1024]u8 = undefined;
        const reader = http_request.readerExpectContinue(&body_buffer) catch |err| switch (err) {
            error.HttpExpectationFailed => return error.HttpExpectationFailed,
            else => |e| return e,
        };
        const body = try reader.allocRemaining(self.gpa, .limited(1 << 20));

        try self.recorded.append(self.gpa, .{
            .method = method,
            .target = target,
            .headers = try headers.toOwnedSlice(self.gpa),
            .body = body,
        });
        _ = self.recorded_count.fetchAdd(1, .release);
    }
};

/// Binds an ephemeral loopback port. `std.Io.net.Server` cannot report the
/// port the kernel picked, so a random one is chosen and retried on collision.
fn listenLoopback(io: std.Io) !struct { std.Io.net.Server, u16 } {
    // Tests in one binary run sequentially, but several binaries may run at
    // once, so the starting point is randomized.
    var seed: [2]u8 = undefined;
    io.random(&seed);
    const start = std.mem.readInt(u16, &seed, .little);

    var attempt: u16 = 0;
    while (attempt < 256) : (attempt += 1) {
        const port: u16 = 20_000 + (start +% attempt) % 40_000;
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        const server = std.Io.net.IpAddress.listen(&address, io, .{
            // A closed exchange leaves connections in TIME_WAIT; without this
            // a rebind of the same port fails.
            .reuse_address = true,
        }) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => continue,
            // Windows reserves port ranges -- Hyper-V and WSL exclude blocks
            // from the dynamic range, and GitHub's runners have them. Binding
            // inside one answers `WSAEACCES`, which arrives here as
            // `error.Unexpected` rather than as `AddressUnavailable`, so
            // without this the retry loop gives up on the first excluded port
            // it draws. That is a CI failure with nothing wrong in the code.
            error.Unexpected => if (native_os == .windows) continue else return err,
            else => |e| return e,
        };
        return .{ server, port };
    }
    return error.AddressInUse;
}

/// Client side of a test: an `std.Io`, an `std.http.Client`, and the `HttpBmc`
/// under test.
const Connection = struct {
    threaded: std.Io.Threaded,
    client: std.http.Client,
    bmc: HttpBmc,

    fn init(self: *Connection, gpa: std.mem.Allocator, base_url: []const u8, options: HttpBmc.Options) !void {
        self.threaded = .init(gpa, .{});
        self.client = .{ .allocator = gpa, .io = self.threaded.io() };
        self.bmc = try .init(gpa, &self.client, base_url, options);
    }

    fn deinit(self: *Connection) void {
        self.bmc.deinit();
        self.client.deinit();
        self.threaded.deinit();
    }
};

/// Runs `request` against a fixture serving `replies`, returning the response
/// allocated in `arena`.
fn exchange(
    arena: std.mem.Allocator,
    fixture: *Fixture,
    options: HttpBmc.Options,
    request: core.bmc.RawRequest,
) !core.bmc.RawResponse {
    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), options);
    defer connection.deinit();

    return connection.bmc.asTransport().send(arena, request);
}

test "GET carries the Redfish protocol headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"Id\":\"1\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }} },
    });
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .get,
        .uri = "/redfish/v1/Chassis/1",
    });

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("{\"Id\":\"1\"}", response.body);
    try testing.expectEqualStrings("W/\"abc\"", response.etag().?.value);

    const recorded = fixture.request(0);
    try testing.expectEqual(std.http.Method.GET, recorded.method);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", recorded.target);
    try testing.expectEqualStrings("4.0", recorded.header("OData-Version").?);
    // A bodiless request must not announce a content type.
    try testing.expectEqual(@as(?[]const u8, null), recorded.header("Content-Type"));
    try testing.expectEqual(@as(?[]const u8, null), recorded.header("Authorization"));
    try testing.expectEqualStrings("", recorded.body);
}

test "Basic credentials are sent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{ .body = "{}" }});
    defer fixture.deinit();

    _ = try exchange(
        arena.allocator(),
        fixture,
        .{ .credentials = .initBasic("root", "calvin") },
        .{ .method = .get, .uri = "/redfish/v1/" },
    );

    // "root:calvin" base64-encoded.
    try testing.expectEqualStrings(
        "Basic cm9vdDpjYWx2aW4=",
        fixture.request(0).header("Authorization").?,
    );
}

test "a session token is sent as X-Auth-Token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{ .body = "{}" }});
    defer fixture.deinit();

    _ = try exchange(
        arena.allocator(),
        fixture,
        .{ .credentials = .initToken("token-value") },
        .{ .method = .get, .uri = "/redfish/v1/" },
    );

    const recorded = fixture.request(0);
    try testing.expectEqualStrings("token-value", recorded.header("X-Auth-Token").?);
    try testing.expectEqual(@as(?[]const u8, null), recorded.header("Authorization"));
}

test "PATCH sends a conditional body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .status = .no_content },
    });
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .patch,
        .uri = "/redfish/v1/Chassis/1",
        .body = .{ .bytes = "{\"AssetTag\":\"rack-7\"}" },
        .if_match = .{ .value = "W/\"abc\"" },
    });

    try testing.expectEqual(@as(u16, 204), response.status);

    const recorded = fixture.request(0);
    try testing.expectEqual(std.http.Method.PATCH, recorded.method);
    try testing.expectEqualStrings("{\"AssetTag\":\"rack-7\"}", recorded.body);
    try testing.expectEqualStrings("application/json", recorded.header("Content-Type").?);
    try testing.expectEqualStrings("W/\"abc\"", recorded.header("If-Match").?);
}

test "a conditional GET reports 304 with no body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .status = .not_modified },
    });
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .get,
        .uri = "/redfish/v1/Chassis/1",
        .if_none_match = .{ .value = "W/\"abc\"" },
    });

    try testing.expectEqual(@as(u16, 304), response.status);
    try testing.expectEqualStrings("", response.body);
    try testing.expectEqualStrings("W/\"abc\"", fixture.request(0).header("If-None-Match").?);
}

test "202 exposes Location and Retry-After" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .accepted,
        .headers = &.{
            .{ .name = "Location", .value = "/redfish/v1/TaskService/Tasks/3" },
            .{ .name = "Retry-After", .value = "5" },
        },
    }});
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .post,
        .uri = "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        .body = .{ .bytes = "{\"ResetType\":\"On\"}" },
    });

    try testing.expectEqual(@as(u16, 202), response.status);
    try testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/3", response.location().?.value);
    try testing.expect(response.retryAfter().?.seconds.eql(.fromInt(5)));
}

test "extra headers are sent on every request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{ .body = "{}" }});
    defer fixture.deinit();

    _ = try exchange(
        arena.allocator(),
        fixture,
        .{ .extra_headers = &.{.{ .name = "X-Trace-Id", .value = "abc123" }} },
        .{
            .method = .get,
            .uri = "/redfish/v1/",
            .headers = &.{.{ .name = "X-Per-Request", .value = "yes" }},
        },
    );

    const recorded = fixture.request(0);
    try testing.expectEqualStrings("abc123", recorded.header("X-Trace-Id").?);
    try testing.expectEqualStrings("yes", recorded.header("X-Per-Request").?);
}

test "DELETE reaches the service" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{ .status = .no_content }});
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .delete,
        .uri = "/redfish/v1/SessionService/Sessions/2",
    });

    try testing.expectEqual(@as(u16, 204), response.status);
    try testing.expectEqual(std.http.Method.DELETE, fixture.request(0).method);
}

test "a same-origin redirect is followed and downgrades to GET" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{
            .status = .see_other,
            .headers = &.{.{ .name = "Location", .value = "/redfish/v1/Chassis/1" }},
        },
        .{ .body = "{\"Id\":\"1\"}" },
    });
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .post,
        .uri = "/redfish/v1/Chassis",
        .body = .{ .bytes = "{\"Name\":\"x\"}" },
    });

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("{\"Id\":\"1\"}", response.body);

    try testing.expectEqual(@as(usize, 2), fixture.requestCount());
    try testing.expectEqual(std.http.Method.POST, fixture.request(0).method);
    // 303 turns the follow-up into a bodiless GET.
    try testing.expectEqual(std.http.Method.GET, fixture.request(1).method);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", fixture.request(1).target);
    try testing.expectEqualStrings("", fixture.request(1).body);
}

test "307 preserves the method and body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{
            .status = .temporary_redirect,
            .headers = &.{.{ .name = "Location", .value = "/redfish/v1/Chassis/2" }},
        },
        .{ .status = .no_content },
    });
    defer fixture.deinit();

    const response = try exchange(arena.allocator(), fixture, .{}, .{
        .method = .patch,
        .uri = "/redfish/v1/Chassis/1",
        .body = .{ .bytes = "{\"AssetTag\":\"x\"}" },
    });

    try testing.expectEqual(@as(u16, 204), response.status);
    try testing.expectEqual(std.http.Method.PATCH, fixture.request(1).method);
    try testing.expectEqualStrings("{\"AssetTag\":\"x\"}", fixture.request(1).body);
}

test "a cross-origin redirect is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .found,
        .headers = &.{.{ .name = "Location", .value = "http://attacker.example/steal" }},
    }});
    defer fixture.deinit();

    try testing.expectError(
        Endpoint.ResolveError.CrossOriginUriReference,
        exchange(arena.allocator(), fixture, .{}, .{ .method = .get, .uri = "/redfish/v1/" }),
    );

    // The credentialed follow-up never left the process.
    try testing.expectEqual(@as(usize, 1), fixture.requestCount());
}

test "a redirect loop is bounded by max_redirects" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const loop: Reply = .{
        .status = .found,
        .headers = &.{.{ .name = "Location", .value = "/redfish/v1/" }},
    };
    const fixture = try Fixture.start(testing.allocator, &.{ loop, loop, loop, loop });
    defer fixture.deinit();

    try testing.expectError(
        HttpBmc.SendError.TooManyRedirects,
        exchange(
            arena.allocator(),
            fixture,
            .{ .max_redirects = 2 },
            .{ .method = .get, .uri = "/redfish/v1/" },
        ),
    );

    // The original request plus `max_redirects` follow-ups.
    try testing.expectEqual(@as(usize, 3), fixture.requestCount());
}

test "an oversized body is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const body = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(body);
    @memset(body, 'x');

    const fixture = try Fixture.start(testing.allocator, &.{.{ .body = body }});
    defer fixture.deinit();

    try testing.expectError(
        HttpBmc.SendError.ResponseTooLarge,
        exchange(
            arena.allocator(),
            fixture,
            .{ .max_response_bytes = 1024 },
            .{ .method = .get, .uri = "/redfish/v1/" },
        ),
    );
}

test "a failing response is captured in diagnostics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const error_body =
        \\{"error":{"code":"Base.1.0.PropertyValueNotInList","message":"Bad value."}}
    ;
    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .status = .bad_request, .body = error_body },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var diagnostics: transport.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    connection.bmc.diagnostics = &diagnostics;

    const Chassis = struct {
        @"@odata.id": []const u8,
        Id: []const u8,
    };
    try testing.expectError(
        core.bmc.Error.BadRequest,
        core.bmc.get(Chassis, testing.allocator, connection.bmc.asTransport(), .init("/redfish/v1/Chassis/1")),
    );

    try testing.expectEqual(@as(u16, 400), diagnostics.status);
    try testing.expectEqualStrings(error_body, diagnostics.body.?);
    try testing.expectEqualStrings(
        "PropertyValueNotInList",
        diagnostics.redfishError(arena.allocator()).?.codeName(),
    );
}

test "the typed layer decodes a resource end to end" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .body =
        \\{"@odata.id":"/redfish/v1/Chassis/1","@odata.etag":"W/\"9\"","Id":"1","Name":"Rack"}
        ,
        .headers = &.{.{ .name = "ETag", .value = "W/\"9\"" }},
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    const Chassis = struct {
        @"@odata.id": []const u8,
        @"@odata.etag": ?[]const u8 = null,
        Id: []const u8,
        Name: []const u8,
    };

    var chassis = try core.bmc.get(
        Chassis,
        testing.allocator,
        connection.bmc.asTransport(),
        .init("/redfish/v1/Chassis/1"),
    );
    defer chassis.deinit();

    try testing.expectEqualStrings("1", chassis.value.Id);
    try testing.expectEqualStrings("Rack", chassis.value.Name);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", chassis.value.@"@odata.id");
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", fixture.request(0).target);
}

test "a repeat GET revalidates and is served from the cache" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{
            .body = "{\"Id\":\"1\",\"AssetTag\":\"a\"}",
            .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }},
        },
        .{ .status = .not_modified, .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    const request: core.bmc.RawRequest = .{ .method = .get, .uri = "/redfish/v1/Chassis/1" };

    const first = try connection.bmc.asTransport().send(arena.allocator(), request);
    try testing.expectEqual(@as(u16, 200), first.status);
    try testing.expect(fixture.request(0).header("If-None-Match") == null);

    // The 304 never reaches the caller: it sees the body the 200 left behind.
    const second = try connection.bmc.asTransport().send(arena.allocator(), request);
    try testing.expectEqual(@as(u16, 200), second.status);
    try testing.expectEqualStrings("{\"Id\":\"1\",\"AssetTag\":\"a\"}", second.body);
    try testing.expectEqualStrings("W/\"abc\"", second.etag().?.value);
    try testing.expectEqualStrings("W/\"abc\"", fixture.request(1).header("If-None-Match").?);
}

test "a changed resource comes back as a fresh body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"AssetTag\":\"a\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"1\"" }} },
        .{ .body = "{\"AssetTag\":\"b\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"2\"" }} },
        .{ .status = .not_modified, .headers = &.{.{ .name = "ETag", .value = "W/\"2\"" }} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    const request: core.bmc.RawRequest = .{ .method = .get, .uri = "/redfish/v1/Chassis/1" };

    _ = try connection.bmc.asTransport().send(arena.allocator(), request);

    const changed = try connection.bmc.asTransport().send(arena.allocator(), request);
    try testing.expectEqualStrings("{\"AssetTag\":\"b\"}", changed.body);

    // The replacement is what gets revalidated next.
    const revalidated = try connection.bmc.asTransport().send(arena.allocator(), request);
    try testing.expectEqualStrings("W/\"2\"", fixture.request(2).header("If-None-Match").?);
    try testing.expectEqualStrings("{\"AssetTag\":\"b\"}", revalidated.body);
}

test "a disabled cache never sends If-None-Match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"Id\":\"1\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }} },
        .{ .body = "{\"Id\":\"1\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{ .cache = .disabled });
    defer connection.deinit();

    const request: core.bmc.RawRequest = .{ .method = .get, .uri = "/redfish/v1/Chassis/1" };
    _ = try connection.bmc.asTransport().send(arena.allocator(), request);
    _ = try connection.bmc.asTransport().send(arena.allocator(), request);

    try testing.expect(fixture.request(1).header("If-None-Match") == null);
    try testing.expectEqual(@as(usize, 0), connection.bmc.cache.count());
}

test "a caller's own precondition is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"Id\":\"1\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"abc\"" }} },
        .{ .status = .not_modified },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    _ = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .get,
        .uri = "/redfish/v1/Chassis/1",
    });

    // `getIfNoneMatch` exists so a caller can see the 304 itself. The cache
    // must not answer it, even though it holds this very resource.
    const response = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .get,
        .uri = "/redfish/v1/Chassis/1",
        .if_none_match = .{ .value = "W/\"caller\"" },
    });
    try testing.expectEqual(@as(u16, 304), response.status);
    try testing.expectEqualStrings("W/\"caller\"", fixture.request(1).header("If-None-Match").?);
}

test "a response with no ETag is not cached" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"Id\":\"1\"}" },
        .{ .body = "{\"Id\":\"1\"}" },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    const request: core.bmc.RawRequest = .{ .method = .get, .uri = "/redfish/v1/Chassis/1" };
    _ = try connection.bmc.asTransport().send(arena.allocator(), request);
    _ = try connection.bmc.asTransport().send(arena.allocator(), request);

    try testing.expect(fixture.request(1).header("If-None-Match") == null);
    try testing.expectEqual(@as(usize, 0), connection.bmc.cache.count());
}

test "an expanded read does not collide with the plain one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"Members@odata.count\":1}", .headers = &.{.{ .name = "ETag", .value = "W/\"1\"" }} },
        .{ .body = "{\"Members\":[{}]}", .headers = &.{.{ .name = "ETag", .value = "W/\"2\"" }} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    _ = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .get,
        .uri = "/redfish/v1/Chassis",
    });
    const expanded = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .get,
        .uri = "/redfish/v1/Chassis?$expand=.",
    });

    try testing.expect(fixture.request(1).header("If-None-Match") == null);
    try testing.expectEqualStrings("{\"Members\":[{}]}", expanded.body);
    try testing.expectEqual(@as(usize, 2), connection.bmc.cache.count());
}

test "a write is not cached and does not revalidate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .body = "{\"AssetTag\":\"a\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"1\"" }} },
        .{ .body = "{\"AssetTag\":\"b\"}", .headers = &.{.{ .name = "ETag", .value = "W/\"2\"" }} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    _ = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .get,
        .uri = "/redfish/v1/Chassis/1",
    });
    _ = try connection.bmc.asTransport().send(arena.allocator(), .{
        .method = .patch,
        .uri = "/redfish/v1/Chassis/1",
        .body = .{ .bytes = "{\"AssetTag\":\"b\"}" },
        .if_match = .{ .value = "W/\"1\"" },
    });

    try testing.expect(fixture.request(1).header("If-None-Match") == null);
    try testing.expectEqualStrings("W/\"1\"", fixture.request(1).header("If-Match").?);
    // The PATCH response replaced nothing; only the GET is held.
    try testing.expectEqual(@as(usize, 1), connection.bmc.cache.count());
}

test "an unsolicited 304 is refused rather than served empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{
        .{ .status = .not_modified },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    try testing.expectError(HttpBmc.SendError.UnexpectedNotModified, connection.bmc.asTransport().send(
        arena.allocator(),
        .{ .method = .get, .uri = "/redfish/v1/Chassis/1" },
    ));
}

test "an event stream is opened and read" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .content_type = "text/event-stream",
        .chunks = &.{
            "id: 1\ndata: {\"Id\":\"1\",\"EventType\":\"Alert\"}\n\n",
            ": heartbeat\n\n",
            "id: 2\ndata: {\"Id\":\"2\",\"EventType\":\"StatusChange\"}\n\n",
        },
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var stream = try core.bmc.stream(
        connection.bmc.asTransport(),
        "/redfish/v1/EventService/SSE",
    );
    defer stream.close();

    const recorded = fixture.request(0);
    try testing.expectEqual(std.http.Method.GET, recorded.method);
    try testing.expectEqualStrings("/redfish/v1/EventService/SSE", recorded.target);
    try testing.expectEqualStrings("text/event-stream", recorded.header("Accept").?);
    try testing.expectEqualStrings("4.0", recorded.header("OData-Version").?);

    var events: core.sse.EventReader = .init(testing.allocator, stream.reader, .{});
    defer events.deinit();

    const Payload = struct { Id: []const u8, EventType: []const u8 };

    var first = (try events.nextAs(Payload, testing.allocator)).?;
    defer first.deinit();
    try testing.expectEqualStrings("1", first.value.Id);
    try testing.expectEqualStrings("Alert", first.value.EventType);

    // The heartbeat comment produced no event, so the next one is the second
    // payload rather than a blank.
    var second = (try events.nextAs(Payload, testing.allocator)).?;
    defer second.deinit();
    try testing.expectEqualStrings("2", second.value.Id);
    try testing.expectEqualStrings("StatusChange", second.value.EventType);

    try testing.expectEqual(@as(?core.sse.Event, null), try events.next());
}

test "an event stream sends credentials" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .content_type = "text/event-stream",
        .chunks = &.{"data: {}\n\n"},
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{
        .credentials = .initToken("session-token"),
        .extra_headers = &.{.{ .name = "X-Vendor", .value = "acme" }},
    });
    defer connection.deinit();

    var stream = try core.bmc.stream(
        connection.bmc.asTransport(),
        "/redfish/v1/EventService/SSE",
    );
    stream.close();

    const recorded = fixture.request(0);
    try testing.expectEqualStrings("session-token", recorded.header("X-Auth-Token").?);
    try testing.expectEqualStrings("acme", recorded.header("X-Vendor").?);
}

test "an event stream follows a same-origin redirect" {
    const fixture = try Fixture.start(testing.allocator, &.{
        .{
            .status = .temporary_redirect,
            .headers = &.{.{ .name = "Location", .value = "/redfish/v1/EventService/Stream" }},
        },
        .{ .content_type = "text/event-stream", .chunks = &.{"data: moved\n\n"} },
    });
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var stream = try core.bmc.stream(
        connection.bmc.asTransport(),
        "/redfish/v1/EventService/SSE",
    );
    defer stream.close();

    var events: core.sse.EventReader = .init(testing.allocator, stream.reader, .{});
    defer events.deinit();

    try testing.expectEqualStrings("moved", (try events.next()).?.data);
    try testing.expectEqualStrings("/redfish/v1/EventService/Stream", fixture.request(1).target);
}

test "an event stream refuses a cross-origin redirect" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .temporary_redirect,
        .headers = &.{.{ .name = "Location", .value = "https://elsewhere.example/sse" }},
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    try testing.expectError(
        Endpoint.ResolveError.CrossOriginUriReference,
        core.bmc.stream(connection.bmc.asTransport(), "/redfish/v1/EventService/SSE"),
    );
}

test "a refused subscription reports the service's reason" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .service_unavailable,
        .body =
        \\{"error":{"code":"Base.1.0.ServiceUnavailable","message":"Try later"}}
        ,
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var diagnostics: transport.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    connection.bmc.diagnostics = &diagnostics;

    try testing.expectError(
        core.bmc.Error.ServiceError,
        core.bmc.stream(connection.bmc.asTransport(), "/redfish/v1/EventService/SSE"),
    );
    try testing.expectEqual(@as(u16, 503), diagnostics.status);
    try testing.expect(std.mem.indexOf(u8, diagnostics.body.?, "Try later") != null);
}

test "a multipart firmware push streams over the wire" {
    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .accepted,
        .headers = &.{.{ .name = "Location", .value = "/redfish/v1/TaskService/Tasks/9" }},
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    const image = "firmware-bytes" ** 64;
    var reader: std.Io.Reader = .fixed(image);
    var prng: std.Random.DefaultPrng = .init(7);

    const Task = struct {
        @"@odata.id": []const u8,
        TaskState: []const u8,
    };

    var result = try core.upload.multipartUpdate(
        Task,
        testing.allocator,
        connection.bmc.asTransport(),
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{ .Targets = [_][]const u8{"/redfish/v1/UpdateService/FirmwareInventory/BMC"} },
        .{ .name = "firmware.bin", .reader = &reader, .len = image.len },
        &.{},
        prng.random(),
    );
    defer result.deinit();

    const recorded = fixture.request(0);
    try testing.expectEqual(std.http.Method.POST, recorded.method);
    try testing.expect(std.mem.startsWith(
        u8,
        recorded.header("Content-Type").?,
        "multipart/form-data; boundary=",
    ));
    // Every part had a length, so the request was measured rather than
    // chunked — which is what a BMC that rejects chunked uploads needs.
    var length: [16]u8 = undefined;
    try testing.expectEqualStrings(
        recorded.header("Content-Length").?,
        try std.fmt.bufPrint(&length, "{d}", .{recorded.body.len}),
    );
    try testing.expect(std.mem.indexOf(u8, recorded.body, "name=\"UpdateParameters\"") != null);
    try testing.expect(std.mem.indexOf(u8, recorded.body, "filename=\"firmware.bin\"") != null);
    try testing.expect(std.mem.indexOf(u8, recorded.body, image) != null);

    try testing.expectEqualStrings(
        "/redfish/v1/TaskService/Tasks/9",
        result.value.task.location.value.value,
    );
}

test "an unmeasured upload is sent chunked" {
    const fixture = try Fixture.start(testing.allocator, &.{.{ .status = .no_content }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");

    var result = try core.upload.httpPushUriUpdate(
        struct {},
        testing.allocator,
        connection.bmc.asTransport(),
        .init("/redfish/v1/UpdateService/FirmwareInventory"),
        &image,
        null,
    );
    defer result.deinit();

    const recorded = fixture.request(0);
    try testing.expectEqualStrings("chunked", recorded.header("Transfer-Encoding").?);
    try testing.expect(recorded.header("Content-Length") == null);
    try testing.expectEqualStrings("application/octet-stream", recorded.header("Content-Type").?);
    try testing.expectEqualStrings("firmware-bytes", recorded.body);
    try testing.expect(result.value == .empty);
}

test "a raw push declares the length it was given" {
    const fixture = try Fixture.start(testing.allocator, &.{.{ .status = .no_content }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");

    var result = try core.upload.httpPushUriUpdate(
        struct {},
        testing.allocator,
        connection.bmc.asTransport(),
        .init("/redfish/v1/UpdateService/FirmwareInventory"),
        &image,
        "firmware-bytes".len,
    );
    defer result.deinit();

    const recorded = fixture.request(0);
    try testing.expectEqualStrings("14", recorded.header("Content-Length").?);
    try testing.expect(recorded.header("Transfer-Encoding") == null);
    try testing.expectEqualStrings("firmware-bytes", recorded.body);
}

test "a stream shorter than its declared length is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{ .status = .no_content }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var image: std.Io.Reader = .fixed("short");

    try testing.expectError(HttpBmc.SendError.UploadLengthMismatch, connection.bmc.asTransport().send(
        arena.allocator(),
        .{
            .method = .post,
            .uri = "/redfish/v1/UpdateService/FirmwareInventory",
            .body = .{ .stream = .{ .reader = &image, .len = 1000 } },
        },
    ));
}

test "a streamed body is not replayed across a preserving redirect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const fixture = try Fixture.start(testing.allocator, &.{.{
        .status = .temporary_redirect,
        .headers = &.{.{ .name = "Location", .value = "/redfish/v1/UpdateService/push" }},
    }});
    defer fixture.deinit();

    var connection: Connection = undefined;
    try connection.init(testing.allocator, fixture.baseUrl(), .{});
    defer connection.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");

    // 307 has to repeat the body, and a consumed stream cannot produce it
    // again, so the request fails rather than sending a truncated one.
    try testing.expectError(HttpBmc.SendError.StreamNotReplayable, connection.bmc.asTransport().send(
        arena.allocator(),
        .{
            .method = .post,
            .uri = "/redfish/v1/UpdateService/FirmwareInventory",
            .body = .{ .stream = .{ .reader = &image, .len = "firmware-bytes".len } },
        },
    ));
}
