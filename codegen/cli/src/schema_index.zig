//! An index over the schemas of a set of EDMX documents.
//!
//! `csdl.zig` reports what one document says; this is where documents start
//! talking to each other. It answers three questions the compiler asks
//! constantly:
//!
//!   * Which schema declares namespace `N`?
//!   * What type does the qualified name `N.T` refer to, once `Include`
//!     aliases are expanded?
//!   * Which types derive from `N.T`?
//!
//! The third one carries more weight in Redfish than it looks. Versions are
//! modelled as inheritance — `Chassis.v1_25_0.Chassis` derives from
//! `Chassis.v1_24_0.Chassis`, and so on back to the unversioned abstract
//! `Chassis.Chassis` — so "the newest version of a type" is really "the most
//! derived type", which is what `mostDerived` walks to.
//!
//! Nothing here interprets a schema. Inheritance is indexed, not flattened;
//! that is `compile.zig`'s job.

const std = @import("std");

const csdl = @import("csdl.zig");

pub const Error = error{
    /// Two schemas in the input declare the same namespace.
    DuplicateNamespace,
    /// A base-type chain leads back to itself.
    CyclicInheritance,
} || std.mem.Allocator.Error;

/// Details of a failed `build`, for a message the caller can act on.
///
/// Both fields borrow from the index arena and the input documents, so they
/// stay valid for as long as those do.
pub const Diagnostics = struct {
    /// The namespace declared twice, on `DuplicateNamespace`.
    duplicate: ?Namespace = null,
    /// The cycle, in inheritance order, on `CyclicInheritance`. The last
    /// element derives from the first.
    cycle: []const QualifiedName = &.{},
};

/// A Redfish schema version, as written in a namespace segment: `v1_25_0`.
pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    errata: u32 = 0,

    /// Parses `v1_25_0`, `v1_25` or `v1`. Returns null for anything else,
    /// including OData's uppercase `V1`, which is not a Redfish version and
    /// must not be treated as one.
    pub fn parse(text: []const u8) ?Version {
        if (text.len < 2 or text[0] != 'v') return null;

        var parts = std.mem.splitScalar(u8, text[1..], '_');
        var result: Version = .{ .major = 0 };
        var index: usize = 0;
        while (parts.next()) |part| : (index += 1) {
            const value = std.fmt.parseInt(u32, part, 10) catch return null;
            switch (index) {
                0 => result.major = value,
                1 => result.minor = value,
                2 => result.errata = value,
                else => return null,
            }
        }
        return result;
    }

    pub fn order(self: Version, other: Version) std.math.Order {
        return switch (std.math.order(self.major, other.major)) {
            .eq => switch (std.math.order(self.minor, other.minor)) {
                .eq => std.math.order(self.errata, other.errata),
                else => |result| result,
            },
            else => |result| result,
        };
    }

    pub fn format(self: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("v{d}_{d}_{d}", .{ self.major, self.minor, self.errata });
    }
};

