// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Choosing what to generate, and turning it into the code model.
//!
//! The Redfish corpus is far larger than any one service implements, and
//! nothing in it says where to start. A profile does: it names the service
//! singletons it cares about, and the compiler reaches everything else by
//! following properties and links from there. What it cannot reach is not
//! generated, which is the difference between a package a BMC client can
//! compile and one it cannot.
//!
//! Reachability alone is not enough, because `ServiceRoot` links to every
//! service there is. A second filter decides which links are worth
//! following: a link the profile did not ask for is still emitted, but only
//! as a bare `@odata.id`, so the shape of the resource stays honest without
//! dragging in the schema behind it.
//!
//! Everything else here is bookkeeping that falls out of those two rules:
//! versioned types resolve to their newest version, a type already being
//! compiled is not compiled again, and the well-known types the protocol
//! itself refers to are compiled whether or not anything links to them.

const std = @import("std");

const annotations = @import("annotations.zig");
const codemodel = @import("codemodel.zig");
const csdl = @import("csdl.zig");
const filter = @import("filter.zig");
const schema_index = @import("schema_index.zig");

const Namespace = schema_index.Namespace;
const QualifiedName = schema_index.QualifiedName;
const SchemaIndex = schema_index.SchemaIndex;

pub const Error = error{
    /// A qualified name referred to a namespace no document declares.
    SchemaNotFound,
    /// A qualified name referred to a type its namespace does not declare.
    TypeNotFound,
    /// A name used where an entity type is required named something else.
    NotAnEntityType,
    /// A `TypeDefinition` whose underlying type is not an EDM primitive.
    TypeDefinitionOfNonPrimitive,
    /// An action that is not bound to a type. Redfish has no unbound
    /// actions: there would be no resource to invoke them on.
    UnboundAction,
    /// A bound action with no binding parameter.
    ActionWithoutBinding,
} || std.mem.Allocator.Error || schema_index.Error;

/// What to compile, and how much of the corpus to pull in with it.
pub const Options = struct {
    /// Package identity, copied into the model unchanged.
    package: codemodel.Package,

    /// Names of the entity-container singletons that seed the root set,
    /// usually just the service root.
    singletons: []const []const u8 = &.{},

    /// Types the profile names directly, in addition to what the singletons
    /// reach. Restrictive: naming nothing roots nothing.
    roots: filter.TypeFilter = .{ .mode = .restrictive },

    /// Which link targets are compiled and expandable. Permissive: a profile
    /// that says nothing follows every link, which is what makes the
    /// unfiltered compile useful for exploring a new schema.
    navigations: filter.TypeFilter = .{ .mode = .permissive },

    /// Collections the service keeps at a fixed length, so a null entry is
    /// meaningful. Nothing in the schema says which those are.
    rigid_arrays: filter.PropertyFilter = .{},

    /// Root every entity and complex type, ignoring `singletons` and
    /// `roots`. Compiles the whole corpus.
    everything: bool = false,

    /// Only documents before this index may contribute roots. An OEM profile
    /// lists its own documents first and the standard schemas after, so the
    /// standard ones resolve references without rooting anything themselves.
    root_documents: ?usize = null,
};

/// Compiles the indexed documents into a model.
///
/// Everything in the result is allocated from `arena` or borrowed from the
/// documents the index was built over, which must outlive it.
pub fn compile(
    arena: std.mem.Allocator,
    index: *const SchemaIndex,
    options: Options,
) Error!codemodel.Model {
    var compiler: Compiler = .{ .arena = arena, .index = index, .options = options };
    return compiler.run();
}

