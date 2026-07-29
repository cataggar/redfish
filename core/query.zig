//! Redfish query parameters — `$expand`, `$filter`, `$select`, `$top`,
//! `$skip`, `$only`, and `$excerpt`.
//!
//! `ExpandQuery` and the small options are values with no allocation: they
//! render on demand into a writer. `FilterQuery` accumulates text as you build
//! it, because a filter is an arbitrarily deep expression.
//!
//! Reference: DMTF DSP0266, "Query parameters".

const std = @import("std");
const edm = @import("edm.zig");

const Decimal = edm.Decimal;

/// Builder for `$expand`.
///
/// ```zig
/// const query: ExpandQuery = .{ .expression = .all, .levels = 3 };
/// // renders as `$expand=*($levels=3)`
/// ```
pub const ExpandQuery = struct {
    expression: Expression = .current,
    /// `$levels`, or null to omit it. Services cap this; 1-6 is typical.
    levels: ?u32 = 1,

    /// What to expand.
    pub const Expression = union(enum) {
        /// `*` — every hyperlink, including those in payload annotations such
        /// as `@Redfish.Settings` and `@Redfish.ActionInfo`.
        all,
        /// `.` — every hyperlink except those under `Links`.
        current,
        /// `~` — only the hyperlinks under `Links`.
        links,
        /// One named navigation property.
        property: []const u8,
        /// Several named navigation properties, rendered comma-separated.
        properties: []const []const u8,

        pub fn format(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .all => try w.writeAll("*"),
                .current => try w.writeAll("."),
                .links => try w.writeAll("~"),
                .property => |name| try w.writeAll(name),
                .properties => |names| for (names, 0..) |name, i| {
                    if (i != 0) try w.writeByte(',');
                    try w.writeAll(name);
                },
            }
        }
    };

    /// Every hyperlink except those under `Links`, one level deep. This is
    /// the safe default: `all` also drags in annotation payloads.
    pub const default: ExpandQuery = .{};

    /// `.` with no `$levels`, for services that reject the parameter.
    pub const no_levels: ExpandQuery = .{ .expression = .current, .levels = null };

    pub fn all(levels: ?u32) ExpandQuery {
        return .{ .expression = .all, .levels = levels };
    }

    pub fn current(levels: ?u32) ExpandQuery {
        return .{ .expression = .current, .levels = levels };
    }

    pub fn links(levels: ?u32) ExpandQuery {
        return .{ .expression = .links, .levels = levels };
    }

    pub fn property(name: []const u8) ExpandQuery {
        return .{ .expression = .{ .property = name } };
    }

    pub fn properties(names: []const []const u8) ExpandQuery {
        return .{ .expression = .{ .properties = names } };
    }

    /// `$expand=<expression>[($levels=<n>)]`.
    pub fn format(self: ExpandQuery, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("$expand={f}", .{self.expression});
        if (self.levels) |levels| try w.print("($levels={d})", .{levels});
    }

    pub fn toQueryString(self: ExpandQuery, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{f}", .{self});
    }
};

/// A literal on the right of a filter comparison.
pub const FilterLiteral = union(enum) {
    string: []const u8,
    integer: i64,
    /// Exact, for a value read out of a resource without going through `f64`.
    decimal: Decimal,
    number: f64,
    boolean: bool,

    /// OData literal syntax. Strings are single-quoted with `'` doubled, per
    /// OData ABNF; everything else is bare.
    pub fn format(self: FilterLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .string => |value| {
                try w.writeByte('\'');
                var rest = value;
                while (std.mem.indexOfScalar(u8, rest, '\'')) |i| {
                    try w.writeAll(rest[0 .. i + 1]);
                    try w.writeByte('\'');
                    rest = rest[i + 1 ..];
                }
                try w.writeAll(rest);
                try w.writeByte('\'');
            },
            .integer => |value| try w.print("{d}", .{value}),
            .decimal => |value| try value.format(w),
            .number => |value| try w.print("{d}", .{value}),
            .boolean => |value| try w.writeAll(if (value) "true" else "false"),
        }
    }
};

