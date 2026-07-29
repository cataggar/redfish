//! `Edm.Duration` — ISO 8601 durations as used by OData and Redfish.
//!
//! Durations are held as exact `Decimal` seconds so that fractional seconds
//! survive a parse/format round trip, and are rendered in the canonical
//! `[-]P[nD][T[nH][nM]nS]` form.
//!
//! References:
//! - OASIS OData 4.01 CSDL Part 3, primitive type `Edm.Duration`.
//! - DMTF Redfish Specification DSP0266.

const std = @import("std");
const decimal = @import("decimal.zig");

const Decimal = decimal.Decimal;

pub const Error = error{
    /// The text is not a well-formed `Edm.Duration`.
    InvalidDuration,
    /// The value is outside the range a `Decimal` can hold exactly.
    Overflow,
};

const seconds_per_minute = 60;
const seconds_per_hour = 60 * 60;
const seconds_per_day = 24 * seconds_per_hour;

/// A signed ISO 8601 duration with exact fractional seconds.
///
/// Only the day-and-below designators are supported: `Y` (years) and the
/// date-position `M` (months) have no fixed length in seconds and Redfish does
/// not use them. `W` (weeks) is likewise rejected, matching OData's profile.
pub const Duration = struct {
    /// Total length in seconds. Negative for a negative duration.
    seconds: Decimal,

    pub const zero: Duration = .{ .seconds = Decimal.zero };

    pub fn fromSeconds(seconds: Decimal) Duration {
        return .{ .seconds = seconds };
    }

    pub fn fromWholeSeconds(seconds: i128) Duration {
        return .{ .seconds = Decimal.fromInt(seconds) };
    }

    pub fn isZero(self: Duration) bool {
        return self.seconds.isZero();
    }

    pub fn isNegative(self: Duration) bool {
        return self.seconds.isNegative();
    }

    pub fn negate(self: Duration) Duration {
        return .{ .seconds = self.seconds.negate() };
    }

    /// Lossy conversion for callers that do not need exactness.
    pub fn toFloatSeconds(self: Duration) f64 {
        return self.seconds.toFloat();
    }

    /// Convert to a non-negative nanosecond count, as used by `std.Io` timeouts.
    /// Fails on a negative duration or one that does not fit in a `u64`.
    pub fn toNanoseconds(self: Duration) Error!u64 {
        if (self.seconds.isNegative()) return Error.InvalidDuration;
        const nanos = self.seconds.mulInt(std.time.ns_per_s) catch return Error.Overflow;
        const whole = nanos.rescale(0) catch return Error.Overflow;
        return std.math.cast(u64, whole.mantissa) orelse Error.Overflow;
    }

    /// Parse the canonical `[-]P[nD][T[nH][nM][nS]]` form.
    ///
    /// Deviations from `nv-redfish`, both deliberate tightenings of inputs the
    /// Rust parser silently accepted:
    ///   * digits may not appear between `P` and `T` without a `D` (`P5T1H`).
    ///   * time components must be given in `H`, `M`, `S` order, at most once
    ///     each (`PT1S1H` and `PT1H2H` are rejected).
    pub fn parse(text: []const u8) Error!Duration {
        var rest = text;
        var negative = false;
        if (rest.len != 0 and rest[0] == '-') {
            negative = true;
            rest = rest[1..];
        }
        if (rest.len == 0 or rest[0] != 'P') return Error.InvalidDuration;
        rest = rest[1..];

        var total = Decimal.zero;

        const date_part = takeDigits(rest);
        rest = date_part.rest;
        switch (date_part.designator orelse return Error.InvalidDuration) {
            'T' => if (date_part.digits.len != 0) return Error.InvalidDuration,
            'D' => {
                total = try scaledSeconds(date_part.digits, seconds_per_day);
                if (rest.len == 0) {
                    return .{ .seconds = if (negative) total.negate() else total };
                }
                if (rest[0] != 'T') return Error.InvalidDuration;
                rest = rest[1..];
            },
            else => return Error.InvalidDuration,
        }

        // Ranks the time designators so that repeats and out-of-order
        // components are rejected. `PT` with no components stays at 0.
        var last_rank: u8 = 0;
        while (true) {
            const part = takeDigits(rest);
            rest = part.rest;
            const designator = part.designator orelse {
                // Trailing digits with no designator, e.g. `PT1H2M3`.
                if (part.digits.len != 0) return Error.InvalidDuration;
                break;
            };
            const rank: u8, const multiplier: i128 = switch (designator) {
                'H' => .{ 1, seconds_per_hour },
                'M' => .{ 2, seconds_per_minute },
                'S' => .{ 3, 1 },
                else => return Error.InvalidDuration,
            };
            if (rank <= last_rank) return Error.InvalidDuration;
            last_rank = rank;

            const component = try scaledSeconds(part.digits, multiplier);
            total = total.add(component) catch return Error.Overflow;
        }
        if (rest.len != 0) return Error.InvalidDuration;

        return .{ .seconds = if (negative) total.negate() else total };
    }

    /// Write the canonical form. Zero is always rendered `PT0S`, and whenever
    /// a `T` section is present it ends with a seconds component even when
    /// that component is zero — both match `nv-redfish`.
    pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.seconds.isZero()) return w.writeAll("PT0S");

        if (self.seconds.isNegative()) try w.writeByte('-');
        try w.writeByte('P');

        var value = self.seconds.abs();

        const days = value.divRemInt(seconds_per_day) catch unreachable;
        value = days.remainder;
        if (!days.quotient.isZero()) try w.print("{f}D", .{days.quotient.normalized()});
        if (value.isZero()) return;

        try w.writeByte('T');

        const hours = value.divRemInt(seconds_per_hour) catch unreachable;
        value = hours.remainder;
        if (!hours.quotient.isZero()) try w.print("{f}H", .{hours.quotient.normalized()});

        const minutes = value.divRemInt(seconds_per_minute) catch unreachable;
        value = minutes.remainder;
        if (!minutes.quotient.isZero()) try w.print("{f}M", .{minutes.quotient.normalized()});

        try w.print("{f}S", .{value.normalized()});
    }

    pub fn jsonStringify(self: Duration, jw: anytype) !void {
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
    ) !Duration {
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
    ) !Duration {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) catch error.InvalidCharacter,
            else => error.UnexpectedToken,
        };
    }
};