/// A dotted namespace: `Chassis`, `Chassis.v1_25_0`, `Org.OData.Core.V1`.
///
/// Borrows its text; a namespace is always a slice of a document or of the
/// index arena.
pub const Namespace = struct {
    text: []const u8,

    pub fn init(text: []const u8) Namespace {
        return .{ .text = text };
    }

    pub fn segmentCount(self: Namespace) usize {
        if (self.text.len == 0) return 0;
        return std.mem.count(u8, self.text, ".") + 1;
    }

    /// The `index`th dot-separated segment, or null past the end.
    pub fn segment(self: Namespace, index: usize) ?[]const u8 {
        var parts = std.mem.splitScalar(u8, self.text, '.');
        var i: usize = 0;
        while (parts.next()) |part| : (i += 1) {
            if (i == index) return part;
        }
        return null;
    }

    /// The first segment: the schema family, `Chassis` for `Chassis.v1_25_0`.
    pub fn root(self: Namespace) Namespace {
        const dot = std.mem.indexOfScalar(u8, self.text, '.') orelse return self;
        return .init(self.text[0..dot]);
    }

    /// The final segment.
    pub fn last(self: Namespace) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, self.text, '.') orelse return self.text;
        return self.text[dot + 1 ..];
    }

    /// This namespace with its final segment removed, or null when it has
    /// only one.
    pub fn parent(self: Namespace) ?Namespace {
        const dot = std.mem.lastIndexOfScalar(u8, self.text, '.') orelse return null;
        return .init(self.text[0..dot]);
    }

    /// The version in the final segment, if it has one.
    pub fn version(self: Namespace) ?Version {
        return .parse(self.last());
    }

    /// This namespace with a trailing version segment removed, so both
    /// `Chassis` and `Chassis.v1_25_0` name the same schema family.
    pub fn unversioned(self: Namespace) Namespace {
        if (self.version() == null) return self;
        return self.parent() orelse self;
    }

    pub fn eql(self: Namespace, other: Namespace) bool {
        return std.mem.eql(u8, self.text, other.text);
    }

    pub fn order(self: Namespace, other: Namespace) std.math.Order {
        return std.mem.order(u8, self.text, other.text);
    }

    pub fn format(self: Namespace, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.text);
    }
};

/// A namespace-qualified type name: `Chassis.v1_25_0.Chassis`.
///
/// The namespace is everything before the last dot, which is why this is not
/// a two-field struct: it is exactly the text a CSDL attribute carries, and
/// keeping it whole means it can be used as a map key without allocating.
pub const QualifiedName = struct {
    text: []const u8,

    /// Borrows `text` as written.
    pub fn parse(text: []const u8) QualifiedName {
        return .{ .text = text };
    }

    /// Joins a namespace and a local name, allocating the result.
    pub fn join(allocator: std.mem.Allocator, in: []const u8, local: []const u8) !QualifiedName {
        return .{ .text = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ in, local }) };
    }

    pub fn namespace(self: QualifiedName) Namespace {
        const dot = std.mem.lastIndexOfScalar(u8, self.text, '.') orelse return .init("");
        return .init(self.text[0..dot]);
    }

    pub fn name(self: QualifiedName) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, self.text, '.') orelse return self.text;
        return self.text[dot + 1 ..];
    }

    pub fn eql(self: QualifiedName, other: QualifiedName) bool {
        return std.mem.eql(u8, self.text, other.text);
    }

    pub fn order(self: QualifiedName, other: QualifiedName) std.math.Order {
        return std.mem.order(u8, self.text, other.text);
    }

    pub fn format(self: QualifiedName, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.text);
    }
};

/// One of the four things a qualified name can resolve to.
pub const TypeEntry = union(enum) {
    entity_type: *const csdl.EntityType,
    complex_type: *const csdl.ComplexType,
    enum_type: *const csdl.EnumType,
    type_definition: *const csdl.TypeDefinition,
};

/// A schema, together with where it came from.
pub const Entry = struct {
    namespace: Namespace,
    schema: *const csdl.Schema,
    /// Index into the document slice `build` was given.
    document: usize,
};

