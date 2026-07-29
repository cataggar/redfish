//! Outcomes of mutating Redfish operations.
//!
//! A POST, PATCH, or DELETE may finish three ways: the service returns the
//! updated resource, it returns `202 Accepted` with a task to poll, or it
//! returns `204 No Content`. `ModificationResponse(T)` makes the caller
//! confront all three instead of assuming a body arrived.
//!
//! Session creation is its own shape because the interesting parts arrive in
//! headers rather than the body.
//!
//! Reference: DMTF DSP0266, "Asynchronous operations" and "Session login".

const std = @import("std");
const edm = @import("edm.zig");
const odata = @import("odata.zig");

const Duration = edm.Duration;
const ODataId = odata.ODataId;

/// Where to poll for the completion of an asynchronous operation.
///
/// Distinct from `ODataId` because it comes from the `Location` response
/// header rather than from a resource body, and points at a task monitor
/// rather than at the resource being modified.
pub const AsyncTaskLocation = struct {
    value: ODataId,

    pub fn init(value: ODataId) AsyncTaskLocation {
        return .{ .value = value };
    }

    pub fn eql(self: AsyncTaskLocation, other: AsyncTaskLocation) bool {
        return self.value.eql(other.value);
    }

    pub fn format(self: AsyncTaskLocation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.value.format(w);
    }
};

/// A handle to an operation the service is still working on.
pub const AsyncTask = struct {
    location: AsyncTaskLocation,
    /// The service's `Retry-After` hint, when it sent one.
    retry_after: ?Duration = null,

    pub fn init(location: AsyncTaskLocation) AsyncTask {
        return .{ .location = location };
    }

    /// The `Retry-After` hint as nanoseconds, for handing to a timer.
    /// Null when the service gave no hint or gave an unusable one.
    pub fn retryAfterNanoseconds(self: AsyncTask) ?u64 {
        const retry_after = self.retry_after orelse return null;
        return retry_after.toNanoseconds() catch null;
    }

    pub fn format(self: AsyncTask, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.location.format(w);
    }
};

pub const ExpectError = error{
    /// The service accepted the request but has not finished it.
    OperationIsAsynchronous,
    /// The service completed the request without returning a body.
    NoResponseBody,
};

/// The result of a mutating operation on a resource of type `T`.
pub fn ModificationResponse(comptime T: type) type {
    return union(enum) {
        /// The service completed the request and returned the resource.
        entity: T,
        /// The service accepted the request; poll the task for completion.
        task: AsyncTask,
        /// The service completed the request with no body.
        empty,

        const Self = @This();

        /// The resource type this response carries.
        pub const Entity = T;

        pub fn entityOrNull(self: Self) ?T {
            return switch (self) {
                .entity => |value| value,
                else => null,
            };
        }

        pub fn taskOrNull(self: Self) ?AsyncTask {
            return switch (self) {
                .task => |value| value,
                else => null,
            };
        }

        /// The resource, or an error naming which of the other two outcomes
        /// happened. For callers that genuinely require a body.
        pub fn expectEntity(self: Self) ExpectError!T {
            return switch (self) {
                .entity => |value| value,
                .task => ExpectError.OperationIsAsynchronous,
                .empty => ExpectError.NoResponseBody,
            };
        }

        /// Transform the resource, leaving the task and empty outcomes alone.
        ///
        /// Zig has no closures, so the mapping is a comptime function plus an
        /// explicit `context` value, which is what a captured environment
        /// would have held.
        pub fn mapEntity(
            self: Self,
            comptime U: type,
            context: anytype,
            comptime map: fn (@TypeOf(context), T) U,
        ) ModificationResponse(U) {
            return switch (self) {
                .entity => |value| .{ .entity = map(context, value) },
                .task => |value| .{ .task = value },
                .empty => .empty,
            };
        }

        /// `mapEntity` for a mapping that can fail. Task and empty outcomes
        /// pass through without ever calling `map`.
        pub fn tryMapEntity(
            self: Self,
            comptime U: type,
            comptime E: type,
            context: anytype,
            comptime map: fn (@TypeOf(context), T) E!U,
        ) E!ModificationResponse(U) {
            return switch (self) {
                .entity => |value| .{ .entity = try map(context, value) },
                .task => |value| .{ .task = value },
                .empty => .empty,
            };
        }
    };
}

/// The result of creating a session.
///
/// Redfish splits the answer across the body and two headers: the session
/// resource, the token in `X-Auth-Token`, and the session URI in `Location`.
/// The URI is needed to log out, and is not always derivable from the body.
pub fn SessionCreateResponse(comptime T: type) type {
    return struct {
        entity: T,
        /// Value of `X-Auth-Token`. Send it on subsequent requests.
        auth_token: []const u8,
        /// Value of `Location`. DELETE it to log out.
        location: ODataId,

        const Self = @This();

        /// Redacts the token. Session tokens are live credentials, and this
        /// type is exactly the sort of value that ends up in a debug log.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return w.print(
                "SessionCreateResponse{{ .location = {f}, .auth_token = [REDACTED] }}",
                .{self.location},
            );
        }
    };
}

