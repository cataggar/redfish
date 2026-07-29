//! `MockBmc` — a `BmcTransport` driven by a queue of expectations.
//!
//! ```zig
//! var mock: MockBmc = .init(gpa);
//! defer mock.deinit();
//! try mock.expect(.get("/redfish/v1", "{\"@odata.id\":\"/redfish/v1\"}"));
//!
//! const root = try core.bmc.get(ServiceRoot, gpa, &mock.transport, .init("/redfish/v1"));
//! defer root.deinit();
//! try mock.verify();
//! ```
//!
//! Expectations are matched **in order**, exactly as `nv-redfish-bmc-mock`
//! matches its `VecDeque`. A request that does not match the next one is a
//! failure; the mock keeps the reason and prints it, because the error
//! itself surfaces at the caller as a bare `error.UnexpectedRequest`.

const std = @import("std");

const core = @import("redfish_core");

const expect_mod = @import("expect.zig");

const BmcTransport = core.bmc.BmcTransport;
const Expect = expect_mod.Expect;
const EventStream = core.bmc.EventStream;
const Header = core.bmc.Header;
const Method = core.bmc.Method;
const RawRequest = core.bmc.RawRequest;
const RawResponse = core.bmc.RawResponse;
const RequestMatch = expect_mod.RequestMatch;
const Response = expect_mod.Response;

pub const Error = error{
    /// A request arrived with the queue exhausted.
    NothingExpected,
    /// A request did not match the next expectation.
    UnexpectedRequest,
    /// `verify` found expectations that were never met.
    ExpectationsRemaining,
};

/// A request as the mock saw it, kept for after-the-fact assertions.
///
/// Every slice is owned by the mock and freed by `deinit`. A streamed body
/// is drained into memory, so `body` is the bytes the transport would have
/// put on the wire either way.
pub const Recorded = struct {
    method: Method,
    uri: []const u8,
    body: []const u8,
    content_type: []const u8,
    if_match: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    headers: []const Header = &.{},
    /// True for a `stream` call rather than a `send`.
    is_stream: bool = false,
    /// The length the caller declared for a streamed body, if any. Null for
    /// an in-memory body, whose length is never in doubt.
    declared_len: ?u64 = null,

    /// First value for `name`, matched case-insensitively.
    pub fn header(self: Recorded, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    /// The path, with any query string removed.
    pub fn path(self: Recorded) []const u8 {
        const mark = std.mem.indexOfScalar(u8, self.uri, '?') orelse self.uri.len;
        return self.uri[0..mark];
    }

    /// The query string, without the `?`, or null when there is none.
    pub fn queryString(self: Recorded) ?[]const u8 {
        const mark = std.mem.indexOfScalar(u8, self.uri, '?') orelse return null;
        return self.uri[mark + 1 ..];
    }

    pub fn format(self: Recorded, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.is_stream) {
            try w.print("STREAM {s}", .{self.uri});
            return;
        }
        try w.print("{s} {s}", .{ self.method.token(), self.uri });
        if (self.body.len > 0) try w.print(" body {s}", .{self.body});
        if (self.if_match) |etag| try w.print(" if-match {s}", .{etag});
        if (self.if_none_match) |etag| try w.print(" if-none-match {s}", .{etag});
    }
};

