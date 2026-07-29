//! Shrinking the compiled model without changing what it describes.
//!
//! Redfish CSDL is written for versioning, not for code generation. Every
//! minor version of a resource is a fresh namespace holding a fresh type that
//! derives from the previous version, so a resource with twenty-five
//! published versions arrives here as twenty-five entity types in a chain,
//! most of them adding nothing. Alongside them sit abstract types with no
//! members at all, declared so that later versions have something to extend.
//!
//! Emitting that verbatim would produce a package that is mostly empty
//! structs and one-field wrappers. These passes fold it back down:
//!
//! 1. A type with no members is replaced by the nearest ancestor that has
//!    some. Nothing can be read out of it that could not be read out of the
//!    ancestor.
//! 2. A type with exactly one child is merged into that child. A base with
//!    several children is worth keeping, because it is a real shared shape;
//!    a base with one is just where half of that child's members were
//!    written down.
//! 3. What survives is hoisted to the shortest namespace where its name is
//!    still unique, which is what turns `Chassis.v1_25_0.Chassis` into
//!    `Chassis.Chassis`.
//!
//! Every pass is a whole-model rewrite: it computes what each name becomes,
//! rebuilds the declarations, and then rewrites every reference in the model
//! through the same map. Passes are ordered so that later ones see the
//! smaller model.

const std = @import("std");

const codemodel = @import("codemodel.zig");
const filter = @import("filter.zig");
const schema_index = @import("schema_index.zig");

const Model = codemodel.Model;
const Namespace = schema_index.Namespace;
const QualifiedName = schema_index.QualifiedName;

pub const Error = std.mem.Allocator.Error;

/// Types that keep their identity however empty they look.
///
/// `Resource.Item` and `Resource.ItemOrCollection` are the roots of the
/// Redfish entity hierarchy and declare nothing themselves. They are the one
/// place where an empty abstract type is worth keeping: everything derives
/// from them, so folding them away would leave the model with no name for
/// "some resource".
pub const default_never_prune = [_][]const u8{ "Resource.Item", "Resource.ItemOrCollection" };

pub const Options = struct {
    /// Entity types that survive every pass. Empty means none are spared —
    /// use `Options.default` for the Redfish set.
    never_prune: filter.TypeFilter = .{ .mode = .restrictive },

    /// The options the Redfish corpus wants.
    pub fn default(arena: std.mem.Allocator) filter.Error!Options {
        return .{
            .never_prune = try .parse(arena, &default_never_prune, .restrictive),
        };
    }
};

/// Applies every optimization, in the order they depend on each other.
pub fn optimize(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var current = model;
    inline for (.{
        removeEmptyComplexTypes,
        removeEmptyEntityTypes,
        mergeComplexTypeInheritance,
        mergeEntityTypeInheritance,
        hoistNamespaces,
    }) |pass| {
        current = try pass(arena, current, options);
    }
    return finish(arena, current);
}

/// What a name became. Absent means the name is unchanged.
const Renames = std.StringHashMapUnmanaged([]const u8);

fn rename(renames: *const Renames, name: []const u8) []const u8 {
    return renames.get(name) orelse name;
}

fn renameOptional(renames: *const Renames, name: ?[]const u8) ?[]const u8 {
    return rename(renames, name orelse return null);
}

fn renameRef(renames: *const Renames, ref: codemodel.TypeRef) codemodel.TypeRef {
    var out = ref;
    out.name = rename(renames, ref.name);
    return out;
}

// -- Rewriting references ---------------------------------------------------