const Compiler = struct {
    arena: std.mem.Allocator,
    index: *const SchemaIndex,
    options: Options,

    entity_types: std.StringArrayHashMapUnmanaged(codemodel.EntityType) = .empty,
    complex_types: std.StringArrayHashMapUnmanaged(codemodel.ComplexType) = .empty,
    enum_types: std.StringArrayHashMapUnmanaged(codemodel.EnumType) = .empty,
    type_definitions: std.StringArrayHashMapUnmanaged(codemodel.TypeDefinition) = .empty,
    actions: std.ArrayList(codemodel.Action) = .empty,

    /// Types whose compilation has started but not finished. A link back to
    /// an ancestor is normal in Redfish -- a chassis links to the systems it
    /// contains, which link back to the chassis -- and would otherwise
    /// recurse forever.
    in_progress: std.StringArrayHashMapUnmanaged(void) = .empty,

    /// The entity types the profile asked for. A link to one of these is
    /// expandable no matter what the navigation filter says.
    root_entities: std.StringArrayHashMapUnmanaged(void) = .empty,
    root_complex: std.ArrayList(QualifiedName) = .empty,

    /// Excerpt views each entity type is copied into, gathered from the
    /// links that copy it.
    excerpt_copies: std.StringArrayHashMapUnmanaged(std.ArrayList(codemodel.ExcerptCopy)) = .empty,

    /// Types that can be created, because an insertable collection has them
    /// as members.
    creatable: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn run(self: *Compiler) Error!codemodel.Model {
        try self.collectRoots();

        for (self.root_entities.keys()) |text| try self.ensureEntityType(.parse(text));
        for (self.root_complex.items) |name| _ = try self.ensureType(name);

        // The protocol refers to these by name, so they are compiled whether
        // or not the profile's surface reaches them. A corpus that does not
        // define them is a partial one, not a broken one.
        if (self.index.settingsType()) |name| _ = try self.ensureType(name);
        if (self.index.preferredApplyTimeType()) |name| _ = try self.ensureType(name);

        const resource = self.index.resourceType();
        if (resource) |name| try self.ensureEntityType(name);
        const collection = self.index.resourceCollectionType();
        if (collection) |name| try self.ensureEntityType(name);

        try self.compileActions();

        // Only these two carry `@odata.type` on the wire; every other
        // resource inherits the field from one of them.
        if (resource) |name| self.markODataType(name);
        if (collection) |name| self.markODataType(name);

        try self.applyExcerptCopies();
        self.applyCreatable();

        return self.finish();
    }

    // -- Root set -----------------------------------------------------------

    fn collectRoots(self: *Compiler) Error!void {
        const limit = self.options.root_documents orelse std.math.maxInt(usize);

        for (self.index.entries) |entry| {
            if (entry.document >= limit) continue;
            const schema = entry.schema;

            if (!self.options.everything) {
                for (schema.containers) |container| {
                    for (container.singletons) |singleton| {
                        if (!self.isSelected(singleton.name)) continue;
                        const declared = try self.resolveIn(entry.document, singleton.type);
                        try self.addRootEntity(self.index.mostDerived(declared));
                    }
                }
            }

            for (schema.entity_types) |entity_type| {
                const name = try self.qualify(entry.namespace, entity_type.name);
                if (self.options.everything or self.options.roots.matches(name)) {
                    try self.addRootEntity(name);
                }
            }

            for (schema.complex_types) |complex_type| {
                const name = try self.qualify(entry.namespace, complex_type.name);
                if (self.options.everything or self.options.roots.matches(name)) {
                    try self.root_complex.append(self.arena, name);
                }
            }
        }
    }

    fn isSelected(self: *const Compiler, name: []const u8) bool {
        for (self.options.singletons) |selected| {
            if (std.mem.eql(u8, selected, name)) return true;
        }
        return false;
    }

    fn addRootEntity(self: *Compiler, name: QualifiedName) Error!void {
        try self.root_entities.put(self.arena, name.text, {});
    }

    // -- Types --------------------------------------------------------------

    /// Compiles whatever `name` refers to, and reports which of the four
    /// kinds it turned out to be.
    fn ensureType(self: *Compiler, name: QualifiedName) Error!codemodel.Kind {
        if (isPrimitive(name)) return .primitive;
        if (self.complex_types.contains(name.text) or
            self.in_progress.contains(name.text)) return .complex;
        if (self.enum_types.contains(name.text)) return .enumeration;
        if (self.type_definitions.contains(name.text)) return .type_definition;
        if (self.entity_types.contains(name.text)) return .entity;

        switch (self.index.find(name) orelse return error.TypeNotFound) {
            .complex_type => |source| {
                try self.compileComplexType(name, source);
                return .complex;
            },
            .enum_type => |source| {
                try self.compileEnumType(name, source);
                return .enumeration;
            },
            .type_definition => |source| {
                try self.compileTypeDefinition(name, source);
                return .type_definition;
            },
            .entity_type => |source| {
                try self.compileEntityType(name, source);
                return .entity;
            },
        }
    }

    fn ensureEntityType(self: *Compiler, name: QualifiedName) Error!void {
        if (self.entity_types.contains(name.text) or
            self.in_progress.contains(name.text)) return;
        const source = self.index.entityType(name) orelse
            return if (self.index.find(name) == null) error.TypeNotFound else error.NotAnEntityType;
        try self.compileEntityType(name, source);
    }

    fn compileEntityType(
        self: *Compiler,
        name: QualifiedName,
        source: *const csdl.EntityType,
    ) Error!void {
        try self.in_progress.put(self.arena, name.text, {});
        const document = try self.documentOf(name.namespace());

        var base: ?[]const u8 = null;
        if (source.base_type) |reference| {
            const resolved = try self.resolveIn(document, reference);
            try self.ensureEntityType(resolved);
            base = resolved.text;
        }

        const compiled: codemodel.EntityType = .{
            .name = name.text,
            .base = base,
            .abstract = source.abstract,
            .key = source.key,
            .properties = try self.compileProperties(name, document, source.properties),
            .navigation_properties = try self.compileNavProperties(
                document,
                source.navigation_properties,
            ),
            .uris = try annotations.uris(self.arena, source.annotations),
            .must_have_id = true,
            .insertable = annotations.insertable(source.annotations) orelse false,
            .updatable = annotations.updatable(source.annotations) orelse false,
            .deletable = annotations.deletable(source.annotations) orelse false,
            .docs = annotations.docs(source.annotations),
        };

        _ = self.in_progress.swapRemove(name.text);
        try self.entity_types.put(self.arena, name.text, compiled);
        try self.noteInsertableMembers(compiled);
    }

    fn compileComplexType(
        self: *Compiler,
        name: QualifiedName,
        source: *const csdl.ComplexType,
    ) Error!void {
        try self.in_progress.put(self.arena, name.text, {});
        const document = try self.documentOf(name.namespace());

        var base: ?[]const u8 = null;
        if (source.base_type) |reference| {
            const resolved = try self.resolveIn(document, reference);
            _ = try self.ensureType(resolved);
            base = resolved.text;
        }

        var compiled: codemodel.ComplexType = .{
            .name = name.text,
            .base = base,
            .abstract = source.abstract,
            .properties = try self.compileProperties(name, document, source.properties),
            .navigation_properties = try self.compileNavProperties(
                document,
                source.navigation_properties,
            ),
            .additional_properties = annotations.additionalProperties(source.annotations) orelse false,
            .dynamic_properties = annotations.dynamicProperties(source.annotations),
            .permissions = annotations.permissions(source.annotations),
            .docs = annotations.docs(source.annotations),
        };
        compiled.permissions = self.inferPermissions(compiled);

        _ = self.in_progress.swapRemove(name.text);
        try self.complex_types.put(self.arena, name.text, compiled);
    }

    fn compileEnumType(
        self: *Compiler,
        name: QualifiedName,
        source: *const csdl.EnumType,
    ) Error!void {
        var members: std.ArrayList(codemodel.EnumMember) = .empty;
        for (source.members) |source_member| {
            try members.append(self.arena, .{
                .name = source_member.name,
                .value = source_member.value,
                .docs = annotations.docs(source_member.annotations),
            });
        }

        try self.enum_types.put(self.arena, name.text, .{
            .name = name.text,
            .members = try members.toOwnedSlice(self.arena),
            .is_flags = source.is_flags,
            .docs = annotations.docs(source.annotations),
        });
    }

    fn compileTypeDefinition(
        self: *Compiler,
        name: QualifiedName,
        source: *const csdl.TypeDefinition,
    ) Error!void {
        const document = try self.documentOf(name.namespace());
        const underlying = try self.resolveIn(document, source.underlying_type);
        if (!isPrimitive(underlying)) return error.TypeDefinitionOfNonPrimitive;

        try self.type_definitions.put(self.arena, name.text, .{
            .name = name.text,
            .underlying_type = .{
                .name = underlying.text,
                .kind = .primitive,
                .collection = source.underlying_type.collection,
            },
            .docs = annotations.docs(source.annotations),
        });
    }

    // -- Properties ---------------------------------------------------------

    fn compileProperties(
        self: *Compiler,
        owner: QualifiedName,
        document: usize,
        source: []const csdl.Property,
    ) Error![]const codemodel.Property {
        var compiled: std.ArrayList(codemodel.Property) = .empty;
        for (source) |property| {
            const declared = try self.resolveIn(document, property.type);
            const target = self.index.mostDerived(declared);
            const kind = try self.ensureType(target);

            try compiled.append(self.arena, .{
                .name = property.name,
                .type = .{
                    .name = target.text,
                    .kind = kind,
                    .collection = property.type.collection,
                },
                .nullable = property.nullable orelse true,
                .permissions = annotations.permissions(property.annotations),
                .required = annotations.isRequired(property.annotations),
                .required_on_create = annotations.isRequiredOnCreate(property.annotations),
                .excerpts = try annotations.excerpts(self.arena, property.annotations),
                .excerpt_only = annotations.isExcerptOnly(property.annotations),
                .rigid_array = property.type.collection and
                    self.options.rigid_arrays.matches(owner, property.name),
                .default_value = property.default_value,
                .docs = annotations.docs(property.annotations),
            });
        }
        return compiled.toOwnedSlice(self.arena);
    }

    fn compileNavProperties(
        self: *Compiler,
        document: usize,
        source: []const csdl.NavigationProperty,
    ) Error![]const codemodel.NavProperty {
        var compiled: std.ArrayList(codemodel.NavProperty) = .empty;
        for (source) |property| {
            const declared = try self.resolveIn(document, property.type);
            const copy = annotations.excerptCopy(property.annotations);
            const expandable = self.root_entities.contains(declared.text) or
                self.options.navigations.matches(declared);

            var target = declared;
            if (expandable) {
                target = self.index.mostDerived(declared);
                try self.ensureEntityType(target);
                if (copy) |value| try self.noteExcerptCopy(target, value);
            } else if (copy != null) {
                // An excerpt copy inlines part of its target. With the target
                // outside the surface there is nothing to inline, and a link
                // is not a substitute -- the service does not serve one here.
                continue;
            }

            try compiled.append(self.arena, .{
                .name = property.name,
                .type = .{
                    .name = target.text,
                    .kind = if (expandable) .entity else .unknown,
                    .collection = property.type.collection,
                },
                .expandable = expandable,
                .nullable = property.nullable orelse false,
                .permissions = annotations.permissions(property.annotations),
                .required = annotations.isRequired(property.annotations),
                .required_on_create = annotations.isRequiredOnCreate(property.annotations),
                .excerpt_copy = copy,
                .excerpts = try annotations.excerpts(self.arena, property.annotations),
                .excerpt_only = annotations.isExcerptOnly(property.annotations),
                .docs = annotations.docs(property.annotations),
            });
        }
        return compiled.toOwnedSlice(self.arena);
    }

    /// Whether a complex type is read-only, when the schema did not say.
    ///
    /// The schema annotates properties, not types, so a type that exists
    /// only to group read-only properties looks writable and would get a
    /// serializable update shape nothing can fill. Reading it back off its
    /// members is a heuristic, but it is the same one the service applies
    /// when it rejects the PATCH.
    fn inferPermissions(self: *const Compiler, complex_type: codemodel.ComplexType) ?codemodel.Permissions {
        for (complex_type.properties) |property| {
            if (property.required_on_create) return null;
        }
        for (complex_type.navigation_properties) |property| {
            if (property.expandable and property.required_on_create) return null;
        }

        if (complex_type.permissions) |declared| return declared;

        // A type that takes properties the schema does not name cannot be
        // called read-only, since the unnamed ones might not be. `OemActions`
        // is the exception the corpus forces: it is open by definition and
        // every member of it is a link to an action.
        if (complex_type.additional_properties and
            !std.mem.eql(u8, QualifiedName.parse(complex_type.name).name(), "OemActions")) return null;

        const empty = complex_type.properties.len == 0 and
            complex_type.navigation_properties.len == 0;
        if (empty) return .read;

        // A link is a way in: whatever it points at can be written even if
        // everything here is read-only.
        if (complex_type.navigation_properties.len != 0) return null;
        if (complex_type.properties.len == 0) return null;

        for (complex_type.properties) |property| {
            if (property.permissions) |declared| {
                if (declared == .read) continue;
                return null;
            }
            const member = self.complex_types.get(property.type.name) orelse return null;
            if (member.permissions != .read) return null;
        }
        return .read;
    }

    // -- Actions ------------------------------------------------------------

    fn compileActions(self: *Compiler) Error!void {
        for (self.index.entries) |entry| {
            for (entry.schema.actions) |*action| {
                try self.compileAction(entry, action);
            }
        }
    }

    fn compileAction(self: *Compiler, entry: schema_index.Entry, source: *const csdl.Action) Error!void {
        if (!source.is_bound) return error.UnboundAction;
        if (source.parameters.len == 0) return error.ActionWithoutBinding;

        const bound = source.parameters[0];
        const binding = try self.resolveIn(entry.document, bound.type);

        // In Redfish an action binds to the `Actions` complex type of the
        // resource that offers it. An action bound to something outside the
        // surface has nowhere to be attached, and is not an error: the
        // corpus is compiled whole, the surface is not.
        if (!self.complex_types.contains(binding.text)) return;

        var return_type: ?codemodel.TypeRef = null;
        if (source.return_type) |returns| {
            const target = try self.resolveIn(entry.document, returns.type);
            return_type = .{
                .name = target.text,
                .kind = try self.ensureType(target),
                .collection = returns.type.collection,
            };
        }

        var parameters: std.ArrayList(codemodel.Parameter) = .empty;
        for (source.parameters[1..]) |parameter| {
            const target = try self.resolveIn(entry.document, parameter.type);
            try parameters.append(self.arena, .{
                .name = parameter.name,
                .type = .{
                    .name = target.text,
                    .kind = try self.ensureType(target),
                    .collection = parameter.type.collection,
                },
                .nullable = parameter.nullable orelse false,
                .required = annotations.isRequired(parameter.annotations),
                .docs = annotations.docs(parameter.annotations),
            });
        }

        try self.actions.append(self.arena, .{
            .name = source.name,
            .binding = binding.text,
            .namespace = entry.namespace.root().text,
            .binding_parameter = bound.name,
            .parameters = try parameters.toOwnedSlice(self.arena),
            .return_type = return_type,
            .docs = annotations.docs(source.annotations),
        });
    }

    // -- Marking ------------------------------------------------------------

    fn markODataType(self: *Compiler, name: QualifiedName) void {
        const found = self.entity_types.getPtr(name.text) orelse return;
        found.must_have_type = true;
    }

    fn noteExcerptCopy(
        self: *Compiler,
        name: QualifiedName,
        copy: codemodel.ExcerptCopy,
    ) Error!void {
        const found = try self.excerpt_copies.getOrPut(self.arena, name.text);
        if (!found.found_existing) found.value_ptr.* = .empty;
        for (found.value_ptr.items) |existing| {
            if (sameCopy(existing, copy)) return;
        }
        try found.value_ptr.append(self.arena, copy);
    }

    fn applyExcerptCopies(self: *Compiler) Error!void {
        var entries = self.excerpt_copies.iterator();
        while (entries.next()) |entry| {
            const found = self.entity_types.getPtr(entry.key_ptr.*) orelse continue;
            found.excerpt_copies = try entry.value_ptr.toOwnedSlice(self.arena);
        }
    }

    /// An insertable collection makes its members creatable. The collection
    /// itself is not: a client posts a member to it, never a collection.
    fn noteInsertableMembers(self: *Compiler, entity_type: codemodel.EntityType) Error!void {
        if (!entity_type.insertable) return;
        for (entity_type.navigation_properties) |property| {
            if (!property.expandable) continue;
            if (!std.mem.eql(u8, property.name, "Members")) continue;
            try self.creatable.put(self.arena, property.type.name, {});
            return;
        }
    }

    fn applyCreatable(self: *Compiler) void {
        for (self.creatable.keys()) |name| {
            const found = self.entity_types.getPtr(name) orelse continue;
            found.creatable = true;
        }
    }

    // -- Assembly -----------------------------------------------------------

    fn finish(self: *Compiler) Error!codemodel.Model {
        const entity_types = try self.arena.dupe(codemodel.EntityType, self.entity_types.values());
        const complex_types = try self.arena.dupe(codemodel.ComplexType, self.complex_types.values());
        const enum_types = try self.arena.dupe(codemodel.EnumType, self.enum_types.values());
        const type_definitions = try self.arena.dupe(
            codemodel.TypeDefinition,
            self.type_definitions.values(),
        );
        const actions = try self.actions.toOwnedSlice(self.arena);

        codemodel.sortByName(codemodel.EntityType, entity_types);
        codemodel.sortByName(codemodel.ComplexType, complex_types);
        codemodel.sortByName(codemodel.EnumType, enum_types);
        codemodel.sortByName(codemodel.TypeDefinition, type_definitions);
        sortActions(actions);

        return .{
            .package = self.options.package,
            .entity_types = entity_types,
            .complex_types = complex_types,
            .enum_types = enum_types,
            .type_definitions = type_definitions,
            .actions = actions,
        };
    }

    // -- Names --------------------------------------------------------------

    fn qualify(self: *const Compiler, namespace: Namespace, name: []const u8) Error!QualifiedName {
        return QualifiedName.join(self.arena, namespace.text, name);
    }

    fn documentOf(self: *const Compiler, namespace: Namespace) Error!usize {
        const entry = self.index.entry(namespace) orelse return error.SchemaNotFound;
        return entry.document;
    }

    /// Resolves a type reference as written in `document`, expanding any
    /// alias the document declared for the namespace.
    fn resolveIn(self: *const Compiler, document: usize, reference: csdl.TypeRef) Error!QualifiedName {
        return .parse(try self.index.expand(document, reference.name));
    }
};

