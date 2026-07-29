//! The BMC transport interface and the typed operations layered on it.
//!
//! `nv-redfish` has one `Bmc` trait whose methods are generic over the
//! resource type. Zig cannot put a generic method in a vtable, so the same
//! surface is split in two:
//!
//!   * `BmcTransport` — a runtime interface over **bytes**. One `send`
//!     function pointer, plus an optional `stream` for `text/event-stream`.
//!     Implemented by `redfish_bmc_http` and `redfish_bmc_mock`.
//!   * The free functions in this file — generic over the resource type,
//!     monomorphized at the call site. They build the request, call the
//!     transport, check the status, and decode the body.
//!
//! ```zig
//! const chassis = try bmc.get(Chassis, gpa, transport, .init("/redfish/v1/Chassis/1"));
//! defer chassis.deinit();
//! ```
//!
//! Every operation allocates one arena, and the returned `Owned(T)` carries
//! it. The raw response bytes and the decoded tree share that arena, so a
//! decoded string can point straight into the response body with no copy.
//!
//! Reference: DMTF DSP0266, "Protocol details".

const std = @import("std");

const action_mod = @import("action.zig");
const edm = @import("edm.zig");
const entity = @import("entity.zig");
const odata = @import("odata.zig");
const owned_mod = @import("owned.zig");
const query_mod = @import("query.zig");
const response_mod = @import("response.zig");

const Action = action_mod.Action;
const AsyncTask = response_mod.AsyncTask;
const Duration = edm.Duration;
const ExpandQuery = query_mod.ExpandQuery;
const ModificationResponse = response_mod.ModificationResponse;
const ODataETag = odata.ODataETag;
const ODataId = odata.ODataId;
const Owned = owned_mod.Owned;
const QueryOptions = query_mod.QueryOptions;
const SessionCreateResponse = response_mod.SessionCreateResponse;

/// The HTTP methods Redfish uses.
pub const Method = enum {
    get,
    post,
    patch,
    put,
    delete,

    /// The method name as it appears on the wire.
    pub fn token(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .patch => "PATCH",
            .put => "PUT",
            .delete => "DELETE",
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Response headers, in the order the service sent them.
///
/// A slice rather than a map: a Redfish response carries a handful of
/// headers and is read once, so a linear scan beats building a map.
pub const Headers = struct {
    entries: []const Header = &.{},

    pub const empty: Headers = .{};

    /// First value for `name`, matched case-insensitively per RFC 9110.
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.entries) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }

    pub fn has(self: Headers, name: []const u8) bool {
        return self.get(name) != null;
    }
};

/// A request as the transport sees it: a URI and an already-encoded body.
pub const RawRequest = struct {
    method: Method,
    /// A Redfish URI reference — either absolute, or an absolute path such as
    /// `/redfish/v1/Chassis`. The transport resolves it against its own base
    /// and may reject references that violate its outbound policy.
    uri: []const u8,
    /// The encoded request body. Empty for GET and DELETE.
    body: []const u8 = &.{},
    /// `Content-Type` for `body`. Ignored when the body is empty.
    content_type: []const u8 = "application/json",
    /// Sent as `If-Match`, making the write conditional on the resource not
    /// having changed.
    if_match: ?ODataETag = null,
    /// Sent as `If-None-Match`, making a read conditional. A matching
    /// resource comes back as `304 Not Modified` with no body.
    if_none_match: ?ODataETag = null,
    /// Extra headers, appended after the transport's own defaults.
    headers: []const Header = &.{},
};