/// The comparison operators DSP0266 requires a service to support.
pub const Comparison = enum {
    eq,
    ne,
    gt,
    ge,
    lt,
    le,

    pub fn token(self: Comparison) []const u8 {
        return @tagName(self);
    }
};

pub const LogicalOp = enum {
    @"and",
    @"or",

    pub fn token(self: LogicalOp) []const u8 {
        return @tagName(self);
    }
};

pub const FilterError = error{
    /// A comparison was appended to a non-empty filter without an intervening
    /// `and` or `or`.
    ///
    /// `nv-redfish` silently discards the earlier expression here. Losing a
    /// clause quietly turns a narrow query into a broad one, so this is an
    /// error instead.
    MissingLogicalOperator,
    /// Two logical operators in a row, or one at the very start.
    UnexpectedLogicalOperator,
    /// `not` or `group` applied to an empty filter.
    EmptyFilter,
} || std.mem.Allocator.Error;

/// Builder for `$filter`.
///
/// The builder keeps rendered text rather than an expression tree. That is
/// sufficient because the grammar it produces is left-leaning: `and` and `or`
/// simply append, `not` prefixes everything built so far, and `group` wraps
/// it. The result is identical to what `nv-redfish`'s AST renders.
///
/// ```zig
/// var filter: FilterQuery = .empty;
/// defer filter.deinit(gpa);
///
/// try filter.compare(gpa, "Status/State", .eq, .{ .string = "Enabled" });
/// try filter.logical(gpa, .@"and");
/// try filter.compare(gpa, "Status/Health", .eq, .{ .string = "OK" });
/// try filter.group(gpa);
/// // `$filter=(Status/State eq 'Enabled' and Status/Health eq 'OK')`
/// ```
pub const FilterQuery = struct {
    text: std.ArrayList(u8) = .empty,
    pending: ?LogicalOp = null,

    pub const empty: FilterQuery = .{};

    pub fn deinit(self: *FilterQuery, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.* = undefined;
    }

    pub fn isEmpty(self: FilterQuery) bool {
        return self.text.items.len == 0;
    }

    /// The expression without the `$filter=` prefix, borrowed from the
    /// builder. Empty when nothing has been added.
    pub fn expression(self: FilterQuery) []const u8 {
        return self.text.items;
    }

    /// Append `<property> <op> <literal>`.
    ///
    /// The property is a path relative to the resource, so `Status/Health` is
    /// valid. After the first comparison, every further one must be preceded
    /// by `logical`.
    pub fn compare(
        self: *FilterQuery,
        gpa: std.mem.Allocator,
        property: []const u8,
        op: Comparison,
        value: FilterLiteral,
    ) FilterError!void {
        if (self.isEmpty()) {
            if (self.pending != null) return FilterError.UnexpectedLogicalOperator;
        } else {
            const pending = self.pending orelse return FilterError.MissingLogicalOperator;
            try self.text.print(gpa, " {s} ", .{pending.token()});
            self.pending = null;
        }
        try self.text.print(gpa, "{s} {s} {f}", .{ property, op.token(), value });
    }

    /// Record the operator joining the previous comparison to the next one.
    pub fn logical(self: *FilterQuery, gpa: std.mem.Allocator, op: LogicalOp) FilterError!void {
        _ = gpa;
        if (self.isEmpty()) return FilterError.UnexpectedLogicalOperator;
        if (self.pending != null) return FilterError.UnexpectedLogicalOperator;
        self.pending = op;
    }

    /// Negate everything built so far.
    pub fn not(self: *FilterQuery, gpa: std.mem.Allocator) FilterError!void {
        if (self.isEmpty()) return FilterError.EmptyFilter;
        try self.text.insertSlice(gpa, 0, "not ");
    }

    /// Parenthesize everything built so far, so a following `or` binds to the
    /// group rather than to the last comparison.
    pub fn group(self: *FilterQuery, gpa: std.mem.Allocator) FilterError!void {
        if (self.isEmpty()) return FilterError.EmptyFilter;
        try self.text.insertSlice(gpa, 0, "(");
        try self.text.append(gpa, ')');
    }

    /// `$filter=<expression>`, or nothing at all when the filter is empty.
    pub fn format(self: FilterQuery, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isEmpty()) return;
        try w.print("$filter={s}", .{self.text.items});
    }

    pub fn toQueryString(self: FilterQuery, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{f}", .{self});
    }
};

