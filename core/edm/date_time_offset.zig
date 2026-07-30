//! `Edm.DateTimeOffset` — RFC 3339 timestamps.
//!
//! The civil fields are stored exactly as written together with the offset, so
//! a parse/format round trip preserves the sender's local time and offset. The
//! only canonicalization is that a zero offset — spelled `+00:00`, `-00:00`,
//! or `Z` — always formats back as `Z`.
//!
//! Parsing is deliberately looser than RFC 3339, because services are. Of
//! DMTF's own 3,780 published mockups, 21 carry a timestamp the grammar
//! rejects: `2012-03-07T14:44` drops the seconds, `2024-11-15T06:18:37` drops
//! the offset, `+6:00` writes the offset hour with one digit, and one has a
//! trailing space. A client that refuses the whole resource over the shape of
//! one timestamp is no use, so all four are accepted. What is *not* done is
//! invent an offset: a timestamp that arrived without one says so, and formats
//! back without one, rather than claiming to be UTC.
//!
//! References:
//! - OASIS OData 4.01 CSDL Part 3, primitive type `Edm.DateTimeOffset`.
//! - RFC 3339, Date and Time on the Internet.
//! - DMTF Redfish Specification DSP0266.

const std = @import("std");

pub const Error = error{
    /// The text is not a well-formed RFC 3339 date-time.
    InvalidDateTime,
    /// The instant does not fit in the requested representation.
    Overflow,
};

/// Number of fractional-second digits retained. Anything beyond is truncated,
/// which keeps a BMC that reports sub-nanosecond noise from failing a parse.
pub const fractional_digits = 9;

const nanoseconds_per_second = 1_000_000_000;
const seconds_per_minute = 60;
const seconds_per_hour = 60 * seconds_per_minute;
const seconds_per_day = 24 * seconds_per_hour;

