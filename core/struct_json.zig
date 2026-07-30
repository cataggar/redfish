//! Reading one member of a generated struct, and the closed struct that needs
//! it.
//!
//! ## Some strings are not values
//!
//! `Edm.Guid`, `Edm.DateTimeOffset` and `Edm.Duration` are strings with a
//! lexical form, and none of those forms has an empty case. A service that
//! sends `"UUID": ""` has not sent a UUID; it has said it does not have one,
//! in the only way its firmware knows how. NVIDIA's DPU does exactly that in
//! NIC mode, and it is not unusual — an empty `DateTime` is common enough on
//! BMCs to be unremarkable.
//!
//! Parsed strictly, that costs the caller the whole resource, because the
//! failure belongs to the payload and not to the property. This stack has
//! already refused that trade twice: an enum value the schema does not name
//! becomes `UnsupportedValue` rather than failing, and `Redfish.Required` is
//! not enforced because it describes a conformant service rather than a real
//! one. The same answer applies here, and the line is exact:
//!
//! - `""` reads as **absent**. An empty string is an absence spelled out
//!   loud, and absent is what the property already means when the service
//!   says nothing at all.
//! - `"2024-13-45"` still **fails**. That is a value that is wrong, and
//!   reading it as absent would tell the caller the service was silent when
//!   it was not.
//!
//! A type may name further spellings of the same absence, and one does:
//! `DateTimeOffset.spellsAbsence` reads the all-zero timestamp — Dell's
//! `"0000-00-00T00:00:00+00:00"`, a firmware inventory's `"00:00:00Z"` — as
//! absent too, on the ground that no timestamp anyone meant has all-zero
//! digits.
//!
//! It applies only to an *optional* field of a formatted type. `Edm.String`
//! is untouched: an empty string there is a perfectly good string, and the
//! commonest one.
//!
//! ## Why a closed struct needs a parser at all
//!
//! Zig offers no hook for a single field, and `std.json` decodes `?T` itself
//! — it looks for the `null` token and otherwise delegates to `T`, which by
//! then can only answer with a `T`. So a type that wants to say "absent"
//! about its own field has to be the thing doing the reading, which means the
//! struct.
//!
//! Only the structs that declare such a field get one. `Closed` is emitted
//! for those and for nothing else, so every other generated struct decodes
//! through `std.json` exactly as before. `Open` (`open_struct.zig`) shares
//! the member rule so the two cannot drift, though as of writing no open
//! struct in the standard schema declares a formatted scalar.

const std = @import("std");
const edm = @import("edm.zig");

/// Whether an empty JSON string cannot be a value of `T`.
fn isFormatted(comptime T: type) bool {
    return T == edm.Guid or T == edm.DateTimeOffset or T == edm.Duration;
}

/// Whether a *field* of type `F` reads an empty string as absent.
///
/// Optional only. A non-optional field has nowhere to put the absence, and a
/// collection of formatted scalars is not covered: an empty string inside an
/// array is a member the service claimed exists, which is a different
/// statement from a property it does not have.
pub fn readsEmptyAsAbsent(comptime F: type) bool {
    const optional = switch (@typeInfo(F)) {
        .optional => |o| o,
        else => return false,
    };
    return isFormatted(optional.child);
}

/// Whether `text` is a spelling of absence rather than a value.
///
/// The empty string is one for every formatted scalar, because none of the
/// three grammars has an empty case. A type may name others: see
/// `DateTimeOffset.spellsAbsence`, which covers the all-zero timestamp a
/// service writes when it has no timestamp and its encoder will not omit the
/// field.
fn spellsAbsence(comptime Inner: type, text: []const u8) bool {
    if (text.len == 0) return true;
    if (@hasDecl(Inner, "spellsAbsence")) return Inner.spellsAbsence(text);
    return false;
}