/// The query parameters for one request, rendered as a `?a=b&c=d` string.
///
/// Every field is optional; omitted ones contribute nothing. `filter` holds
/// an already-rendered expression, usually `FilterQuery.expression()`, which
/// keeps the ownership of the builder's buffer with the caller.
pub const QueryOptions = struct {
    expand: ?ExpandQuery = null,
    /// A `$filter` expression, without the `$filter=` prefix.
    filter: ?[]const u8 = null,
    /// `$select` property paths.
    select: ?[]const []const u8 = null,
    /// `$top` — maximum number of collection members to return.
    top: ?u32 = null,
    /// `$skip` — number of collection members to skip.
    skip: ?u32 = null,
    /// `$only` — return the sole member of a collection directly.
    only: bool = false,
    /// `$excerpt` — return the excerpt form of the resource.
    excerpt: bool = false,

    pub const none: QueryOptions = .{};

    pub fn isEmpty(self: QueryOptions) bool {
        return self.expand == null and
            self.filter == null and
            self.select == null and
            self.top == null and
            self.skip == null and
            !self.only and
            !self.excerpt;
    }

    /// Renders `?<param>&<param>…`, or nothing when no parameter is set, so
    /// the result can be concatenated onto a resource path unconditionally.
    pub fn format(self: QueryOptions, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isEmpty()) return;

        var separator: u8 = '?';
        if (self.expand) |expand| {
            try w.print("{c}{f}", .{ separator, expand });
            separator = '&';
        }
        if (self.filter) |filter| {
            try w.print("{c}$filter={s}", .{ separator, filter });
            separator = '&';
        }
        if (self.select) |paths| {
            try w.print("{c}$select=", .{separator});
            for (paths, 0..) |path, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll(path);
            }
            separator = '&';
        }
        if (self.top) |top| {
            try w.print("{c}$top={d}", .{ separator, top });
            separator = '&';
        }
        if (self.skip) |skip| {
            try w.print("{c}$skip={d}", .{ separator, skip });
            separator = '&';
        }
        if (self.only) {
            try w.print("{c}$only", .{separator});
            separator = '&';
        }
        if (self.excerpt) {
            try w.print("{c}$excerpt", .{separator});
            separator = '&';
        }
    }

    pub fn toQueryString(self: QueryOptions, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{f}", .{self});
    }
};

const testing = std.testing;

fn expectRender(expected: []const u8, value: anytype) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{value}));
}

test "the default expand is one level, excluding links" {
    try expectRender("$expand=.($levels=1)", ExpandQuery.default);
    try expectRender("$expand=.($levels=1)", ExpandQuery{});
}

test "renders each expand expression" {
    try expectRender("$expand=*($levels=1)", ExpandQuery.all(1));
    try expectRender("$expand=.($levels=1)", ExpandQuery.current(1));
    try expectRender("$expand=~($levels=1)", ExpandQuery.links(1));
    try expectRender("$expand=Thermal($levels=1)", ExpandQuery.property("Thermal"));
    try expectRender(
        "$expand=Thermal,Power($levels=1)",
        ExpandQuery.properties(&.{ "Thermal", "Power" }),
    );
    try expectRender(
        "$expand=Processors,Memory,Storage($levels=1)",
        ExpandQuery.properties(&.{ "Processors", "Memory", "Storage" }),
    );
}