/// A response as the transport delivers it, before any decoding.
///
/// `headers` and `body` are allocated in the arena passed to `send` and are
/// valid for as long as that arena is.
pub const RawResponse = struct {
    status: u16,
    headers: Headers = .empty,
    body: []const u8 = &.{},

    pub fn isSuccess(self: RawResponse) bool {
        return self.status >= 200 and self.status < 300;
    }

    pub fn header(self: RawResponse, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// `ETag`, for feeding back as `If-Match` on the next write.
    pub fn etag(self: RawResponse) ?ODataETag {
        return .init(self.header("ETag") orelse return null);
    }

    /// `Location`, which carries the new resource on a create and the task
    /// monitor on a `202 Accepted`.
    pub fn location(self: RawResponse) ?ODataId {
        return .init(self.header("Location") orelse return null);
    }

    /// `Retry-After` as a duration.
    ///
    /// Only the delta-seconds form is understood. RFC 9110 also allows an
    /// HTTP-date, which needs a clock to turn into a delay; that yields null,
    /// and callers should fall back to their own backoff.
    pub fn retryAfter(self: RawResponse) ?Duration {
        const value = std.mem.trim(u8, self.header("Retry-After") orelse return null, " \t");
        const seconds = std.fmt.parseInt(u32, value, 10) catch return null;
        return .fromWholeSeconds(seconds);
    }
};

/// A read of a `text/event-stream`, for `EventService` server-sent events.
///
/// Borrows a reader owned by the transport. `close` releases the underlying
/// connection and must be called exactly once.
pub const EventStream = struct {
    reader: *std.Io.Reader,
    context: ?*anyopaque = null,
    closeFn: *const fn (self: *EventStream) void,

    pub fn close(self: *EventStream) void {
        self.closeFn(self);
    }
};

/// The runtime interface a BMC connection implements.
///
/// Embed this in the implementation and recover the implementation with
/// `@fieldParentPtr`:
///
/// ```zig
/// const MockBmc = struct {
///     transport: BmcTransport = .{ .sendFn = &send },
///
///     fn send(t: *BmcTransport, arena: std.mem.Allocator, request: RawRequest) anyerror!RawResponse {
///         const self: *MockBmc = @fieldParentPtr("transport", t);
///         ...
///     }
/// };
/// ```
///
/// `anyerror` is deliberate. `nv-redfish` gives the `Bmc` trait an associated
/// `Error` type; a Zig function pointer has to name one concrete error set,
/// so the open set is what lets an implementation surface its own failures
/// (TLS, DNS, a mock's expectation mismatch) without this file enumerating
/// them.
pub const BmcTransport = struct {
    /// Perform one request. Anything the response points at must be
    /// allocated in `arena`.
    sendFn: *const fn (
        self: *BmcTransport,
        arena: std.mem.Allocator,
        request: RawRequest,
    ) anyerror!RawResponse,

    /// Open a `text/event-stream`. Null when the transport cannot stream, in
    /// which case `stream` fails with `error.StreamingUnsupported`.
    streamFn: ?*const fn (
        self: *BmcTransport,
        uri: []const u8,
    ) anyerror!EventStream = null,

    pub fn send(
        self: *BmcTransport,
        arena: std.mem.Allocator,
        request: RawRequest,
    ) anyerror!RawResponse {
        return self.sendFn(self, arena, request);
    }

    pub fn stream(self: *BmcTransport, uri: []const u8) anyerror!EventStream {
        const streamFn = self.streamFn orelse return Error.StreamingUnsupported;
        return streamFn(self, uri);
    }
};

/// Failures the typed layer raises on its own, on top of whatever the
/// transport returns.
pub const Error = error{
    /// 304. Only reachable when the request carried `If-None-Match`; the
    /// caller's cached copy is still current.
    NotModified,
    /// 400.
    BadRequest,
    /// 401 — no credentials, or credentials the service rejected.
    Unauthorized,
    /// 403 — authenticated, but not permitted.
    Forbidden,
    /// 404.
    ResourceNotFound,
    /// 405.
    MethodNotAllowed,
    /// 409 — the request conflicts with the resource's current state.
    Conflict,
    /// 412 — `If-Match` did not match; re-read and retry.
    PreconditionFailed,
    /// 415.
    UnsupportedMediaType,
    /// 429 — the service is rate limiting.
    TooManyRequests,
    /// 500, 501, 502, 503, 504.
    ServiceError,
    /// Any other non-2xx status.
    UnexpectedStatus,
    /// A 2xx that should have carried a body did not.
    MissingResponseBody,
    /// `202 Accepted` with no `Location`, so there is no task to poll.
    MissingTaskLocation,
    /// A session was created but the service returned no `X-Auth-Token`.
    MissingAuthToken,
    /// A session was created but the service returned no `Location`, so
    /// there is no URI to delete at logout.
    MissingSessionLocation,
    /// The transport cannot open event streams.
    StreamingUnsupported,
};

/// Map a non-2xx status onto `Error`. Returns null for 2xx.
pub fn statusError(status: u16) ?Error {
    if (status >= 200 and status < 300) return null;
    return switch (status) {
        304 => Error.NotModified,
        400 => Error.BadRequest,
        401 => Error.Unauthorized,
        403 => Error.Forbidden,
        404 => Error.ResourceNotFound,
        405 => Error.MethodNotAllowed,
        409 => Error.Conflict,
        412 => Error.PreconditionFailed,
        415 => Error.UnsupportedMediaType,
        429 => Error.TooManyRequests,
        500, 501, 502, 503, 504 => Error.ServiceError,
        else => Error.UnexpectedStatus,
    };
}

/// An arena plus the raw response that lives in it, so an operation can hand
/// both to a decoder and then transfer the arena into the `Owned` result.
const Operation = struct {
    arena: *std.heap.ArenaAllocator,
    raw: RawResponse,

    fn begin(
        gpa: std.mem.Allocator,
        transport: *BmcTransport,
        request: RawRequest,
    ) anyerror!Operation {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const raw = try transport.send(arena.allocator(), request);
        return .{ .arena = arena, .raw = raw };
    }

    fn allocator(self: Operation) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn abort(self: Operation) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    /// Decode the body into the operation's own arena, so the decoded tree
    /// borrows the response bytes instead of copying them.
    fn decode(self: Operation, comptime T: type) !T {
        if (self.raw.body.len == 0) return Error.MissingResponseBody;
        return std.json.parseFromSliceLeaky(
            T,
            self.allocator(),
            self.raw.body,
            .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = true },
        );
    }
};

