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

    /// Names another package already provides, which must come out of the
    /// optimizer exactly as they went in.
    ///
    /// A vendor package is compiled against the standard corpus but emits
    /// only the vendor's own types, referring to the rest through an import.
    /// That only works if both packages agree on what a type is called, and
    /// left alone they would not: every pass here decides a type's fate from
    /// what else is in the model, and a vendor model holds a fraction of the
    /// corpus. `PowerSupply` is the case that shows it — in the standard
    /// model it has several children and survives; in LiteOn's it has exactly
    /// one, so `mergeEntityTypeInheritance` folds it into
    /// `LiteonPowerSupply` and the name disappears.
    ///
    /// Freezing is not a hint. A frozen type is never removed, never merged
    /// in either direction, and never hoisted, so its name is whatever the
    /// caller renamed it to before the first pass ran.
    frozen: ?*const Frozen = null,

    /// Where to record what every name became, composed across passes and
    /// keyed by the name the model came in with. Null records nothing.
    ///
    /// This is how the standard run tells a vendor run what to freeze: the
    /// vendor model arrives with CSDL names, and the trace is the only thing
    /// that knows `PowerSupply.v1_6_0.PowerSupply` ended up as
    /// `PowerSupply.PowerSupply`.
    trace: ?*Renames = null,

    /// The options the Redfish corpus wants.
    pub fn default(arena: std.mem.Allocator) filter.Error!Options {
        return .{
            .never_prune = try .parse(arena, &default_never_prune, .restrictive),
        };
    }

    fn isFrozen(self: Options, name: []const u8) bool {
        const frozen = self.frozen orelse return false;
        return frozen.contains(name);
    }
};

/// Names provided by another package.
pub const Frozen = std.StringHashMapUnmanaged(void);

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
pub const Renames = std.StringHashMapUnmanaged([]const u8);

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

/// Rewrites a model's names through a trace another run produced.
///
/// A vendor model arrives holding CSDL names for types the standard package
/// has already renamed. Applying the standard run's trace first is what lets
/// `Options.frozen` be a plain set of final names rather than a second map.
///
/// The trace is not injective: the standard run folded whole version chains
/// into one name, so several declarations here land on it. They have to be
/// coalesced, and not only for tidiness -- a chain's own links become each
/// other, so the most derived of them ends up naming itself as its base, and
/// every walk up a base chain in this file would run forever.
pub fn adopt(arena: std.mem.Allocator, model: Model, renames: *const Renames) Error!Model {
    return coalesce(arena, try applyRenames(arena, model, renames, .{}));
}

/// Folds declarations that now share a name into one, the way the run that
/// produced the trace folded them: properties joined, most derived last.
fn coalesce(arena: std.mem.Allocator, model: Model) Error!Model {
    var out = model;
    out.entity_types = try coalesceKind(codemodel.EntityType, arena, model.entity_types);
    out.complex_types = try coalesceKind(codemodel.ComplexType, arena, model.complex_types);
    out.enum_types = try coalesceKind(codemodel.EnumType, arena, model.enum_types);
    out.type_definitions =
        try coalesceKind(codemodel.TypeDefinition, arena, model.type_definitions);
    return out;
}

fn coalesceKind(
    comptime T: type,
    arena: std.mem.Allocator,
    declarations: []const T,
) Error![]const T {
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    defer at.deinit(arena);

    var kept: std.ArrayList(T) = .empty;
    for (declarations) |declaration| {
        const entry = try at.getOrPut(arena, declaration.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = kept.items.len;
            try kept.append(arena, declaration);
            continue;
        }
        if (@hasField(T, "properties")) try join(T, arena, &kept.items[entry.value_ptr.*], declaration);
        if (T == codemodel.EntityType) try absorb(arena, &kept.items[entry.value_ptr.*], declaration);
    }

    // A chain collapsed onto one name leaves that name deriving from itself.
    for (kept.items) |*declaration| {
        if (!@hasField(T, "base")) continue;
        const base = declaration.base orelse continue;
        if (std.mem.eql(u8, base, declaration.name)) declaration.base = null;
    }
    return kept.toOwnedSlice(arena);
}