pub const DateTimeOffset = struct {
    year: u16,
    /// 1-12.
    month: u8,
    /// 1-31, validated against the month and the leap year.
    day: u8,
    /// 0-23.
    hour: u8,
    /// 0-59. Leap seconds are rejected: OData has no representation for them.
    minute: u8,
    /// 0-59.
    second: u8,
    /// 0-999_999_999.
    nanosecond: u32,
    /// Offset from UTC in minutes, -1439 to 1439. Zero prints as `Z`.
    offset_minutes: i16,
    /// Whether the sender gave an offset at all. When false `offset_minutes`
    /// is zero, every instant calculation treats the value as UTC because
    /// there is nothing else to treat it as, and `format` writes no suffix.
    offset_specified: bool = true,

    pub const unix_epoch: DateTimeOffset = .{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .offset_minutes = 0,
    };

    /// Whether `text` is a timestamp that denotes no instant.
    ///
    /// A service with no value for a required-looking timestamp sometimes
    /// zeroes every field rather than omit it: Dell writes
    /// `"0000-00-00T00:00:00+00:00"` for a `LastResetTime` on a system that
    /// has never been reset, and firmware inventories write
    /// `"0000-00-00T00:00:00Z"` and even `"00:00:00Z"` for a `ReleaseDate`
    /// nobody recorded. All of those are the zero value of a struct, reached
    /// by an encoder that had nothing to say and no way to say so.
    ///
    /// The test is that every digit present is `0`. That can never absorb a
    /// value a service meant, because months and days are one-based: no
    /// timestamp this type would accept has all-zero digits, so a string that
    /// does was never a timestamp. It is deliberately narrower than "invalid":
    /// `"2024-13-45"` is a real value formatted wrong, and reading *that* as
    /// absent would report a silence the service never kept.
    ///
    /// `parse` still rejects all of these. Only a struct reading an optional
    /// field has somewhere to put the absence; see `core/struct_json.zig`.
    pub fn spellsAbsence(raw: []const u8) bool {
        const text = std.mem.trim(u8, raw, " \t\r\n");
        var digits: usize = 0;
        for (text) |c| {
            if (!std.ascii.isDigit(c)) continue;
            if (c != '0') return false;
            digits += 1;
        }
        return digits != 0;
    }

    /// Parse the RFC 3339 `date-time` production, leniently; see the module
    /// comment for exactly which departures are tolerated.
    pub fn parse(raw: []const u8) Error!DateTimeOffset {
        const text = std.mem.trim(u8, raw, " \t\r\n");
        // The shortest form accepted is `YYYY-MM-DDTHH:MM`.
        if (text.len < 16) return Error.InvalidDateTime;

        var self: DateTimeOffset = undefined;
        self.year = try fixedDigits(u16, text[0..4]);
        if (text[4] != '-') return Error.InvalidDateTime;
        self.month = try fixedDigits(u8, text[5..7]);
        if (text[7] != '-') return Error.InvalidDateTime;
        self.day = try fixedDigits(u8, text[8..10]);
        if (text[10] != 'T' and text[10] != 't') return Error.InvalidDateTime;
        self.hour = try fixedDigits(u8, text[11..13]);
        if (text[13] != ':') return Error.InvalidDateTime;
        self.minute = try fixedDigits(u8, text[14..16]);

        // Seconds are omitted by some services. `14:44` means `14:44:00`,
        // which invents nothing, so read them if they are there.
        var rest = text[16..];
        self.second = 0;
        self.nanosecond = 0;
        // `14:44.30` is a mistyped `14:44:30`, and DMTF publishes it 21 times
        // -- on `Bios` and `EthernetInterface`, inside the `@Redfish.Settings`
        // that is the only writable copy of either. Rejecting it costs a caller
        // the whole resource over the timestamp on its pending settings.
        //
        // ISO 8601 does give this a legal reading, as a decimal fraction of the
        // last component: `14:44.30` would be 14:44:18. That reading is not
        // taken here. Nothing in Redfish writes fractional minutes, every one
        // of these values has exactly the two digits a seconds field has, and
        // the same documents spell the field `14:44:00Z` elsewhere. A parser
        // that returned 14:44:18 would turn a typo a human reads correctly into
        // a wrong time that looks right, which is worse than either failing or
        // being lenient.
        const mistyped_separator = rest.len >= 3 and
            rest[0] == '.' and
            std.ascii.isDigit(rest[1]) and
            std.ascii.isDigit(rest[2]) and
            (rest.len == 3 or !std.ascii.isDigit(rest[3]));
        if (rest.len >= 3 and (rest[0] == ':' or mistyped_separator)) {
            self.second = try fixedDigits(u8, rest[1..3]);
            rest = rest[3..];

            if (!mistyped_separator and rest.len != 0 and rest[0] == '.') {
                rest = rest[1..];
                var seen: usize = 0;
                var scale: u32 = nanoseconds_per_second;
                while (rest.len != 0 and std.ascii.isDigit(rest[0])) : (rest = rest[1..]) {
                    seen += 1;
                    if (seen > fractional_digits) continue;
                    scale /= 10;
                    self.nanosecond += @as(u32, rest[0] - '0') * scale;
                }
                // RFC 3339 requires at least one digit after the dot.
                if (seen == 0) return Error.InvalidDateTime;
            }
        }

        if (rest.len == 0) {
            self.offset_minutes = 0;
            self.offset_specified = false;
        } else {
            self.offset_minutes = try parseOffset(rest);
            self.offset_specified = true;
        }
        try self.validate();
        return self;
    }

    fn parseOffset(text: []const u8) Error!i16 {
        if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;
        // `+06:00` and, from services that pad nothing, `+6:00`.
        if (text.len != 6 and text.len != 5) return Error.InvalidDateTime;
        const negative = switch (text[0]) {
            '+' => false,
            '-' => true,
            else => return Error.InvalidDateTime,
        };
        const colon = text.len - 3;
        const hours = try fixedDigits(u8, text[1..colon]);
        if (text[colon] != ':') return Error.InvalidDateTime;
        const minutes = try fixedDigits(u8, text[colon + 1 ..]);
        if (hours > 23 or minutes > 59) return Error.InvalidDateTime;

        const total: i16 = @intCast(@as(u16, hours) * 60 + minutes);
        return if (negative) -total else total;
    }

    fn validate(self: DateTimeOffset) Error!void {
        if (self.month < 1 or self.month > 12) return Error.InvalidDateTime;
        if (self.day < 1 or self.day > daysInMonth(self.year, self.month)) {
            return Error.InvalidDateTime;
        }
        if (self.hour > 23 or self.minute > 59 or self.second > 59) {
            return Error.InvalidDateTime;
        }
    }

    /// Seconds since the Unix epoch, negative before 1970.
    pub fn toUnixSeconds(self: DateTimeOffset) i64 {
        const days = daysFromCivil(self.year, self.month, self.day);
        const local = days * seconds_per_day +
            @as(i64, self.hour) * seconds_per_hour +
            @as(i64, self.minute) * seconds_per_minute +
            @as(i64, self.second);
        return local - @as(i64, self.offset_minutes) * seconds_per_minute;
    }

    /// Nanoseconds since the Unix epoch. Before the epoch this is negative,
    /// with the fractional part folded in: `1969-12-31T23:59:59.5Z` is
    /// `-500_000_000`.
    pub fn toUnixNanoseconds(self: DateTimeOffset) i128 {
        return @as(i128, self.toUnixSeconds()) * nanoseconds_per_second +
            @as(i128, self.nanosecond);
    }

    /// Order two timestamps by the instant they denote, ignoring the offset
    /// they were written in.
    pub fn order(self: DateTimeOffset, other: DateTimeOffset) std.math.Order {
        return std.math.order(self.toUnixNanoseconds(), other.toUnixNanoseconds());
    }

    /// True when both denote the same instant, even if written with different
    /// offsets. Use `std.meta.eql` to compare the written form instead.
    pub fn eql(self: DateTimeOffset, other: DateTimeOffset) bool {
        return self.order(other) == .eq;
    }

    /// Re-express the same instant as UTC, so that the written form and the
    /// instant agree.
    pub fn toUtc(self: DateTimeOffset) DateTimeOffset {
        if (self.offset_minutes == 0) return self;
        return fromUnixSeconds(self.toUnixSeconds(), self.nanosecond);
    }

    /// Build a UTC timestamp from a Unix second count.
    pub fn fromUnixSeconds(seconds: i64, nanosecond: u32) DateTimeOffset {
        const days = @divFloor(seconds, seconds_per_day);
        const rem = seconds - days * seconds_per_day;
        const civil = civilFromDays(days);
        return .{
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
            .hour = @intCast(@divTrunc(rem, seconds_per_hour)),
            .minute = @intCast(@divTrunc(@rem(rem, seconds_per_hour), seconds_per_minute)),
            .second = @intCast(@rem(rem, seconds_per_minute)),
            .nanosecond = nanosecond,
            .offset_minutes = 0,
        };
    }

    pub fn format(self: DateTimeOffset, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year, self.month, self.day, self.hour, self.minute, self.second,
        });

        if (self.nanosecond != 0) {
            var digits: [fractional_digits]u8 = undefined;
            var value = self.nanosecond;
            var i: usize = fractional_digits;
            while (i > 0) : (i -= 1) {
                digits[i - 1] = @intCast(value % 10 + '0');
                value /= 10;
            }
            var len: usize = fractional_digits;
            while (len > 1 and digits[len - 1] == '0') len -= 1;
            try w.writeByte('.');
            try w.writeAll(digits[0..len]);
        }

        if (!self.offset_specified) return;
        if (self.offset_minutes == 0) return w.writeByte('Z');

        const negative = self.offset_minutes < 0;
        const magnitude: u16 = @intCast(if (negative) -self.offset_minutes else self.offset_minutes);
        try w.print("{c}{d:0>2}:{d:0>2}", .{
            @as(u8, if (negative) '-' else '+'),
            magnitude / 60,
            magnitude % 60,
        });
    }

    pub fn jsonStringify(self: DateTimeOffset, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        try self.format(jw.writer);
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !DateTimeOffset {
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
    ) !DateTimeOffset {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) catch error.InvalidCharacter,
            else => error.UnexpectedToken,
        };
    }
};