pub const MockBmc = struct {
    transport: BmcTransport = .{ .sendFn = &sendImpl, .streamFn = &streamImpl },
    gpa: std.mem.Allocator,
    /// Owns everything in `queue`'s recorded counterparts: request copies and
    /// the mismatch report.
    arena: std.heap.ArenaAllocator,
    queue: std.ArrayList(Expect) = .empty,
    /// Index of the next expectation.
    cursor: usize = 0,
    requests: std.ArrayList(Recorded) = .empty,
    /// The first mismatch, already formatted. Set once and kept, because a
    /// later request may fail as a consequence of this one.
    mismatch: ?[]const u8 = null,
    /// Suppress printing the mismatch report. For tests *of* the mock.
    quiet: bool = false,

    pub fn init(gpa: std.mem.Allocator) MockBmc {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *MockBmc) void {
        self.queue.deinit(self.gpa);
        self.requests.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Queue one expectation.
    pub fn expect(self: *MockBmc, expectation: Expect) !void {
        try self.queue.append(self.gpa, expectation);
    }

    /// Queue several, in order.
    pub fn expectAll(self: *MockBmc, expectations: []const Expect) !void {
        try self.queue.appendSlice(self.gpa, expectations);
    }

    /// Expectations that have not been met yet.
    pub fn pending(self: *const MockBmc) usize {
        return self.queue.items.len - self.cursor;
    }

    /// Requests the mock has seen, matched or not.
    pub fn requestCount(self: *const MockBmc) usize {
        return self.requests.items.len;
    }

    pub fn request(self: *const MockBmc, index: usize) Recorded {
        return self.requests.items[index];
    }

    pub fn lastRequest(self: *const MockBmc) ?Recorded {
        if (self.requests.items.len == 0) return null;
        return self.requests.items[self.requests.items.len - 1];
    }

    /// Fail unless every expectation was met and none was violated. Call it
    /// at the end of a test: an operation that is never performed is just as
    /// much a bug as one performed wrongly.
    pub fn verify(self: *MockBmc) Error!void {
        if (self.mismatch != null) return Error.UnexpectedRequest;
        if (self.pending() == 0) return;

        self.report("{d} expectation(s) were never met:", .{self.pending()});
        for (self.queue.items[self.cursor..], 0..) |expectation, offset| {
            self.report("  [{d}] {f}", .{ self.cursor + offset, expectation });
        }
        return Error.ExpectationsRemaining;
    }

    /// The mismatch report, when there is one. Useful for asserting on the
    /// mock's own behavior.
    pub fn mismatchReport(self: *const MockBmc) ?[]const u8 {
        return self.mismatch;
    }

    fn report(self: *const MockBmc, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        std.debug.print("mock: " ++ fmt ++ "\n", args);
    }

    /// Record the mismatch, print it, and return the error. The first one
    /// wins: later requests are usually collateral damage.
    fn fail(
        self: *MockBmc,
        err: Error,
        comptime reason: []const u8,
        args: anytype,
    ) Error {
        if (self.mismatch == null) {
            self.mismatch = std.fmt.allocPrint(self.arena.allocator(), reason, args) catch
                "mismatch (out of memory while formatting the report)";
            self.report("{s}", .{self.mismatch.?});
        }
        return err;
    }

    fn take(self: *MockBmc) ?Expect {
        if (self.cursor >= self.queue.items.len) return null;
        defer self.cursor += 1;
        return self.queue.items[self.cursor];
    }

    fn sendImpl(
        transport: *BmcTransport,
        arena: std.mem.Allocator,
        raw_request: RawRequest,
    ) anyerror!RawResponse {
        const self: *MockBmc = @fieldParentPtr("transport", transport);

        const recorded = try self.record(raw_request);
        const index = self.cursor;
        const expectation = self.take() orelse return self.fail(
            Error.NothingExpected,
            "no expectation left for {f}",
            .{recorded},
        );

        const expected = switch (expectation) {
            .request => |value| value,
            .event_stream => return self.fail(
                Error.UnexpectedRequest,
                "expectation [{d}] is {f}, but the client sent {f}",
                .{ index, expectation, recorded },
            ),
        };

        if (!try self.matches(expected.match, recorded)) return self.fail(
            Error.UnexpectedRequest,
            "expectation [{d}] is {f}, but the client sent {f}",
            .{ index, expectation, recorded },
        );

        return switch (expected.reply) {
            .failure => |err| err,
            .response => |response| render(arena, response),
        };
    }

    fn streamImpl(transport: *BmcTransport, uri: []const u8) anyerror!EventStream {
        const self: *MockBmc = @fieldParentPtr("transport", transport);

        const recorded = try self.recordStream(uri);
        const index = self.cursor;
        const expectation = self.take() orelse return self.fail(
            Error.NothingExpected,
            "no expectation left for {f}",
            .{recorded},
        );

        const expected = switch (expectation) {
            .event_stream => |value| value,
            .request => return self.fail(
                Error.UnexpectedRequest,
                "expectation [{d}] is {f}, but the client sent {f}",
                .{ index, expectation, recorded },
            ),
        };

        if (!expected.uri.matches(uri)) return self.fail(
            Error.UnexpectedRequest,
            "expectation [{d}] is {f}, but the client sent {f}",
            .{ index, expectation, recorded },
        );

        return switch (expected.reply) {
            .failure => |err| err,
            .body => |body| self.openStream(body),
        };
    }

    fn matches(self: *MockBmc, match: RequestMatch, recorded: Recorded) !bool {
        if (match.method) |method| {
            if (method != recorded.method) return false;
        }
        if (!match.uri.matches(recorded.uri)) return false;
        if (!try match.body.matches(self.gpa, recorded.body)) return false;
        if (match.content_type) |content_type| {
            if (!std.mem.eql(u8, content_type, recorded.content_type)) return false;
        }
        if (!match.if_match.matches(asEtag(recorded.if_match))) return false;
        if (!match.if_none_match.matches(asEtag(recorded.if_none_match))) return false;
        for (match.headers) |wanted| {
            const actual = recorded.header(wanted.name) orelse return false;
            if (!std.mem.eql(u8, wanted.value, actual)) return false;
        }
        return true;
    }

    /// Copy a request into the mock's arena, draining a streamed body so it
    /// can be matched and asserted on like any other.
    fn record(self: *MockBmc, raw_request: RawRequest) !Recorded {
        const arena = self.arena.allocator();

        var body: []const u8 = &.{};
        var declared_len: ?u64 = null;
        switch (raw_request.body) {
            .bytes => |bytes| body = try arena.dupe(u8, bytes),
            .stream => |source| {
                declared_len = source.len;
                var collected: std.Io.Writer.Allocating = .init(arena);
                _ = try source.reader.streamRemaining(&collected.writer);
                body = collected.written();
            },
        }

        const headers = try arena.alloc(Header, raw_request.headers.len);
        for (raw_request.headers, headers) |source, *copy| {
            copy.* = .{
                .name = try arena.dupe(u8, source.name),
                .value = try arena.dupe(u8, source.value),
            };
        }

        const recorded: Recorded = .{
            .method = raw_request.method,
            .uri = try arena.dupe(u8, raw_request.uri),
            .body = body,
            .content_type = try arena.dupe(u8, raw_request.content_type),
            .if_match = if (raw_request.if_match) |etag| try arena.dupe(u8, etag.value) else null,
            .if_none_match = if (raw_request.if_none_match) |etag|
                try arena.dupe(u8, etag.value)
            else
                null,
            .headers = headers,
            .declared_len = declared_len,
        };
        try self.requests.append(self.gpa, recorded);
        return recorded;
    }

    fn recordStream(self: *MockBmc, uri: []const u8) !Recorded {
        const recorded: Recorded = .{
            .method = .get,
            .uri = try self.arena.allocator().dupe(u8, uri),
            .body = &.{},
            .content_type = "text/event-stream",
            .is_stream = true,
        };
        try self.requests.append(self.gpa, recorded);
        return recorded;
    }

    /// An event stream served from memory.
    ///
    /// The state is heap-allocated because the reader outlives this call and
    /// `EventStream.reader` points at it. `closeFn` is handed the caller's
    /// own copy of the `EventStream`, so the state is reached through
    /// `context` rather than `@fieldParentPtr`.
    fn openStream(self: *MockBmc, body: []const u8) !EventStream {
        const state = try self.gpa.create(StreamState);
        state.* = .{ .gpa = self.gpa, .reader = .fixed(body) };
        return .{
            .reader = &state.reader,
            .context = state,
            .closeFn = &StreamState.closeImpl,
        };
    }

    const StreamState = struct {
        gpa: std.mem.Allocator,
        reader: std.Io.Reader,

        fn closeImpl(stream: *EventStream) void {
            const state: *StreamState = @ptrCast(@alignCast(stream.context.?));
            state.gpa.destroy(state);
        }
    };
};

fn asEtag(value: ?[]const u8) ?core.ODataETag {
    return if (value) |text| .init(text) else null;
}

/// Turn an expected `Response` into what the transport would have returned,
/// allocating in the operation's arena as a real transport does.
fn render(arena: std.mem.Allocator, response: Response) !RawResponse {
    var headers: std.ArrayList(Header) = .empty;

    if (response.body.len > 0 or response.content_type != null) {
        try headers.append(arena, .{
            .name = "Content-Type",
            .value = response.content_type orelse "application/json",
        });
    }
    if (response.etag) |etag| {
        try headers.append(arena, .{ .name = "ETag", .value = etag });
    }
    if (response.location) |location| {
        try headers.append(arena, .{ .name = "Location", .value = location });
    }
    if (response.auth_token) |token| {
        try headers.append(arena, .{ .name = "X-Auth-Token", .value = token });
    }
    if (response.retry_after) |seconds| {
        try headers.append(arena, .{
            .name = "Retry-After",
            .value = try std.fmt.allocPrint(arena, "{d}", .{seconds}),
        });
    }
    try headers.appendSlice(arena, response.headers);

    return .{
        .status = response.status,
        .headers = .{ .entries = try headers.toOwnedSlice(arena) },
        .body = try arena.dupe(u8, response.body),
    };
}

const testing = std.testing;

const ServiceRoot = struct {
    @"@odata.id": core.ODataId,
    Id: []const u8,
    Name: []const u8,
};

const Chassis = struct {
    @"@odata.id": core.ODataId,
    @"@odata.etag": ?core.ODataETag = null,
    Id: []const u8,
    IndicatorLED: ?[]const u8 = null,
};

test "a queued get is answered and verified" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.get("/redfish/v1",
        \\{"@odata.id":"/redfish/v1","Id":"RootService","Name":"Root Service"}
    ));

    const root = try core.bmc.get(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1"),
    );
    defer root.deinit();

    try testing.expectEqualStrings("RootService", root.value.Id);
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
    try testing.expectEqual(core.bmc.Method.get, mock.request(0).method);
    try mock.verify();
}