/// Reads one member from a streaming source.
pub fn parseMember(
    comptime F: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !F {
    if (comptime !readsEmptyAsAbsent(F)) {
        return std.json.innerParse(F, allocator, source, options);
    }

    // Only a string can be the empty one, and every other token — including
    // `null` — means whatever it already meant.
    if (try source.peekNextTokenType() != .string) {
        return std.json.innerParse(F, allocator, source, options);
    }

    const token = try source.nextAllocMax(
        allocator,
        .alloc_always,
        options.max_value_len orelse std.json.default_max_value_len,
    );
    const text = switch (token) {
        inline .string, .allocated_string => |slice| slice,
        else => return error.UnexpectedToken,
    };
    const Inner = @typeInfo(F).optional.child;
    if (spellsAbsence(Inner, text)) return null;

    // Hand the text back to the scalar so that a malformed value fails with
    // the error that type would have produced on its own.
    return try Inner.jsonParseFromValue(allocator, .{ .string = text }, options);
}

/// Reads one member from an already-parsed tree.
pub fn parseMemberFromValue(
    comptime F: type,
    allocator: std.mem.Allocator,
    source: std.json.Value,
    options: std.json.ParseOptions,
) !F {
    if (comptime readsEmptyAsAbsent(F)) {
        const Inner = @typeInfo(F).optional.child;
        if (source == .string and spellsAbsence(Inner, source.string)) return null;
    }
    return std.json.innerParseFromValue(F, allocator, source, options);
}

/// JSON reading hooks for a struct that keeps no unrecognized members.
///
/// A generated struct borrows them the way an open one borrows `Open`:
///
/// ```zig
/// pub const Chassis = struct {
///     UUID: ?core.Guid = null,
///
///     const closed = core.ClosedStruct(@This());
///     pub const jsonParse = closed.jsonParse;
///     pub const jsonParseFromValue = closed.jsonParseFromValue;
/// };
/// ```
///
/// There is no `jsonStringify`: writing a closed struct was already right,
/// and `std.json` keeps doing it.
///
/// Everything except the member rule matches `std.json`'s own struct parser,
/// `duplicate_field_behavior` and `ignore_unknown_fields` included, because a
/// type that decodes differently depending on whether it happens to declare a
/// UUID would be worse than the problem being solved.
pub fn Closed(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("closed structs must be structs, found " ++ @typeName(T)),
    };

    return struct {
        const fields = info.fields;

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !T {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var result: T = undefined;
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
                    if (std.mem.eql(u8, field.name, member)) {
                        if (seen[index]) switch (options.duplicate_field_behavior) {
                            .use_first => {
                                // Parsed rather than skipped, so a second copy
                                // is still type-checked.
                                _ = try parseMember(field.type, allocator, source, options);
                                break;
                            },
                            .@"error" => return error.DuplicateField,
                            .use_last => {},
                        };
                        @field(result, field.name) =
                            try parseMember(field.type, allocator, source, options);
                        seen[index] = true;
                        break;
                    }
                } else {
                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                    } else {
                        return error.UnknownField;
                    }
                }
            }

            try fill(&result, seen);
            return result;
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !T {
            if (source != .object) return error.UnexpectedToken;

            var result: T = undefined;
            var seen = [_]bool{false} ** fields.len;

            var members = source.object.iterator();
            while (members.next()) |entry| {
                const member = entry.key_ptr.*;
                inline for (fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field.name, member)) {
                        @field(result, field.name) = try parseMemberFromValue(
                            field.type,
                            allocator,
                            entry.value_ptr.*,
                            options,
                        );
                        seen[index] = true;
                        break;
                    }
                } else {
                    if (!options.ignore_unknown_fields) return error.UnknownField;
                }
            }

            try fill(&result, seen);
            return result;
        }

        /// Gives every member the service did not send its default, and fails
        /// on the ones that have none.
        fn fill(result: *T, seen: [fields.len]bool) error{MissingField}!void {
            inline for (fields, 0..) |field, index| {
                if (!seen[index]) {
                    const default = field.defaultValue() orelse return error.MissingField;
                    @field(result, field.name) = default;
                }
            }
        }
    };
}

const testing = std.testing;

/// Shaped as the emitter writes a resource that declares a formatted scalar.
const Chassis = struct {
    Id: ?[]const u8 = null,
    Name: ?[]const u8 = null,
    UUID: ?edm.Guid = null,
    ProductionDate: ?edm.DateTimeOffset = null,
    EjectTimeout: ?edm.Duration = null,

    const closed = Closed(@This());
    pub const jsonParse = closed.jsonParse;
    pub const jsonParseFromValue = closed.jsonParseFromValue;
};

fn parse(json: []const u8, options: std.json.ParseOptions) !std.json.Parsed(Chassis) {
    return std.json.parseFromSlice(Chassis, testing.allocator, json, options);
}

/// The same payload through the tree, which is the path a nested value takes.
fn parseViaValue(json: []const u8, options: std.json.ParseOptions) !std.json.Parsed(Chassis) {
    const tree = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer tree.deinit();
    return std.json.parseFromValue(Chassis, testing.allocator, tree.value, options);
}

test "an empty string reads as absent, on every formatted type" {
    for ([_]std.json.ParseOptions{
        .{ .ignore_unknown_fields = true },
        .{},
    }) |options| {
        for ([_]*const fn ([]const u8, std.json.ParseOptions) anyerror!std.json.Parsed(Chassis){
            &parse,
            &parseViaValue,
        }) |through| {
            const parsed = try through(
                \\{"Id":"1","UUID":"","ProductionDate":"","EjectTimeout":""}
            , options);
            defer parsed.deinit();

            try testing.expectEqualStrings("1", parsed.value.Id.?);
            try testing.expect(parsed.value.UUID == null);
            try testing.expect(parsed.value.ProductionDate == null);
            try testing.expect(parsed.value.EjectTimeout == null);
        }
    }
}

