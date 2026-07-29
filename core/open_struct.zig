//! Structs that keep the properties their schema does not name.
//!
//! A Redfish complex type annotated `OData.AdditionalProperties` is open: the
//! service is allowed to put anything it likes in it. That is how every OEM
//! extension arrives — `Oem` is an ordinary property whose *type* is open, and
//! the vendor's payload lives in members no schema declares.
//!
//! `std.json` has two answers for a member a struct does not declare: fail, or
//! drop it. Neither is right here. Failing makes a client break the moment a
//! BMC ships a new firmware; dropping loses exactly the data an OEM caller
//! came for. Rust's generator uses `#[serde(flatten)]` into a map, which is
//! the third answer, and this is its equivalent.
//!
//! A generated open struct declares an `additional_properties` field and
//! borrows its JSON hooks:
//!
//! ```zig
//! pub const Oem = struct {
//!     additional_properties: core.AdditionalProperties = .{},
//!
//!     const open = core.OpenStruct(@This());
//!     pub const jsonParse = open.jsonParse;
//!     pub const jsonParseFromValue = open.jsonParseFromValue;
//!     pub const jsonStringify = open.jsonStringify;
//! };
//! ```
//!
//! Note that `jsonStringify` is part of the deal: a value that round-trips
//! through this type must come out with the vendor's members still on it,
//! otherwise a read-modify-write PATCH would quietly delete them.

const std = @import("std");

/// The name of the field unrecognized members are collected into.
pub const extras_field = "additional_properties";

/// Where unrecognized members go. Insertion-ordered, so a value that is parsed
/// and written back comes out in the order it arrived.
pub const AdditionalProperties = std.json.ArrayHashMap(std.json.Value);

/// JSON hooks for a struct with an `additional_properties` field.
pub fn Open(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("open structs must be structs, found " ++ @typeName(T)),
    };
    if (!@hasField(T, extras_field)) {
        @compileError(@typeName(T) ++ " has no `" ++ extras_field ++ "` field");
    }

    return struct {
        const fields = info.fields;

        /// Whether a field is the extras field itself, which is never matched
        /// against a member name.
        fn isExtras(comptime name: []const u8) bool {
            return std.mem.eql(u8, name, extras_field);
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !T {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var result: T = undefined;
            var extras: std.json.ArrayHashMap(std.json.Value) = .{};
            var seen = [_]bool{false} ** fields.len;

            while (true) {
                const token = try source.nextAllocMax(
                    allocator,
                    .alloc_always,
                    options.max_value_len orelse std.json.default_max_value_len,
                );
                const member = switch (token) {
                    inline .string, .allocated_string => |text| text,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };

                inline for (fields, 0..) |field, index| {
                    if (comptime !isExtras(field.name)) {
                        if (std.mem.eql(u8, field.name, member)) {
                            if (seen[index]) switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    _ = try std.json.innerParse(field.type, allocator, source, options);
                                    break;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            };
                            @field(result, field.name) =
                                try std.json.innerParse(field.type, allocator, source, options);
                            seen[index] = true;
                            break;
                        }
                    }
                } else {
                    // Unknown to the schema this package was generated from,
                    // which is the whole point of the type being open.
                    const value = try std.json.innerParse(
                        std.json.Value,
                        allocator,
                        source,
                        options,
                    );
                    try extras.map.put(allocator, member, value);
                }
            }

            try fill(&result, seen);
            @field(result, extras_field) = extras;
            return result;
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !T {
            if (source != .object) return error.UnexpectedToken;

            var result: T = undefined;
            var extras: std.json.ArrayHashMap(std.json.Value) = .{};
            var seen = [_]bool{false} ** fields.len;

            var members = source.object.iterator();
            while (members.next()) |entry| {
                const member = entry.key_ptr.*;
                inline for (fields, 0..) |field, index| {
                    if (comptime !isExtras(field.name)) {
                        if (std.mem.eql(u8, field.name, member)) {
                            @field(result, field.name) = try std.json.innerParseFromValue(
                                field.type,
                                allocator,
                                entry.value_ptr.*,
                                options,
                            );
                            seen[index] = true;
                            break;
                        }
                    }
                } else {
                    try extras.map.put(allocator, member, entry.value_ptr.*);
                }
            }

            try fill(&result, seen);
            @field(result, extras_field) = extras;
            return result;
        }

        /// Gives every member the schema did not send its default, and fails
        /// on the ones that have none.
        fn fill(result: *T, seen: [fields.len]bool) error{MissingField}!void {
            inline for (fields, 0..) |field, index| {
                if (comptime !isExtras(field.name)) {
                    if (!seen[index]) {
                        const default = field.defaultValue() orelse return error.MissingField;
                        @field(result, field.name) = default;
                    }
                }
            }
        }

        pub fn jsonStringify(self: T, jws: anytype) !void {
            try jws.beginObject();
            inline for (fields) |field| {
                if (comptime !isExtras(field.name) and field.type != void) {
                    const value = @field(self, field.name);
                    const omit = @typeInfo(field.type) == .optional and
                        !jws.options.emit_null_optional_fields and
                        value == null;
                    if (!omit) {
                        try jws.objectField(field.name);
                        try jws.write(value);
                    }
                }
            }

            const extras = @field(self, extras_field);
            for (extras.map.keys(), extras.map.values()) |member, value| {
                try jws.objectField(member);
                try jws.write(value);
            }
            try jws.endObject();
        }
    };
}