/// A document and the aliases in scope inside it.
const Doc = struct {
    document: *const csdl.Document,
    aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

pub const SchemaIndex = struct {
    arena: std.mem.Allocator,
    docs: []Doc,
    entries: []Entry,
    /// Namespace text to index into `entries`.
    by_namespace: std.StringArrayHashMapUnmanaged(usize) = .empty,
    /// Qualified name to its base type, for entity and complex types.
    bases: std.StringArrayHashMapUnmanaged(QualifiedName) = .empty,
    /// Qualified name to the types that derive from it, in document order.
    derived: std.StringArrayHashMapUnmanaged([]const QualifiedName) = .empty,

    /// Indexes `documents`, which must outlive the index — entries point into
    /// it. Everything allocated is allocated from `arena`, so there is no
    /// `deinit`; free the arena.
    pub fn build(
        arena: std.mem.Allocator,
        documents: []const csdl.Document,
        diagnostics: ?*Diagnostics,
    ) Error!SchemaIndex {
        var self: SchemaIndex = .{
            .arena = arena,
            .docs = try arena.alloc(Doc, documents.len),
            .entries = &.{},
        };

        for (documents, 0..) |*document, index| {
            self.docs[index] = .{ .document = document };
            const aliases = &self.docs[index].aliases;
            for (document.references) |reference| {
                for (reference.includes) |include| {
                    if (include.alias) |alias| try aliases.put(arena, alias, include.namespace);
                }
            }
            for (document.schemas) |*declared| {
                if (declared.alias) |alias| try aliases.put(arena, alias, declared.namespace);
            }
        }

        var entries: std.ArrayList(Entry) = .empty;
        for (documents, 0..) |*document, index| {
            for (document.schemas) |*declared| {
                const slot = try self.by_namespace.getOrPut(arena, declared.namespace);
                if (slot.found_existing) {
                    if (diagnostics) |d| d.duplicate = .init(declared.namespace);
                    return error.DuplicateNamespace;
                }
                slot.value_ptr.* = entries.items.len;
                try entries.append(arena, .{
                    .namespace = .init(declared.namespace),
                    .schema = declared,
                    .document = index,
                });
            }
        }
        self.entries = try entries.toOwnedSlice(arena);

        var derived: std.StringArrayHashMapUnmanaged(std.ArrayList(QualifiedName)) = .empty;
        for (self.entries) |origin| {
            for (origin.schema.entity_types) |entity_type| {
                try self.link(&derived, origin, entity_type.name, entity_type.base_type);
            }
            for (origin.schema.complex_types) |complex_type| {
                try self.link(&derived, origin, complex_type.name, complex_type.base_type);
            }
        }

        try self.derived.ensureTotalCapacity(arena, derived.count());
        for (derived.keys(), derived.values()) |key, *list| {
            self.derived.putAssumeCapacity(key, try list.toOwnedSlice(arena));
        }

        if (try self.findCycle()) |cycle| {
            if (diagnostics) |d| d.cycle = cycle;
            return error.CyclicInheritance;
        }
        return self;
    }

    fn link(
        self: *SchemaIndex,
        derived: *std.StringArrayHashMapUnmanaged(std.ArrayList(QualifiedName)),
        origin: Entry,
        name: []const u8,
        base_type: ?csdl.TypeRef,
    ) Error!void {
        const base = base_type orelse return;
        const qualified: QualifiedName = try .join(self.arena, origin.namespace.text, name);
        const base_name: QualifiedName = .parse(try self.expand(origin.document, base.name));

        try self.bases.put(self.arena, qualified.text, base_name);
        const slot = try derived.getOrPut(self.arena, base_name.text);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(self.arena, qualified);
    }

    /// Expands an alias-qualified name written in document `index` into a
    /// fully namespace-qualified one: inside a document that includes
    /// `RedfishExtensions.v1_0_0` as `Redfish`, `Redfish.Revisions` becomes
    /// `RedfishExtensions.v1_0_0.Revisions`.
    ///
    /// Names that are already qualified come back untouched, borrowing the
    /// input rather than copying it.
    pub fn expand(self: *const SchemaIndex, index: usize, text: []const u8) Error![]const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return text;
        const namespace = text[0..dot];
        const target = self.docs[index].aliases.get(namespace) orelse return text;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ target, text[dot + 1 ..] });
    }

    /// The schema declaring `namespace`.
    pub fn schema(self: *const SchemaIndex, namespace: Namespace) ?*const csdl.Schema {
        const index = self.by_namespace.get(namespace.text) orelse return null;
        return self.entries[index].schema;
    }

    /// The entry for `namespace`, which also says which document it came from.
    pub fn entry(self: *const SchemaIndex, namespace: Namespace) ?Entry {
        const index = self.by_namespace.get(namespace.text) orelse return null;
        return self.entries[index];
    }

    /// Whatever `qualified` names, or null if nothing does.
    pub fn find(self: *const SchemaIndex, qualified: QualifiedName) ?TypeEntry {
        const target = self.schema(qualified.namespace()) orelse return null;
        const name = qualified.name();

        for (target.entity_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return .{ .entity_type = value };
        }
        for (target.complex_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return .{ .complex_type = value };
        }
        for (target.enum_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return .{ .enum_type = value };
        }
        for (target.type_definitions) |*value| {
            if (std.mem.eql(u8, value.name, name)) return .{ .type_definition = value };
        }
        return null;
    }

    pub fn entityType(self: *const SchemaIndex, qualified: QualifiedName) ?*const csdl.EntityType {
        return switch (self.find(qualified) orelse return null) {
            .entity_type => |value| value,
            else => null,
        };
    }

    pub fn complexType(self: *const SchemaIndex, qualified: QualifiedName) ?*const csdl.ComplexType {
        return switch (self.find(qualified) orelse return null) {
            .complex_type => |value| value,
            else => null,
        };
    }

    /// The type `qualified` derives from, if any.
    pub fn baseOf(self: *const SchemaIndex, qualified: QualifiedName) ?QualifiedName {
        return self.bases.get(qualified.text);
    }

    /// The types that derive directly from `qualified`, in document order.
    pub fn derivedFrom(self: *const SchemaIndex, qualified: QualifiedName) []const QualifiedName {
        return self.derived.get(qualified.text) orelse &.{};
    }

    /// Walks down the inheritance chain to the newest version of a type.
    ///
    /// Descends while there is exactly one derived type that contributes
    /// something. A type with two contributing children is a genuine fork —
    /// picking either would be a guess — so the walk stops there, as does one
    /// with none.
    pub fn mostDerived(self: *const SchemaIndex, qualified: QualifiedName) QualifiedName {
        var current = qualified;
        while (true) {
            var only: ?QualifiedName = null;
            var count: usize = 0;
            for (self.derivedFrom(current)) |child| {
                if (!self.contributes(child)) continue;
                count += 1;
                if (count > 1) break;
                only = child;
            }
            if (count != 1) return current;
            current = only.?;
        }
    }

    /// Whether a type adds anything of its own, directly or through a type
    /// derived from it. An empty version bump carries no properties and is
    /// not worth descending to on its own — but one further down the chain
    /// might be.
    fn contributes(self: *const SchemaIndex, qualified: QualifiedName) bool {
        const own = switch (self.find(qualified) orelse return false) {
            .entity_type => |value| value.properties.len > 0 or value.navigation_properties.len > 0,
            .complex_type => |value| value.properties.len > 0 or value.navigation_properties.len > 0,
            else => return false,
        };
        if (own) return true;

        for (self.derivedFrom(qualified)) |child| {
            if (self.contributes(child)) return true;
        }
        return false;
    }

    /// `Resource.Resource`, the base of every Redfish resource, at its newest
    /// version.
    pub fn resourceType(self: *const SchemaIndex) ?QualifiedName {
        return self.wellKnown("Resource.Resource");
    }

    /// `Resource.ResourceCollection`, the base of every collection.
    pub fn resourceCollectionType(self: *const SchemaIndex) ?QualifiedName {
        return self.wellKnown("Resource.ResourceCollection");
    }

    /// `Settings.Settings`, the target of the `@Redfish.Settings` annotation.
    pub fn settingsType(self: *const SchemaIndex) ?QualifiedName {
        return self.wellKnown("Settings.Settings");
    }

    /// `Settings.PreferredApplyTime`, the target of the
    /// `@Redfish.SettingsApplyTime` annotation.
    pub fn preferredApplyTimeType(self: *const SchemaIndex) ?QualifiedName {
        return self.wellKnown("Settings.PreferredApplyTime");
    }

    /// Resources a client receives but that no navigation property points
    /// at, because the protocol addresses them by URI: an `ActionInfo` comes
    /// from the `@Redfish.ActionInfo` annotation on an action, a registry
    /// from a `Location.Uri` inside a registry file, and an `Event` from an
    /// SSE stream or a POST to a subscribed destination.
    ///
    /// Reachability cannot find any of them, so a corpus that declares them
    /// compiles them. The reference project reaches the same conclusion by
    /// hand, listing `Event.v1_0_0.Event` as a root pattern in its event
    /// service feature.
    pub const addressed_by_uri = [_][]const u8{
        "ActionInfo.ActionInfo",
        "AttributeRegistry.AttributeRegistry",
        "Event.Event",
        "MessageRegistry.MessageRegistry",
    };

    /// The subset of `addressed_by_uri` this corpus declares.
    pub fn addressedByUri(self: *const SchemaIndex, into: *std.ArrayList(QualifiedName), gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        for (addressed_by_uri) |text| {
            if (self.wellKnown(text)) |name| try into.append(gpa, name);
        }
    }

    fn wellKnown(self: *const SchemaIndex, text: []const u8) ?QualifiedName {
        const qualified: QualifiedName = .parse(text);
        if (self.find(qualified) == null) return null;
        return self.mostDerived(qualified);
    }

    /// Walks every inheritance chain looking for one that returns to a type
    /// it has already passed through. Chains proven acyclic are remembered,
    /// so each type is walked once.
    fn findCycle(self: *SchemaIndex) Error!?[]const QualifiedName {
        var acyclic: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer acyclic.deinit(self.arena);

        var chain: std.ArrayList(QualifiedName) = .empty;
        defer chain.deinit(self.arena);
        var positions: std.StringArrayHashMapUnmanaged(usize) = .empty;
        defer positions.deinit(self.arena);

        for (self.bases.keys()) |start| {
            if (acyclic.contains(start)) continue;
            chain.clearRetainingCapacity();
            positions.clearRetainingCapacity();

            var current = start;
            while (!acyclic.contains(current)) {
                if (positions.get(current)) |at| {
                    return try self.arena.dupe(QualifiedName, chain.items[at..]);
                }
                try positions.put(self.arena, current, chain.items.len);
                try chain.append(self.arena, .parse(current));
                current = (self.bases.get(current) orelse break).text;
            }
            for (chain.items) |visited| try acyclic.put(self.arena, visited.text, {});
        }
        return null;
    }
};