/// Rewrites every name in the model through `renames`.
///
/// This is deliberately indiscriminate: it does not care which kind of
/// declaration a map was built for, because qualified names are unique across
/// kinds. A pass builds one map and this applies it everywhere a name can
/// appear, which is what keeps the passes short enough to read.
fn applyRenames(arena: std.mem.Allocator, model: Model, renames: *const Renames) Error!Model {
    if (renames.count() == 0) return model;

    const entity_types = try arena.dupe(codemodel.EntityType, model.entity_types);
    for (entity_types) |*entity_type| {
        entity_type.name = rename(renames, entity_type.name);
        entity_type.base = renameOptional(renames, entity_type.base);
        entity_type.properties = try renameProperties(arena, entity_type.properties, renames);
        entity_type.navigation_properties =
            try renameNavProperties(arena, entity_type.navigation_properties, renames);
    }

    const complex_types = try arena.dupe(codemodel.ComplexType, model.complex_types);
    for (complex_types) |*complex_type| {
        complex_type.name = rename(renames, complex_type.name);
        complex_type.base = renameOptional(renames, complex_type.base);
        complex_type.properties = try renameProperties(arena, complex_type.properties, renames);
        complex_type.navigation_properties =
            try renameNavProperties(arena, complex_type.navigation_properties, renames);
        if (complex_type.dynamic_properties) |*dynamic| {
            dynamic.type = rename(renames, dynamic.type);
        }
    }

    const enum_types = try arena.dupe(codemodel.EnumType, model.enum_types);
    for (enum_types) |*enum_type| enum_type.name = rename(renames, enum_type.name);

    const type_definitions = try arena.dupe(codemodel.TypeDefinition, model.type_definitions);
    for (type_definitions) |*definition| definition.name = rename(renames, definition.name);

    const actions = try arena.dupe(codemodel.Action, model.actions);
    for (actions) |*action| {
        action.binding = rename(renames, action.binding);
        const parameters = try arena.dupe(codemodel.Parameter, action.parameters);
        for (parameters) |*parameter| parameter.type = renameRef(renames, parameter.type);
        action.parameters = parameters;
        if (action.return_type) |returned| action.return_type = renameRef(renames, returned);
    }

    var out = model;
    out.package.root = renameOptional(renames, model.package.root);
    out.entity_types = entity_types;
    out.complex_types = complex_types;
    out.enum_types = enum_types;
    out.type_definitions = type_definitions;
    out.actions = try dedupeActions(arena, actions);
    return out;
}

fn renameProperties(
    arena: std.mem.Allocator,
    properties: []const codemodel.Property,
    renames: *const Renames,
) Error![]const codemodel.Property {
    const out = try arena.dupe(codemodel.Property, properties);
    for (out) |*property| property.type = renameRef(renames, property.type);
    return out;
}

fn renameNavProperties(
    arena: std.mem.Allocator,
    properties: []const codemodel.NavProperty,
    renames: *const Renames,
) Error![]const codemodel.NavProperty {
    const out = try arena.dupe(codemodel.NavProperty, properties);
    for (out) |*property| property.type = renameRef(renames, property.type);
    return out;
}

/// Two types that merge can carry the same action, so keep the first of each
/// binding-and-name pair.
fn dedupeActions(
    arena: std.mem.Allocator,
    actions: []const codemodel.Action,
) Error![]const codemodel.Action {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);

    var kept: std.ArrayList(codemodel.Action) = .empty;
    for (actions) |action| {
        const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ action.binding, action.name });
        if ((try seen.fetchPut(arena, key, {})) != null) continue;
        try kept.append(arena, action);
    }
    return kept.toOwnedSlice(arena);
}

// -- Removing empty types ---------------------------------------------------

/// A complex type says nothing if it declares no members and admits none.
fn complexIsEmpty(complex_type: codemodel.ComplexType) bool {
    return complex_type.properties.len == 0 and
        complex_type.navigation_properties.len == 0 and
        !complex_type.additional_properties and
        complex_type.dynamic_properties == null;
}

/// An entity type says nothing if it declares no members, no key, no address,
/// and no capability of its own.
fn entityIsEmpty(entity_type: codemodel.EntityType) bool {
    return entity_type.properties.len == 0 and
        entity_type.navigation_properties.len == 0 and
        entity_type.key.len == 0 and
        entity_type.uris.len == 0 and
        !entity_type.insertable and
        !entity_type.updatable and
        !entity_type.deletable and
        entity_type.docs.description == null and
        entity_type.docs.long_description == null;
}

/// Walks up from `name` to the first ancestor that is not empty.
fn firstMeaningfulAncestor(
    comptime T: type,
    comptime isEmpty: fn (T) bool,
    types: *const std.StringHashMapUnmanaged(T),
    start: []const u8,
) ?[]const u8 {
    var name = start;
    while (types.get(name)) |declared| {
        if (!isEmpty(declared)) return name;
        name = declared.base orelse return null;
    }
    return null;
}

