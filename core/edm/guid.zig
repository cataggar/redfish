//! `Edm.Guid` — RFC 9562 (formerly RFC 4122) UUIDs.
//!
//! Stored as the 16 raw bytes in network order. Parsing accepts the same four
//! spellings the Rust `uuid` crate does, so payloads written by `nv-redfish`
//! are read identically; formatting always produces the canonical lowercase
//! hyphenated form.

const std = @import("std");

pub const Error = error{
    /// The text is not a well-formed UUID in any accepted spelling.
    InvalidGuid,
};

pub const Guid = struct {
    bytes: [16]u8,

    pub const nil: Guid = .{ .bytes = @splat(0) };
    pub const max: Guid = .{ .bytes = @splat(0xff) };

    pub fn fromBytes(bytes: [16]u8) Guid {
        return .{ .bytes = bytes };
    }

    /// Parse the hyphenated form (`67e5504410b1426f9247bb680e5fe0c8` with
    /// dashes), the simple 32-hex form, the braced form, or the
    /// `urn:uuid:` form. Hex digits may be upper or lower case.
    pub fn parse(text: []const u8) Error!Guid {
        var rest = text;
        if (rest.len >= 2 and rest[0] == '{' and rest[rest.len - 1] == '}') {
            rest = rest[1 .. rest.len - 1];
        } else if (rest.len > 9 and std.ascii.eqlIgnoreCase(rest[0..9], "urn:uuid:")) {
            rest = rest[9..];
        }

        return switch (rest.len) {
            36 => parseHyphenated(rest),
            32 => parseSimple(rest),
            else => Error.InvalidGuid,
        };
    }

    fn parseHyphenated(text: []const u8) Error!Guid {
        const group_lengths = [_]usize{ 8, 4, 4, 4, 12 };

        var self: Guid = undefined;
        var cursor: usize = 0;
        var written: usize = 0;
        for (group_lengths, 0..) |length, group| {
            if (group != 0) {
                if (text[cursor] != '-') return Error.InvalidGuid;
                cursor += 1;
            }
            var i: usize = 0;
            while (i < length) : (i += 2) {
                self.bytes[written] = try hexByte(text[cursor + i ..][0..2].*);
                written += 1;
            }
            cursor += length;
        }
        return self;
    }

    fn parseSimple(text: []const u8) Error!Guid {
        var self: Guid = undefined;
        for (&self.bytes, 0..) |*slot, i| {
            slot.* = try hexByte(text[i * 2 ..][0..2].*);
        }
        return self;
    }

    pub fn eql(self: Guid, other: Guid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn order(self: Guid, other: Guid) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn isNil(self: Guid) bool {
        return self.eql(nil);
    }

    /// The RFC 9562 version nibble, or null for the nil and max UUIDs and any
    /// value whose variant is not the RFC one.
    pub fn version(self: Guid) ?u4 {
        if (self.variant() != .rfc9562) return null;
        return @intCast(self.bytes[6] >> 4);
    }

    pub const Variant = enum { ncs, rfc9562, microsoft, future };

    pub fn variant(self: Guid) Variant {
        const octet = self.bytes[8];
        if (octet & 0x80 == 0x00) return .ncs;
        if (octet & 0xc0 == 0x80) return .rfc9562;
        if (octet & 0xe0 == 0xc0) return .microsoft;
        return .future;
    }

    /// Canonical lowercase hyphenated form, always 36 characters.
    pub fn format(self: Guid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [36]u8 = undefined;
        try w.writeAll(self.bufPrint(&buf));
    }

    /// Render into a caller-provided buffer, for callers that need the text
    /// without a writer.
    pub fn bufPrint(self: Guid, buf: *[36]u8) []const u8 {
        const hyphens_after = [_]usize{ 4, 6, 8, 10 };

        var out: usize = 0;
        for (self.bytes, 0..) |byte, i| {
            buf[out] = std.fmt.hex_charset[byte >> 4];
            buf[out + 1] = std.fmt.hex_charset[byte & 0x0f];
            out += 2;
            if (std.mem.indexOfScalar(usize, &hyphens_after, i + 1) != null) {
                buf[out] = '-';
                out += 1;
            }
        }
        return buf[0..out];
    }

    pub fn jsonStringify(self: Guid, jw: anytype) !void {
        var buf: [36]u8 = undefined;
        try jw.write(self.bufPrint(&buf));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Guid {
        const token = try source.nextAllocMax(
            allocator,
            .alloc_if_needed,
            options.max_value_len orelse std.json.default_max_value_len,
        );
        const text = switch (token) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
        return parse(text) catch error.InvalidCharacter;
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Guid {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) catch error.InvalidCharacter,
            else => error.UnexpectedToken,
        };
    }
};

fn hexByte(pair: [2]u8) Error!u8 {
    // `std.fmt.parseInt` would accept a sign and underscores, so decode the
    // two nibbles directly.
    return (try hexNibble(pair[0])) << 4 | try hexNibble(pair[1]);
}

fn hexNibble(c: u8) Error!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => Error.InvalidGuid,
    };
}

const testing = std.testing;

