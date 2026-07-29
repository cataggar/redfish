//! Fixed-point decimal, the representation behind `Edm.Decimal` and
//! `Edm.Duration`.
//!
//! Redfish numeric properties arrive as JSON decimal literals. Decoding them
//! through `f64` loses information — `0.1` has no exact binary representation,
//! and sensor readings round-trip badly. `nv-redfish` reaches for the
//! `rust_decimal` crate here; Zig's standard library has no equivalent, so
//! this is a small exact fixed-point type:
//!
//!     value = mantissa × 10⁻ˢᶜᵃˡᵉ
//!
//! Only what the Redfish surface needs is implemented: parsing, formatting,
//! addition, multiplication by an integer, and truncating division by an
//! integer with an exact remainder (which is how `Edm.Duration` renders
//! itself). Every operation that could silently lose information returns an
//! error instead.

const std = @import("std");

pub const Error = error{
    /// Input is not a decimal literal.
    InvalidDecimal,
    /// The value needs more fractional digits than `max_scale`.
    ScaleTooLarge,
    /// The result does not fit in the mantissa, or a rescale would discard a
    /// significant digit.
    Overflow,
    DivisionByZero,
};

/// Largest number of fractional digits. Matches `rust_decimal`, and leaves
/// several decimal digits of headroom in the i128 mantissa.
pub const max_scale: u8 = 28;

const pow10_table = blk: {
    var table: [39]i128 = undefined;
    table[0] = 1;
    var i: usize = 1;
    while (i < table.len) : (i += 1) table[i] = table[i - 1] * 10;
    break :blk table;
};

fn pow10(n: u8) Error!i128 {
    if (n >= pow10_table.len) return Error.Overflow;
    return pow10_table[n];
}