const testing = std.testing;

/// Two documents that between them exercise everything the index does:
/// an alias, a versioned inheritance chain with an empty version in the
/// middle, a fork, and a cross-document base type.
const resource_csdl =
    \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
    \\  <edmx:DataServices>
    \\    <Schema Namespace="Resource" Alias="Res">
    \\      <EntityType Name="Resource" Abstract="true">
    \\        <Property Name="Id" Type="Resource.Id"/>
    \\      </EntityType>
    \\      <EntityType Name="ResourceCollection" Abstract="true"/>
    \\      <ComplexType Name="Status">
    \\        <Property Name="Health" Type="Resource.Health"/>
    \\      </ComplexType>
    \\    </Schema>
    \\  </edmx:DataServices>
    \\</edmx:Edmx>
;

const chassis_csdl =
    \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
    \\  <edmx:Reference Uri="http://redfish.dmtf.org/schemas/v1/Resource_v1.xml">
    \\    <edmx:Include Namespace="Resource" Alias="Res"/>
    \\  </edmx:Reference>
    \\  <edmx:DataServices>
    \\    <Schema Namespace="Chassis">
    \\      <EntityType Name="Chassis" BaseType="Res.Resource" Abstract="true"/>
    \\    </Schema>
    \\    <Schema Namespace="Chassis.v1_0_0">
    \\      <EntityType Name="Chassis" BaseType="Chassis.Chassis">
    \\        <Property Name="AssetTag" Type="Edm.String"/>
    \\      </EntityType>
    \\    </Schema>
    \\    <Schema Namespace="Chassis.v1_1_0">
    \\      <EntityType Name="Chassis" BaseType="Chassis.v1_0_0.Chassis"/>
    \\    </Schema>
    \\    <Schema Namespace="Chassis.v1_2_0">
    \\      <EntityType Name="Chassis" BaseType="Chassis.v1_1_0.Chassis">
    \\        <NavigationProperty Name="Drives" Type="Collection(Drive.Drive)"/>
    \\      </EntityType>
    \\    </Schema>
    \\  </edmx:DataServices>
    \\</edmx:Edmx>
