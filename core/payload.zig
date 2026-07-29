//! Serializing what a client sends, as opposed to what it receives.
//!
//! A write payload is not a resource with holes in it. A PATCH body means
//! "change exactly these properties"; every member that appears in it is an
//! instruction, so a member that appears by accident is a bug with
//! consequences. `{"AssetTag": null}` clears the asset tag, and a serializer
//! that writes unset fields as null would clear every property the caller did
//! not set.
//!
//! So a generated update or create shape borrows `Payload(T).jsonStringify`,
//! which leaves out:
//!
//!   * a `Nullable(T)` field that is `.absent` -- the caller said nothing,
//!     as distinct from `.none`, which clears the property and is written;
//!   * an optional field that is null -- the same intent, for a property
//!     that has no null to send.
//!
//! and writes out an `additional_properties` field, if the shape has one, so
//! an OEM caller can send members no schema names.
//!
//! This is the equivalent of Rust's `#[serde(skip_serializing_if =
//! "Option::is_none")]` on every field, which is what the reference generator
//! emits.

const std = @import("std");

const nullable = @import("nullable.zig");
const open_struct = @import("open_struct.zig");

/// JSON serialization for a payload shape.
pub fn Payload(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("payloads must be structs, found " ++ @typeName(T)),
    };

    return struct {
        pub fn jsonStringify(self: T, jws: anytype) !void {
            try jws.beginObject();
            inline for (info.fields) |field| {
                const is_extras = comptime std.mem.eql(u8, field.name, open_struct.extras_field);
                if (comptime !is_extras and field.type != void) {
                    const value = @field(self, field.name);
                    const omit = if (comptime nullable.isNullable(field.type))
                        value == .absent
                    else if (comptime @typeInfo(field.type) == .optional)
                        value == null
                    else
                        false;
                    if (!omit) {
                        try jws.objectField(field.name);
                        try jws.write(value);
                    }
                }
            }

            if (comptime @hasField(T, open_struct.extras_field)) {
                const extras = @field(self, open_struct.extras_field);
                for (extras.map.keys(), extras.map.values()) |member, value| {
                    try jws.objectField(member);
                    try jws.write(value);
                }
            }
            try jws.endObject();
        }
    };
}

const testing = std.testing;
const Nullable = nullable.Nullable;

const ChassisUpdate = struct {
    AssetTag: Nullable([]const u8) = .absent,
    IndicatorLED: Nullable([]const u8) = .absent,
    Count: ?i64 = null,

    pub const jsonStringify = Payload(@This()).jsonStringify;
};

fn write(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

test "a payload the caller did not fill in is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("{}", try write(arena.allocator(), ChassisUpdate{}));
}

test "a set property is the only one written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        \\{"AssetTag":"rack-1"}
    , try write(arena.allocator(), ChassisUpdate{ .AssetTag = .init("rack-1") }));
}

test "clearing a property is not the same as leaving it alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        \\{"AssetTag":null}
    , try write(arena.allocator(), ChassisUpdate{ .AssetTag = .none }));
}

test "an optional field is left out when it is null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        \\{"Count":3}
    , try write(arena.allocator(), ChassisUpdate{ .Count = 3 }));
}

test "a required field is written whatever it holds" {
    const SessionCreate = struct {
        UserName: []const u8,
        Password: []const u8,
        SessionType: ?[]const u8 = null,

        pub const jsonStringify = Payload(@This()).jsonStringify;
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        \\{"UserName":"root","Password":"hunter2"}
    , try write(arena.allocator(), SessionCreate{ .UserName = "root", .Password = "hunter2" }));
}

test "an open payload can carry members no schema names" {
    const OemUpdate = struct {
        Name: Nullable([]const u8) = .absent,
        additional_properties: open_struct.AdditionalProperties = .{},

        pub const jsonStringify = Payload(@This()).jsonStringify;
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var payload: OemUpdate = .{ .Name = .init("fan") };
    try payload.additional_properties.map.put(
        arena.allocator(),
        "Nvidia",
        .{ .string = "custom" },
    );

    try testing.expectEqualStrings(
        \\{"Name":"fan","Nvidia":"custom"}
    , try write(arena.allocator(), payload));
}