fn isPrimitive(name: QualifiedName) bool {
    return std.mem.eql(u8, name.namespace().text, "Edm");
}

fn sameCopy(left: codemodel.ExcerptCopy, right: codemodel.ExcerptCopy) bool {
    const a = left.key orelse return right.key == null;
    const b = right.key orelse return false;
    return std.mem.eql(u8, a, b);
}

/// Actions are ordered by the type they are bound to, then by name, so an
/// emitter can walk one type's actions as a contiguous run.
fn sortActions(items: []codemodel.Action) void {
    const by = struct {
        fn lessThan(_: void, left: codemodel.Action, right: codemodel.Action) bool {
            return switch (std.mem.order(u8, left.binding, right.binding)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, left.name, right.name) == .lt,
            };
        }
    };
    std.mem.sort(codemodel.Action, items, {}, by.lessThan);
}

const testing = std.testing;

/// Parses documents, indexes them, and compiles the result.
fn compileText(
    arena: std.mem.Allocator,
    sources: []const []const u8,
    options: Options,
) !codemodel.Model {
    const documents = try arena.alloc(csdl.Document, sources.len);
    for (sources, 0..) |source, index| documents[index] = try csdl.parse(arena, source);
    const built = try SchemaIndex.build(arena, documents, null);
    return compile(arena, &built, options);
}