/// Build the request URI for `id` with `options` appended, in `arena`.
///
/// Returns `id.value` unchanged when no option is set, which avoids a copy on
/// the overwhelmingly common plain GET.
fn requestUri(
    arena: std.mem.Allocator,
    id: ODataId,
    options: QueryOptions,
) std.mem.Allocator.Error![]const u8 {
    if (options.isEmpty()) return id.value;
    return std.fmt.allocPrint(arena, "{s}{f}", .{ id.value, options });
}

/// GET the resource at `id`.
///
/// The result owns its arena; one `deinit` frees the decoded tree and the
/// response bytes it borrows from.
pub fn get(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
) !Owned(T) {
    return getWithOptions(T, gpa, transport, id, .none);
}

/// GET the resource at `id` with `$expand`, so navigation properties come
/// back inline instead of as references.
pub fn expand(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    query: ExpandQuery,
) !Owned(T) {
    return getWithOptions(T, gpa, transport, id, .{ .expand = query });
}

/// GET the collection at `id` with `$filter`.
///
/// `expression` is a filter without the `$filter=` prefix, normally
/// `FilterQuery.expression()`.
pub fn filter(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    expression: []const u8,
) !Owned(T) {
    return getWithOptions(T, gpa, transport, id, .{ .filter = expression });
}

/// GET the resource at `id` with an arbitrary set of query parameters.
pub fn getWithOptions(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    options: QueryOptions,
) !Owned(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const uri = try requestUri(arena.allocator(), id, options);
    const raw = try transport.send(arena.allocator(), .{ .method = .get, .uri = uri });
    if (statusError(raw.status)) |err| return err;

    const operation: Operation = .{ .arena = arena, .raw = raw };
    return .adopt(arena, try operation.decode(T));
}