fn indexByName(
    arena: std.mem.Allocator,
    comptime T: type,
    declarations: []const T,
) Error!std.StringHashMapUnmanaged(T) {
    var map: std.StringHashMapUnmanaged(T) = .empty;
    try map.ensureTotalCapacity(arena, @intCast(declarations.len));
    for (declarations) |declaration| map.putAssumeCapacity(declaration.name, declaration);
    return map;
}

fn removeEmptyComplexTypes(arena: std.mem.Allocator, model: Model, _: Options) Error!Model {
    var types = try indexByName(arena, codemodel.ComplexType, model.complex_types);
    defer types.deinit(arena);

    var renames: Renames = .empty;
    defer renames.deinit(arena);

    for (model.complex_types) |complex_type| {
        if (!complexIsEmpty(complex_type)) continue;
        const target = firstMeaningfulAncestor(
            codemodel.ComplexType,
            complexIsEmpty,
            &types,
            complex_type.name,
        ) orelse continue;
        try renames.put(arena, complex_type.name, target);
    }
    if (renames.count() == 0) return model;

    var kept: std.ArrayList(codemodel.ComplexType) = .empty;
    for (model.complex_types) |complex_type| {
        if (renames.contains(complex_type.name)) continue;
        try kept.append(arena, complex_type);
    }

    var out = model;
    out.complex_types = try kept.toOwnedSlice(arena);
    return applyRenames(arena, out, &renames);
}

fn removeEmptyEntityTypes(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var types = try indexByName(arena, codemodel.EntityType, model.entity_types);
    defer types.deinit(arena);

    var renames: Renames = .empty;
    defer renames.deinit(arena);

    for (model.entity_types) |entity_type| {
        if (options.never_prune.matches(.parse(entity_type.name))) continue;
        if (!entityIsEmpty(entity_type)) continue;
        const target = firstMeaningfulAncestor(
            codemodel.EntityType,
            entityIsEmpty,
            &types,
            entity_type.name,
        ) orelse continue;
        try renames.put(arena, entity_type.name, target);
    }
    if (renames.count() == 0) return model;

    var kept: std.ArrayList(codemodel.EntityType) = .empty;
    for (model.entity_types) |entity_type| {
        if (renames.contains(entity_type.name)) continue;
        try kept.append(arena, entity_type);
    }

    // A type is going away, but what other passes recorded against it is
    // still true of whatever replaces it. The replacement is never itself
    // removed, so it is always in `kept`.
    for (model.entity_types) |entity_type| {
        const target = renames.get(entity_type.name) orelse continue;
        for (kept.items) |*candidate| {
            if (!std.mem.eql(u8, candidate.name, target)) continue;
            try absorb(arena, candidate, entity_type);
            break;
        }
    }

    var out = model;
    out.entity_types = try kept.toOwnedSlice(arena);
    return applyRenames(arena, out, &renames);
}

fn absorb(
    arena: std.mem.Allocator,
    target: *codemodel.EntityType,
    removed: codemodel.EntityType,
) Error!void {
    target.creatable = target.creatable or removed.creatable;
    target.must_have_id = target.must_have_id or removed.must_have_id;
    target.must_have_type = target.must_have_type or removed.must_have_type;
    target.excerpt_copies = try mergeCopies(arena, target.excerpt_copies, removed.excerpt_copies);
}

fn mergeCopies(
    arena: std.mem.Allocator,
    into: []const codemodel.ExcerptCopy,
    from: []const codemodel.ExcerptCopy,
) Error![]const codemodel.ExcerptCopy {
    if (from.len == 0) return into;
    var merged: std.ArrayList(codemodel.ExcerptCopy) = .empty;
    try merged.appendSlice(arena, into);
    outer: for (from) |copy| {
        for (merged.items) |existing| {
            if (sameCopy(existing, copy)) continue :outer;
        }
        try merged.append(arena, copy);
    }
    return merged.toOwnedSlice(arena);
}

fn sameCopy(left: codemodel.ExcerptCopy, right: codemodel.ExcerptCopy) bool {
    const a = left.key orelse return right.key == null;
    const b = right.key orelse return false;
    return std.mem.eql(u8, a, b);
}

