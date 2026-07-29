//! The code model: everything the emitter needs, and nothing about Zig.
//!
//! This is the seam of the generator. `compile.zig` resolves CSDL into a
//! `Model`; `emit.zig` turns a `Model` into a package. Neither knows about
//! the other, and the model in between is **JSON-serializable in both
//! directions** so it can be checked in as a fixture — which is what makes an
//! emitter change reviewable as a diff instead of a leap of faith. The
//! pattern is borrowed from `azure-sdk-for-zig/codegen`.
//!
//! Two properties are load-bearing:
//!
//!   * **Ordered, not hashed.** Every collection is a slice in a defined
//!     order, so the same input produces byte-identical JSON.
//!   * **Open and tolerant.** Parsing ignores unknown fields and every field
//!     has a default, so a fixture written by an older generator still loads.
//!
//! Names are kept exactly as the schema writes them: types are qualified
//! (`Chassis.v1_25_0.Chassis`), properties are the wire names
//! (`@odata.id`). Casing and escaping are the emitter's business.

const std = @import("std");

/// What a type reference points at. `unknown` is a legal state: a reference
/// to a type outside the compiled surface can still be named.
pub const Kind = enum {
    primitive,
    entity,
    complex,
    enumeration,
    type_definition,
    unknown,
};

/// A reference to a type, as a property or parameter uses it.
pub const TypeRef = struct {
    /// Qualified name: `Edm.String`, `Chassis.v1_25_0.Chassis`.
    name: []const u8,
    kind: Kind = .unknown,
    /// `Collection(...)` in CSDL.
    collection: bool = false,

    pub fn isPrimitive(self: TypeRef) bool {
        return self.kind == .primitive or std.mem.startsWith(u8, self.name, "Edm.");
    }
};

/// `OData.Permissions`. Absent means the schema did not say, which is not the
/// same as read/write — a property with no permission annotation inherits the
/// containing resource's.
pub const Permissions = enum { read, write, read_write };

/// A `Redfish.ExcerptCopy` target: the default excerpt of a resource, or a
/// named one.
pub const ExcerptCopy = struct {
    /// The excerpt name, or null for the resource's default excerpt.
    key: ?[]const u8 = null,
};