fn wrap(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\
        ,
        body,
        \\
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    });
}

/// A service root, a chassis behind a link, and the two well-known types.
const service =
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Resource">
    \\  <EntityType Name="Resource" Abstract="true">
    \\    <Key><PropertyRef Name="Id"/></Key>
    \\    <Property Name="Id" Type="Edm.String" Nullable="false"/>
    \\  </EntityType>
    \\  <EntityType Name="ResourceCollection" Abstract="true"/>
    \\  <ComplexType Name="Status">
    \\    <Property Name="State" Type="Resource.State">
    \\      <Annotation Term="OData.Permissions" EnumMember="OData.Permission/Read"/>
    \\    </Property>
    \\  </ComplexType>
    \\  <EnumType Name="State">
    \\    <Member Name="Enabled"/>
    \\    <Member Name="Disabled"/>
    \\  </EnumType>
    \\</Schema>
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Settings">
    \\  <ComplexType Name="Settings"/>
    \\  <ComplexType Name="PreferredApplyTime"/>
    \\</Schema>
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="ServiceRoot">
    \\  <EntityType Name="ServiceRoot" BaseType="Resource.Resource" Abstract="true"/>
    \\  <EntityContainer Name="ServiceContainer">
    \\    <Singleton Name="Service" Type="ServiceRoot.ServiceRoot"/>
    \\  </EntityContainer>
    \\</Schema>
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="ServiceRoot.v1_0_0">
    \\  <EntityType Name="ServiceRoot" BaseType="ServiceRoot.ServiceRoot">
    \\    <Property Name="RedfishVersion" Type="Edm.String">
    \\      <Annotation Term="OData.Description" String="The version of the service."/>
    \\    </Property>
    \\    <Property Name="Status" Type="Resource.Status"/>
    \\    <NavigationProperty Name="Chassis" Type="Chassis.Chassis" Nullable="false"/>
    \\  </EntityType>
    \\</Schema>
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis">
    \\  <EntityType Name="Chassis" BaseType="Resource.Resource" Abstract="true"/>
    \\</Schema>
    \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis.v1_0_0">
    \\  <EntityType Name="Chassis" BaseType="Chassis.Chassis">
    \\    <Property Name="AssetTag" Type="Edm.String"/>
    \\  </EntityType>
    \\</Schema>