pub const Decimal = struct {
    mantissa: i128,
    /// Number of fractional digits, at most `max_scale`.
    scale: u8,

    pub const zero: Decimal = .{ .mantissa = 0, .scale = 0 };
    pub const one: Decimal = .{ .mantissa = 1, .scale = 0 };

    pub fn fromInt(value: i128) Decimal {
        return .{ .mantissa = value, .scale = 0 };
    }

    pub fn isZero(self: Decimal) bool {
        return self.mantissa == 0;
    }

    pub fn isNegative(self: Decimal) bool {
        return self.mantissa < 0;
    }

    pub fn negate(self: Decimal) Decimal {
        return .{ .mantissa = -self.mantissa, .scale = self.scale };
    }

    pub fn abs(self: Decimal) Decimal {
        return if (self.isNegative()) self.negate() else self;
    }

    /// Parse a decimal literal: an optional sign, digits, and an optional
    /// fractional part.
    ///
    /// Exponent notation is rejected. Redfish does not use it for these
    /// properties, and accepting it would mean either implementing exact
    /// scaling for arbitrary exponents or quietly losing precision.
    pub fn parse(text: []const u8) Error!Decimal {
        if (text.len == 0) return Error.InvalidDecimal;

        var rest = text;
        var negative = false;
        if (rest[0] == '+' or rest[0] == '-') {
            negative = rest[0] == '-';
            rest = rest[1..];
        }
        if (rest.len == 0) return Error.InvalidDecimal;

        var mantissa: i128 = 0;
        var scale: u8 = 0;
        var seen_dot = false;
        var digits: usize = 0;

        for (rest) |c| {
            if (c == '.') {
                if (seen_dot) return Error.InvalidDecimal;
                seen_dot = true;
                continue;
            }
            if (!std.ascii.isDigit(c)) return Error.InvalidDecimal;
            digits += 1;
            mantissa = std.math.mul(i128, mantissa, 10) catch return Error.Overflow;
            mantissa = std.math.add(i128, mantissa, c - '0') catch return Error.Overflow;
            if (seen_dot) {
                if (scale == max_scale) return Error.ScaleTooLarge;
                scale += 1;
            }
        }
        if (digits == 0) return Error.InvalidDecimal;
        // A dot must be followed by at least one digit: `.5` is accepted as a
        // convenience, `3.` is not.
        if (seen_dot and scale == 0) return Error.InvalidDecimal;

        return .{ .mantissa = if (negative) -mantissa else mantissa, .scale = scale };
    }

    /// Re-express the value with exactly `target` fractional digits.
    /// Reducing the scale is refused when it would discard a non-zero digit.
    pub fn rescale(self: Decimal, target: u8) Error!Decimal {
        if (target > max_scale) return Error.ScaleTooLarge;
        if (target == self.scale) return self;

        if (target > self.scale) {
            const factor = try pow10(target - self.scale);
            const mantissa = std.math.mul(i128, self.mantissa, factor) catch
                return Error.Overflow;
            return .{ .mantissa = mantissa, .scale = target };
        }

        const factor = try pow10(self.scale - target);
        if (@rem(self.mantissa, factor) != 0) return Error.Overflow;
        return .{ .mantissa = @divExact(self.mantissa, factor), .scale = target };
    }

    /// Drop trailing fractional zeros. `1.500` becomes `1.5` and `2.0000`
    /// becomes `2`. Never changes the value.
    pub fn normalized(self: Decimal) Decimal {
        var result = self;
        while (result.scale > 0 and @rem(result.mantissa, 10) == 0) {
            result.mantissa = @divExact(result.mantissa, 10);
            result.scale -= 1;
        }
        return result;
    }

    pub fn add(self: Decimal, other: Decimal) Error!Decimal {
        const scale = @max(self.scale, other.scale);
        const a = try self.rescale(scale);
        const b = try other.rescale(scale);
        const mantissa = std.math.add(i128, a.mantissa, b.mantissa) catch
            return Error.Overflow;
        return .{ .mantissa = mantissa, .scale = scale };
    }

    pub fn sub(self: Decimal, other: Decimal) Error!Decimal {
        return self.add(other.negate());
    }

    pub fn mulInt(self: Decimal, factor: i128) Error!Decimal {
        const mantissa = std.math.mul(i128, self.mantissa, factor) catch
            return Error.Overflow;
        return .{ .mantissa = mantissa, .scale = self.scale };
    }

    pub const DivRem = struct {
        /// Exact integer quotient, truncated toward zero.
        quotient: Decimal,
        /// `self − divisor × quotient`. Keeps the original fractional part and
        /// takes the sign of `self`.
        remainder: Decimal,
    };

    /// Divide by an integer, truncating toward zero, and return the exact
    /// remainder alongside the quotient.
    ///
    /// This is how `Edm.Duration` peels off days, hours, and minutes while
    /// leaving fractional seconds intact.
    pub fn divRemInt(self: Decimal, divisor: i128) Error!DivRem {
        if (divisor == 0) return Error.DivisionByZero;

        const unit = try pow10(self.scale);
        const scaled_divisor = std.math.mul(i128, divisor, unit) catch return Error.Overflow;
        const remainder = @rem(self.mantissa, scaled_divisor);
        const quotient = @divExact(self.mantissa - remainder, scaled_divisor);

        return .{
            .quotient = .{ .mantissa = quotient, .scale = 0 },
            .remainder = .{ .mantissa = remainder, .scale = self.scale },
        };
    }

    pub fn order(self: Decimal, other: Decimal) Error!std.math.Order {
        const difference = try self.sub(other);
        return std.math.order(difference.mantissa, 0);
    }

    /// Value equality across differing scales: `1.500` equals `1.5`.
    pub fn eql(self: Decimal, other: Decimal) bool {
        const difference = self.sub(other) catch return false;
        return difference.mantissa == 0;
    }

    /// Lossy conversion for callers that do not need exactness. Saturates to
    /// infinity rather than trapping.
    pub fn toFloat(self: Decimal) f64 {
        const divisor = pow10(self.scale) catch
            return if (self.isNegative()) -std.math.inf(f64) else std.math.inf(f64);
        return @as(f64, @floatFromInt(self.mantissa)) / @as(f64, @floatFromInt(divisor));
    }

    pub fn format(self: Decimal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.scale == 0) return w.print("{d}", .{self.mantissa});

        const divisor = pow10(self.scale) catch unreachable;
        const magnitude = if (self.mantissa < 0) -self.mantissa else self.mantissa;
        if (self.mantissa < 0) try w.writeByte('-');
        try w.print("{d}.", .{@divTrunc(magnitude, divisor)});

        var digits: [max_scale]u8 = undefined;
        var fraction = @rem(magnitude, divisor);
        var i: usize = self.scale;
        while (i > 0) : (i -= 1) {
            digits[i - 1] = @intCast(@as(u8, @intCast(@rem(fraction, 10))) + '0');
            fraction = @divTrunc(fraction, 10);
        }
        try w.writeAll(digits[0..self.scale]);
    }

    pub fn jsonStringify(self: Decimal, jw: anytype) !void {
        try jw.beginWriteRaw();
        try self.format(jw.writer);
        jw.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Decimal {
        const token = try source.nextAllocMax(
            allocator,
            .alloc_if_needed,
            options.max_value_len orelse std.json.default_max_value_len,
        );
        const text = switch (token) {
            inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
        return parse(text) catch error.InvalidNumber;
    }

    /// Parses from an already-decoded `std.json.Value`.
    ///
    /// `std.json.Value` decodes numbers to `.integer` or `.float` unless the
    /// document was parsed with `.parse_numbers = false`, which keeps them as
    /// `.number_string`. Only the `.number_string` and `.integer` paths are
    /// exact; a `.float` has already been rounded to the nearest `f64` before
    /// this function sees it, so parse with `.parse_numbers = false` when the
    /// document may carry more precision than an `f64` holds.
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Decimal {
        _ = allocator;
        _ = options;
        return switch (source) {
            .number_string, .string => |s| parse(s) catch error.InvalidNumber,
            .integer => |i| fromInt(i),
            .float => |f| blk: {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.InvalidNumber;
                break :blk parse(text) catch error.InvalidNumber;
            },
            else => error.UnexpectedToken,
        };
    }
};

const testing = std.testing;

fn expectFormat(expected: []const u8, value: Decimal) !void {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

test "parse reads sign, integer, and fractional parts" {
    try testing.expectEqual(Decimal{ .mantissa = 42, .scale = 0 }, try Decimal.parse("42"));
    try testing.expectEqual(Decimal{ .mantissa = 35, .scale = 1 }, try Decimal.parse("3.5"));
    try testing.expectEqual(Decimal{ .mantissa = -35, .scale = 1 }, try Decimal.parse("-3.5"));
    try testing.expectEqual(Decimal{ .mantissa = 35, .scale = 1 }, try Decimal.parse("+3.5"));
    try testing.expectEqual(Decimal{ .mantissa = 5, .scale = 1 }, try Decimal.parse(".5"));
    try testing.expectEqual(Decimal{ .mantissa = 100, .scale = 2 }, try Decimal.parse("1.00"));
}

test "parse rejects malformed input" {
    inline for (.{ "", "-", "+", ".", "3.", "-.", "1.2.3", "1e5", "abc", "1 2", "0x10" }) |bad| {
        try testing.expectError(Error.InvalidDecimal, Decimal.parse(bad));
    }
}

test "parse rejects more fractional digits than max_scale" {
    const too_many = "0." ++ ("1" ** (max_scale + 1));
    try testing.expectError(Error.ScaleTooLarge, Decimal.parse(too_many));
}

test "format round-trips through parse" {
    inline for (.{ "0", "42", "-42", "3.5", "-3.5", "0.001", "1.00", "-0.25" }) |text| {
        try expectFormat(text, try Decimal.parse(text));
    }
}

test "format pads fractional digits" {
    try expectFormat("1.05", Decimal{ .mantissa = 105, .scale = 2 });
    try expectFormat("0.007", Decimal{ .mantissa = 7, .scale = 3 });
    try expectFormat("-0.007", Decimal{ .mantissa = -7, .scale = 3 });
}

test "normalized strips trailing fractional zeros only" {
    try expectFormat("1.5", (try Decimal.parse("1.500")).normalized());
    try expectFormat("2", (try Decimal.parse("2.0000")).normalized());
    try expectFormat("100", (try Decimal.parse("100")).normalized());
    try expectFormat("0", (try Decimal.parse("0.000")).normalized());
}

test "add aligns scales" {
    try expectFormat("3.75", try (try Decimal.parse("1.5")).add(try Decimal.parse("2.25")));
    try expectFormat("7.001", try (try Decimal.parse("0.001")).add(Decimal.fromInt(7)));
}

test "sub produces exact differences a f64 would not" {
    try expectFormat("0.1", try (try Decimal.parse("0.3")).sub(try Decimal.parse("0.2")));
}

test "mulInt scales the mantissa and keeps the scale" {
    try expectFormat("86400", try Decimal.fromInt(1).mulInt(86_400));
    try expectFormat("5400.0", try (try Decimal.parse("1.5")).mulInt(3600));
    try expectFormat("-7.0", try (try Decimal.parse("-3.5")).mulInt(2));
}

test "divRemInt splits into whole units and an exact remainder" {
    const hours = try (try Decimal.parse("3723.5")).divRemInt(3600);
    try expectFormat("1", hours.quotient);
    try expectFormat("123.5", hours.remainder);

    const minutes = try hours.remainder.divRemInt(60);
    try expectFormat("2", minutes.quotient);
    try expectFormat("3.5", minutes.remainder);
}

test "divRemInt truncates toward zero for negatives" {
    const split = try (try Decimal.parse("-3723.5")).divRemInt(3600);
    try expectFormat("-1", split.quotient);
    try expectFormat("-123.5", split.remainder);
}

test "divRemInt rejects a zero divisor" {
    try testing.expectError(Error.DivisionByZero, Decimal.fromInt(1).divRemInt(0));
}

test "rescale refuses to discard significant digits" {
    try expectFormat("1.500", try (try Decimal.parse("1.5")).rescale(3));
    try expectFormat("1.5", try (try Decimal.parse("1.500")).rescale(1));
    try testing.expectError(Error.Overflow, (try Decimal.parse("1.55")).rescale(1));
    try testing.expectError(Error.ScaleTooLarge, Decimal.one.rescale(max_scale + 1));
}

test "arithmetic reports overflow rather than wrapping" {
    const huge = Decimal{ .mantissa = std.math.maxInt(i128), .scale = 0 };
    try testing.expectError(Error.Overflow, huge.add(Decimal.one));
    try testing.expectError(Error.Overflow, huge.mulInt(2));
    try testing.expectError(Error.Overflow, huge.rescale(1));
}

test "order and eql compare across scales" {
    const a = try Decimal.parse("1.50");
    const b = try Decimal.parse("1.5");
    try testing.expectEqual(std.math.Order.eq, try a.order(b));
    try testing.expectEqual(std.math.Order.lt, try b.order(try Decimal.parse("1.75")));
    try testing.expectEqual(std.math.Order.gt, try Decimal.fromInt(2).order(try Decimal.parse("1.999")));
    try testing.expect(a.eql(b));
    try testing.expect(!b.eql(try Decimal.parse("1.6")));
}

test "toFloat converts approximately" {
    try testing.expectApproxEqAbs(@as(f64, 3723.5), (try Decimal.parse("3723.5")).toFloat(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.25), (try Decimal.parse("-0.25")).toFloat(), 1e-12);
}

test "JSON round-trips without going through f64" {
    const parsed = try std.json.parseFromSlice(Decimal, testing.allocator, "0.1", .{});
    defer parsed.deinit();
    try testing.expectEqual(Decimal{ .mantissa = 1, .scale = 1 }, parsed.value);

    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(parsed.value, .{}, &w);
    try testing.expectEqualStrings("0.1", w.buffered());
}

test "JSON preserves precision that a f64 would lose" {
    const text = "1.0000000000000000000000001";
    const parsed = try std.json.parseFromSlice(Decimal, testing.allocator, text, .{});
    defer parsed.deinit();

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(parsed.value, .{}, &w);
    try testing.expectEqualStrings(text, w.buffered());
}

test "JSON emits a number, not a string" {
    const Sensor = struct { Reading: Decimal };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(Sensor{ .Reading = try Decimal.parse("12.75") }, .{}, &w);
    try testing.expectEqualStrings("{\"Reading\":12.75}", w.buffered());
}

test "JSON parses from a decoded value tree" {
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"Reading\":12.75}",
        .{},
    );
    defer doc.deinit();

    const field = doc.value.object.get("Reading").?;
    const reading = try std.json.parseFromValue(Decimal, testing.allocator, field, .{});
    defer reading.deinit();
    try expectFormat("12.75", reading.value);
}

test "JSON value trees keep full precision with parse_numbers disabled" {
    const literal = "0.1000000000000000055511151231";
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"Reading\":" ++ literal ++ "}",
        .{ .parse_numbers = false },
    );
    defer doc.deinit();

    const field = doc.value.object.get("Reading").?;
    try testing.expect(field == .number_string);

    const reading = try std.json.parseFromValue(Decimal, testing.allocator, field, .{});
    defer reading.deinit();
    try expectFormat(literal, reading.value);
}

test "JSON rejects a non-numeric token" {
    try testing.expectError(
        error.InvalidNumber,
        std.json.parseFromSlice(Decimal, testing.allocator, "\"not a number\"", .{}),
    );
}