/// A `Redfish.Revisions` entry that deprecated something.
pub const Deprecation = struct {
    /// The version the deprecation was announced in, `v1_5_0`.
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Documentation, kept together because every declaration carries it.
pub const Docs = struct {
    description: ?[]const u8 = null,
    long_description: ?[]const u8 = null,
    deprecated: ?Deprecation = null,
};

/// A structural property.
pub const Property = struct {
    /// The wire name, verbatim: `Id`, `@odata.id`, `Members@odata.count`.
    name: []const u8,
    type: TypeRef,
    nullable: bool = true,
    permissions: ?Permissions = null,
    required: bool = false,
    required_on_create: bool = false,
    /// The excerpt views this property belongs to. Empty means the property
    /// is not part of any excerpt; a single empty string means it is part of
    /// every one. Use `Property.inExcerpt` rather than reading this directly.
    excerpts: []const []const u8 = &.{},
    /// The property exists only in excerpt copies, never in the resource.
    excerpt_only: bool = false,
    /// A collection whose length is fixed by the service, so its entries are
    /// addressable by index and nulls are meaningful.
    rigid_array: bool = false,
    default_value: ?[]const u8 = null,
    docs: Docs = .{},

    /// Whether this property appears in a given excerpt copy of its type.
    ///
    /// A copy that names no view takes every excerpt property, and a property
    /// in every view is taken by every copy; otherwise the copy's view has to
    /// be one the property lists.
    pub fn inExcerpt(self: Property, copy: ExcerptCopy) bool {
        for (self.excerpts) |view| {
            if (view.len == 0) return true;
        }
        const key = copy.key orelse return self.excerpts.len != 0;
        for (self.excerpts) |view| {
            if (std.mem.eql(u8, view, key)) return true;
        }
        return false;
    }
};

/// A navigation property: a link to another resource.
pub const NavProperty = struct {
    name: []const u8,
    /// The target entity type. `collection` distinguishes a member list from
    /// a single link.
    type: TypeRef,
    /// Whether the target is part of the compiled surface. A link out of the
    /// surface is still emitted, but only as a reference — there is no type
    /// to expand into.
    expandable: bool = false,
    nullable: bool = false,
    permissions: ?Permissions = null,
    required: bool = false,
    required_on_create: bool = false,
    /// Set when the link is annotated `Redfish.ExcerptCopy`, meaning the
    /// service inlines part of the target instead of linking to it.
    excerpt_copy: ?ExcerptCopy = null,
    excerpts: []const []const u8 = &.{},
    excerpt_only: bool = false,
    docs: Docs = .{},
};

/// A pattern-matched set of properties, from
/// `Redfish.DynamicPropertyPatterns`.
pub const DynamicProperties = struct {
    /// Regular expression the property name must match.
    pattern: []const u8,
    /// Qualified type every matching property has.
    type: []const u8,
};

pub const EntityType = struct {
    /// Qualified name, at the version it was compiled from.
    name: []const u8,
    /// The type this one derives from, if it is in the model.
    base: ?[]const u8 = null,
    abstract: bool = false,
    /// Names of the properties forming the entity key.
    key: []const []const u8 = &.{},
    properties: []const Property = &.{},
    navigation_properties: []const NavProperty = &.{},
    /// `Redfish.Uris`: where instances of this resource live.
    uris: []const []const u8 = &.{},
    /// The resource always carries `@odata.id` / `@odata.type`.
    must_have_id: bool = false,
    must_have_type: bool = false,
    /// From `Capabilities.*Restrictions` on the containing collection.
    insertable: bool = false,
    updatable: bool = false,
    deletable: bool = false,
    /// A create shape is needed because some collection accepts inserts of
    /// this type.
    creatable: bool = false,
    /// Excerpt shapes that some navigation property asks for.
    excerpt_copies: []const ExcerptCopy = &.{},
    docs: Docs = .{},
};

pub const ComplexType = struct {
    name: []const u8,
    base: ?[]const u8 = null,
    abstract: bool = false,
    properties: []const Property = &.{},
    navigation_properties: []const NavProperty = &.{},
    /// `OData.AdditionalProperties`: the service may add properties the
    /// schema does not name.
    additional_properties: bool = false,
    dynamic_properties: ?DynamicProperties = null,
    /// Type-level permissions. Redfish uses these on very few types, but
    /// `Resource.Status` is one of them, so every resource inherits the
    /// question.
    permissions: ?Permissions = null,
    docs: Docs = .{},
};

pub const EnumMember = struct {
    /// The wire name, verbatim.
    name: []const u8,
    /// An explicit value, for a flags enum.
    value: ?i64 = null,
    docs: Docs = .{},
};

pub const EnumType = struct {
    name: []const u8,
    members: []const EnumMember = &.{},
    is_flags: bool = false,
    docs: Docs = .{},
};

pub const TypeDefinition = struct {
    name: []const u8,
    /// Always an `Edm.*` primitive.
    underlying_type: TypeRef,
    docs: Docs = .{},
};

pub const Parameter = struct {
    name: []const u8,
    type: TypeRef,
    nullable: bool = true,
    required: bool = false,
    docs: Docs = .{},
};

/// A bound action: `#Chassis.Reset` and friends.
pub const Action = struct {
    /// The local action name, without the `#Namespace.` prefix the wire uses.
    name: []const u8,
    /// The entity type the action is bound to.
    binding: []const u8,
    /// The namespace that declares it, which is what the wire prefix is
    /// built from.
    namespace: []const u8,
    /// The bound parameter's name, almost always `Chassis`-style: the target
    /// itself.
    binding_parameter: []const u8 = "",
    parameters: []const Parameter = &.{},
    return_type: ?TypeRef = null,
    docs: Docs = .{},
};

/// What the emitted package is called and where it starts.
pub const Package = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    display_name: ?[]const u8 = null,
    /// The profile in `profiles.yaml` this was generated from.
    profile: ?[]const u8 = null,
    /// The qualified entity type the surface is rooted at, normally
    /// `ServiceRoot.v1_x_y.ServiceRoot`.
    root: ?[]const u8 = null,
};