const sample_text = "67e55044-10b1-426f-9247-bb680e5fe0c8";
const sample_bytes = [16]u8{
    0x67, 0xe5, 0x50, 0x44, 0x10, 0xb1, 0x42, 0x6f,
    0x92, 0x47, 0xbb, 0x68, 0x0e, 0x5f, 0xe0, 0xc8,
};

fn expectFormat(expected: []const u8, value: Guid) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

test "parses the canonical hyphenated form" {
    const value = try Guid.parse(sample_text);
    try testing.expectEqualSlices(u8, &sample_bytes, &value.bytes);
    try expectFormat(sample_text, value);
}

test "parses the alternative spellings the uuid crate accepts" {
    const expected = Guid.fromBytes(sample_bytes);
    inline for (.{
        sample_text,
        "67e5504410b1426f9247bb680e5fe0c8",
        "{67e55044-10b1-426f-9247-bb680e5fe0c8}",
        "{67e5504410b1426f9247bb680e5fe0c8}",
        "urn:uuid:67e55044-10b1-426f-9247-bb680e5fe0c8",
        "URN:UUID:67e55044-10b1-426f-9247-bb680e5fe0c8",
    }) |text| {
        try testing.expect(expected.eql(try Guid.parse(text)));
    }
}

test "parsing is case-insensitive but formatting is lowercase" {
    const upper = try Guid.parse("67E55044-10B1-426F-9247-BB680E5FE0C8");
    try testing.expect(upper.eql(Guid.fromBytes(sample_bytes)));
    try expectFormat(sample_text, upper);
}

test "rejects malformed input" {
    inline for (.{
        "",
        "not-a-uuid",
        // One digit short and one digit long.
        "67e55044-10b1-426f-9247-bb680e5fe0c",
        "67e55044-10b1-426f-9247-bb680e5fe0c88",
        // Hyphens in the wrong places.
        "67e550441-0b1-426f-9247-bb680e5fe0c8",
        "67e55044.10b1.426f.9247.bb680e5fe0c8",
        // Non-hex digits.
        "67e55044-10b1-426f-9247-bb680e5fe0cg",
        "67e55044-10b1-426f-9247-bb680e5fe0c ",
        // `+` and whitespace are accepted by parseInt but not by us.
        "+7e55044-10b1-426f-9247-bb680e5fe0c8",
        // Unbalanced braces.
        "{67e55044-10b1-426f-9247-bb680e5fe0c8",
        "67e55044-10b1-426f-9247-bb680e5fe0c8}",
    }) |bad| {
        try testing.expectError(Error.InvalidGuid, Guid.parse(bad));
    }
}

test "nil and max round-trip" {
    try expectFormat("00000000-0000-0000-0000-000000000000", Guid.nil);
    try expectFormat("ffffffff-ffff-ffff-ffff-ffffffffffff", Guid.max);
    try testing.expect(Guid.nil.isNil());
    try testing.expect(!Guid.max.isNil());
    try testing.expect(Guid.nil.eql(try Guid.parse("00000000-0000-0000-0000-000000000000")));
}

test "reports the version and variant" {
    const v4 = try Guid.parse(sample_text);
    try testing.expectEqual(Guid.Variant.rfc9562, v4.variant());
    try testing.expectEqual(@as(?u4, 4), v4.version());

    try testing.expectEqual(Guid.Variant.ncs, Guid.nil.variant());
    try testing.expectEqual(@as(?u4, null), Guid.nil.version());
    try testing.expectEqual(Guid.Variant.future, Guid.max.variant());
}

test "order sorts by the raw bytes" {
    const low = try Guid.parse("00000000-0000-0000-0000-000000000001");
    const high = try Guid.parse("00000000-0000-0000-0000-000000000002");
    try testing.expectEqual(std.math.Order.lt, low.order(high));
    try testing.expectEqual(std.math.Order.gt, high.order(low));
    try testing.expectEqual(std.math.Order.eq, low.order(low));
}

test "works as a hash map key" {
    var map: std.AutoHashMapUnmanaged(Guid, u32) = .empty;
    defer map.deinit(testing.allocator);

    try map.put(testing.allocator, try Guid.parse(sample_text), 7);
    try testing.expectEqual(@as(?u32, 7), map.get(Guid.fromBytes(sample_bytes)));
    try testing.expectEqual(@as(?u32, null), map.get(Guid.nil));
}

test "JSON round-trips as a string" {
    const System = struct { UUID: Guid };

    var buf: [96]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(System{ .UUID = Guid.fromBytes(sample_bytes) }, .{}, &w);
    try testing.expectEqualStrings("{\"UUID\":\"" ++ sample_text ++ "\"}", w.buffered());

    const parsed = try std.json.parseFromSlice(System, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.UUID.eql(Guid.fromBytes(sample_bytes)));
}

test "JSON parses from a decoded value tree" {
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"UUID\":\"" ++ sample_text ++ "\"}",
        .{},
    );
    defer doc.deinit();

    const parsed = try std.json.parseFromValue(
        Guid,
        testing.allocator,
        doc.value.object.get("UUID").?,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.eql(Guid.fromBytes(sample_bytes)));
}

test "JSON rejects a non-string token and a malformed string" {
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Guid, testing.allocator, "12", .{}),
    );
    try testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(Guid, testing.allocator, "\"nope\"", .{}),
    );
}