test "a value that is merely wrong still fails" {
    // The distinction the whole rule rests on: absent is a statement the
    // service is entitled to make, and a malformed value is not.
    try testing.expectError(error.InvalidCharacter, parse(
        \\{"UUID":"not-a-uuid"}
    , .{}));
    try testing.expectError(error.InvalidCharacter, parseViaValue(
        \\{"UUID":"not-a-uuid"}
    , .{}));
    try testing.expectError(error.InvalidCharacter, parse(
        \\{"ProductionDate":"2024-13-45"}
    , .{}));
}

test "a well-formed value is unaffected" {
    const parsed = try parse(
        \\{"UUID":"92384634-2938-2342-8820-489239905423"}
    , .{});
    defer parsed.deinit();

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{parsed.value.UUID.?});
    try testing.expectEqualStrings("92384634-2938-2342-8820-489239905423", writer.buffered());
}

test "an explicit null is still a null, and a non-string is still rejected" {
    const parsed = try parse(
        \\{"UUID":null}
    , .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.UUID == null);

    try testing.expectError(error.UnexpectedToken, parse(
        \\{"UUID":42}
    , .{}));
}

test "an empty string is still a string" {
    // The rule reaches formatted scalars and nothing else. `Name` is
    // `Edm.String`, for which the empty string is the commonest value there
    // is, and reading it as absent would lose data on every payload.
    const parsed = try parse(
        \\{"Name":""}
    , .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("", parsed.value.Name.?);
}

test "strictness is std's, in both directions" {
    try testing.expectError(error.UnknownField, parse(
        \\{"Unknown":1}
    , .{}));
    try testing.expectError(error.UnknownField, parseViaValue(
        \\{"Unknown":1}
    , .{}));

    const ignored = try parse(
        \\{"Unknown":1,"Id":"1"}
    , .{ .ignore_unknown_fields = true });
    defer ignored.deinit();
    try testing.expectEqualStrings("1", ignored.value.Id.?);

    try testing.expectError(error.DuplicateField, parse(
        \\{"Id":"1","Id":"2"}
    , .{}));

    const last = try parse(
        \\{"Id":"1","Id":"2"}
    , .{ .duplicate_field_behavior = .use_last });
    defer last.deinit();
    try testing.expectEqualStrings("2", last.value.Id.?);

    const first = try parse(
        \\{"UUID":"","UUID":"92384634-2938-2342-8820-489239905423"}
    , .{ .duplicate_field_behavior = .use_first });
    defer first.deinit();
    // Read and discarded rather than skipped, so the second copy was still
    // type-checked -- and the first, being empty, is still absent.
    try testing.expect(first.value.UUID == null);
}

test "a member with no default is still required" {
    const Required = struct {
        Id: []const u8,
        UUID: ?edm.Guid = null,

        const closed = Closed(@This());
        pub const jsonParse = closed.jsonParse;
        pub const jsonParseFromValue = closed.jsonParseFromValue;
    };

    try testing.expectError(error.MissingField, std.json.parseFromSlice(
        Required,
        testing.allocator,
        \\{"UUID":""}
    ,
        .{},
    ));
}

test "an all-zero timestamp reads as absent too, on both paths" {
    for ([_]*const fn ([]const u8, std.json.ParseOptions) anyerror!std.json.Parsed(Chassis){
        &parse,
        &parseViaValue,
    }) |read| {
        const parsed = try read(
            \\{"Id":"1","ProductionDate":"0000-00-00T00:00:00+00:00"}
        , .{});
        defer parsed.deinit();

        try testing.expect(parsed.value.ProductionDate == null);
        try testing.expectEqualStrings("1", parsed.value.Id.?);
    }
}

test "only the type that named the spelling honours it" {
    // `Duration` and `Guid` declare no `spellsAbsence`, so an all-zero string
    // of either is nothing special -- and neither is a Guid of all zeros,
    // which is the nil UUID and a value in its own right.
    for ([_]*const fn ([]const u8, std.json.ParseOptions) anyerror!std.json.Parsed(Chassis){
        &parse,
        &parseViaValue,
    }) |read| {
        const parsed = try read(
            \\{"UUID":"00000000-0000-0000-0000-000000000000"}
        , .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.UUID.?.isNil());

        try testing.expectError(error.InvalidCharacter, read(
            \\{"EjectTimeout":"P0"}
        , .{}));
    }
}

test "a formatted scalar that is not optional is left to std" {
    // Nowhere to put the absence, so the empty string is what it always was:
    // a value of the wrong shape.
    try testing.expect(!readsEmptyAsAbsent(edm.Guid));
    try testing.expect(readsEmptyAsAbsent(?edm.Guid));
    try testing.expect(!readsEmptyAsAbsent(?[]const u8));
    try testing.expect(!readsEmptyAsAbsent(?[]const edm.Guid));
}

test {
    testing.refAllDecls(@This());
}
