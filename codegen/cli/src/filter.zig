//! Wildcard patterns that select which types a profile compiles.
//!
//! A profile does not name every type it wants — Redfish versions its
//! namespaces, so naming `Chassis.v1_25_0.Chassis` would pin a profile to a
//! schema release. Profiles name shapes instead:
//!
//!     Chassis.*                 every type in the unversioned namespace
//!     Chassis.*.*               every type in every version of it
//!     Chassis.*.Chassis|Power   two named types, any version
//!     *.*.Redundancy            one named type, any namespace, any version
//!
//! The last pattern segment names types (`|`-separated, or `*` for any); the
//! rest match namespace segments positionally, and the segment count must
//! match exactly. That exactness is what makes `Chassis.*` and `Chassis.*.*`
//! different patterns rather than one subsuming the other.
//!
//! Ported from `nv-redfish`'s `EntityTypeFilter`, because `features.toml`
//! entries are written in this syntax and `profiles.yaml` will carry them
//! across unchanged.

const std = @import("std");

const schema_index = @import("schema_index.zig");

const QualifiedName = schema_index.QualifiedName;

pub const Error = error{
    /// The pattern was empty, or a segment of it was.
    EmptyPattern,
    /// A segment was neither `*` nor a valid OData simple identifier.
    InvalidIdentifier,
} || std.mem.Allocator.Error;

/// One pattern: namespace segments, then the type names.
pub const Pattern = struct {
    /// One entry per namespace segment; null is `*`.
    namespace: []const ?[]const u8 = &.{},
    /// The names this pattern accepts. Empty means any name.
    names: []const []const u8 = &.{},

    pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Pattern {
        if (text.len == 0) return error.EmptyPattern;

        const split = std.mem.lastIndexOfScalar(u8, text, '.');
        const name_part = if (split) |at| text[at + 1 ..] else text;
        const namespace_part = if (split) |at| text[0..at] else "";

        var names: std.ArrayList([]const u8) = .empty;
        if (!std.mem.eql(u8, name_part, "*")) {
            var parts = std.mem.splitScalar(u8, name_part, '|');
            while (parts.next()) |part| {
                if (!isSimpleIdentifier(part)) return error.InvalidIdentifier;
                try names.append(arena, part);
            }
        }

        var namespace: std.ArrayList(?[]const u8) = .empty;
        if (namespace_part.len > 0) {
            var parts = std.mem.splitScalar(u8, namespace_part, '.');
            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, "*")) {
                    try namespace.append(arena, null);
                } else {
                    if (!isSimpleIdentifier(part)) return error.InvalidIdentifier;
                    try namespace.append(arena, part);
                }
            }
        }

        return .{
            .namespace = try namespace.toOwnedSlice(arena),
            .names = try names.toOwnedSlice(arena),
        };
    }

    pub fn matches(self: Pattern, qualified: QualifiedName) bool {
        if (self.names.len > 0) {
            const name = qualified.name();
            var found = false;
            for (self.names) |candidate| {
                if (std.mem.eql(u8, candidate, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        const namespace = qualified.namespace();
        if (namespace.segmentCount() != self.namespace.len) return false;
        for (self.namespace, 0..) |expected, depth| {
            const actual = namespace.segment(depth) orelse return false;
            if (expected) |text| {
                if (!std.mem.eql(u8, text, actual)) return false;
            }
        }
        return true;
    }

    pub fn format(self: Pattern, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.namespace) |segment| try w.print("{s}.", .{segment orelse "*"});
        if (self.names.len == 0) {
            try w.writeAll("*");
            return;
        }
        for (self.names, 0..) |name, index| {
            if (index > 0) try w.writeByte('|');
            try w.writeAll(name);
        }
    }
};

/// How a filter behaves when it holds no patterns at all.
pub const Mode = enum {
    /// No patterns means "everything" — the default for a filter that
    /// narrows an already-bounded set.
    permissive,
    /// No patterns means "nothing" — for a filter that selects from
    /// everything.
    restrictive,
};

pub const TypeFilter = struct {
    patterns: []const Pattern = &.{},
    mode: Mode = .permissive,

    pub fn parse(arena: std.mem.Allocator, texts: []const []const u8, mode: Mode) Error!TypeFilter {
        const patterns = try arena.alloc(Pattern, texts.len);
        for (texts, patterns) |text, *pattern| pattern.* = try .parse(arena, text);
        return .{ .patterns = patterns, .mode = mode };
    }

    pub fn matches(self: TypeFilter, qualified: QualifiedName) bool {
        if (self.patterns.len == 0) return self.mode == .permissive;
        for (self.patterns) |pattern| {
            if (pattern.matches(qualified)) return true;
        }
        return false;
    }
};

/// A property selected by type and name: `Chassis.*.Chassis/Location`.
///
/// Used for rigid arrays — collections a service treats as fixed-length, so
/// their entries stay addressable and a null entry is meaningful. The schema
/// does not say which collections those are, so profiles list them.
pub const PropertyFilter = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        property: []const u8,
        types: TypeFilter,
    };

    /// Parses `<type pattern>/<property name>` entries. Entries naming the
    /// same property are merged, so one lookup answers for all of them.
    pub fn parse(arena: std.mem.Allocator, texts: []const []const u8) Error!PropertyFilter {
        var entries: std.ArrayList(Entry) = .empty;
        var patterns: std.ArrayList(std.ArrayList(Pattern)) = .empty;

        for (texts) |text| {
            const split = std.mem.lastIndexOfScalar(u8, text, '/') orelse return error.EmptyPattern;
            const property = text[split + 1 ..];
            if (!isSimpleIdentifier(property)) return error.InvalidIdentifier;
            const pattern: Pattern = try .parse(arena, text[0..split]);

            const index = for (entries.items, 0..) |entry, at| {
                if (std.mem.eql(u8, entry.property, property)) break at;
            } else index: {
                try entries.append(arena, .{
                    .property = property,
                    .types = .{ .mode = .restrictive },
                });
                try patterns.append(arena, .empty);
                break :index entries.items.len - 1;
            };
            try patterns.items[index].append(arena, pattern);
        }

        for (entries.items, patterns.items) |*entry, *list| {
            entry.types.patterns = try list.toOwnedSlice(arena);
        }
        return .{ .entries = try entries.toOwnedSlice(arena) };
    }

    pub fn matches(self: PropertyFilter, qualified: QualifiedName, property: []const u8) bool {
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.property, property)) continue;
            if (entry.types.matches(qualified)) return true;
        }
        return false;
    }
};