fn fixedDigits(comptime T: type, text: []const u8) Error!T {
    var value: T = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return Error.InvalidDateTime;
        value = value * 10 + (c - '0');
    }
    return value;
}

pub fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Days since 1970-01-01 for a proleptic Gregorian date, using Howard
/// Hinnant's `days_from_civil`.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: u16, month: u8, day: u8 };

/// Inverse of `daysFromCivil`.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{
        .year = @intCast(y + @intFromBool(month <= 2)),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

const testing = std.testing;

fn expectRoundTrip(text: []const u8) !void {
    var buf: [64]u8 = undefined;
    const value = try DateTimeOffset.parse(text);
    try testing.expectEqualStrings(text, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

fn expectFormat(expected: []const u8, text: []const u8) !void {
    var buf: [64]u8 = undefined;
    const value = try DateTimeOffset.parse(text);
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

test "parses and formats a UTC timestamp" {
    const value = try DateTimeOffset.parse("2021-03-04T05:06:07Z");
    try testing.expectEqual(@as(u16, 2021), value.year);
    try testing.expectEqual(@as(u8, 3), value.month);
    try testing.expectEqual(@as(u8, 4), value.day);
    try testing.expectEqual(@as(u8, 5), value.hour);
    try testing.expectEqual(@as(u8, 6), value.minute);
    try testing.expectEqual(@as(u8, 7), value.second);
    try testing.expectEqual(@as(u32, 0), value.nanosecond);
    try testing.expectEqual(@as(i16, 0), value.offset_minutes);
    try expectRoundTrip("2021-03-04T05:06:07Z");
}

test "canonicalizes a zero offset to Z" {
    try expectFormat("2021-03-04T05:06:07Z", "2021-03-04T05:06:07+00:00");
    try expectFormat("2021-03-04T05:06:07Z", "2021-03-04T05:06:07-00:00");
}

test "preserves a non-zero offset" {
    try expectRoundTrip("2021-03-04T10:36:07+05:30");
    try expectRoundTrip("2021-03-04T00:06:07-05:00");

    const plus = try DateTimeOffset.parse("2021-03-04T10:36:07+05:30");
    try testing.expectEqual(@as(i16, 330), plus.offset_minutes);
    const minus = try DateTimeOffset.parse("2021-03-04T00:06:07-05:00");
    try testing.expectEqual(@as(i16, -300), minus.offset_minutes);
}

test "an offset and Z spelling of the same instant compare equal" {
    const utc = try DateTimeOffset.parse("2021-03-04T05:06:07Z");
    const shifted = try DateTimeOffset.parse("2021-03-04T10:36:07+05:30");
    try testing.expect(utc.eql(shifted));
    try testing.expect(!std.meta.eql(utc, shifted));
    try testing.expect(std.meta.eql(utc, shifted.toUtc()));
}

test "parses boundary offsets" {
    try expectRoundTrip("2021-03-04T12:00:00+14:00");
    try expectRoundTrip("2021-03-04T12:00:00-12:00");
}

test "round-trips fractional seconds" {
    try expectRoundTrip("2021-03-04T05:06:07.123456789Z");
    try expectRoundTrip("2021-03-04T05:06:07.5+01:00");
    try expectRoundTrip("2021-03-04T05:06:07.001Z");
}

test "trims trailing zeros from the fractional part" {
    try expectFormat("2021-03-04T05:06:07Z", "2021-03-04T05:06:07.000Z");
    try expectFormat("2021-03-04T05:06:07.5Z", "2021-03-04T05:06:07.500000000Z");
}

test "truncates fractional digits beyond nanosecond precision" {
    const value = try DateTimeOffset.parse("2021-03-04T05:06:07.1234567891234Z");
    try testing.expectEqual(@as(u32, 123456789), value.nanosecond);
}

test "accepts the lowercase separator and zone" {
    const lower = try DateTimeOffset.parse("2021-03-04t05:06:07z");
    try testing.expect(lower.eql(try DateTimeOffset.parse("2021-03-04T05:06:07Z")));
}

test "rejects malformed input" {
    inline for (.{
        "",
        "not-a-date",
        "2021-03-04T05:06:07+0530",
        "2021-03-04T05:06:07+05",
        "2021-03-04 05:06:07Z",
        "2021-03-04T05:06:07.Z",
        "2021/03/04T05:06:07Z",
        "21-03-04T05:06:07Z",
        "2021-03-04T05:06:07Q",
        "2021-03-04T05:06:07+24:00",
        "2021-03-04T05:06:07+05:60",
    }) |bad| {
        try testing.expectError(Error.InvalidDateTime, DateTimeOffset.parse(bad));
    }
}

test "accepts the shapes services actually send" {
    // Every one of these is taken from DMTF's own published mockups.

    // Seconds omitted. `14:44` is `14:44:00`; nothing is invented.
    const no_seconds = try DateTimeOffset.parse("2012-03-07T14:45+06:00");
    try testing.expectEqual(@as(u8, 0), no_seconds.second);
    try testing.expectEqual(@as(i16, 360), no_seconds.offset_minutes);
    try expectFormat("2012-03-07T14:45:00+06:00", "2012-03-07T14:45+06:00");

    // A one-digit offset hour.
    const short_offset = try DateTimeOffset.parse("2018-04-01T00:01+6:00");
    try testing.expectEqual(@as(i16, 360), short_offset.offset_minutes);
    try expectFormat("2018-04-01T00:01:00+06:00", "2018-04-01T00:01+6:00");

    // No offset at all. This is the one case where the sender left out
    // something that cannot be reconstructed, so the value remembers that it
    // was missing and writes it back the way it arrived rather than claiming
    // an authority over the timezone that we do not have.
    const naive = try DateTimeOffset.parse("2024-11-15T06:18:37");
    try testing.expect(!naive.offset_specified);
    try testing.expectEqual(@as(i16, 0), naive.offset_minutes);
    try expectFormat("2024-11-15T06:18:37", "2024-11-15T06:18:37");

    // Both at once, plus the trailing space one mockup carries.
    const bare = try DateTimeOffset.parse("2012-03-07T14:44 ");
    try testing.expect(!bare.offset_specified);
    try expectFormat("2012-03-07T14:44:00", "2012-03-07T14:44 ");

    // An explicit `Z` still means UTC, and still says so on the way out.
    const utc = try DateTimeOffset.parse("2024-11-15T06:18:37Z");
    try testing.expect(utc.offset_specified);
    try expectFormat("2024-11-15T06:18:37Z", "2024-11-15T06:18:37Z");
}

test "rejects a leap second" {
    try testing.expectError(
        Error.InvalidDateTime,
        DateTimeOffset.parse("2021-03-04T23:59:60Z"),
    );
}

test "rejects out-of-range calendar fields" {
    inline for (.{
        "2021-00-04T05:06:07Z",
        "2021-13-04T05:06:07Z",
        "2021-03-00T05:06:07Z",
        "2021-03-32T05:06:07Z",
        "2021-04-31T05:06:07Z",
        "2021-02-29T05:06:07Z",
        "2021-03-04T24:06:07Z",
        "2021-03-04T05:60:07Z",
    }) |bad| {
        try testing.expectError(Error.InvalidDateTime, DateTimeOffset.parse(bad));
    }
}

test "accepts a leap day in a leap year" {
    try expectRoundTrip("2020-02-29T05:06:07Z");
    try expectRoundTrip("2000-02-29T05:06:07Z");
    try testing.expectError(
        Error.InvalidDateTime,
        DateTimeOffset.parse("1900-02-29T05:06:07Z"),
    );
}

test "converts to Unix seconds" {
    const cases = .{
        .{ "2021-03-04T05:06:07-00:00", @as(i64, 1614834367) },
        .{ "1970-01-01T00:00:00Z", @as(i64, 0) },
        .{ "1960-01-01T00:00:00Z", @as(i64, -315619200) },
        .{ "1601-01-01T00:00:00Z", @as(i64, -11644473600) },
        .{ "0001-01-01T00:00:00Z", @as(i64, -62135596800) },
        .{ "9999-12-31T23:59:59Z", @as(i64, 253402300799) },
    };
    inline for (cases) |case| {
        try testing.expectEqual(case[1], (try DateTimeOffset.parse(case[0])).toUnixSeconds());
    }
}

test "the offset shifts the instant" {
    const utc = try DateTimeOffset.parse("2021-03-04T05:06:07Z");
    const east = try DateTimeOffset.parse("2021-03-04T10:36:07+05:30");
    const west = try DateTimeOffset.parse("2021-03-04T00:06:07-05:00");
    try testing.expectEqual(utc.toUnixSeconds(), east.toUnixSeconds());
    try testing.expectEqual(utc.toUnixSeconds(), west.toUnixSeconds());
}

test "folds the fractional part into a pre-epoch nanosecond count" {
    const value = try DateTimeOffset.parse("1969-12-31T23:59:59.5Z");
    try testing.expectEqual(@as(i64, -1), value.toUnixSeconds());
    try testing.expectEqual(@as(i128, -500_000_000), value.toUnixNanoseconds());
}

test "fromUnixSeconds inverts toUnixSeconds" {
    inline for (.{
        "2021-03-04T05:06:07Z",
        "1970-01-01T00:00:00Z",
        "1960-01-01T00:00:00Z",
        "1601-01-01T00:00:00Z",
        "0001-01-01T00:00:00Z",
        "9999-12-31T23:59:59Z",
    }) |text| {
        const value = try DateTimeOffset.parse(text);
        const rebuilt = DateTimeOffset.fromUnixSeconds(value.toUnixSeconds(), value.nanosecond);
        try testing.expect(std.meta.eql(value, rebuilt));
    }
}

test "civilFromDays inverts daysFromCivil across four centuries" {
    var year: u16 = 1800;
    while (year <= 2200) : (year += 1) {
        var month: u8 = 1;
        while (month <= 12) : (month += 1) {
            const last = daysInMonth(year, month);
            for ([_]u8{ 1, 15, last }) |day| {
                const days = daysFromCivil(year, month, day);
                const civil = civilFromDays(days);
                try testing.expectEqual(year, civil.year);
                try testing.expectEqual(month, civil.month);
                try testing.expectEqual(day, civil.day);
            }
        }
    }
}

test "order compares instants, not written forms" {
    const early = try DateTimeOffset.parse("2021-03-04T05:06:07Z");
    const late = try DateTimeOffset.parse("2021-03-04T05:06:07.000000001Z");
    try testing.expectEqual(std.math.Order.lt, early.order(late));
    try testing.expectEqual(std.math.Order.gt, late.order(early));
    try testing.expectEqual(std.math.Order.eq, early.order(early));
}

test "JSON round-trips as a string" {
    const Status = struct { LastUpdated: DateTimeOffset };

    var buf: [96]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(
        Status{ .LastUpdated = try DateTimeOffset.parse("2021-03-04T10:36:07+05:30") },
        .{},
        &w,
    );
    try testing.expectEqualStrings(
        "{\"LastUpdated\":\"2021-03-04T10:36:07+05:30\"}",
        w.buffered(),
    );

    const parsed = try std.json.parseFromSlice(Status, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expect(std.meta.eql(
        try DateTimeOffset.parse("2021-03-04T10:36:07+05:30"),
        parsed.value.LastUpdated,
    ));
}

test "JSON canonicalizes a zero offset on the way out" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(
        try DateTimeOffset.parse("2021-03-04T05:06:07+00:00"),
        .{},
        &w,
    );
    try testing.expectEqualStrings("\"2021-03-04T05:06:07Z\"", w.buffered());
}

test "JSON parses from a decoded value tree" {
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"LastUpdated\":\"2021-03-04T05:06:07.123456789Z\"}",
        .{},
    );
    defer doc.deinit();

    const parsed = try std.json.parseFromValue(
        DateTimeOffset,
        testing.allocator,
        doc.value.object.get("LastUpdated").?,
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 123456789), parsed.value.nanosecond);
}

test "JSON rejects a non-string token and a malformed string" {
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(DateTimeOffset, testing.allocator, "12", .{}),
    );
    try testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(DateTimeOffset, testing.allocator, "\"nope\"", .{}),
    );
}