;

const package: codemodel.Package = .{ .name = "redfish_schema_test" };

test "the root set starts at the named singleton" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    // The singleton names the abstract type; the newest version is compiled.
    try testing.expect(model.entityType("ServiceRoot.v1_0_0.ServiceRoot") != null);
    try testing.expect(model.entityType("ServiceRoot.ServiceRoot") != null);
    try testing.expect(model.entityType("Resource.Resource") != null);
}

test "an unnamed singleton roots nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package },
    );

    try testing.expect(model.entityType("ServiceRoot.v1_0_0.ServiceRoot") == null);
    // The well-known types are compiled regardless.
    try testing.expect(model.entityType("Resource.Resource") != null);
    try testing.expect(model.complexType("Settings.Settings") != null);
}

test "a property pulls in the types it names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const root = model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?;
    try testing.expectEqualStrings("RedfishVersion", root.properties[0].name);
    try testing.expectEqualStrings("Edm.String", root.properties[0].type.name);
    try testing.expectEqual(codemodel.Kind.primitive, root.properties[0].type.kind);
    try testing.expectEqualStrings(
        "The version of the service.",
        root.properties[0].docs.description.?,
    );

    try testing.expectEqual(codemodel.Kind.complex, root.properties[1].type.kind);
    try testing.expect(model.complexType("Resource.Status") != null);
    try testing.expect(model.enumType("Resource.State") != null);
}