// -- Merging single-child inheritance ---------------------------------------

/// Bases that exactly one type derives from, mapped to that one type.
fn onlyChildren(
    arena: std.mem.Allocator,
    comptime T: type,
    declarations: []const T,
    keep: ?*const filter.TypeFilter,
    comptime hasKey: fn (T) bool,
) Error!Renames {
    const Count = struct { child: []const u8, seen: usize };
    var counts: std.StringHashMapUnmanaged(Count) = .empty;
    defer counts.deinit(arena);

    for (declarations) |declaration| {
        const base = declaration.base orelse continue;
        const entry = try counts.getOrPut(arena, base);
        if (!entry.found_existing) entry.value_ptr.* = .{ .child = declaration.name, .seen = 0 };
        entry.value_ptr.seen += 1;
    }

    var declared = try indexByName(arena, T, declarations);
    defer declared.deinit(arena);

    // A base is foldable when it has one child, is in the model, is not
    // spared, and carries no key of its own — a key names the resource, and
    // the type that owns it has to keep it.
    var foldable: Renames = .empty;
    defer foldable.deinit(arena);
    var counted = counts.iterator();
    while (counted.next()) |entry| {
        if (entry.value_ptr.seen != 1) continue;
        const base = declared.get(entry.key_ptr.*) orelse continue;
        if (hasKey(base)) continue;
        if (keep) |spared| {
            if (spared.matches(.parse(base.name))) continue;
        }
        try foldable.put(arena, base.name, entry.value_ptr.child);
    }

    // Follow each chain to the type it all ends up in.
    var renames: Renames = .empty;
    var chains = foldable.iterator();
    while (chains.next()) |entry| {
        var child = entry.value_ptr.*;
        while (foldable.get(child)) |next| child = next;
        try renames.put(arena, entry.key_ptr.*, child);
    }
    return renames;
}

fn alwaysUnkeyed(_: codemodel.ComplexType) bool {
    return false;
}

fn entityHasKey(entity_type: codemodel.EntityType) bool {
    return entity_type.key.len != 0;
}

/// Appends `source` onto `into`, letting a redeclared name keep its position
/// but take the more derived definition.
fn joinProperties(
    comptime T: type,
    arena: std.mem.Allocator,
    into: *std.ArrayList(T),
    source: []const T,
) Error!void {
    outer: for (source) |property| {
        for (into.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, property.name)) continue;
            existing.* = property;
            continue :outer;
        }
        try into.append(arena, property);
    }
}

fn mergeComplexTypeInheritance(arena: std.mem.Allocator, model: Model, _: Options) Error!Model {
    var renames = try onlyChildren(
        arena,
        codemodel.ComplexType,
        model.complex_types,
        null,
        alwaysUnkeyed,
    );
    defer renames.deinit(arena);
    if (renames.count() == 0) return model;

    var folded = try indexByName(arena, codemodel.ComplexType, model.complex_types);
    defer folded.deinit(arena);

    var kept: std.ArrayList(codemodel.ComplexType) = .empty;
    for (model.complex_types) |complex_type| {
        if (renames.contains(complex_type.name)) continue;

        var merged = complex_type;
        var properties: std.ArrayList(codemodel.Property) = .empty;
        var navigations: std.ArrayList(codemodel.NavProperty) = .empty;

        var ancestors: std.ArrayList(codemodel.ComplexType) = .empty;
        defer ancestors.deinit(arena);
        var base = complex_type.base;
        while (base) |name| {
            if (!renames.contains(name)) break;
            const parent = folded.get(name) orelse break;
            try ancestors.append(arena, parent);
            base = parent.base;
        }

        var index = ancestors.items.len;
        while (index > 0) {
            index -= 1;
            const ancestor = ancestors.items[index];
            try joinProperties(codemodel.Property, arena, &properties, ancestor.properties);
            try joinProperties(
                codemodel.NavProperty,
                arena,
                &navigations,
                ancestor.navigation_properties,
            );
        }
        try joinProperties(codemodel.Property, arena, &properties, complex_type.properties);
        try joinProperties(
            codemodel.NavProperty,
            arena,
            &navigations,
            complex_type.navigation_properties,
        );

        merged.base = base;
        merged.properties = try properties.toOwnedSlice(arena);
        merged.navigation_properties = try navigations.toOwnedSlice(arena);
        try kept.append(arena, merged);
    }

    var out = model;
    out.complex_types = try kept.toOwnedSlice(arena);
    return applyRenames(arena, out, &renames);
}