test "expectations are matched in order" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expectAll(&.{
        .get("/redfish/v1/Chassis/1",
            \\{"@odata.id":"/redfish/v1/Chassis/1","Id":"1"}
        ),
        .get("/redfish/v1/Chassis/2",
            \\{"@odata.id":"/redfish/v1/Chassis/2","Id":"2"}
        ),
    });

    for ([_][]const u8{ "/redfish/v1/Chassis/1", "/redfish/v1/Chassis/2" }) |uri| {
        const chassis = try core.bmc.get(Chassis, testing.allocator, &mock.transport, .init(uri));
        defer chassis.deinit();
        try testing.expectEqualStrings(uri, chassis.value.@"@odata.id".value);
    }
    try mock.verify();
}

test "an out-of-order request is a mismatch with a report" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();
    mock.quiet = true;

    try mock.expect(.get("/redfish/v1/Chassis/1", "{}"));

    try testing.expectError(Error.UnexpectedRequest, core.bmc.get(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Chassis/2"),
    ));

    const report = mock.mismatchReport() orelse return error.TestExpectedReport;
    try testing.expect(std.mem.indexOf(u8, report, "/redfish/v1/Chassis/1") != null);
    try testing.expect(std.mem.indexOf(u8, report, "/redfish/v1/Chassis/2") != null);
    try testing.expectError(Error.UnexpectedRequest, mock.verify());
}