;

fn parseInto(arena: *std.heap.ArenaAllocator, input: []const u8) !csdl.Document {
    return csdl.parse(arena.allocator(), input);
}

test "namespaces are indexed across documents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena, chassis_csdl),
    };
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expectEqual(@as(usize, 5), index.entries.len);
    try testing.expect(index.schema(.init("Resource")) != null);
    try testing.expect(index.schema(.init("Chassis.v1_2_0")) != null);
    try testing.expect(index.schema(.init("Chassis.v9_9_9")) == null);

    const entry = index.entry(.init("Chassis")).?;
    try testing.expectEqual(@as(usize, 1), entry.document);
}

test "a qualified name resolves to the kind of type it names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena, resource_csdl)};
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expect(index.find(.parse("Resource.Resource")).? == .entity_type);
    try testing.expect(index.find(.parse("Resource.Status")).? == .complex_type);
    try testing.expect(index.find(.parse("Resource.Missing")) == null);

    try testing.expect(index.entityType(.parse("Resource.Resource")) != null);
    try testing.expect(index.entityType(.parse("Resource.Status")) == null);
    try testing.expect(index.complexType(.parse("Resource.Status")) != null);
}

test "an aliased base type is expanded to its namespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena, chassis_csdl),
    };
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    // Written `Res.Resource` in the document, indexed as what it means.
    const base = index.baseOf(.parse("Chassis.Chassis")).?;
    try testing.expectEqualStrings("Resource.Resource", base.text);

    const children = index.derivedFrom(.parse("Resource.Resource"));
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings("Chassis.Chassis", children[0].text);
}