const testing = std.testing;

const Oem = struct {
    Name: ?[]const u8 = null,
    Count: i64 = 0,
    additional_properties: AdditionalProperties = .{},

    const open = Open(@This());
    pub const jsonParse = open.jsonParse;
    pub const jsonParseFromValue = open.jsonParseFromValue;
    pub const jsonStringify = open.jsonStringify;
};

test "a declared member lands in its field" {
    const parsed = try std.json.parseFromSlice(
        Oem,
        testing.allocator,
        \\{"Name":"fan","Count":3}
    ,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("fan", parsed.value.Name.?);
    try testing.expectEqual(@as(i64, 3), parsed.value.Count);
    try testing.expectEqual(@as(usize, 0), parsed.value.additional_properties.map.count());
}

test "an undeclared member is kept rather than dropped" {
    const parsed = try std.json.parseFromSlice(
        Oem,
        testing.allocator,
        \\{"Name":"fan","Nvidia":{"Speed":42},"Vendor":"acme"}
    ,
        .{},
    );
    defer parsed.deinit();

    const extras = parsed.value.additional_properties.map;
    try testing.expectEqual(@as(usize, 2), extras.count());
    try testing.expectEqual(
        @as(i64, 42),
        extras.get("Nvidia").?.object.get("Speed").?.integer,
    );
    try testing.expectEqualStrings("acme", extras.get("Vendor").?.string);
}

test "a missing member falls back to its default" {
    const parsed = try std.json.parseFromSlice(Oem, testing.allocator, "{}", .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(?[]const u8, null), parsed.value.Name);
    try testing.expectEqual(@as(i64, 0), parsed.value.Count);
}

test "a member with no default is still required" {
    const Strict = struct {
        Id: []const u8,
        additional_properties: AdditionalProperties = .{},

        const open = Open(@This());
        pub const jsonParse = open.jsonParse;
    };

    try testing.expectError(error.MissingField, std.json.parseFromSlice(
        Strict,
        testing.allocator,
        "{}",
        .{},
    ));
}

test "parsing from a value keeps undeclared members too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"Count":7,"Dell":{"Tag":"abc"}}
    ,
        .{},
    );
    const oem = try std.json.parseFromValueLeaky(Oem, arena.allocator(), value, .{});

    try testing.expectEqual(@as(i64, 7), oem.Count);
    try testing.expectEqualStrings("abc", oem.additional_properties.map.get("Dell").?.object.get("Tag").?.string);
}

test "writing back keeps what reading kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\{"Name":"fan","Count":3,"Nvidia":{"Speed":42}}
    ;
    const oem = try std.json.parseFromSliceLeaky(Oem, arena.allocator(), source, .{});
    const written = try std.json.Stringify.valueAlloc(arena.allocator(), oem, .{});

    try testing.expectEqualStrings(source, written);
}

test "an unset optional is omitted when the caller asks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const written = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        Oem{ .Count = 1 },
        .{ .emit_null_optional_fields = false },
    );
    try testing.expectEqualStrings(
        \\{"Count":1}
    , written);
}

test "a duplicate member is an error unless the caller says otherwise" {
    const source =
        \\{"Count":1,"Count":2}
    ;
    try testing.expectError(error.DuplicateField, std.json.parseFromSlice(
        Oem,
        testing.allocator,
        source,
        .{},
    ));

    const parsed = try std.json.parseFromSlice(
        Oem,
        testing.allocator,
        source,
        .{ .duplicate_field_behavior = .use_last },
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.Count);
}