/// Conditional GET: returns `error.NotModified` when the resource still
/// matches `etag`, so the caller can keep its cached copy.
pub fn getIfNoneMatch(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    etag: ODataETag,
) !Owned(T) {
    const operation = try Operation.begin(gpa, transport, .{
        .method = .get,
        .uri = id.value,
        .if_none_match = etag,
    });
    errdefer operation.abort();

    if (statusError(operation.raw.status)) |err| return err;
    return .adopt(operation.arena, try operation.decode(T));
}

/// Turn a completed mutating request into a `ModificationResponse`.
///
/// `202 Accepted` becomes a task, `204 No Content` and an empty body become
/// `.empty`, and anything else with a body is decoded as the resource.
fn modificationResponse(
    comptime T: type,
    operation: Operation,
) !Owned(ModificationResponse(T)) {
    if (statusError(operation.raw.status)) |err| return err;

    if (operation.raw.status == 202) {
        const location = operation.raw.location() orelse return Error.MissingTaskLocation;
        const task: AsyncTask = .{
            .location = .init(location),
            .retry_after = operation.raw.retryAfter(),
        };
        return .adopt(operation.arena, .{ .task = task });
    }

    if (operation.raw.status == 204 or operation.raw.body.len == 0) {
        return .adopt(operation.arena, .empty);
    }

    return .adopt(operation.arena, .{ .entity = try operation.decode(T) });
}

/// Encode `value` as a JSON request body in `arena`.
fn encodeBody(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

/// POST `body` to the collection at `id` to create a member.
pub fn create(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    body: anytype,
) !Owned(ModificationResponse(T)) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const encoded = try encodeBody(arena.allocator(), body);
    const raw = try transport.send(arena.allocator(), .{
        .method = .post,
        .uri = id.value,
        .body = encoded,
    });
    return modificationResponse(T, .{ .arena = arena, .raw = raw });
}

/// PATCH the resource at `id`.
///
/// Pass the entity's `etag` to make the write conditional; the service then
/// answers `412` rather than clobbering a concurrent change, which surfaces
/// here as `error.PreconditionFailed`.
pub fn update(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    etag: ?ODataETag,
    body: anytype,
) !Owned(ModificationResponse(T)) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const encoded = try encodeBody(arena.allocator(), body);
    const raw = try transport.send(arena.allocator(), .{
        .method = .patch,
        .uri = id.value,
        .body = encoded,
        .if_match = etag,
    });
    return modificationResponse(T, .{ .arena = arena, .raw = raw });
}

/// PATCH the resource an entity value came from, reusing its own `@odata.id`
/// and `@odata.etag`.
///
/// `target` must satisfy the `entity` contract. This is the safe form of
/// `update`: the ETag cannot be forgotten or mismatched with the id.
pub fn updateEntity(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    target: anytype,
    body: anytype,
) !Owned(ModificationResponse(T)) {
    comptime entity.assertEntity(@TypeOf(target));
    return update(T, gpa, transport, entity.id(target), entity.etag(target), body);
}

/// DELETE the resource at `id`.
pub fn delete(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
) !Owned(ModificationResponse(T)) {
    const operation = try Operation.begin(gpa, transport, .{
        .method = .delete,
        .uri = id.value,
    });
    errdefer operation.abort();
    return modificationResponse(T, operation);
}

/// POST `params` to an action's target.
///
/// The parameter and result types come from the `Action` itself, so they
/// cannot drift apart from the action being invoked.
pub fn invokeAction(
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    act: anytype,
    params: @TypeOf(act).Parameters,
) !Owned(ModificationResponse(@TypeOf(act).Result)) {
    const A = @TypeOf(act);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const encoded = try encodeBody(arena.allocator(), params);
    const raw = try transport.send(arena.allocator(), .{
        .method = .post,
        .uri = act.target.value,
        .body = encoded,
    });
    return modificationResponse(A.Result, .{ .arena = arena, .raw = raw });
}

