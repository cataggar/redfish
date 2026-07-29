//! Reading through a link without caring how it arrived.
//!
//! A navigation property comes back one of two ways. Normally it is a bare
//! `@odata.id` and the resource behind it costs another `GET`. Under
//! `$expand` the service inlines the resource, and the `GET` would be waste.
//!
//! The difference is worth exploiting — skipping a round trip is the entire
//! point of `$expand` — but it puts the choice in every caller, and the two
//! branches do not even have the same lifetime: an expanded resource borrows
//! from the arena of the response that carried it, while a fetched one owns
//! an arena of its own.
//!
//! `follow` erases the distinction. It hands back a value that is used the
//! same way and released the same way whichever branch produced it, so a
//! caller can add `$expand` to a request, change nothing else, and have it
//! take effect.

const std = @import("std");

const bmc = @import("bmc.zig");
const nav_property = @import("nav_property.zig");
const odata = @import("odata.zig");

const BmcTransport = bmc.BmcTransport;
const ODataId = odata.ODataId;
const Owned = @import("owned.zig").Owned;

/// A resource reached through a link, however it got here.
///
/// `deinit` is correct in both cases: it frees the arena when the link was
/// resolved by a fetch, and does nothing when the resource was already in
/// hand. Call it unconditionally.
///
/// The resource is reached through `get` rather than a stored pointer,
/// because a fetched one lives *inside* this value: `Owned(T)` holds its `T`
/// inline, so a pointer taken to it before this struct was returned would
/// point at the stack frame that built it. Deriving the pointer from `self`
/// makes that mistake unrepresentable.
pub fn Resolved(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: union(enum) {
            /// Sent inline by the service; owned by the response that carried
            /// it, and valid exactly as long as that response is.
            borrowed: *const T,
            /// Fetched to resolve this link, and ours to free.
            fetched: Owned(T),
        },

        /// The resource. Valid while this value is.
        pub fn get(self: *const Self) *const T {
            return switch (self.storage) {
                .borrowed => |resource| resource,
                .fetched => |*owned| &owned.value,
            };
        }

        /// Whether reading this link cost a request.
        pub fn wasFetched(self: Self) bool {
            return self.storage == .fetched;
        }

        pub fn deinit(self: Self) void {
            switch (self.storage) {
                .fetched => |owned| owned.deinit(),
                .borrowed => {},
            }
        }
    };
}

/// Reads the resource a navigation property points at, fetching it only if
/// the service did not already send it.
///
/// A link is either expanded or a reference, and a reference always carries
/// an `@odata.id` -- so unlike most things that read one, this cannot fail
/// for want of an address.
pub fn follow(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    link: nav_property.NavProperty(T),
) !Resolved(T) {
    return switch (link) {
        .expanded => |resource| .{ .storage = .{ .borrowed = resource } },
        .reference => |ref| .{
            .storage = .{ .fetched = try bmc.get(T, gpa, transport, ref.odataId()) },
        },
    };
}

const testing = std.testing;

const Thermal = struct {
    @"@odata.id": ?ODataId = null,
    Name: ?[]const u8 = null,
};

/// Answers one URI, and counts how many times it was asked.
const CountingTransport = struct {
    transport: BmcTransport = .{ .sendFn = send },
    body: []const u8 = "{}",
    calls: usize = 0,

    fn send(transport: *BmcTransport, arena: std.mem.Allocator, request: bmc.RawRequest) !bmc.RawResponse {
        const self: *CountingTransport = @fieldParentPtr("transport", transport);
        self.calls += 1;
        _ = request;
        return .{ .status = 200, .body = try arena.dupe(u8, self.body), .headers = .empty };
    }
};

test "an expanded link is read without a request" {
    var transport: CountingTransport = .{};

    const inlined: Thermal = .{ .Name = "Thermal" };
    const link: nav_property.NavProperty(Thermal) = .initExpanded(&inlined);

    const resolved = try follow(Thermal, testing.allocator, &transport.transport, link);
    defer resolved.deinit();

    try testing.expectEqualStrings("Thermal", resolved.get().Name.?);
    try testing.expect(!resolved.wasFetched());
    try testing.expectEqual(@as(usize, 0), transport.calls);
}

test "a bare reference is fetched" {
    var transport: CountingTransport = .{ .body = "{\"Name\":\"Thermal\"}" };

    const link: nav_property.NavProperty(Thermal) = .initReference(.{
        .value = "/redfish/v1/Chassis/1/Thermal",
    });

    const resolved = try follow(Thermal, testing.allocator, &transport.transport, link);
    defer resolved.deinit();

    try testing.expectEqualStrings("Thermal", resolved.get().Name.?);
    try testing.expect(resolved.wasFetched());
    try testing.expectEqual(@as(usize, 1), transport.calls);
}

test "both branches are released the same way" {
    // The point of the type: a caller writes one `defer` and does not have to
    // know which branch ran. Under the testing allocator, getting this wrong
    // in either direction is a leak or a double free.
    var transport: CountingTransport = .{ .body = "{\"Name\":\"Fetched\"}" };
    const inlined: Thermal = .{ .Name = "Inline" };

    for ([_]nav_property.NavProperty(Thermal){
        .initExpanded(&inlined),
        .initReference(.{ .value = "/redfish/v1/Chassis/1/Thermal" }),
    }) |link| {
        const resolved = try follow(Thermal, testing.allocator, &transport.transport, link);
        defer resolved.deinit();
        try testing.expect(resolved.get().Name != null);
    }
}

test "a fetched resource survives the return that produced it" {
    // `Owned(T)` stores its `T` inline, so a `Resolved` that cached a pointer
    // to it would hand back the stack frame `follow` returned from. Reading
    // the value only after `follow` has returned is what makes that visible.
    var transport: CountingTransport = .{ .body = "{\"Name\":\"Fetched\",\"@odata.id\":\"/redfish/v1/Chassis/1/Thermal\"}" };

    const resolved = try follow(
        Thermal,
        testing.allocator,
        &transport.transport,
        nav_property.NavProperty(Thermal).initReference(.{ .value = "/redfish/v1/Chassis/1/Thermal" }),
    );
    defer resolved.deinit();

    try testing.expectEqualStrings("Fetched", resolved.get().Name.?);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1/Thermal", resolved.get().@"@odata.id".?.value);
}

test {
    testing.refAllDecls(@This());
}