/// An OData simple identifier: a letter or underscore, then letters, digits
/// and underscores, up to 128 characters.
pub fn isSimpleIdentifier(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const testing = std.testing;

test "a namespace pattern matches every type in that namespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const pattern: Pattern = try .parse(arena.allocator(), "Chassis.*");

    try testing.expect(pattern.matches(.parse("Chassis.Chassis")));
    try testing.expect(pattern.matches(.parse("Chassis.Anything")));

    // A versioned namespace has two segments, so it is not this pattern.
    try testing.expect(!pattern.matches(.parse("Chassis.v1_25_0.Chassis")));
    try testing.expect(!pattern.matches(.parse("Drive.Drive")));
}

test "a version wildcard matches every version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const pattern: Pattern = try .parse(arena.allocator(), "Chassis.*.*");

    try testing.expect(pattern.matches(.parse("Chassis.v1_0_0.Chassis")));
    try testing.expect(pattern.matches(.parse("Chassis.v1_25_0.Thermal")));

    // Exactly two namespace segments: not the unversioned one, not a deeper
    // one.
    try testing.expect(!pattern.matches(.parse("Chassis.Chassis")));
    try testing.expect(!pattern.matches(.parse("Drive.v1_0_0.Drive")));
}

test "a name list matches only those names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const pattern: Pattern = try .parse(arena.allocator(), "Chassis.*.Chassis|Thermal");

    try testing.expect(pattern.matches(.parse("Chassis.v1_25_0.Chassis")));
    try testing.expect(pattern.matches(.parse("Chassis.v1_1_0.Thermal")));
    try testing.expect(!pattern.matches(.parse("Chassis.v1_25_0.Power")));
}

test "a leading wildcard matches any namespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const pattern: Pattern = try .parse(arena.allocator(), "*.*.Redundancy");

    try testing.expect(pattern.matches(.parse("Redundancy.v1_4_0.Redundancy")));
    try testing.expect(pattern.matches(.parse("Anything.v1_0_0.Redundancy")));
    try testing.expect(!pattern.matches(.parse("Redundancy.v1_4_0.Other")));
    try testing.expect(!pattern.matches(.parse("Redundancy.Redundancy")));
}

test "an unqualified pattern matches an unqualified name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const pattern: Pattern = try .parse(arena.allocator(), "Resource");

    try testing.expect(pattern.matches(.parse("Resource")));
    try testing.expect(!pattern.matches(.parse("Resource.Resource")));
}