test "a request with nothing expected fails" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();
    mock.quiet = true;

    try testing.expectError(Error.NothingExpected, core.bmc.get(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1"),
    ));
}

test "an unmet expectation fails verification" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();
    mock.quiet = true;

    try mock.expect(.get("/redfish/v1", "{}"));
    try testing.expectEqual(@as(usize, 1), mock.pending());
    try testing.expectError(Error.ExpectationsRemaining, mock.verify());
}

test "a patch matches its payload as json, not as text" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.patch("/redfish/v1/Chassis/1",
        \\{ "IndicatorLED" : "Lit" }
    ,
        \\{"@odata.id":"/redfish/v1/Chassis/1","Id":"1","IndicatorLED":"Lit"}
    ));

    const updated = try core.bmc.update(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Chassis/1"),
        null,
        .{ .IndicatorLED = "Lit" },
    );
    defer updated.deinit();

    try testing.expectEqualStrings("Lit", updated.value.entity.IndicatorLED.?);
    try mock.verify();
}

test "a conditional patch carries the entity's etag" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.{ .request = .{
        .match = .{
            .method = .patch,
            .uri = .{ .exact = "/redfish/v1/Chassis/1" },
            .body = .{ .json = "{\"IndicatorLED\":\"Off\"}" },
            .if_match = .{ .value = "\"abc\"" },
        },
        .reply = .{ .response = .{ .status = 204 } },
    } });

    const chassis: Chassis = .{
        .@"@odata.id" = .init("/redfish/v1/Chassis/1"),
        .@"@odata.etag" = .init("\"abc\""),
        .Id = "1",
    };
    const updated = try core.bmc.updateEntity(
        Chassis,
        testing.allocator,
        &mock.transport,
        chassis,
        .{ .IndicatorLED = "Off" },
    );
    defer updated.deinit();

    try testing.expect(updated.value == .empty);
    try testing.expectEqualStrings("\"abc\"", mock.request(0).if_match.?);
    try mock.verify();
}

