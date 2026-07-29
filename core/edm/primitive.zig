//! `Edm.PrimitiveType` — the open primitive slot OData uses where a schema
//! declines to name a concrete type.
//!
//! Serializes untagged, exactly like `nv-redfish`'s `EdmPrimitiveType`: the
//! JSON carries a bare string, boolean, or number with no discriminator.

const std = @import("std");
const decimal = @import("decimal.zig");

const Decimal = decimal.Decimal;

/// A value of any EDM primitive type.
///
/// `string` borrows from the arena that owns the surrounding response, so it
/// lives exactly as long as its `Owned(T)`.
pub const PrimitiveType = union(enum) {
    string: []const u8,
    boolean: bool,
    /// A JSON number with no fractional part.
    integer: i64,
    /// A JSON number that did not fit `integer`, held exactly.
    decimal: Decimal,

    pub fn format(self: PrimitiveType, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .string => |s| try w.writeAll(s),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |i| try w.print("{d}", .{i}),
            .decimal => |d| try d.format(w),
        }
    }

    pub fn jsonStringify(self: PrimitiveType, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .boolean => |b| try jw.write(b),
            .integer => |i| try jw.write(i),
            .decimal => |d| try d.jsonStringify(jw),
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !PrimitiveType {
        const max_len = options.max_value_len orelse std.json.default_max_value_len;
        switch (try source.peekNextTokenType()) {
            .true, .false => return .{ .boolean = switch (try source.next()) {
                .true => true,
                .false => false,
                else => unreachable,
            } },
            .number, .string => {},
            else => return error.UnexpectedToken,
        }

        const token = try source.nextAllocMax(
            allocator,
            options.allocate orelse .alloc_always,
            max_len,
        );
        return switch (token) {
            inline .string, .allocated_string => |slice| .{ .string = slice },
            inline .number, .allocated_number => |slice| fromNumberSlice(slice),
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !PrimitiveType {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| .{ .string = s },
            .bool => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .number_string => |s| fromNumberSlice(s),
            .float => |f| blk: {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{f}) catch
                    return error.InvalidCharacter;
                break :blk fromNumberSlice(text);
            },
            else => error.UnexpectedToken,
        };
    }

    fn fromNumberSlice(slice: []const u8) error{InvalidCharacter}!PrimitiveType {
        if (std.fmt.parseInt(i64, slice, 10)) |value| {
            return .{ .integer = value };
        } else |_| {}
        const value = Decimal.parse(slice) catch return error.InvalidCharacter;
        return .{ .decimal = value };
    }
};

const testing = std.testing;

fn expectRoundTrip(comptime json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(PrimitiveType, testing.allocator, json, .{});
    defer parsed.deinit();

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(parsed.value, .{}, &w);
    try testing.expectEqualStrings(json, w.buffered());
}

test "parses each primitive shape" {
    const cases = .{
        .{ "\"text\"", PrimitiveType{ .string = "text" } },
        .{ "true", PrimitiveType{ .boolean = true } },
        .{ "false", PrimitiveType{ .boolean = false } },
        .{ "42", PrimitiveType{ .integer = 42 } },
        .{ "-42", PrimitiveType{ .integer = -42 } },
    };
    inline for (cases) |case| {
        const parsed = try std.json.parseFromSlice(PrimitiveType, testing.allocator, case[0], .{});
        defer parsed.deinit();
        try testing.expectEqualDeep(case[1], parsed.value);
    }
}

test "a fractional number becomes an exact decimal, not a float" {
    const parsed = try std.json.parseFromSlice(
        PrimitiveType,
        testing.allocator,
        "0.1000000000000000055511151231",
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.decimal.eql(
        try Decimal.parse("0.1000000000000000055511151231"),
    ));
}

test "an integer too large for i64 falls back to a decimal" {
    const parsed = try std.json.parseFromSlice(
        PrimitiveType,
        testing.allocator,
        "170141183460469231731687303715",
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.decimal.eql(
        try Decimal.parse("170141183460469231731687303715"),
    ));
}

test "round-trips untagged, with no discriminator" {
    try expectRoundTrip("\"text\"");
    try expectRoundTrip("true");
    try expectRoundTrip("false");
    try expectRoundTrip("42");
    try expectRoundTrip("-42");
    try expectRoundTrip("1.25");
}

test "the string variant survives its input buffer with alloc_always" {
    const owned = @import("../owned.zig");

    const body = try testing.allocator.dupe(u8, "\"borrowed\"");
    const parsed = try owned.parseJson(PrimitiveType, testing.allocator, body, null);
    defer parsed.deinit();

    @memset(body, 'x');
    testing.allocator.free(body);

    try testing.expectEqualStrings("borrowed", parsed.value.string);
}

test "rejects composite and null values" {
    inline for (.{ "null", "[]", "{}" }) |bad| {
        try testing.expectError(
            error.UnexpectedToken,
            std.json.parseFromSlice(PrimitiveType, testing.allocator, bad, .{}),
        );
    }
}

test "parses from a decoded value tree" {
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"a\":\"text\",\"b\":true,\"c\":42,\"d\":1.25}",
        .{},
    );
    defer doc.deinit();

    const object = doc.value.object;
    const cases = .{
        .{ "a", PrimitiveType{ .string = "text" } },
        .{ "b", PrimitiveType{ .boolean = true } },
        .{ "c", PrimitiveType{ .integer = 42 } },
        .{ "d", PrimitiveType{ .decimal = .{ .mantissa = 125, .scale = 2 } } },
    };
    inline for (cases) |case| {
        const parsed = try std.json.parseFromValue(
            PrimitiveType,
            testing.allocator,
            object.get(case[0]).?,
            .{},
        );
        defer parsed.deinit();
        try testing.expectEqualDeep(case[1], parsed.value);
    }
}

test "formats as the bare value" {
    var buf: [64]u8 = undefined;
    const cases = .{
        .{ "text", PrimitiveType{ .string = "text" } },
        .{ "true", PrimitiveType{ .boolean = true } },
        .{ "42", PrimitiveType{ .integer = 42 } },
        .{ "1.25", PrimitiveType{ .decimal = .{ .mantissa = 125, .scale = 2 } } },
    };
    inline for (cases) |case| {
        try testing.expectEqualStrings(
            case[0],
            try std.fmt.bufPrint(&buf, "{f}", .{case[1]}),
        );
    }
}