test "expand leaves an unaliased name alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena, chassis_csdl)};
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expectEqualStrings("Resource.Resource", try index.expand(0, "Res.Resource"));
    try testing.expectEqualStrings("Chassis.v1_0_0.Chassis", try index.expand(0, "Chassis.v1_0_0.Chassis"));
    try testing.expectEqualStrings("Edm.String", try index.expand(0, "Edm.String"));
    try testing.expectEqualStrings("Unqualified", try index.expand(0, "Unqualified"));
}

test "mostDerived walks to the newest version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena, chassis_csdl),
    };
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    // v1_1_0 adds nothing, but v1_2_0 below it does, so the walk goes past it.
    const newest = index.mostDerived(.parse("Chassis.Chassis"));
    try testing.expectEqualStrings("Chassis.v1_2_0.Chassis", newest.text);

    // The newest version is its own most derived type.
    try testing.expectEqualStrings(
        "Chassis.v1_2_0.Chassis",
        index.mostDerived(.parse("Chassis.v1_2_0.Chassis")).text,
    );
}

test "mostDerived stops where the chain forks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Fork">
        \\      <EntityType Name="Base" Abstract="true"/>
        \\      <EntityType Name="Left" BaseType="Fork.Base">
        \\        <Property Name="A" Type="Edm.String"/>
        \\      </EntityType>
        \\      <EntityType Name="Right" BaseType="Fork.Base">
        \\        <Property Name="B" Type="Edm.String"/>
        \\      </EntityType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    )};
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expectEqualStrings("Fork.Base", index.mostDerived(.parse("Fork.Base")).text);
}