fn mergeEntityTypeInheritance(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var renames = try onlyChildren(
        arena,
        codemodel.EntityType,
        model.entity_types,
        &options.never_prune,
        entityHasKey,
    );
    defer renames.deinit(arena);
    if (renames.count() == 0) return model;

    var folded = try indexByName(arena, codemodel.EntityType, model.entity_types);
    defer folded.deinit(arena);

    var kept: std.ArrayList(codemodel.EntityType) = .empty;
    for (model.entity_types) |entity_type| {
        if (renames.contains(entity_type.name)) continue;

        var merged = entity_type;
        var properties: std.ArrayList(codemodel.Property) = .empty;
        var navigations: std.ArrayList(codemodel.NavProperty) = .empty;

        var ancestors: std.ArrayList(codemodel.EntityType) = .empty;
        defer ancestors.deinit(arena);
        var base = entity_type.base;
        while (base) |name| {
            if (!renames.contains(name)) break;
            const parent = folded.get(name) orelse break;
            try ancestors.append(arena, parent);
            base = parent.base;
        }

        var index = ancestors.items.len;
        while (index > 0) {
            index -= 1;
            const ancestor = ancestors.items[index];
            try joinProperties(codemodel.Property, arena, &properties, ancestor.properties);
            try joinProperties(
                codemodel.NavProperty,
                arena,
                &navigations,
                ancestor.navigation_properties,
            );
        }
        // Nearest first, so the closest ancestor to say something wins.
        for (ancestors.items) |ancestor| try inherit(arena, &merged, ancestor);
        try joinProperties(codemodel.Property, arena, &properties, entity_type.properties);
        try joinProperties(
            codemodel.NavProperty,
            arena,
            &navigations,
            entity_type.navigation_properties,
        );

        merged.base = base;
        merged.properties = try properties.toOwnedSlice(arena);
        merged.navigation_properties = try navigations.toOwnedSlice(arena);
        try kept.append(arena, merged);
    }

    var out = model;
    out.entity_types = try kept.toOwnedSlice(arena);
    return applyRenames(arena, out, &renames);
}

/// Takes from a folded-away base everything the child did not say for itself.
fn inherit(
    arena: std.mem.Allocator,
    child: *codemodel.EntityType,
    base: codemodel.EntityType,
) Error!void {
    try absorb(arena, child, base);
    child.insertable = child.insertable or base.insertable;
    child.updatable = child.updatable or base.updatable;
    child.deletable = child.deletable or base.deletable;
    if (child.uris.len == 0) child.uris = base.uris;
    if (child.docs.description == null) child.docs.description = base.docs.description;
    if (child.docs.long_description == null) {
        child.docs.long_description = base.docs.long_description;
    }
    if (child.docs.deprecated == null) child.docs.deprecated = base.docs.deprecated;
}

// -- Hoisting out of versioned namespaces -----------------------------------

fn hoistNamespaces(arena: std.mem.Allocator, model: Model, _: Options) Error!Model {
    var current = model;
    current = try hoist(arena, current, codemodel.EnumType, current.enum_types);
    current = try hoist(arena, current, codemodel.TypeDefinition, current.type_definitions);
    current = try hoist(arena, current, codemodel.ComplexType, current.complex_types);
    current = try hoist(arena, current, codemodel.EntityType, current.entity_types);
    return current;
}