test "a link resolves to the newest version of its target" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const root = model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?;
    const link = root.navigation_properties[0];
    try testing.expectEqualStrings("Chassis", link.name);
    try testing.expect(link.expandable);
    try testing.expectEqualStrings("Chassis.v1_0_0.Chassis", link.type.name);
    try testing.expect(model.entityType("Chassis.v1_0_0.Chassis") != null);
}

test "a link the profile did not ask for stays a reference" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{
            .package = package,
            .singletons = &.{"Service"},
            .navigations = .{ .mode = .restrictive },
        },
    );

    const root = model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?;
    const link = root.navigation_properties[0];
    try testing.expect(!link.expandable);
    // The target is still named, so the reference can be typed later.
    try testing.expectEqualStrings("Chassis.Chassis", link.type.name);
    try testing.expect(model.entityType("Chassis.v1_0_0.Chassis") == null);
}

test "a pattern roots a type nothing links to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const roots = try filter.TypeFilter.parse(
        arena.allocator(),
        &.{"Chassis.*.Chassis"},
        .restrictive,
    );
    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .roots = roots, .navigations = .{ .mode = .restrictive } },
    );

    try testing.expect(model.entityType("Chassis.v1_0_0.Chassis") != null);
    try testing.expect(model.entityType("ServiceRoot.v1_0_0.ServiceRoot") == null);
}

test "nullability differs between a property and a link" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const root = model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?;
    // `Nullable` is absent on the property and false on the link.
    try testing.expect(root.properties[0].nullable);
    try testing.expect(!root.navigation_properties[0].nullable);
}

test "compiling everything ignores the root set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .everything = true },
    );

    try testing.expect(model.entityType("Chassis.Chassis") != null);
    try testing.expect(model.entityType("Chassis.v1_0_0.Chassis") != null);
    try testing.expect(model.entityType("ServiceRoot.v1_0_0.ServiceRoot") != null);
}

test "only the two base resources carry an odata type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    try testing.expect(model.entityType("Resource.Resource").?.must_have_type);
    try testing.expect(model.entityType("Resource.ResourceCollection").?.must_have_type);
    try testing.expect(!model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?.must_have_type);
    try testing.expect(model.entityType("ServiceRoot.v1_0_0.ServiceRoot").?.must_have_id);
}

test "a link back to an ancestor does not recurse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cyclic =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <NavigationProperty Name="Chassis" Type="Chassis.Chassis"/>
        \\  </EntityType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis">
        \\  <EntityType Name="Chassis">
        \\    <NavigationProperty Name="Parent" Type="Root.Root"/>
        \\    <NavigationProperty Name="Contains" Type="Collection(Chassis.Chassis)"/>
        \\  </EntityType>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), cyclic)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const chassis = model.entityType("Chassis.Chassis").?;
    try testing.expect(chassis.navigation_properties[0].expandable);
    try testing.expect(chassis.navigation_properties[1].expandable);
    try testing.expect(chassis.navigation_properties[1].type.collection);
}

test "an insertable collection makes its members creatable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <NavigationProperty Name="Sessions" Type="SessionCollection.SessionCollection"/>
        \\  </EntityType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="SessionCollection">
        \\  <EntityType Name="SessionCollection">
        \\    <Annotation Term="Capabilities.InsertRestrictions">
        \\      <Record><PropertyValue Property="Insertable" Bool="true"/></Record>
        \\    </Annotation>
        \\    <NavigationProperty Name="Members" Type="Collection(Session.Session)"/>
        \\  </EntityType>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Session">
        \\  <EntityType Name="Session">
        \\    <Property Name="UserName" Type="Edm.String">
        \\      <Annotation Term="Redfish.RequiredOnCreate"/>
        \\    </Property>
        \\  </EntityType>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    try testing.expect(model.entityType("SessionCollection.SessionCollection").?.insertable);
    try testing.expect(!model.entityType("SessionCollection.SessionCollection").?.creatable);
    try testing.expect(model.entityType("Session.Session").?.creatable);
    try testing.expect(model.entityType("Session.Session").?.properties[0].required_on_create);
}

