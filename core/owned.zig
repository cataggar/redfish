//! Response ownership.
//!
//! `nv-redfish` returns `Arc<T>` from every read so a decoded resource can be
//! shared cheaply. Zig has no such idiom, and refcounting a deeply nested
//! decoded tree costs more than it saves. Instead every read decodes into its
//! own arena and hands back the arena with the value:
//!
//! ```zig
//! const chassis = try owned.parseJson(Chassis, gpa, body, .{});
//! defer chassis.deinit();
//! std.debug.print("{f}\n", .{chassis.value.odata_id});
//! ```
//!
//! One `deinit()` releases the whole tree. Sharing is the caller's problem.
//!
//! Because the arena owns every string in the tree, borrowed types such as
//! `ODataId` stay valid for exactly as long as the `Owned(T)` that produced
//! them — and no longer.

const std = @import("std");

/// A value together with the arena that owns everything it points at.
///
/// An `Owned(T)` is a move-only handle by convention: copy it freely, but
/// call `deinit` exactly once.
pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        arena: *std.heap.ArenaAllocator,

        /// Create an empty arena and place `value` in it. Use when the value
        /// is synthesized rather than decoded, then allocate any referenced
        /// memory with `self.allocator()`.
        pub fn init(gpa: std.mem.Allocator, value: T) std.mem.Allocator.Error!Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            errdefer gpa.destroy(arena);
            arena.* = .init(gpa);
            return .{ .value = value, .arena = arena };
        }

        /// Adopt an arena that the caller already allocated with `gpa.create`.
        /// Ownership of `arena` transfers to the returned value.
        pub fn adopt(arena: *std.heap.ArenaAllocator, value: T) Self {
            return .{ .value = value, .arena = arena };
        }

        /// Release the value and everything the arena backs.
        pub fn deinit(self: Self) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }

        /// Allocator backing this value's tree. Anything allocated here lives
        /// until `deinit`.
        pub fn allocator(self: Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        /// Replace the value while keeping the same arena, transferring
        /// ownership to the result. Use to project a decoded payload into a
        /// wrapper type without copying the tree.
        ///
        /// The receiver must not be used afterwards.
        pub fn withValue(self: Self, comptime U: type, value: U) Owned(U) {
            return .{ .value = value, .arena = self.arena };
        }
    };
}

/// Parse options that guarantee the arena owns every decoded string.
///
/// `alloc_always` matters here: the default `alloc_if_needed` lets decoded
/// strings borrow the input buffer, which for us is an HTTP response body
/// that is freed long before the `Owned(T)` is.
pub const parse_options: std.json.ParseOptions = .{
    .allocate = .alloc_always,
    .ignore_unknown_fields = true,
};

/// Decode `bytes` as JSON into a fresh arena.
///
/// Pass `null` for `options` to get `parse_options`, which ignores unknown
/// fields: BMCs routinely return properties from a newer schema version than
/// the one a package was generated from. A caller that supplies its own
/// options gets `std.json`'s defaults for everything it does not set, and so
/// opts into strict field checking.
///
/// `allocate` is always forced to `alloc_always`, whatever the caller asks
/// for, because the arena has to outlive the input buffer.
pub fn parseJson(
    comptime T: type,
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: ?std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!Owned(T) {
    var effective = options orelse parse_options;
    effective.allocate = .alloc_always;

    const parsed = try std.json.parseFromSlice(T, gpa, bytes, effective);
    return .{ .value = parsed.value, .arena = parsed.arena };
}

const testing = std.testing;

test "init creates an empty arena the caller can allocate into" {
    var o = try Owned([]const u8).init(testing.allocator, "");
    defer o.deinit();

    o.value = try o.allocator().dupe(u8, "/redfish/v1");
    try testing.expectEqualStrings("/redfish/v1", o.value);
}

test "adopt takes ownership of a caller-created arena" {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(testing.allocator);

    const message = try arena.allocator().dupe(u8, "Base.1.0.Success");
    const o = Owned([]const u8).adopt(arena, message);
    defer o.deinit();

    try testing.expectEqualStrings("Base.1.0.Success", o.value);
}

test "parseJson decodes into an arena that outlives the input buffer" {
    const Chassis = struct {
        @"@odata.id": []const u8,
        Name: []const u8,
    };

    const body = try testing.allocator.dupe(
        u8,
        "{\"@odata.id\":\"/redfish/v1/Chassis/1\",\"Name\":\"Computer System Chassis\"}",
    );
    const chassis = try parseJson(Chassis, testing.allocator, body, .{});
    defer chassis.deinit();

    // Free the source bytes; the decoded strings must survive.
    testing.allocator.free(body);

    try testing.expectEqualStrings("/redfish/v1/Chassis/1", chassis.value.@"@odata.id");
    try testing.expectEqualStrings("Computer System Chassis", chassis.value.Name);
}

test "parseJson ignores unknown fields when it picks the options" {
    const Partial = struct { Name: []const u8 };
    const body = "{\"Name\":\"Tray\",\"UnknownFromNewerSchema\":{\"A\":[1,2]}}";

    const tolerant = try parseJson(Partial, testing.allocator, body, null);
    defer tolerant.deinit();
    try testing.expectEqualStrings("Tray", tolerant.value.Name);

    // Passing options explicitly opts into `std.json`'s strict defaults.
    try testing.expectError(
        error.UnknownField,
        parseJson(Partial, testing.allocator, body, .{}),
    );
}

test "parseJson forces alloc_always even when the caller asks otherwise" {
    const Partial = struct { Name: []const u8 };

    const body = try testing.allocator.dupe(u8, "{\"Name\":\"Tray\"}");
    const owned = try parseJson(Partial, testing.allocator, body, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    });
    defer owned.deinit();
    testing.allocator.free(body);

    try testing.expectEqualStrings("Tray", owned.value.Name);
}

test "withValue retargets the value and keeps the arena" {
    const Raw = struct { Name: []const u8 };
    const Wrapper = struct { name: []const u8 };

    const raw = try parseJson(Raw, testing.allocator, "{\"Name\":\"Drive Bay\"}", .{});
    const wrapped = raw.withValue(Wrapper, .{ .name = raw.value.Name });
    defer wrapped.deinit();

    try testing.expectEqualStrings("Drive Bay", wrapped.value.name);
}

test "parseJson surfaces malformed JSON as an error" {
    try testing.expectError(
        error.UnexpectedEndOfInput,
        parseJson(struct { Name: []const u8 }, testing.allocator, "{\"Name\":", .{}),
    );
}