test "an accepted write comes back as a task" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.patchAccepted(
        "/redfish/v1/Systems/1",
        "{\"AssetTag\":\"rack-3\"}",
        "/redfish/v1/TaskService/Tasks/7",
    ));

    const updated = try core.bmc.update(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Systems/1"),
        null,
        .{ .AssetTag = "rack-3" },
    );
    defer updated.deinit();

    try testing.expectEqualStrings(
        "/redfish/v1/TaskService/Tasks/7",
        updated.value.task.location.value.value,
    );
    try mock.verify();
}

test "a session create surfaces the token and location" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.session("/redfish/v1/SessionService/Sessions",
        \\{"UserName":"admin","Password":"hunter2"}
    , "token-abc", "/redfish/v1/SessionService/Sessions/9",
        \\{"@odata.id":"/redfish/v1/SessionService/Sessions/9","Id":"9","Name":"Session"}
    ));

    const created = try core.bmc.createSession(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/SessionService/Sessions"),
        .{ .UserName = "admin", .Password = "hunter2" },
    );
    defer created.deinit();

    try testing.expectEqualStrings("token-abc", created.value.auth_token);
    try testing.expectEqualStrings(
        "/redfish/v1/SessionService/Sessions/9",
        created.value.location.value,
    );
    try mock.verify();
}

test "a non-2xx reply reaches the caller as a typed error" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.status("/redfish/v1/Chassis/nope", 404));

    try testing.expectError(core.bmc.Error.ResourceNotFound, core.bmc.get(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Chassis/nope"),
    ));
    try mock.verify();
}

test "a transport failure is injectable" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.failure("/redfish/v1", error.ConnectionRefused));

    try testing.expectError(error.ConnectionRefused, core.bmc.get(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1"),
    ));
    try mock.verify();
}

test "an expand records the query the operation appended" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.expand("/redfish/v1/Chassis",
        \\{"@odata.id":"/redfish/v1/Chassis","Id":"Chassis"}
    ));

    const collection = try core.bmc.expand(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Chassis"),
        .all(1),
    );
    defer collection.deinit();

    const recorded = mock.request(0);
    try testing.expectEqualStrings("/redfish/v1/Chassis", recorded.path());
    try testing.expect(std.mem.startsWith(u8, recorded.queryString().?, "$expand="));
    try mock.verify();
}

test "an event stream is served from memory" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.stream("/redfish/v1/EventService/SSE",
        \\event: Alert
        \\data: {"Id":"1"}
        \\
        \\
    ));

    var stream = try core.bmc.stream(&mock.transport, "/redfish/v1/EventService/SSE");
    defer stream.close();

    var events: core.EventReader = .init(testing.allocator, stream.reader, .{});
    defer events.deinit();
    const event = (try events.next()) orelse return error.TestExpectedEvent;

    try testing.expectEqualStrings("Alert", event.name);
    try testing.expectEqualStrings("{\"Id\":\"1\"}", event.data);
    try testing.expect(mock.request(0).is_stream);
    try mock.verify();
}