test "an excerpt copy is recorded against the type it copies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <NavigationProperty Name="PrimaryVoltage" Type="Sensor.Sensor">
        \\      <Annotation Term="Redfish.ExcerptCopy" String="Voltage"/>
        \\    </NavigationProperty>
        \\    <NavigationProperty Name="SecondaryVoltage" Type="Sensor.Sensor">
        \\      <Annotation Term="Redfish.ExcerptCopy" String="Voltage"/>
        \\    </NavigationProperty>
        \\    <NavigationProperty Name="Power" Type="Sensor.Sensor">
        \\      <Annotation Term="Redfish.ExcerptCopy"/>
        \\    </NavigationProperty>
        \\  </EntityType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Sensor">
        \\  <EntityType Name="Sensor">
        \\    <Property Name="Reading" Type="Edm.Decimal">
        \\      <Annotation Term="Redfish.Excerpt"/>
        \\    </Property>
        \\    <Property Name="Volts" Type="Edm.Decimal">
        \\      <Annotation Term="Redfish.ExcerptCopyOnly" String="Voltage"/>
        \\    </Property>
        \\  </EntityType>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const sensor = model.entityType("Sensor.Sensor").?;
    // Two links take the same view, so it is recorded once.
    try testing.expectEqual(@as(usize, 2), sensor.excerpt_copies.len);
    try testing.expectEqualStrings("Voltage", sensor.excerpt_copies[0].key.?);
    try testing.expect(sensor.excerpt_copies[1].key == null);

    // A property in every view is in both copies; one named view is not.
    try testing.expect(sensor.properties[0].inExcerpt(sensor.excerpt_copies[0]));
    try testing.expect(sensor.properties[0].inExcerpt(sensor.excerpt_copies[1]));
    try testing.expect(sensor.properties[1].inExcerpt(.{ .key = "Voltage" }));
    try testing.expect(!sensor.properties[1].inExcerpt(.{ .key = "Current" }));
    try testing.expect(sensor.properties[1].excerpt_only);
}

test "a copy of a type outside the surface is dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <NavigationProperty Name="Voltage" Type="Sensor.Sensor">
        \\      <Annotation Term="Redfish.ExcerptCopy" String="Voltage"/>
        \\    </NavigationProperty>
        \\    <NavigationProperty Name="Sensors" Type="Sensor.Sensor"/>
        \\  </EntityType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Sensor">
        \\  <EntityType Name="Sensor"/>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{
            .package = package,
            .singletons = &.{"Service"},
            .navigations = .{ .mode = .restrictive },
        },
    );

    const root = model.entityType("Root.Root").?;
    try testing.expectEqual(@as(usize, 1), root.navigation_properties.len);
    try testing.expectEqualStrings("Sensors", root.navigation_properties[0].name);
}

test "a complex type of read-only properties is read-only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Status" Type="Root.Status"/>
        \\    <Property Name="Location" Type="Root.Location"/>
        \\    <Property Name="Empty" Type="Root.Empty"/>
        \\    <Property Name="Oem" Type="Root.Oem"/>
        \\    <Property Name="Actions" Type="Root.OemActions"/>
        \\    <Property Name="Create" Type="Root.Create"/>
        \\  </EntityType>
        \\  <ComplexType Name="Status">
        \\    <Property Name="State" Type="Edm.String">
        \\      <Annotation Term="OData.Permissions" EnumMember="OData.Permission/Read"/>
        \\    </Property>
        \\  </ComplexType>
        \\  <ComplexType Name="Location">
        \\    <Property Name="Info" Type="Edm.String"/>
        \\  </ComplexType>
        \\  <ComplexType Name="Empty"/>
        \\  <ComplexType Name="Oem">
        \\    <Annotation Term="OData.AdditionalProperties" Bool="true"/>
        \\  </ComplexType>
        \\  <ComplexType Name="OemActions">
        \\    <Annotation Term="OData.AdditionalProperties" Bool="true"/>
        \\  </ComplexType>
        \\  <ComplexType Name="Create">
        \\    <Property Name="Name" Type="Edm.String">
        \\      <Annotation Term="OData.Permissions" EnumMember="OData.Permission/Read"/>
        \\      <Annotation Term="Redfish.RequiredOnCreate"/>
        \\    </Property>
        \\  </ComplexType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    try testing.expectEqual(codemodel.Permissions.read, model.complexType("Root.Status").?.permissions.?);
    try testing.expect(model.complexType("Root.Location").?.permissions == null);
    try testing.expectEqual(codemodel.Permissions.read, model.complexType("Root.Empty").?.permissions.?);
    try testing.expect(model.complexType("Root.Oem").?.permissions == null);
    try testing.expectEqual(
        codemodel.Permissions.read,
        model.complexType("Root.OemActions").?.permissions.?,
    );
    // A member required on create keeps the type writable.
    try testing.expect(model.complexType("Root.Create").?.permissions == null);
}

test "a type whose members are read-only complex types is read-only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Outer" Type="Root.Outer"/>
        \\  </EntityType>
        \\  <ComplexType Name="Outer">
        \\    <Property Name="Inner" Type="Root.Inner"/>
        \\  </ComplexType>
        \\  <ComplexType Name="Inner">
        \\    <Property Name="State" Type="Edm.String">
        \\      <Annotation Term="OData.Permissions" EnumMember="OData.Permission/Read"/>
        \\    </Property>
        \\  </ComplexType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    try testing.expectEqual(codemodel.Permissions.read, model.complexType("Root.Inner").?.permissions.?);
    try testing.expectEqual(codemodel.Permissions.read, model.complexType("Root.Outer").?.permissions.?);
}