/// POST to the session collection to log in.
///
/// Unlike every other create, the parts that matter arrive in headers: the
/// token to authenticate with and the URI to delete at logout.
pub fn createSession(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    body: anytype,
) !Owned(SessionCreateResponse(T)) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const encoded = try encodeBody(arena.allocator(), body);
    const raw = try transport.send(arena.allocator(), .{
        .method = .post,
        .uri = id.value,
        .body = encoded,
    });
    if (statusError(raw.status)) |err| return err;

    const auth_token = raw.header("X-Auth-Token") orelse return Error.MissingAuthToken;
    const location = raw.location() orelse return Error.MissingSessionLocation;

    const operation: Operation = .{ .arena = arena, .raw = raw };
    return .adopt(arena, .{
        .entity = try operation.decode(T),
        .auth_token = auth_token,
        .location = location,
    });
}

/// Open a `text/event-stream` at `uri`, for `EventService` subscriptions.
///
/// The caller must `close` the returned stream.
pub fn stream(transport: *BmcTransport, uri: []const u8) !EventStream {
    return transport.stream(uri);
}

const testing = std.testing;

/// A transport that answers from a fixed script, so the typed layer can be
/// tested without any I/O. The real thing lands in `redfish_bmc_mock`.
const ScriptedTransport = struct {
    transport: BmcTransport = .{ .sendFn = &sendImpl, .streamFn = null },
    reply: RawResponse,
    /// The request the last call made, for assertions.
    seen: ?RawRequest = null,

    fn sendImpl(
        t: *BmcTransport,
        arena: std.mem.Allocator,
        request: RawRequest,
    ) anyerror!RawResponse {
        const self: *ScriptedTransport = @fieldParentPtr("transport", t);
        // Copy into the arena so the reply behaves like a real one: owned by
        // the operation, not by the test.
        self.seen = .{
            .method = request.method,
            .uri = try arena.dupe(u8, request.uri),
            .body = try arena.dupe(u8, request.body),
            .if_match = request.if_match,
            .if_none_match = request.if_none_match,
        };
        return .{
            .status = self.reply.status,
            .headers = self.reply.headers,
            .body = try arena.dupe(u8, self.reply.body),
        };
    }
};

const Chassis = struct {
    @"@odata.id": ODataId,
    @"@odata.etag": ?ODataETag = null,
    Name: []const u8,
};

test "get decodes a 200 into an owned value" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body =
        \\{"@odata.id":"/redfish/v1/Chassis/1","Name":"Computer System Chassis"}
        ,
    } };

    const chassis = try get(Chassis, testing.allocator, &bmc.transport, .init("/redfish/v1/Chassis/1"));
    defer chassis.deinit();

    try testing.expectEqualStrings("Computer System Chassis", chassis.value.Name);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", chassis.value.@"@odata.id".value);
    try testing.expectEqual(Method.get, bmc.seen.?.method);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", bmc.seen.?.uri);
}

test "get ignores properties from a newer schema version" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body =
        \\{"@odata.id":"/redfish/v1/Chassis/1","Name":"Tray","AddedInAnewerVersion":[1,2]}
        ,
    } };

    const chassis = try get(Chassis, testing.allocator, &bmc.transport, .init("/redfish/v1/Chassis/1"));
    defer chassis.deinit();
    try testing.expectEqualStrings("Tray", chassis.value.Name);
}

test "expand appends the query parameter to the URI" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body = "{\"@odata.id\":\"/redfish/v1/Chassis/1\",\"Name\":\"Tray\"}",
    } };

    const chassis = try expand(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        .all(2),
    );
    defer chassis.deinit();

    try testing.expectEqualStrings(
        "/redfish/v1/Chassis/1?$expand=*($levels=2)",
        bmc.seen.?.uri,
    );
}

test "filter appends the expression to the URI" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body = "{\"@odata.id\":\"/redfish/v1/Systems\",\"Name\":\"Systems\"}",
    } };

    var expression: query_mod.FilterQuery = .empty;
    defer expression.deinit(testing.allocator);
    try expression.compare(testing.allocator, "SystemType", .eq, .{ .string = "Physical" });

    const systems = try filter(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Systems"),
        expression.expression(),
    );
    defer systems.deinit();

    try testing.expectEqualStrings(
        "/redfish/v1/Systems?$filter=SystemType eq 'Physical'",
        bmc.seen.?.uri,
    );
}