test "a stream call that was not expected is a mismatch" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();
    mock.quiet = true;

    try mock.expect(.get("/redfish/v1", "{}"));
    try testing.expectError(
        Error.UnexpectedRequest,
        core.bmc.stream(&mock.transport, "/redfish/v1"),
    );
}

test "a streamed upload body is drained and matched" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.{ .request = .{
        .match = .{
            .method = .post,
            .uri = .{ .exact = "/redfish/v1/UpdateService/upload" },
            .body = .{ .bytes = "firmware-bytes" },
        },
        .reply = .{ .response = .{ .status = 202, .location = "/redfish/v1/TaskService/Tasks/1" } },
    } });

    var image: std.Io.Reader = .fixed("firmware-bytes");
    const Task = struct { @"@odata.id": []const u8 };
    const result = try core.upload.httpPushUriUpdate(
        Task,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/UpdateService/upload"),
        &image,
        "firmware-bytes".len,
    );
    defer result.deinit();

    const recorded = mock.request(0);
    try testing.expectEqualStrings("firmware-bytes", recorded.body);
    try testing.expectEqual(@as(?u64, "firmware-bytes".len), recorded.declared_len);
    try mock.verify();
}

test "a multipart update is matched by its part headers" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.{ .request = .{
        .match = .{
            .method = .post,
            .uri = .{ .exact = "/redfish/v1/UpdateService/update-multipart" },
            .body = .{ .contains = "name=\"UpdateParameters\"" },
        },
        .reply = .{ .response = .{ .status = 204 } },
    } });

    var image: std.Io.Reader = .fixed("firmware-bytes");
    var prng: std.Random.DefaultPrng = .init(7);
    const Task = struct { @"@odata.id": []const u8 };

    const result = try core.upload.multipartUpdate(
        Task,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{ .Targets = [_][]const u8{"/redfish/v1/UpdateService/FirmwareInventory/BMC"} },
        .{ .name = "firmware.bin", .reader = &image, .len = "firmware-bytes".len },
        &.{},
        prng.random(),
    );
    defer result.deinit();

    try testing.expect(std.mem.startsWith(
        u8,
        mock.request(0).content_type,
        "multipart/form-data; boundary=",
    ));
    try testing.expect(std.mem.indexOf(u8, mock.request(0).body, "firmware-bytes") != null);
    try mock.verify();
}

test "a header expectation must be present on the request" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();
    mock.quiet = true;

    try mock.expect(.{ .request = .{
        .match = .{
            .uri = .{ .exact = "/redfish/v1" },
            .headers = &.{.{ .name = "OData-Version", .value = "4.0" }},
        },
        .reply = .{ .response = .{ .body = "{}" } },
    } });

    // The typed layer does not add default headers; that is the transport's
    // job, and this mock is the transport.
    try testing.expectError(Error.UnexpectedRequest, core.bmc.get(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1"),
    ));
}

test "a delete is answered with no content" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.delete("/redfish/v1/SessionService/Sessions/9"));

    const removed = try core.bmc.delete(
        ServiceRoot,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/SessionService/Sessions/9"),
    );
    defer removed.deinit();

    try testing.expect(removed.value == .empty);
    try testing.expectEqual(core.bmc.Method.delete, mock.lastRequest().?.method);
    try mock.verify();
}

test "an error body reaches the caller through the typed layer" {
    var mock: MockBmc = .init(testing.allocator);
    defer mock.deinit();

    try mock.expect(.errorBody("/redfish/v1/Chassis/1", 400,
        \\{"error":{"code":"Base.1.0.GeneralError","message":"bad request"}}
    ));

    try testing.expectError(core.bmc.Error.BadRequest, core.bmc.get(
        Chassis,
        testing.allocator,
        &mock.transport,
        .init("/redfish/v1/Chassis/1"),
    ));
    try mock.verify();
}