test "omits levels when it is null" {
    try expectRender("$expand=.", ExpandQuery.no_levels);
    try expectRender("$expand=*", ExpandQuery.all(null));
}

test "carries levels other than one" {
    try expectRender("$expand=*($levels=3)", ExpandQuery.all(3));
    try expectRender("$expand=Thermal($levels=2)", ExpandQuery{
        .expression = .{ .property = "Thermal" },
        .levels = 2,
    });
}

test "an empty property list renders an empty expression" {
    try expectRender("$expand=($levels=1)", ExpandQuery.properties(&.{}));
}

test "toQueryString allocates the same text format writes" {
    const rendered = try ExpandQuery.all(3).toQueryString(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("$expand=*($levels=3)", rendered);
}

test "renders each literal type" {
    try expectRender("2", FilterLiteral{ .integer = 2 });
    try expectRender("-7", FilterLiteral{ .integer = -7 });
    try expectRender("'Physical'", FilterLiteral{ .string = "Physical" });
    try expectRender("true", FilterLiteral{ .boolean = true });
    try expectRender("false", FilterLiteral{ .boolean = false });
    try expectRender("98.6", FilterLiteral{ .number = 98.6 });
    try expectRender("98.60", FilterLiteral{ .decimal = try Decimal.parse("98.60") });
}

test "doubles single quotes inside a string literal" {
    try expectRender("'O''Brien'", FilterLiteral{ .string = "O'Brien" });
    try expectRender("''''", FilterLiteral{ .string = "'" });
    try expectRender("''''''", FilterLiteral{ .string = "''" });
    try expectRender("'a''b''c'", FilterLiteral{ .string = "a'b'c" });
    try expectRender("''", FilterLiteral{ .string = "" });
}

test "a single comparison" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try expectRender("$filter=Count eq 2", filter);
    try testing.expectEqualStrings("Count eq 2", filter.expression());
}

test "renders every comparison operator" {
    const cases = .{
        .{ Comparison.ne, "$filter=A ne 1" },
        .{ Comparison.gt, "$filter=A gt 1" },
        .{ Comparison.ge, "$filter=A ge 1" },
        .{ Comparison.lt, "$filter=A lt 1" },
        .{ Comparison.le, "$filter=A le 1" },
        .{ Comparison.eq, "$filter=A eq 1" },
    };
    inline for (cases) |case| {
        var filter: FilterQuery = .empty;
        defer filter.deinit(testing.allocator);
        try filter.compare(testing.allocator, "A", case[0], .{ .integer = 1 });
        try expectRender(case[1], filter);
    }
}

test "joins comparisons with and" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try filter.logical(testing.allocator, .@"and");
    try filter.compare(testing.allocator, "Type", .eq, .{ .string = "Physical" });
    try expectRender("$filter=Count eq 2 and Type eq 'Physical'", filter);
}

test "joins comparisons with or" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try filter.logical(testing.allocator, .@"or");
    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 4 });
    try expectRender("$filter=Count eq 2 or Count eq 4", filter);
}

test "not negates everything built so far" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try filter.not(testing.allocator);
    try expectRender("$filter=not Count eq 2", filter);
}

test "group parenthesizes so a following or binds to the whole group" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Status/State", .eq, .{ .string = "Enabled" });
    try filter.logical(testing.allocator, .@"and");
    try filter.compare(testing.allocator, "Status/Health", .eq, .{ .string = "OK" });
    try filter.group(testing.allocator);
    try filter.logical(testing.allocator, .@"or");
    try filter.compare(testing.allocator, "SystemType", .eq, .{ .string = "Physical" });

    try expectRender(
        "$filter=(Status/State eq 'Enabled' and Status/Health eq 'OK')" ++
            " or SystemType eq 'Physical'",
        filter,
    );
}