test "a plain get sends the id with no query string appended" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body = "{\"@odata.id\":\"/redfish/v1\",\"Name\":\"Root\"}",
    } };

    const root = try get(Chassis, testing.allocator, &bmc.transport, .service_root);
    defer root.deinit();
    try testing.expectEqualStrings("/redfish/v1", bmc.seen.?.uri);
}

test "maps each status onto a named error" {
    const cases = .{
        .{ @as(u16, 304), Error.NotModified },
        .{ @as(u16, 400), Error.BadRequest },
        .{ @as(u16, 401), Error.Unauthorized },
        .{ @as(u16, 403), Error.Forbidden },
        .{ @as(u16, 404), Error.ResourceNotFound },
        .{ @as(u16, 405), Error.MethodNotAllowed },
        .{ @as(u16, 409), Error.Conflict },
        .{ @as(u16, 412), Error.PreconditionFailed },
        .{ @as(u16, 415), Error.UnsupportedMediaType },
        .{ @as(u16, 429), Error.TooManyRequests },
        .{ @as(u16, 500), Error.ServiceError },
        .{ @as(u16, 503), Error.ServiceError },
        .{ @as(u16, 418), Error.UnexpectedStatus },
    };
    inline for (cases) |case| {
        try testing.expectEqual(case[1], statusError(case[0]).?);
    }

    try testing.expectEqual(@as(?Error, null), statusError(200));
    try testing.expectEqual(@as(?Error, null), statusError(202));
    try testing.expectEqual(@as(?Error, null), statusError(204));
}

test "an error status frees the arena instead of leaking it" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 404, .body = "{}" } };

    try testing.expectError(
        Error.ResourceNotFound,
        get(Chassis, testing.allocator, &bmc.transport, .init("/redfish/v1/Chassis/9")),
    );
}

test "a 200 with no body is an error, not an empty value" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 200, .body = "" } };

    try testing.expectError(
        Error.MissingResponseBody,
        get(Chassis, testing.allocator, &bmc.transport, .init("/redfish/v1/Chassis/1")),
    );
}

test "getIfNoneMatch sends the etag and reports an unchanged resource" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 304 } };

    try testing.expectError(Error.NotModified, getIfNoneMatch(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        .init("\"abc123\""),
    ));
    try testing.expectEqualStrings("\"abc123\"", bmc.seen.?.if_none_match.?.value);
}

test "getIfNoneMatch decodes a changed resource" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body = "{\"@odata.id\":\"/redfish/v1/Chassis/1\",\"Name\":\"Tray\"}",
    } };

    const chassis = try getIfNoneMatch(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        .init("\"stale\""),
    );
    defer chassis.deinit();
    try testing.expectEqualStrings("Tray", chassis.value.Name);
}

test "update sends a PATCH with If-Match and decodes the result" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 200,
        .body = "{\"@odata.id\":\"/redfish/v1/Chassis/1\",\"Name\":\"Renamed\"}",
    } };

    const result = try update(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        .init("\"abc123\""),
        .{ .Name = "Renamed" },
    );
    defer result.deinit();

    try testing.expectEqual(Method.patch, bmc.seen.?.method);
    try testing.expectEqualStrings("\"abc123\"", bmc.seen.?.if_match.?.value);
    try testing.expectEqualStrings("{\"Name\":\"Renamed\"}", bmc.seen.?.body);
    try testing.expectEqualStrings("Renamed", (try result.value.expectEntity()).Name);
}

test "update omits If-Match when no etag is given" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 204 } };

    const result = try update(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        null,
        .{ .Name = "Renamed" },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?ODataETag, null), bmc.seen.?.if_match);
    try testing.expectEqual(
        response_mod.ExpectError.NoResponseBody,
        result.value.expectEntity(),
    );
}