test "a pattern round-trips through its own formatting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "Chassis.*",
        "Chassis.*.*",
        "Chassis.*.Chassis|Thermal",
        "*.*.Redundancy",
    }) |text| {
        const pattern: Pattern = try .parse(arena.allocator(), text);
        try testing.expectFmt(text, "{f}", .{pattern});
    }
}

test "a malformed pattern is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.EmptyPattern, Pattern.parse(a, ""));
    try testing.expectError(error.InvalidIdentifier, Pattern.parse(a, "Chassis..Chassis"));
    try testing.expectError(error.InvalidIdentifier, Pattern.parse(a, "Chassis.*.1Chassis"));
    try testing.expectError(error.InvalidIdentifier, Pattern.parse(a, "Chassis-Bay.*"));
    try testing.expectError(error.InvalidIdentifier, Pattern.parse(a, "Chassis.*.A|"));
}

test "an empty filter answers according to its mode" {
    const permissive: TypeFilter = .{ .mode = .permissive };
    const restrictive: TypeFilter = .{ .mode = .restrictive };

    try testing.expect(permissive.matches(.parse("Anything.At.All")));
    try testing.expect(!restrictive.matches(.parse("Anything.At.All")));
}

test "a filter matches if any of its patterns does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const filter: TypeFilter = try .parse(arena.allocator(), &.{
        "Chassis.*",
        "ChassisCollection.*",
        "Drive.*.Drive",
    }, .restrictive);

    try testing.expect(filter.matches(.parse("Chassis.Chassis")));
    try testing.expect(filter.matches(.parse("ChassisCollection.ChassisCollection")));
    try testing.expect(filter.matches(.parse("Drive.v1_21_0.Drive")));
    try testing.expect(!filter.matches(.parse("Drive.v1_21_0.Links")));
    try testing.expect(!filter.matches(.parse("Thermal.Thermal")));
}

test "a rigid-array pattern selects one property of one type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Both entries are from features.toml, verbatim.
    const filter: PropertyFilter = try .parse(arena.allocator(), &.{
        "AccountService.*.ExternalAccountProvider/RemoteRoleMapping",
        "EthernetInterface.*.EthernetInterface/StaticNameServers",
    });

    try testing.expect(filter.matches(
        .parse("AccountService.v1_15_0.ExternalAccountProvider"),
        "RemoteRoleMapping",
    ));
    try testing.expect(filter.matches(
        .parse("EthernetInterface.v1_12_0.EthernetInterface"),
        "StaticNameServers",
    ));

    // Right property, wrong type.
    try testing.expect(!filter.matches(
        .parse("EthernetInterface.v1_12_0.EthernetInterface"),
        "RemoteRoleMapping",
    ));
    // Right type, wrong property.
    try testing.expect(!filter.matches(
        .parse("AccountService.v1_15_0.ExternalAccountProvider"),
        "Something",
    ));
    // Right shape, wrong namespace.
    try testing.expect(!filter.matches(
        .parse("Other.v1_0_0.ExternalAccountProvider"),
        "RemoteRoleMapping",
    ));
}

test "rigid-array patterns for one property are merged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const filter: PropertyFilter = try .parse(arena.allocator(), &.{
        "A.*.One/Shared",
        "B.*.Two/Shared",
        "C.*.Three/Other",
    });

    try testing.expectEqual(@as(usize, 2), filter.entries.len);
    try testing.expect(filter.matches(.parse("A.v1_0_0.One"), "Shared"));
    try testing.expect(filter.matches(.parse("B.v1_0_0.Two"), "Shared"));
    try testing.expect(!filter.matches(.parse("C.v1_0_0.Three"), "Shared"));
    try testing.expect(filter.matches(.parse("C.v1_0_0.Three"), "Other"));
}

test "a property pattern without a property name is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.EmptyPattern,
        PropertyFilter.parse(arena.allocator(), &.{"Chassis.*.Chassis"}),
    );
    try testing.expectError(
        error.InvalidIdentifier,
        PropertyFilter.parse(arena.allocator(), &.{"Chassis.*.Chassis/@odata.id"}),
    );
}

test isSimpleIdentifier {
    try testing.expect(isSimpleIdentifier("Chassis"));
    try testing.expect(isSimpleIdentifier("v1_25_0"));
    try testing.expect(isSimpleIdentifier("_private"));

    try testing.expect(!isSimpleIdentifier(""));
    try testing.expect(!isSimpleIdentifier("1Chassis"));
    try testing.expect(!isSimpleIdentifier("@odata.id"));
    try testing.expect(!isSimpleIdentifier("Chassis-Bay"));
    try testing.expect(!isSimpleIdentifier("*"));
    try testing.expect(!isSimpleIdentifier("x" ** 129));
}