fn hoist(
    arena: std.mem.Allocator,
    model: Model,
    comptime T: type,
    declarations: []const T,
) Error!Model {
    // For every simple name, how many declarations of this kind sit at or
    // below each namespace.
    var reach: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(usize)) = .empty;
    defer {
        var counted = reach.valueIterator();
        while (counted.next()) |namespaces| namespaces.deinit(arena);
        reach.deinit(arena);
    }

    for (declarations) |declaration| {
        const qualified: QualifiedName = .parse(declaration.name);
        const namespaces = try reach.getOrPut(arena, qualified.name());
        if (!namespaces.found_existing) namespaces.value_ptr.* = .empty;

        var namespace: ?Namespace = qualified.namespace();
        while (namespace) |scope| : (namespace = scope.parent()) {
            const seen = try namespaces.value_ptr.getOrPut(arena, scope.text);
            if (!seen.found_existing) seen.value_ptr.* = 0;
            seen.value_ptr.* += 1;
        }
    }

    var renames: Renames = .empty;
    defer renames.deinit(arena);

    for (declarations) |declaration| {
        const qualified: QualifiedName = .parse(declaration.name);
        const namespaces = reach.get(qualified.name()) orelse continue;

        // Climb while the name stays the only one of its kind in scope.
        var scope = qualified.namespace();
        var best: ?Namespace = null;
        while (scope.parent()) |parent| {
            if ((namespaces.get(parent.text) orelse 0) != 1) break;
            best = parent;
            scope = parent;
        }

        const target = best orelse continue;
        try renames.put(arena, declaration.name, try std.fmt.allocPrint(
            arena,
            "{s}.{s}",
            .{ target.text, qualified.name() },
        ));
    }

    return applyRenames(arena, model, &renames);
}

// -- Finishing --------------------------------------------------------------

fn finish(arena: std.mem.Allocator, model: Model) Error!Model {
    var out = model;
    const entity_types = try arena.dupe(codemodel.EntityType, model.entity_types);
    const complex_types = try arena.dupe(codemodel.ComplexType, model.complex_types);
    const enum_types = try arena.dupe(codemodel.EnumType, model.enum_types);
    const type_definitions = try arena.dupe(codemodel.TypeDefinition, model.type_definitions);
    const actions = try arena.dupe(codemodel.Action, model.actions);

    codemodel.sortByName(codemodel.EntityType, entity_types);
    codemodel.sortByName(codemodel.ComplexType, complex_types);
    codemodel.sortByName(codemodel.EnumType, enum_types);
    codemodel.sortByName(codemodel.TypeDefinition, type_definitions);
    codemodel.sortActions(actions);

    out.entity_types = entity_types;
    out.complex_types = complex_types;
    out.enum_types = enum_types;
    out.type_definitions = type_definitions;
    out.actions = actions;
    return out;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const package: codemodel.Package = .{ .name = "redfish_schema_test" };

fn run(arena: std.mem.Allocator, model: Model) !Model {
    return optimize(arena, model, try .default(arena));
}

fn nameAt(model: Model, comptime field: []const u8, index: usize) []const u8 {
    return @field(model, field)[index].name;
}

test "an empty complex type gives way to the ancestor that has members" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{.{
            .name = "Root.Root",
            .key = &.{"Id"},
            .properties = &.{.{ .name = "Where", .type = .{ .name = "Root.Empty", .kind = .complex } }},
        }},
        .complex_types = &.{
            .{ .name = "Root.Real", .properties = &.{.{ .name = "City", .type = .{ .name = "Edm.String" } }} },
            .{ .name = "Root.Empty", .base = "Root.Real" },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.complex_types.len);
    try testing.expectEqualStrings("Root.Real", nameAt(out, "complex_types", 0));
    try testing.expectEqualStrings("Root.Real", out.entity_types[0].properties[0].type.name);
}

test "an empty complex type with no ancestor to fall back on is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .complex_types = &.{.{ .name = "Root.Empty" }},
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.complex_types.len);
}

test "a type that admits properties the schema does not name is not empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .complex_types = &.{
            .{ .name = "Root.Real", .properties = &.{.{ .name = "City", .type = .{ .name = "Edm.String" } }} },
            .{ .name = "Root.Oem", .base = "Root.Real", .additional_properties = true },
            .{ .name = "Root.Other", .base = "Root.Real", .properties = &.{.{ .name = "Note", .type = .{ .name = "Edm.String" } }} },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 3), out.complex_types.len);
    try testing.expectEqualStrings("Root.Oem", nameAt(out, "complex_types", 0));
}