test "updateEntity reuses the entity's own id and etag" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 204 } };

    const target: Chassis = .{
        .@"@odata.id" = .init("/redfish/v1/Chassis/1"),
        .@"@odata.etag" = .init("\"W/abc\""),
        .Name = "Tray",
    };

    const result = try updateEntity(
        Chassis,
        testing.allocator,
        &bmc.transport,
        target,
        .{ .Name = "Renamed" },
    );
    defer result.deinit();

    try testing.expectEqualStrings("/redfish/v1/Chassis/1", bmc.seen.?.uri);
    try testing.expectEqualStrings("\"W/abc\"", bmc.seen.?.if_match.?.value);
}

test "a 202 becomes a task carrying Location and Retry-After" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 202,
        .headers = .{ .entries = &.{
            .{ .name = "Location", .value = "/redfish/v1/TaskService/Tasks/3" },
            .{ .name = "Retry-After", .value = "30" },
        } },
    } };

    const result = try create(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis"),
        .{ .Name = "New" },
    );
    defer result.deinit();

    const task = result.value.taskOrNull().?;
    try testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/3", task.location.value.value);
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), task.retryAfterNanoseconds().?);
}

test "a 202 without Location is an error" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 202 } };

    try testing.expectError(Error.MissingTaskLocation, create(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis"),
        .{ .Name = "New" },
    ));
}

test "an HTTP-date Retry-After yields no duration rather than a wrong one" {
    const raw: RawResponse = .{
        .status = 202,
        .headers = .{ .entries = &.{
            .{ .name = "Retry-After", .value = "Fri, 31 Dec 1999 23:59:59 GMT" },
        } },
    };
    try testing.expectEqual(@as(?Duration, null), raw.retryAfter());
}

test "a 204 becomes the empty outcome" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 204 } };

    const result = try delete(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/SessionService/Sessions/1"),
    );
    defer result.deinit();

    try testing.expectEqual(Method.delete, bmc.seen.?.method);
    try testing.expect(result.value == .empty);
    try testing.expectEqual(@as(?AsyncTask, null), result.value.taskOrNull());
}

test "a 201 with a body becomes the created entity" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 201,
        .body = "{\"@odata.id\":\"/redfish/v1/Chassis/2\",\"Name\":\"New\"}",
    } };

    const result = try create(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis"),
        .{ .Name = "New" },
    );
    defer result.deinit();

    try testing.expectEqual(Method.post, bmc.seen.?.method);
    try testing.expectEqualStrings("/redfish/v1/Chassis/2", (try result.value.expectEntity()).@"@odata.id".value);
}

test "request bodies omit null optional fields" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 204 } };

    const Patch = struct {
        Name: []const u8,
        AssetTag: ?[]const u8 = null,
    };

    const result = try update(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Chassis/1"),
        null,
        Patch{ .Name = "Renamed" },
    );
    defer result.deinit();

    try testing.expectEqualStrings("{\"Name\":\"Renamed\"}", bmc.seen.?.body);
}

test "invokeAction posts the parameters to the action target" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 204 } };

    const ResetParameters = struct { ResetType: []const u8 };
    const Reset = Action(ResetParameters, Chassis);
    const reset: Reset = .init(.init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"));

    const result = try invokeAction(
        testing.allocator,
        &bmc.transport,
        reset,
        .{ .ResetType = "GracefulRestart" },
    );
    defer result.deinit();

    try testing.expectEqual(Method.post, bmc.seen.?.method);
    try testing.expectEqualStrings(
        "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        bmc.seen.?.uri,
    );
    try testing.expectEqualStrings("{\"ResetType\":\"GracefulRestart\"}", bmc.seen.?.body);
    try testing.expect(result.value == .empty);
}

test "createSession takes the token and logout URI from the headers" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 201,
        .headers = .{ .entries = &.{
            .{ .name = "X-Auth-Token", .value = "6f4b3c2a" },
            .{ .name = "Location", .value = "/redfish/v1/SessionService/Sessions/1" },
        } },
        .body = "{\"@odata.id\":\"/redfish/v1/SessionService/Sessions/1\",\"Name\":\"User Session\"}",
    } };

    const session = try createSession(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/SessionService/Sessions"),
        .{ .UserName = "admin", .Password = "hunter2" },
    );
    defer session.deinit();

    try testing.expectEqualStrings("6f4b3c2a", session.value.auth_token);
    try testing.expectEqualStrings("/redfish/v1/SessionService/Sessions/1", session.value.location.value);
    try testing.expectEqualStrings("User Session", session.value.entity.Name);
}