/// Bumped when a change to this file makes an old fixture unreadable. Adding
/// a field with a default does not count — that is what defaults are for.
pub const format_version: u32 = 1;

pub const Model = struct {
    format: u32 = format_version,
    package: Package,
    entity_types: []const EntityType = &.{},
    complex_types: []const ComplexType = &.{},
    enum_types: []const EnumType = &.{},
    type_definitions: []const TypeDefinition = &.{},
    actions: []const Action = &.{},

    /// Reads a model from JSON. Everything allocated comes from `arena`;
    /// unknown fields are ignored so a fixture from a newer generator still
    /// loads what it can.
    pub fn parse(arena: std.mem.Allocator, json: []const u8) !Model {
        return std.json.parseFromSliceLeaky(Model, arena, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Writes the model as indented JSON, with nulls omitted. Deterministic:
    /// the same model always produces the same bytes.
    pub fn stringify(self: Model, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
    }

    pub fn entityType(self: Model, name: []const u8) ?*const EntityType {
        for (self.entity_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return value;
        }
        return null;
    }

    pub fn complexType(self: Model, name: []const u8) ?*const ComplexType {
        for (self.complex_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return value;
        }
        return null;
    }

    pub fn enumType(self: Model, name: []const u8) ?*const EnumType {
        for (self.enum_types) |*value| {
            if (std.mem.eql(u8, value.name, name)) return value;
        }
        return null;
    }

    pub fn typeDefinition(self: Model, name: []const u8) ?*const TypeDefinition {
        for (self.type_definitions) |*value| {
            if (std.mem.eql(u8, value.name, name)) return value;
        }
        return null;
    }

    /// The actions bound to `name`, in model order.
    pub fn actionsFor(self: Model, arena: std.mem.Allocator, name: []const u8) ![]const Action {
        var found: std.ArrayList(Action) = .empty;
        for (self.actions) |action| {
            if (std.mem.eql(u8, action.binding, name)) try found.append(arena, action);
        }
        return found.toOwnedSlice(arena);
    }

    /// Total number of declarations, for a one-line summary after a compile.
    pub fn declarationCount(self: Model) usize {
        return self.entity_types.len +
            self.complex_types.len +
            self.enum_types.len +
            self.type_definitions.len +
            self.actions.len;
    }
};

/// Sorts declarations by qualified name. The compiler sorts with this so a
/// model — and the package emitted from it — does not depend on the order
/// documents happened to be read in.
pub fn sortByName(comptime T: type, items: []T) void {
    const order = struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(T, items, {}, order.lessThan);
}

const testing = std.testing;

fn sampleModel() Model {
    return .{
        .package = .{
            .name = "redfish_schema_chassis",
            .version = "0.1.0",
            .display_name = "Redfish chassis schema",
            .profile = "chassis",
            .root = "ServiceRoot.v1_17_0.ServiceRoot",
        },
        .entity_types = &.{
            .{
                .name = "Chassis.v1_25_0.Chassis",
                .base = "Resource.v1_0_0.Resource",
                .key = &.{"Id"},
                .must_have_id = true,
                .must_have_type = true,
                .updatable = true,
                .uris = &.{"/redfish/v1/Chassis/{ChassisId}"},
                .properties = &.{
                    .{
                        .name = "@odata.id",
                        .type = .{ .name = "Edm.String", .kind = .primitive },
                        .nullable = false,
                        .permissions = .read,
                        .required = true,
                    },
                    .{
                        .name = "AssetTag",
                        .type = .{ .name = "Edm.String", .kind = .primitive },
                        .permissions = .read_write,
                        .excerpts = &.{""},
                        .docs = .{ .description = "The user-assigned asset tag." },
                    },
                    .{
                        .name = "IndicatorLED",
                        .type = .{ .name = "Resource.IndicatorLED", .kind = .enumeration },
                        .docs = .{ .deprecated = .{
                            .version = "v1_14_0",
                            .description = "Deprecated in favor of LocationIndicatorActive.",
                        } },
                    },
                },
                .navigation_properties = &.{
                    .{
                        .name = "Drives",
                        .type = .{ .name = "Drive.v1_21_0.Drive", .kind = .entity, .collection = true },
                        .expandable = true,
                    },
                    .{
                        .name = "PowerSubsystem",
                        .type = .{ .name = "PowerSubsystem.PowerSubsystem", .kind = .entity },
                        .excerpt_copy = .{ .key = "Power" },
                    },
                },
            },
        },
        .complex_types = &.{
            .{
                .name = "Resource.Status",
                .permissions = .read,
                .properties = &.{
                    .{
                        .name = "Health",
                        .type = .{ .name = "Resource.Health", .kind = .enumeration },
                        .permissions = .read,
                    },
                },
            },
            .{
                .name = "Resource.Oem",
                .additional_properties = true,
                .dynamic_properties = .{
                    .pattern = "^[A-Za-z0-9_]+$",
                    .type = "Resource.OemObject",
                },
            },
        },
        .enum_types = &.{
            .{
                .name = "Resource.Health",
                .members = &.{
                    .{ .name = "OK", .docs = .{ .description = "Normal." } },
                    .{ .name = "Warning" },
                    .{ .name = "Critical" },
                },
            },
        },
        .type_definitions = &.{
            .{
                .name = "Resource.Id",
                .underlying_type = .{ .name = "Edm.String", .kind = .primitive },
            },
        },
        .actions = &.{
            .{
                .name = "Reset",
                .binding = "Chassis.v1_25_0.Chassis",
                .namespace = "Chassis.v1_25_0",
                .binding_parameter = "Chassis",
                .parameters = &.{
                    .{
                        .name = "ResetType",
                        .type = .{ .name = "Resource.ResetType", .kind = .enumeration },
                        .required = true,
                    },
                },
            },
        },
    };
}

test "a model round-trips through JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const original = sampleModel();
    const json = try original.stringify(arena.allocator());
    const parsed = try Model.parse(arena.allocator(), json);

    // The second pass must produce the same bytes: that is what makes a
    // fixture a contract rather than a snapshot.
    const again = try parsed.stringify(arena.allocator());
    try testing.expectEqualStrings(json, again);

    try testing.expectEqual(format_version, parsed.format);
    try testing.expectEqualStrings("redfish_schema_chassis", parsed.package.name);
    try testing.expectEqualStrings("chassis", parsed.package.profile.?);
    // 1 entity + 2 complex + 1 enum + 1 type definition + 1 action.
    try testing.expectEqual(@as(usize, 6), parsed.declarationCount());
}

test "parsed declarations keep their detail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const json = try sampleModel().stringify(arena.allocator());
    const model = try Model.parse(arena.allocator(), json);

    const chassis = model.entityType("Chassis.v1_25_0.Chassis").?;
    try testing.expectEqualStrings("Resource.v1_0_0.Resource", chassis.base.?);
    try testing.expect(chassis.must_have_id);
    try testing.expectEqualStrings("Id", chassis.key[0]);
    try testing.expectEqualStrings("/redfish/v1/Chassis/{ChassisId}", chassis.uris[0]);

    // A wire name survives verbatim; nothing in the model is cased.
    try testing.expectEqualStrings("@odata.id", chassis.properties[0].name);
    try testing.expectEqual(Permissions.read, chassis.properties[0].permissions.?);
    try testing.expect(!chassis.properties[0].nullable);

    const asset_tag = chassis.properties[1];
    try testing.expectEqualStrings("", asset_tag.excerpts[0]);
    try testing.expectEqualStrings("The user-assigned asset tag.", asset_tag.docs.description.?);

    const led = chassis.properties[2];
    try testing.expectEqualStrings("v1_14_0", led.docs.deprecated.?.version.?);
    try testing.expectEqual(Kind.enumeration, led.type.kind);

    const drives = chassis.navigation_properties[0];
    try testing.expect(drives.type.collection);
    try testing.expect(drives.expandable);
    try testing.expect(drives.excerpt_copy == null);

    const power = chassis.navigation_properties[1];
    try testing.expectEqualStrings("Power", power.excerpt_copy.?.key.?);

    const oem = model.complexType("Resource.Oem").?;
    try testing.expect(oem.additional_properties);
    try testing.expectEqualStrings("Resource.OemObject", oem.dynamic_properties.?.type);

    const health = model.enumType("Resource.Health").?;
    try testing.expectEqual(@as(usize, 3), health.members.len);
    try testing.expectEqualStrings("OK", health.members[0].name);

    const id = model.typeDefinition("Resource.Id").?;
    try testing.expect(id.underlying_type.isPrimitive());

    const actions = try model.actionsFor(arena.allocator(), "Chassis.v1_25_0.Chassis");
    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expectEqualStrings("Reset", actions[0].name);
    try testing.expect(actions[0].parameters[0].required);
}