test "property paths may be nested" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "ProcessorSummary/Count", .eq, .{ .integer = 2 });
    try filter.logical(testing.allocator, .@"and");
    try filter.compare(
        testing.allocator,
        "MemorySummary/TotalSystemMemoryGiB",
        .gt,
        .{ .integer = 64 },
    );

    try expectRender(
        "$filter=ProcessorSummary/Count eq 2 and" ++
            " MemorySummary/TotalSystemMemoryGiB gt 64",
        filter,
    );
}

test "a chained comparison without a logical operator is an error" {
    // nv-redfish silently discards the earlier clause here, which broadens
    // the query instead of narrowing it.
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try testing.expectError(
        FilterError.MissingLogicalOperator,
        filter.compare(testing.allocator, "Type", .eq, .{ .string = "Physical" }),
    );

    // The first clause is untouched, so the caller can recover.
    try expectRender("$filter=Count eq 2", filter);
}

test "a stray logical operator is an error" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try testing.expectError(
        FilterError.UnexpectedLogicalOperator,
        filter.logical(testing.allocator, .@"and"),
    );

    try filter.compare(testing.allocator, "Count", .eq, .{ .integer = 2 });
    try filter.logical(testing.allocator, .@"and");
    try testing.expectError(
        FilterError.UnexpectedLogicalOperator,
        filter.logical(testing.allocator, .@"or"),
    );
}

test "not and group reject an empty filter" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try testing.expectError(FilterError.EmptyFilter, filter.not(testing.allocator));
    try testing.expectError(FilterError.EmptyFilter, filter.group(testing.allocator));
}

test "an empty filter renders nothing" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.isEmpty());
    try expectRender("", filter);
    try testing.expectEqualStrings("", filter.expression());
}

test "QueryOptions renders nothing when empty" {
    try expectRender("", QueryOptions.none);
    try testing.expect(QueryOptions.none.isEmpty());
}

test "QueryOptions renders one parameter with a leading question mark" {
    try expectRender("?$top=10", QueryOptions{ .top = 10 });
    try expectRender("?$skip=5", QueryOptions{ .skip = 5 });
    try expectRender("?$only", QueryOptions{ .only = true });
    try expectRender("?$excerpt", QueryOptions{ .excerpt = true });
    try expectRender("?$expand=.($levels=1)", QueryOptions{ .expand = .default });
    try expectRender(
        "?$select=Name,Status/Health",
        QueryOptions{ .select = &.{ "Name", "Status/Health" } },
    );
    try expectRender(
        "?$filter=Count eq 2",
        QueryOptions{ .filter = "Count eq 2" },
    );
}

test "QueryOptions joins parameters with ampersands in a fixed order" {
    try expectRender(
        "?$expand=*($levels=2)&$filter=Count eq 2&$select=Name&$top=10&$skip=5&$only&$excerpt",
        QueryOptions{
            .expand = .all(2),
            .filter = "Count eq 2",
            .select = &.{"Name"},
            .top = 10,
            .skip = 5,
            .only = true,
            .excerpt = true,
        },
    );
}

test "QueryOptions takes a filter straight from the builder" {
    var filter: FilterQuery = .empty;
    defer filter.deinit(testing.allocator);

    try filter.compare(testing.allocator, "Status/Health", .eq, .{ .string = "OK" });

    try expectRender(
        "?$expand=.($levels=1)&$filter=Status/Health eq 'OK'",
        QueryOptions{ .expand = .default, .filter = filter.expression() },
    );
}

test "QueryOptions appends cleanly onto a resource path" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/redfish/v1/Systems?$top=10",
        try std.fmt.bufPrint(&buf, "/redfish/v1/Systems{f}", .{QueryOptions{ .top = 10 }}),
    );
    try testing.expectEqualStrings(
        "/redfish/v1/Systems",
        try std.fmt.bufPrint(&buf, "/redfish/v1/Systems{f}", .{QueryOptions.none}),
    );
}