test "a dot where a service meant a seconds colon still reads as seconds" {
    // DMTF publishes this exact spelling 21 times, most consequentially in the
    // `@Redfish.Settings` of `Bios` and `EthernetInterface`.
    const parsed = try DateTimeOffset.parse("2016-03-07T14:44.30-05:00");
    try std.testing.expectEqual(@as(u8, 44), parsed.minute);
    try std.testing.expectEqual(@as(u8, 30), parsed.second);
    try std.testing.expectEqual(@as(u32, 0), parsed.nanosecond);
    try std.testing.expectEqual(@as(i16, -5 * 60), parsed.offset_minutes);
}

test "the lenient reading does not swallow a real fractional second" {
    const parsed = try DateTimeOffset.parse("2016-03-07T14:44:30.125Z");
    try std.testing.expectEqual(@as(u8, 30), parsed.second);
    try std.testing.expectEqual(@as(u32, 125_000_000), parsed.nanosecond);
}

test "a dot with the wrong number of digits is still an error" {
    // Two digits are what a seconds field has; anything else is not the typo
    // this tolerates, and guessing further would be inventing a time.
    try std.testing.expectError(error.InvalidDateTime, DateTimeOffset.parse("2016-03-07T14:44.3Z"));
    try std.testing.expectError(error.InvalidDateTime, DateTimeOffset.parse("2016-03-07T14:44.305Z"));
}