const DigitRun = struct {
    /// Leading run of digits and decimal points, possibly empty.
    digits: []const u8,
    /// The character that ended the run, or null at end of input.
    designator: ?u8,
    /// Everything after the designator.
    rest: []const u8,
};

fn takeDigits(text: []const u8) DigitRun {
    for (text, 0..) |c, i| {
        if (std.ascii.isDigit(c) or c == '.') continue;
        return .{ .digits = text[0..i], .designator = c, .rest = text[i + 1 ..] };
    }
    return .{ .digits = text, .designator = null, .rest = text[text.len..] };
}

fn scaledSeconds(digits: []const u8, multiplier: i128) Error!Decimal {
    const value = Decimal.parse(digits) catch |err| return switch (err) {
        error.Overflow, error.ScaleTooLarge => Error.Overflow,
        else => Error.InvalidDuration,
    };
    return value.mulInt(multiplier) catch Error.Overflow;
}

const testing = std.testing;

fn expectSeconds(expected: []const u8, text: []const u8) !void {
    const parsed = try Duration.parse(text);
    try testing.expect(parsed.seconds.eql(try Decimal.parse(expected)));
}

fn expectFormat(expected: []const u8, text: []const u8) !void {
    var buf: [128]u8 = undefined;
    const value = try Duration.parse(text);
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

test "parses time-only hours, minutes, and seconds" {
    try expectSeconds("3723", "PT1H2M3S");
}

test "parses a day-only duration" {
    try expectSeconds("259200", "P3D");
}

test "parses days combined with a time part" {
    try expectSeconds("90000", "P1DT1H");
}

test "parses fractional seconds exactly" {
    try expectSeconds("0.25", "PT0.25S");
}

test "parses fractional minutes and days" {
    try expectSeconds("90", "PT1.5M");
    try expectSeconds("129600", "P1.5D");
}

test "parses negative durations" {
    try expectSeconds("-120", "-PT2M");
    try expectSeconds("-86400", "-P1D");
}

test "parses both spellings of zero" {
    try expectSeconds("0", "PT0S");
    try expectSeconds("0", "PT");
}

test "rejects malformed input" {
    inline for (.{
        "",
        "P",
        "T1H",
        "PT1X",
        "-P",
        "-",
        "1DT1H",
        "PD",
        "PTS",
        "P1D1H",
        "P1DX",
        "PT1H2M3",
        "P1W",
        "P1Y",
    }) |bad| {
        try testing.expectError(Error.InvalidDuration, Duration.parse(bad));
    }
}

test "rejects the loose forms nv-redfish accepted" {
    // Digits between `P` and `T` without a `D`.
    try testing.expectError(Error.InvalidDuration, Duration.parse("P5T1H"));
    // Out-of-order and repeated time components.
    try testing.expectError(Error.InvalidDuration, Duration.parse("PT1S1H"));
    try testing.expectError(Error.InvalidDuration, Duration.parse("PT1M1H"));
    try testing.expectError(Error.InvalidDuration, Duration.parse("PT1H2H"));
}

test "reports overflow rather than wrapping" {
    try testing.expectError(
        Error.Overflow,
        Duration.parse("P1000000000000000000000000000000000000D"),
    );
}

test "formats zero as PT0S" {
    try expectFormat("PT0S", "PT");
    try expectFormat("PT0S", "PT0S");
    try expectFormat("PT0S", "-PT0S");
}

test "formats a seconds-only duration" {
    try expectFormat("PT3S", "PT3S");
}

test "formats fractional seconds" {
    try expectFormat("PT0.25S", "PT0.25S");
}

test "always emits a seconds component inside a time part" {
    try expectFormat("PT2M0S", "PT2M");
    try expectFormat("PT1H0S", "PT1H");
    try expectFormat("PT1H2M0S", "PT1H2M");
}

test "formats days with and without a time part" {
    try expectFormat("P3D", "P3D");
    try expectFormat("P1DT1H0S", "P1DT1H");
}

test "formats negative durations" {
    try expectFormat("-PT2M0S", "-PT2M");
    try expectFormat("-P1D", "-P1D");
}

test "normalizes fractional components into whole ones" {
    try expectFormat("PT1M30S", "PT1.5M");
    try expectFormat("PT1H45M0S", "PT1.75H");
    try expectFormat("P1DT6H0S", "P1.25D");
}

test "trims trailing fractional zeros" {
    try expectFormat("PT30S", "PT30.0S");
    try expectFormat("PT1.23S", "PT1.2300S");
    try expectFormat("PT1S", "PT01S");
}

test "carries seconds up into minutes, hours, and days" {
    try expectFormat("PT1M0S", "PT60S");
    try expectFormat("PT1H0S", "PT3600S");
    try expectFormat("P4166DT16H0S", "PT100000H");
}

test "keeps fractional seconds while peeling larger units" {
    try expectFormat("P1DT1H1M1.5S", "PT90061.5S");
    try expectFormat("-P1DT1H1M1.5S", "-PT90061.5S");
}

test "toNanoseconds converts and rejects out-of-range values" {
    try testing.expectEqual(@as(u64, 1_500_000_000), try (try Duration.parse("PT1.5S")).toNanoseconds());
    try testing.expectEqual(@as(u64, 0), try (try Duration.parse("PT")).toNanoseconds());
    try testing.expectError(
        Error.InvalidDuration,
        (try Duration.parse("-PT1S")).toNanoseconds(),
    );
    try testing.expectError(
        Error.Overflow,
        (try Duration.parse("P1000000000000000D")).toNanoseconds(),
    );
}

test "toNanoseconds rounds nothing away" {
    // A precision finer than a nanosecond cannot be represented exactly.
    try testing.expectError(
        Error.Overflow,
        (try Duration.parse("PT0.0000000001S")).toNanoseconds(),
    );
}

test "toFloatSeconds is approximate" {
    try testing.expectApproxEqAbs(
        @as(f64, 3723.5),
        (try Duration.parse("PT1H2M3.5S")).toFloatSeconds(),
        1e-9,
    );
}

test "JSON round-trips as a string" {
    const Policy = struct { Timeout: Duration };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(
        Policy{ .Timeout = try Duration.parse("PT1H2M3.5S") },
        .{},
        &w,
    );
    try testing.expectEqualStrings("{\"Timeout\":\"PT1H2M3.5S\"}", w.buffered());

    const parsed = try std.json.parseFromSlice(Policy, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.Timeout.seconds.eql(try Decimal.parse("3723.5")));
}

test "JSON parses from a decoded value tree" {
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"Timeout\":\"P1DT1H\"}",
        .{},
    );
    defer doc.deinit();

    const parsed = try std.json.parseFromValue(
        Duration,
        testing.allocator,
        doc.value.object.get("Timeout").?,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.seconds.eql(try Decimal.parse("90000")));
}

test "JSON rejects a non-string token and a malformed string" {
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Duration, testing.allocator, "12", .{}),
    );
    try testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(Duration, testing.allocator, "\"nope\"", .{}),
    );
}

test "takeDigits splits on the first designator" {
    const run = takeDigits("1.5DT2H");
    try testing.expectEqualStrings("1.5", run.digits);
    try testing.expectEqual(@as(?u8, 'D'), run.designator);
    try testing.expectEqualStrings("T2H", run.rest);

    const trailing = takeDigits("42");
    try testing.expectEqualStrings("42", trailing.digits);
    try testing.expectEqual(@as(?u8, null), trailing.designator);
    try testing.expectEqualStrings("", trailing.rest);
}