test "an empty entity type gives way, carrying what was recorded against it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Root.Real",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
                .excerpt_copies = &.{.{ .key = "Status" }},
            },
            .{ .name = "Root.Empty", .base = "Root.Real", .creatable = true, .excerpt_copies = &.{.{}} },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.entity_types.len);

    const kept = out.entity_types[0];
    try testing.expectEqualStrings("Root.Real", kept.name);
    try testing.expect(kept.creatable);
    try testing.expectEqual(@as(usize, 2), kept.excerpt_copies.len);
}

test "the roots of the hierarchy are spared however empty they are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Resource.Resource",
                .base = "Resource.Item",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
            },
            .{ .name = "Resource.Item", .abstract = true },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 2), out.entity_types.len);
}

test "a version chain collapses into its newest version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.v1_0_0.Chassis",
                .base = "Resource.Resource",
                .properties = &.{.{ .name = "Manufacturer", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Chassis.v1_1_0.Chassis",
                .base = "Chassis.v1_0_0.Chassis",
                .properties = &.{.{ .name = "Model", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Chassis.v1_2_0.Chassis",
                .base = "Chassis.v1_1_0.Chassis",
                .properties = &.{.{ .name = "SKU", .type = .{ .name = "Edm.String" } }},
                .uris = &.{"/redfish/v1/Chassis/{ChassisId}"},
            },
            .{
                .name = "Resource.Resource",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
            },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 2), out.entity_types.len);

    const chassis = out.entity_types[0];
    // Hoisted out of the version namespace once nothing else claims the name.
    try testing.expectEqualStrings("Chassis.Chassis", chassis.name);
    try testing.expectEqualStrings("Resource.Resource", chassis.base.?);

    // Base first, in declaration order, ending with the newest version's own.
    try testing.expectEqual(@as(usize, 3), chassis.properties.len);
    try testing.expectEqualStrings("Manufacturer", chassis.properties[0].name);
    try testing.expectEqualStrings("Model", chassis.properties[1].name);
    try testing.expectEqualStrings("SKU", chassis.properties[2].name);
}

test "a base several types derive from is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .complex_types = &.{
            .{ .name = "Root.Base", .properties = &.{.{ .name = "Kind", .type = .{ .name = "Edm.String" } }} },
            .{ .name = "Root.Left", .base = "Root.Base", .properties = &.{.{ .name = "L", .type = .{ .name = "Edm.String" } }} },
            .{ .name = "Root.Right", .base = "Root.Base", .properties = &.{.{ .name = "R", .type = .{ .name = "Edm.String" } }} },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 3), out.complex_types.len);
    try testing.expectEqualStrings("Root.Base", out.complex_types[0].name);
    try testing.expectEqual(@as(usize, 1), out.complex_types[0].properties.len);
}

test "a base that names the resource keeps its key and its identity" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Resource.Resource",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Chassis.v1_0_0.Chassis",
                .base = "Resource.Resource",
                .properties = &.{.{ .name = "Model", .type = .{ .name = "Edm.String" } }},
            },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 2), out.entity_types.len);
    try testing.expectEqualStrings("Chassis.Chassis", nameAt(out, "entity_types", 0));
    try testing.expectEqualStrings("Resource.Resource", nameAt(out, "entity_types", 1));
}

test "a redeclared property keeps its place and takes the newer definition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Root.v1_0_0.Location",
                .properties = &.{
                    .{ .name = "City", .type = .{ .name = "Edm.String" } },
                    .{ .name = "Postcode", .type = .{ .name = "Edm.String" } },
                },
            },
            .{
                .name = "Root.v1_1_0.Location",
                .base = "Root.v1_0_0.Location",
                .properties = &.{.{ .name = "City", .type = .{ .name = "Edm.String" }, .required = true }},
            },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.complex_types.len);

    const merged = out.complex_types[0];
    try testing.expectEqual(@as(usize, 2), merged.properties.len);
    try testing.expectEqualStrings("City", merged.properties[0].name);
    try testing.expect(merged.properties[0].required);
    try testing.expectEqualStrings("Postcode", merged.properties[1].name);
}