fn join(comptime T: type, arena: std.mem.Allocator, target: *T, source: T) Error!void {
    var properties: std.ArrayList(codemodel.Property) = .empty;
    try joinProperties(codemodel.Property, arena, &properties, target.properties);
    try joinProperties(codemodel.Property, arena, &properties, source.properties);
    target.properties = try properties.toOwnedSlice(arena);

    var navigations: std.ArrayList(codemodel.NavProperty) = .empty;
    try joinProperties(codemodel.NavProperty, arena, &navigations, target.navigation_properties);
    try joinProperties(codemodel.NavProperty, arena, &navigations, source.navigation_properties);
    target.navigation_properties = try navigations.toOwnedSlice(arena);
}

// -- Rewriting references ---------------------------------------------------

/// Composes one pass's renames into the running trace.
///
/// The trace is keyed by the name the model arrived with, so an entry already
/// pointing at a name this pass moves has to follow it. Names this pass
/// touches that the trace has never seen start their own entry, which is the
/// case for everything on the first pass.
fn record(arena: std.mem.Allocator, renames: *const Renames, options: Options) Error!void {
    const trace = options.trace orelse return;

    var seen = trace.iterator();
    while (seen.next()) |entry| {
        if (renames.get(entry.value_ptr.*)) |moved| entry.value_ptr.* = moved;
    }

    var moved = renames.iterator();
    while (moved.next()) |entry| {
        const result = try trace.getOrPut(arena, entry.key_ptr.*);
        if (!result.found_existing) result.value_ptr.* = entry.value_ptr.*;
    }
}