test "an empty derived type does not attract the walk on its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Empty">
        \\      <EntityType Name="Base">
        \\        <Property Name="A" Type="Edm.String"/>
        \\      </EntityType>
        \\      <EntityType Name="Bump" BaseType="Empty.Base"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    )};
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expectEqualStrings("Empty.Base", index.mostDerived(.parse("Empty.Base")).text);
}

test "the Redfish well-known types resolve to their newest versions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena,
            \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
            \\  <edmx:DataServices>
            \\    <Schema Namespace="Settings">
            \\      <ComplexType Name="Settings" Abstract="true"/>
            \\      <ComplexType Name="PreferredApplyTime" Abstract="true"/>
            \\    </Schema>
            \\    <Schema Namespace="Settings.v1_3_0">
            \\      <ComplexType Name="Settings" BaseType="Settings.Settings">
            \\        <Property Name="SettingsObject" Type="Edm.String"/>
            \\      </ComplexType>
            \\      <ComplexType Name="PreferredApplyTime" BaseType="Settings.PreferredApplyTime">
            \\        <Property Name="ApplyTime" Type="Edm.String"/>
            \\      </ComplexType>
            \\    </Schema>
            \\  </edmx:DataServices>
            \\</edmx:Edmx>
        ),
    };
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expectEqualStrings("Resource.Resource", index.resourceType().?.text);
    try testing.expectEqualStrings("Resource.ResourceCollection", index.resourceCollectionType().?.text);
    try testing.expectEqualStrings("Settings.v1_3_0.Settings", index.settingsType().?.text);
    try testing.expectEqualStrings(
        "Settings.v1_3_0.PreferredApplyTime",
        index.preferredApplyTimeType().?.text,
    );
}

test "a well-known type that is not loaded is absent, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena, chassis_csdl)};
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    try testing.expect(index.resourceType() == null);
    try testing.expect(index.settingsType() == null);
}

test "a namespace declared twice is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena, resource_csdl),
    };

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.DuplicateNamespace,
        SchemaIndex.build(arena.allocator(), &documents, &diagnostics),
    );
    try testing.expectEqualStrings("Resource", diagnostics.duplicate.?.text);
}

test "an inheritance cycle is reported with the types in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Loop">
        \\      <EntityType Name="A" BaseType="Loop.B"/>
        \\      <EntityType Name="B" BaseType="Loop.C"/>
        \\      <EntityType Name="C" BaseType="Loop.A"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    )};

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.CyclicInheritance,
        SchemaIndex.build(arena.allocator(), &documents, &diagnostics),
    );
    try testing.expectEqual(@as(usize, 3), diagnostics.cycle.len);
    try testing.expectEqualStrings("Loop.A", diagnostics.cycle[0].text);
    try testing.expectEqualStrings("Loop.B", diagnostics.cycle[1].text);
    try testing.expectEqualStrings("Loop.C", diagnostics.cycle[2].text);
}

test "a type deriving from itself is a cycle too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Loop">
        \\      <ComplexType Name="Self" BaseType="Loop.Self"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    )};

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.CyclicInheritance,
        SchemaIndex.build(arena.allocator(), &documents, &diagnostics),
    );
    try testing.expectEqual(@as(usize, 1), diagnostics.cycle.len);
}

test "a long inheritance chain is not mistaken for a cycle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const documents = [_]csdl.Document{
        try parseInto(&arena, resource_csdl),
        try parseInto(&arena, chassis_csdl),
    };
    const index: SchemaIndex = try .build(arena.allocator(), &documents, null);

    var walked: usize = 0;
    var current: ?QualifiedName = .parse("Chassis.v1_2_0.Chassis");
    while (current) |value| : (walked += 1) current = index.baseOf(value);
    // v1_2_0 -> v1_1_0 -> v1_0_0 -> Chassis.Chassis -> Resource.Resource
    try testing.expectEqual(@as(usize, 5), walked);
}