test "absent optionals are omitted rather than written as null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{ .package = .{ .name = "redfish_schema_empty" } };
    const json = try model.stringify(arena.allocator());

    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "display_name") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"entity_types\": []") != null);
}

test "an unknown field does not stop a model from loading" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try Model.parse(arena.allocator(),
        \\{
        \\  "format": 1,
        \\  "package": { "name": "redfish_schema_future", "unheard_of": 42 },
        \\  "entity_types": [
        \\    { "name": "Chassis.Chassis", "invented_later": true }
        \\  ],
        \\  "invented_later": ["also", "here"]
        \\}
    );

    try testing.expectEqualStrings("redfish_schema_future", model.package.name);
    try testing.expectEqualStrings("0.1.0", model.package.version);
    try testing.expectEqual(@as(usize, 1), model.entity_types.len);
    try testing.expectEqualStrings("Chassis.Chassis", model.entity_types[0].name);
    try testing.expect(!model.entity_types[0].abstract);
    try testing.expectEqual(@as(usize, 0), model.entity_types[0].properties.len);
}

test "enums and permissions are written as names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = .{ .name = "redfish_schema_kinds" },
        .complex_types = &.{.{
            .name = "Test.Complex",
            .permissions = .read_write,
            .properties = &.{.{
                .name = "Value",
                .type = .{ .name = "Edm.Int64", .kind = .primitive },
            }},
        }},
    };

    const json = try model.stringify(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, json, "\"read_write\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"primitive\"") != null);

    const parsed = try Model.parse(arena.allocator(), json);
    try testing.expectEqual(Permissions.read_write, parsed.complex_types[0].permissions.?);
    try testing.expectEqual(Kind.primitive, parsed.complex_types[0].properties[0].type.kind);
}

test "declarations sort by qualified name" {
    var types = [_]EntityType{
        .{ .name = "Chassis.v1_2_0.Chassis" },
        .{ .name = "Chassis.v1_10_0.Chassis" },
        .{ .name = "Bay.Bay" },
    };
    sortByName(EntityType, &types);

    try testing.expectEqualStrings("Bay.Bay", types[0].name);
    // Lexicographic, not numeric: v1_10_0 before v1_2_0. Deterministic is
    // what matters here, not humane.
    try testing.expectEqualStrings("Chassis.v1_10_0.Chassis", types[1].name);
    try testing.expectEqualStrings("Chassis.v1_2_0.Chassis", types[2].name);
}