const testing = std.testing;

const Chassis = struct {
    @"@odata.id": ODataId,
    Name: []const u8,
};

const Summary = struct { name: []const u8 };

fn summarize(prefix: []const u8, chassis: Chassis) Summary {
    _ = prefix;
    return .{ .name = chassis.Name };
}

fn failingSummarize(_: void, chassis: Chassis) error{Rejected}!Summary {
    _ = chassis;
    return error.Rejected;
}

fn sampleEntity() ModificationResponse(Chassis) {
    return .{ .entity = .{ .@"@odata.id" = .init("/redfish/v1/Chassis/1"), .Name = "Tray" } };
}

fn sampleTask() ModificationResponse(Chassis) {
    return .{ .task = .{
        .location = .init(.init("/redfish/v1/TaskService/Tasks/1")),
        .retry_after = Duration.fromWholeSeconds(5),
    } };
}

test "entityOrNull answers only for the entity outcome" {
    try testing.expectEqualStrings("Tray", sampleEntity().entityOrNull().?.Name);
    try testing.expectEqual(@as(?Chassis, null), sampleTask().entityOrNull());

    const empty: ModificationResponse(Chassis) = .empty;
    try testing.expectEqual(@as(?Chassis, null), empty.entityOrNull());
}

test "taskOrNull answers only for the task outcome" {
    try testing.expect(sampleTask().taskOrNull().?.location.eql(
        .init(.init("/redfish/v1/TaskService/Tasks/1")),
    ));
    try testing.expectEqual(@as(?AsyncTask, null), sampleEntity().taskOrNull());
}

test "expectEntity names the outcome that got in the way" {
    try testing.expectEqualStrings("Tray", (try sampleEntity().expectEntity()).Name);
    try testing.expectError(
        ExpectError.OperationIsAsynchronous,
        sampleTask().expectEntity(),
    );

    const empty: ModificationResponse(Chassis) = .empty;
    try testing.expectError(ExpectError.NoResponseBody, empty.expectEntity());
}

test "mapEntity transforms the entity and passes the rest through" {
    const mapped = sampleEntity().mapEntity(Summary, @as([]const u8, "p"), summarize);
    try testing.expectEqualStrings("Tray", mapped.entityOrNull().?.name);

    const task = sampleTask().mapEntity(Summary, @as([]const u8, "p"), summarize);
    try testing.expectEqual(ModificationResponse(Summary), @TypeOf(task));
    try testing.expect(task.taskOrNull() != null);

    const empty: ModificationResponse(Chassis) = .empty;
    try testing.expect(empty.mapEntity(Summary, @as([]const u8, "p"), summarize) == .empty);
}

test "tryMapEntity propagates the mapping error only for an entity" {
    try testing.expectError(
        error.Rejected,
        sampleEntity().tryMapEntity(Summary, error{Rejected}, {}, failingSummarize),
    );

    // The mapping never runs, so its error cannot occur.
    const task = try sampleTask().tryMapEntity(Summary, error{Rejected}, {}, failingSummarize);
    try testing.expect(task.taskOrNull() != null);

    const empty: ModificationResponse(Chassis) = .empty;
    try testing.expect(
        try empty.tryMapEntity(Summary, error{Rejected}, {}, failingSummarize) == .empty,
    );
}

test "the entity type is reachable from the response type" {
    try testing.expectEqual(Chassis, ModificationResponse(Chassis).Entity);
}

test "retryAfterNanoseconds converts the hint" {
    try testing.expectEqual(
        @as(?u64, 5 * std.time.ns_per_s),
        sampleTask().taskOrNull().?.retryAfterNanoseconds(),
    );

    const no_hint: AsyncTask = .init(.init(.init("/redfish/v1/TaskService/Tasks/1")));
    try testing.expectEqual(@as(?u64, null), no_hint.retryAfterNanoseconds());

    const unusable: AsyncTask = .{
        .location = .init(.init("/redfish/v1/TaskService/Tasks/1")),
        .retry_after = try Duration.parse("-PT1S"),
    };
    try testing.expectEqual(@as(?u64, null), unusable.retryAfterNanoseconds());
}

test "a task formats as its poll location" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "/redfish/v1/TaskService/Tasks/1",
        try std.fmt.bufPrint(&buf, "{f}", .{sampleTask().taskOrNull().?}),
    );
}

test "SessionCreateResponse never formats its token" {
    const Session = struct { @"@odata.id": ODataId };
    const response: SessionCreateResponse(Session) = .{
        .entity = .{ .@"@odata.id" = .init("/redfish/v1/SessionService/Sessions/1") },
        .auth_token = "super-secret-token",
        .location = .init("/redfish/v1/SessionService/Sessions/1"),
    };

    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{response});
    try testing.expect(std.mem.indexOf(u8, rendered, "super-secret-token") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "[REDACTED]") != null);
    try testing.expect(
        std.mem.indexOf(u8, rendered, "/redfish/v1/SessionService/Sessions/1") != null,
    );
}
