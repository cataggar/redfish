//! Enums that survive a value the schema does not name.
//!
//! A generated package is built from one snapshot of the Redfish schema, and
//! a BMC is not. A service that implements a newer schema, or a vendor
//! extension, will send a `Status` or a `ResetType` this package has never
//! heard of. Failing the whole parse over one unrecognized string would make
//! the client useless against exactly the services it most needs to talk to.
//!
//! So every generated enum carries an `UnsupportedValue` member and parses
//! anything it does not recognize into it. The value is lost, which is a real
//! cost, but it is the same trade nv-redfish makes and it keeps the rest of
//! the resource readable.

const std = @import("std");

/// The member an unrecognized value decodes to.
pub const fallback_name = "UnsupportedValue";

/// JSON hooks for an enum whose members are wire names.
///
/// Generated enums pull `jsonParse` and `jsonParseFromValue` out of this, so
/// the fallback lives here once instead of in every emitted declaration.
/// Serialization needs no hook: the members are spelled exactly as the wire
/// spells them, so `std.json`'s default is already right.
pub fn Open(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"enum") @compileError("Open expects an enum, got " ++ @typeName(T));
    if (!@hasField(T, fallback_name)) {
        @compileError(@typeName(T) ++ " has no `" ++ fallback_name ++ "` member");
    }

    return struct {
        pub const fallback: T = @field(T, fallback_name);

        pub fn parse(text: []const u8) T {
            return std.meta.stringToEnum(T, text) orelse fallback;
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !T {
            const limit = options.max_value_len orelse std.json.default_max_value_len;
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            return switch (token) {
                inline .string, .allocated_string => |text| parse(text),
                else => error.UnexpectedToken,
            };
        }

        pub fn jsonParseFromValue(
            _: std.mem.Allocator,
            source: std.json.Value,
            _: std.json.ParseOptions,
        ) !T {
            return switch (source) {
                .string => |text| parse(text),
                else => error.UnexpectedToken,
            };
        }
    };
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const ResetType = enum {
    On,
    ForceOff,
    GracefulShutdown,
    UnsupportedValue,

    const open = Open(@This());
    pub const jsonParse = open.jsonParse;
    pub const jsonParseFromValue = open.jsonParseFromValue;
};

test "a member the schema names decodes to itself" {
    const parsed = try std.json.parseFromSlice(ResetType, testing.allocator, "\"ForceOff\"", .{});
    defer parsed.deinit();
    try testing.expectEqual(ResetType.ForceOff, parsed.value);
}

test "a member the schema does not name decodes to the fallback" {
    const parsed = try std.json.parseFromSlice(ResetType, testing.allocator, "\"PowerCycle\"", .{});
    defer parsed.deinit();
    try testing.expectEqual(ResetType.UnsupportedValue, parsed.value);
}

test "a value that is not a string is still an error" {
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(ResetType, testing.allocator, "17", .{}),
    );
}

test "an enum inside a resource does not fail the whole parse" {
    const Resource = struct {
        Id: []const u8,
        ResetType: ResetType,
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Resource,
        arena.allocator(),
        \\{"Id": "1", "ResetType": "SomethingNewer"}
    ,
        .{},
    );
    try testing.expectEqualStrings("1", parsed.Id);
    try testing.expectEqual(ResetType.UnsupportedValue, parsed.ResetType);
}

test "the same fallback applies when parsing from a parsed value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "\"PowerCycle\"",
        .{},
    );
    const parsed = try std.json.parseFromValueLeaky(
        ResetType,
        arena.allocator(),
        value,
        .{},
    );
    try testing.expectEqual(ResetType.UnsupportedValue, parsed);
}

test "a member is written back exactly as the wire spells it" {
    const written = try std.json.Stringify.valueAlloc(
        testing.allocator,
        ResetType.GracefulShutdown,
        .{},
    );
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("\"GracefulShutdown\"", written);
}