test "a name two namespaces claim stays where it was written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .enum_types = &.{
            .{ .name = "Chassis.v1_0_0.ChassisType", .members = &.{.{ .name = "Rack" }} },
            .{ .name = "Chassis.ChassisType", .members = &.{.{ .name = "Blade" }} },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 2), out.enum_types.len);
    try testing.expectEqualStrings("Chassis.ChassisType", nameAt(out, "enum_types", 0));
    try testing.expectEqualStrings("Chassis.v1_0_0.ChassisType", nameAt(out, "enum_types", 1));
}

test "hoisting rewrites every reference to the name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Root.Root",
                .key = &.{"Id"},
                .properties = &.{
                    .{ .name = "Kind", .type = .{ .name = "Chassis.v1_0_0.ChassisType", .kind = .enumeration } },
                },
                .navigation_properties = &.{
                    .{ .name = "Links", .type = .{ .name = "Chassis.v1_0_0.Chassis", .kind = .entity } },
                },
            },
            .{
                .name = "Chassis.v1_0_0.Chassis",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
            },
        },
        .enum_types = &.{.{ .name = "Chassis.v1_0_0.ChassisType", .members = &.{.{ .name = "Rack" }} }},
        .actions = &.{.{
            .name = "Reset",
            .binding = "Chassis.v1_0_0.Chassis",
            .namespace = "Chassis.v1_0_0",
            .parameters = &.{.{ .name = "ResetType", .type = .{ .name = "Chassis.v1_0_0.ChassisType" } }},
        }},
    };

    const out = try run(arena.allocator(), model);

    const root = out.entity_types[1];
    try testing.expectEqualStrings("Root.Root", root.name);
    try testing.expectEqualStrings("Chassis.ChassisType", root.properties[0].type.name);
    try testing.expectEqualStrings("Chassis.Chassis", root.navigation_properties[0].type.name);
    try testing.expectEqualStrings("Chassis.ChassisType", nameAt(out, "enum_types", 0));
    try testing.expectEqualStrings("Chassis.Chassis", out.actions[0].binding);
    try testing.expectEqualStrings("Chassis.ChassisType", out.actions[0].parameters[0].type.name);
}

test "an action that survives on both sides of a merge is kept once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.v1_0_0.Chassis",
                .properties = &.{.{ .name = "Model", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Chassis.v1_1_0.Chassis",
                .base = "Chassis.v1_0_0.Chassis",
                .properties = &.{.{ .name = "SKU", .type = .{ .name = "Edm.String" } }},
            },
        },
        .actions = &.{
            .{ .name = "Reset", .binding = "Chassis.v1_0_0.Chassis", .namespace = "Chassis.v1_0_0" },
            .{ .name = "Reset", .binding = "Chassis.v1_1_0.Chassis", .namespace = "Chassis.v1_1_0" },
        },
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.actions.len);
    try testing.expectEqualStrings("Chassis.Chassis", out.actions[0].binding);
}

test "a model with nothing to fold comes out unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{.{
            .name = "Root.Root",
            .key = &.{"Id"},
            .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
        }},
    };

    const out = try run(arena.allocator(), model);
    try testing.expectEqual(@as(usize, 1), out.entity_types.len);
    try testing.expectEqualStrings("Root.Root", nameAt(out, "entity_types", 0));
}

test "optimizing twice changes nothing the first pass did not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.v1_0_0.Chassis",
                .base = "Resource.Resource",
                .properties = &.{.{ .name = "Model", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Chassis.v1_1_0.Chassis",
                .base = "Chassis.v1_0_0.Chassis",
                .properties = &.{.{ .name = "SKU", .type = .{ .name = "Edm.String" } }},
            },
            .{
                .name = "Resource.Resource",
                .key = &.{"Id"},
                .properties = &.{.{ .name = "Id", .type = .{ .name = "Edm.String" } }},
            },
        },
        .complex_types = &.{
            .{ .name = "Root.Empty" },
            .{ .name = "Root.Location", .properties = &.{.{ .name = "City", .type = .{ .name = "Edm.String" } }} },
        },
    };

    const once = try run(arena.allocator(), model);
    const twice = try run(arena.allocator(), once);

    const first = try once.stringify(arena.allocator());
    const second = try twice.stringify(arena.allocator());
    try testing.expectEqualStrings(first, second);
}