/// Rewrites every name in the model through `renames`.
///
/// This is deliberately indiscriminate: it does not care which kind of
/// declaration a map was built for, because qualified names are unique across
/// kinds. A pass builds one map and this applies it everywhere a name can
/// appear, which is what keeps the passes short enough to read.
///
/// Every rename in the pipeline comes through here, so this is also where
/// `options.trace` is kept up to date.
fn applyRenames(
    arena: std.mem.Allocator,
    model: Model,
    renames: *const Renames,
    options: Options,
) Error!Model {
    if (renames.count() == 0) return model;
    try record(arena, renames, options);

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

fn removeEmptyComplexTypes(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var types = try indexByName(arena, codemodel.ComplexType, model.complex_types);
    defer types.deinit(arena);

    var renames: Renames = .empty;
    defer renames.deinit(arena);

    for (model.complex_types) |complex_type| {
        if (options.isFrozen(complex_type.name)) continue;
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
    return applyRenames(arena, out, &renames, options);
}

fn removeEmptyEntityTypes(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var types = try indexByName(arena, codemodel.EntityType, model.entity_types);
    defer types.deinit(arena);

    var renames: Renames = .empty;
    defer renames.deinit(arena);

    for (model.entity_types) |entity_type| {
        if (options.isFrozen(entity_type.name)) continue;
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
    return applyRenames(arena, out, &renames, options);
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
    options: Options,
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
        if (options.isFrozen(base.name)) continue;
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

fn mergeComplexTypeInheritance(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var renames = try onlyChildren(
        arena,
        codemodel.ComplexType,
        model.complex_types,
        null,
        alwaysUnkeyed,
        options,
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
    return applyRenames(arena, out, &renames, options);
}

fn mergeEntityTypeInheritance(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var renames = try onlyChildren(
        arena,
        codemodel.EntityType,
        model.entity_types,
        &options.never_prune,
        entityHasKey,
        options,
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
    return applyRenames(arena, out, &renames, options);
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

fn hoistNamespaces(arena: std.mem.Allocator, model: Model, options: Options) Error!Model {
    var current = model;
    current = try hoist(arena, current, codemodel.EnumType, current.enum_types, options);
    current = try hoist(arena, current, codemodel.TypeDefinition, current.type_definitions, options);
    current = try hoist(arena, current, codemodel.ComplexType, current.complex_types, options);
    current = try hoist(arena, current, codemodel.EntityType, current.entity_types, options);
    return current;
}

fn hoist(
    arena: std.mem.Allocator,
    model: Model,
    comptime T: type,
    declarations: []const T,
    options: Options,
) Error!Model {
    // For every simple name, how many declarations of this kind sit at or
    // below each namespace. Frozen names are counted but never moved, so a
    // local type cannot climb into a namespace one of them already holds.
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
        if (options.isFrozen(declaration.name)) continue;
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

    return applyRenames(arena, model, &renames, options);
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

// -- Agreeing with another package ----------------------------------------

/// The model a standard corpus would compile to: a version chain over a
/// shared base, which the passes fold to `Chassis.Chassis` and
/// `Resource.Resource`.
const standard: Model = .{
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
};

test "a trace records where every name a pass moved ended up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var trace: Renames = .empty;
    const out = try optimize(arena.allocator(), standard, options: {
        var options: Options = try .default(arena.allocator());
        options.trace = &trace;
        break :options options;
    });

    // Both versions folded onto the one name the package ends up exporting.
    try testing.expectEqualStrings("Chassis.Chassis", trace.get("Chassis.v1_0_0.Chassis").?);
    try testing.expectEqualStrings("Chassis.Chassis", trace.get("Chassis.v1_1_0.Chassis").?);

    // And the trace agrees with what the model actually holds.
    for (out.entity_types) |entity| {
        if (trace.get("Chassis.v1_1_0.Chassis")) |final| {
            if (std.mem.eql(u8, entity.name, final)) break;
        }
    } else return error.TraceDisagreesWithModel;
}

test "a vendor model adopts the names the base package settled on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var trace: Renames = .empty;
    _ = try optimize(arena.allocator(), standard, options: {
        var options: Options = try .default(arena.allocator());
        options.trace = &trace;
        break :options options;
    });

    // The same corpus, plus one vendor type extending the newest version.
    var types: std.ArrayList(codemodel.EntityType) = .empty;
    try types.appendSlice(arena.allocator(), standard.entity_types);
    try types.append(arena.allocator(), .{
        .name = "AcmeChassis.v1_0_0.AcmeChassis",
        .base = "Chassis.v1_1_0.Chassis",
        .properties = &.{.{ .name = "AcmeTag", .type = .{ .name = "Edm.String" } }},
    });

    const vendor: Model = .{ .package = package, .entity_types = types.items };
    const adopted = try adopt(arena.allocator(), vendor, &trace);

    // Three declarations became two: the version chain the base package
    // folded is one type here as well, and it is the only one left holding
    // both versions' properties.
    var chassis: ?codemodel.EntityType = null;
    for (adopted.entity_types) |entity| {
        if (std.mem.eql(u8, entity.name, "Chassis.Chassis")) {
            try testing.expect(chassis == null);
            chassis = entity;
        }
    }
    try testing.expect(chassis != null);
    try testing.expectEqual(@as(usize, 2), chassis.?.properties.len);

    // A type cannot be its own base, however the fold landed.
    for (adopted.entity_types) |entity| {
        if (entity.base) |base| try testing.expect(!std.mem.eql(u8, base, entity.name));
    }
}

test "a frozen name is left where the base package put it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var frozen: Frozen = .empty;
    try frozen.put(arena.allocator(), "Chassis.v1_0_0.Chassis", {});

    // `Chassis.v1_0_0.Chassis` has exactly one child, so the merge pass would
    // fold it away and hoisting would shorten what was left to
    // `Chassis.Chassis`. Frozen, it survives under the name it was given:
    // the base package exports it that way and this package refers to it.
    const out = try optimize(arena.allocator(), standard, options: {
        var options: Options = try .default(arena.allocator());
        options.frozen = &frozen;
        break :options options;
    });

    var kept = false;
    for (out.entity_types) |entity| {
        if (std.mem.eql(u8, entity.name, "Chassis.v1_0_0.Chassis")) kept = true;
    }
    try testing.expect(kept);
}