test "Version.parse" {
    try testing.expectEqual(Version{ .major = 1, .minor = 25, .errata = 0 }, Version.parse("v1_25_0").?);
    try testing.expectEqual(Version{ .major = 1, .minor = 0, .errata = 0 }, Version.parse("v1").?);
    try testing.expectEqual(Version{ .major = 2, .minor = 3, .errata = 0 }, Version.parse("v2_3").?);

    // Not versions: OData's uppercase form, a bare name, an extra segment.
    try testing.expect(Version.parse("V1") == null);
    try testing.expect(Version.parse("Chassis") == null);
    try testing.expect(Version.parse("v1_2_3_4") == null);
    try testing.expect(Version.parse("v") == null);
    try testing.expect(Version.parse("") == null);
}

test "Version.order" {
    const older: Version = .{ .major = 1, .minor = 2, .errata = 3 };
    try testing.expectEqual(std.math.Order.lt, older.order(.{ .major = 1, .minor = 3 }));
    try testing.expectEqual(std.math.Order.lt, older.order(.{ .major = 2 }));
    try testing.expectEqual(std.math.Order.gt, older.order(.{ .major = 1, .minor = 2, .errata = 2 }));
    try testing.expectEqual(std.math.Order.eq, older.order(older));
    try testing.expectFmt("v1_2_3", "{f}", .{older});
}

test "Namespace segments" {
    const versioned: Namespace = .init("Chassis.v1_25_0");
    try testing.expectEqual(@as(usize, 2), versioned.segmentCount());
    try testing.expectEqualStrings("Chassis", versioned.segment(0).?);
    try testing.expectEqualStrings("v1_25_0", versioned.segment(1).?);
    try testing.expect(versioned.segment(2) == null);
    try testing.expectEqualStrings("Chassis", versioned.root().text);
    try testing.expectEqualStrings("v1_25_0", versioned.last());
    try testing.expectEqualStrings("Chassis", versioned.parent().?.text);
    try testing.expectEqual(@as(u32, 25), versioned.version().?.minor);
    try testing.expectEqualStrings("Chassis", versioned.unversioned().text);

    const plain: Namespace = .init("Chassis");
    try testing.expectEqual(@as(usize, 1), plain.segmentCount());
    try testing.expectEqualStrings("Chassis", plain.root().text);
    try testing.expect(plain.parent() == null);
    try testing.expect(plain.version() == null);
    try testing.expectEqualStrings("Chassis", plain.unversioned().text);

    // An OData namespace is deep but unversioned: `V1` is not `v1`.
    const odata: Namespace = .init("Org.OData.Core.V1");
    try testing.expectEqual(@as(usize, 4), odata.segmentCount());
    try testing.expectEqualStrings("Org", odata.root().text);
    try testing.expect(odata.version() == null);
    try testing.expectEqualStrings("Org.OData.Core.V1", odata.unversioned().text);
}

test "QualifiedName splits at the last dot" {
    const versioned: QualifiedName = .parse("Chassis.v1_25_0.Chassis");
    try testing.expectEqualStrings("Chassis.v1_25_0", versioned.namespace().text);
    try testing.expectEqualStrings("Chassis", versioned.name());

    const primitive: QualifiedName = .parse("Edm.String");
    try testing.expectEqualStrings("Edm", primitive.namespace().text);
    try testing.expectEqualStrings("String", primitive.name());

    const bare: QualifiedName = .parse("Unqualified");
    try testing.expectEqualStrings("", bare.namespace().text);
    try testing.expectEqualStrings("Unqualified", bare.name());

    const joined: QualifiedName = try .join(testing.allocator, "Chassis.v1_25_0", "Chassis");
    defer testing.allocator.free(joined.text);
    try testing.expect(joined.eql(versioned));
    try testing.expectFmt("Chassis.v1_25_0.Chassis", "{f}", .{joined});
}