test "an all-zero timestamp denotes nothing" {
    // Dell writes the first for a system that has never been reset; firmware
    // inventories write the other two for a release date nobody recorded.
    try std.testing.expect(DateTimeOffset.spellsAbsence("0000-00-00T00:00:00+00:00"));
    try std.testing.expect(DateTimeOffset.spellsAbsence("0000-00-00T00:00:00Z"));
    try std.testing.expect(DateTimeOffset.spellsAbsence("00:00:00Z"));
    try std.testing.expect(DateTimeOffset.spellsAbsence("0000-00-00"));

    // Still not a timestamp, which is why only an optional field may act on
    // it. `parse` has no way to answer "nothing".
    try std.testing.expectError(
        error.InvalidDateTime,
        DateTimeOffset.parse("0000-00-00T00:00:00+00:00"),
    );
}

test "a timestamp anyone meant has a digit that is not zero" {
    // Months and days are one-based, so this can never absorb a real value --
    // not even the two that come closest.
    try std.testing.expect(!DateTimeOffset.spellsAbsence("1970-01-01T00:00:00Z"));
    try std.testing.expect(!DateTimeOffset.spellsAbsence("0001-01-01T00:00:00Z"));

    // A value formatted wrong is not a value withheld.
    try std.testing.expect(!DateTimeOffset.spellsAbsence("2024-13-45T00:00:00Z"));

    // No digits at all is the empty-string rule's business, not this one.
    try std.testing.expect(!DateTimeOffset.spellsAbsence(""));
    try std.testing.expect(!DateTimeOffset.spellsAbsence("T:Z"));
}