test "an action attaches to the type it is bound to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Actions" Type="Root.Actions"/>
        \\  </EntityType>
        \\  <ComplexType Name="Actions"/>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root.v1_0_0">
        \\  <Action Name="Reset" IsBound="true">
        \\    <Annotation Term="OData.Description" String="Resets the resource."/>
        \\    <Parameter Name="Target" Type="Root.Actions"/>
        \\    <Parameter Name="ResetType" Type="Edm.String">
        \\      <Annotation Term="Redfish.Required"/>
        \\    </Parameter>
        \\  </Action>
        \\  <Action Name="Unattached" IsBound="true">
        \\    <Parameter Name="Target" Type="Elsewhere.Actions"/>
        \\  </Action>
        \\</Schema>
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Elsewhere">
        \\  <ComplexType Name="Actions"/>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    try testing.expectEqual(@as(usize, 1), model.actions.len);
    const action = model.actions[0];
    try testing.expectEqualStrings("Reset", action.name);
    try testing.expectEqualStrings("Root.Actions", action.binding);
    try testing.expectEqualStrings("Root", action.namespace);
    try testing.expectEqualStrings("Target", action.binding_parameter);
    try testing.expectEqual(@as(usize, 1), action.parameters.len);
    try testing.expectEqualStrings("ResetType", action.parameters[0].name);
    try testing.expect(action.parameters[0].required);
    try testing.expect(!action.parameters[0].nullable);
    try testing.expectEqualStrings("Resets the resource.", action.docs.description.?);
}

test "an unbound action is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root"/>
        \\  <Action Name="Reset"/>
        \\</Schema>
    ;

    try testing.expectError(error.UnboundAction, compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package },
    ));
}

test "a type definition must rename a primitive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const good =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Id" Type="Root.Identifier"/>
        \\  </EntityType>
        \\  <TypeDefinition Name="Identifier" UnderlyingType="Edm.String"/>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), good)},
        .{ .package = package, .singletons = &.{"Service"} },
    );
    const defined = model.typeDefinition("Root.Identifier").?;
    try testing.expectEqualStrings("Edm.String", defined.underlying_type.name);
    try testing.expectEqual(
        codemodel.Kind.type_definition,
        model.entityType("Root.Root").?.properties[0].type.kind,
    );

    const bad =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Id" Type="Root.Identifier"/>
        \\  </EntityType>
        \\  <TypeDefinition Name="Identifier" UnderlyingType="Root.Other"/>
        \\  <ComplexType Name="Other"/>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
    ;

    try testing.expectError(error.TypeDefinitionOfNonPrimitive, compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), bad)},
        .{ .package = package, .singletons = &.{"Service"} },
    ));
}

test "a reference to a type nothing declares is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\<Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\  <EntityType Name="Root">
        \\    <Property Name="Missing" Type="Absent.Type"/>
        \\  </EntityType>
        \\  <EntityContainer Name="Container">
        \\    <Singleton Name="Service" Type="Root.Root"/>
        \\  </EntityContainer>
        \\</Schema>
    ;

    try testing.expectError(error.TypeNotFound, compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), source)},
        .{ .package = package, .singletons = &.{"Service"} },
    ));
}

test "an alias is resolved against the document that declared it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const referenced =
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Resource.v1_0_0">
        \\      <ComplexType Name="Status">
        \\        <Property Name="State" Type="Edm.String"/>
        \\      </ComplexType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;
    const referring =
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:Reference Uri="Resource_v1.xml">
        \\    <edmx:Include Namespace="Resource.v1_0_0" Alias="Resource"/>
        \\  </edmx:Reference>
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Root">
        \\      <EntityType Name="Root">
        \\        <Property Name="Status" Type="Resource.Status"/>
        \\      </EntityType>
        \\      <EntityContainer Name="Container">
        \\        <Singleton Name="Service" Type="Root.Root"/>
        \\      </EntityContainer>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;

    const model = try compileText(
        arena.allocator(),
        &.{ referenced, referring },
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const root = model.entityType("Root.Root").?;
    try testing.expectEqualStrings("Resource.v1_0_0.Status", root.properties[0].type.name);
    try testing.expect(model.complexType("Resource.v1_0_0.Status") != null);
}

test "only the leading documents may contribute roots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const oem =
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="OemChassis">
        \\      <EntityType Name="OemChassis"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;
    const standard =
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis">
        \\      <EntityType Name="Chassis"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;

    const roots = try filter.TypeFilter.parse(arena.allocator(), &.{"*.*"}, .restrictive);
    const model = try compileText(
        arena.allocator(),
        &.{ oem, standard },
        .{ .package = package, .roots = roots, .root_documents = 1 },
    );

    try testing.expect(model.entityType("OemChassis.OemChassis") != null);
    try testing.expect(model.entityType("Chassis.Chassis") == null);
}

test "the model round-trips through JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .singletons = &.{"Service"} },
    );

    const json = try model.stringify(arena.allocator());
    const parsed = try codemodel.Model.parse(arena.allocator(), json);

    try testing.expectEqual(model.entity_types.len, parsed.entity_types.len);
    try testing.expectEqual(model.complex_types.len, parsed.complex_types.len);
    try testing.expectEqualStrings(
        model.entity_types[0].name,
        parsed.entity_types[0].name,
    );
}

test "declarations come out in a stable order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model = try compileText(
        arena.allocator(),
        &.{try wrap(arena.allocator(), service)},
        .{ .package = package, .everything = true },
    );

    for (model.entity_types[1..], 1..) |entity_type, index| {
        try testing.expect(std.mem.order(
            u8,
            model.entity_types[index - 1].name,
            entity_type.name,
        ) == .lt);
    }
    for (model.complex_types[1..], 1..) |complex_type, index| {
        try testing.expect(std.mem.order(
            u8,
            model.complex_types[index - 1].name,
            complex_type.name,
        ) == .lt);
    }
}