test "createSession without a token is an error" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 201,
        .headers = .{ .entries = &.{
            .{ .name = "Location", .value = "/redfish/v1/SessionService/Sessions/1" },
        } },
        .body = "{\"@odata.id\":\"/redfish/v1/SessionService/Sessions/1\",\"Name\":\"S\"}",
    } };

    try testing.expectError(Error.MissingAuthToken, createSession(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/SessionService/Sessions"),
        .{ .UserName = "admin", .Password = "hunter2" },
    ));
}

test "createSession without a Location is an error" {
    var bmc: ScriptedTransport = .{ .reply = .{
        .status = 201,
        .headers = .{ .entries = &.{
            .{ .name = "X-Auth-Token", .value = "6f4b3c2a" },
        } },
        .body = "{\"@odata.id\":\"/redfish/v1/SessionService/Sessions/1\",\"Name\":\"S\"}",
    } };

    try testing.expectError(Error.MissingSessionLocation, createSession(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/SessionService/Sessions"),
        .{ .UserName = "admin", .Password = "hunter2" },
    ));
}

test "a transport without streaming reports it rather than crashing" {
    var bmc: ScriptedTransport = .{ .reply = .{ .status = 200 } };

    try testing.expectError(
        Error.StreamingUnsupported,
        stream(&bmc.transport, "/redfish/v1/EventService/SSE"),
    );
}

test "header lookup is case-insensitive" {
    const headers: Headers = .{ .entries = &.{
        .{ .name = "etag", .value = "\"abc\"" },
        .{ .name = "X-Auth-Token", .value = "tok" },
    } };

    try testing.expectEqualStrings("\"abc\"", headers.get("ETag").?);
    try testing.expectEqualStrings("tok", headers.get("x-auth-token").?);
    try testing.expect(headers.has("ETag"));
    try testing.expect(!headers.has("Location"));
    try testing.expectEqual(@as(?[]const u8, null), Headers.empty.get("ETag"));
}

test "a response exposes ETag and Location as typed values" {
    const raw: RawResponse = .{
        .status = 201,
        .headers = .{ .entries = &.{
            .{ .name = "ETag", .value = "W/\"abc123\"" },
            .{ .name = "Location", .value = "/redfish/v1/Chassis/2" },
        } },
    };

    try testing.expect(raw.isSuccess());
    try testing.expectEqualStrings("W/\"abc123\"", raw.etag().?.value);
    try testing.expectEqualStrings("/redfish/v1/Chassis/2", raw.location().?.value);

    const bare: RawResponse = .{ .status = 500 };
    try testing.expect(!bare.isSuccess());
    try testing.expectEqual(@as(?ODataETag, null), bare.etag());
    try testing.expectEqual(@as(?ODataId, null), bare.location());
}

test "method tokens are the wire spellings" {
    try testing.expectEqualStrings("GET", Method.get.token());
    try testing.expectEqualStrings("POST", Method.post.token());
    try testing.expectEqualStrings("PATCH", Method.patch.token());
    try testing.expectEqualStrings("PUT", Method.put.token());
    try testing.expectEqualStrings("DELETE", Method.delete.token());
}

test "a transport failure propagates unchanged" {
    const Failing = struct {
        transport: BmcTransport = .{ .sendFn = &sendImpl },

        fn sendImpl(_: *BmcTransport, _: std.mem.Allocator, _: RawRequest) anyerror!RawResponse {
            return error.ConnectionRefused;
        }
    };

    var bmc: Failing = .{};
    try testing.expectError(
        error.ConnectionRefused,
        get(Chassis, testing.allocator, &bmc.transport, .service_root),
    );
}
