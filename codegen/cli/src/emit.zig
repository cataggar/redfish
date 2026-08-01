//! Writing a code model out as a Zig package.
//!
//! The emitter produces files in memory rather than on disk. A generated
//! package is checked in here, so what matters about the output is that it is
//! reviewable and reproducible, and both are easier to test when the whole
//! package is a value: a test can render a model and assert on the text
//! without a temporary directory, and `main.zig` is left with nothing to do
//! but write bytes.
//!
//! Layout follows the naming map: a file per namespace under `src/`, a
//! `src/root.zig` that re-exports them, and the package scaffolding around
//! it. Every file is emitter-owned end to end — there is no hand-edited file
//! inside a generated package, so there is nothing to merge.

const std = @import("std");

const codemodel = @import("codemodel.zig");
const identifiers = @import("identifiers.zig");
const names = @import("names.zig");
const permissions = @import("permissions.zig");
const schema_index = @import("schema_index.zig");
const types = @import("types.zig");

const Model = codemodel.Model;
const Namespace = schema_index.Namespace;
const QualifiedName = schema_index.QualifiedName;
const Writer = std.Io.Writer.Allocating;

pub const Error = std.Io.Writer.Error || names.Registry.ClaimError;

/// One generated file, path relative to the package root.
pub const File = struct {
    path: []const u8,
    contents: []const u8,
};

pub const Options = struct {
    /// The module name the package imports `redfish_core` under.
    core_module: []const u8 = "redfish_core",
    /// The dependency in `build.zig.zon` that provides it.
    dependency: []const u8 = "redfish",
    /// Where that dependency is, relative to the package.
    dependency_path: []const u8 = "../..",
    /// What to blame in the do-not-edit banner.
    generator: []const u8 = "redfish-codegen",
    /// The Zig release the package declares it needs.
    minimum_zig_version: []const u8 = "0.16.0",
    /// The package that already provides the standard types this one refers
    /// to. Null emits everything the model holds, which is what the standard
    /// package itself does.
    base: ?Base = null,
    /// The schema corpora this package was generated from, in the order they
    /// were given. Emitted into the README so a generated package says what
    /// produced it: the types are a function of the corpus and the generator,
    /// and nothing else in the package records which corpus that was.
    corpora: []const Corpus = &.{},
};

/// A pinned schema corpus, for the record the README keeps.
///
/// `commit` is the truth and `name` is the label. The tag a corpus release
/// carries is deliberately not held here: `build.zig` derives these from the
/// pinned URLs in `build.zig.zon`, which name a commit and not a tag, so a
/// tag string would be a second copy of a fact nobody updates. A reader who
/// wants the tag can resolve the commit; a reader given a stale tag cannot
/// tell that it is stale.
pub const Corpus = struct {
    /// What to call it, e.g. `DMTF Redfish-Publications`.
    name: []const u8,
    /// Where it came from, without the fragment.
    url: []const u8,
    /// The commit the build pinned.
    commit: []const u8,
};

/// A package this one builds on.
///
/// A vendor extension is a handful of properties hung off the standard
/// schemas, but it is compiled against the whole corpus, so the model handed
/// to the emitter holds every standard type the vendor's types can reach.
/// Emitting those would copy a slice of the standard package into every
/// vendor package -- 63,000 lines of it for LiteOn, whose extension is one
/// boolean -- and worse, the copies would be *different Zig types*, so a
/// program holding both packages would have two unrelated `Assembly`s.
///
/// `provides` names the types to refer to instead of emitting. It is the
/// standard package's own output, computed by running the same pipeline, so
/// the two agree on names by construction rather than by luck.
pub const Base = struct {
    /// The Zig module name: `redfish_schema_std`.
    module: []const u8,
    /// The dependency in `build.zig.zon` that provides it.
    dependency: []const u8,
    /// Where that dependency is, relative to this package.
    dependency_path: []const u8,
    /// Qualified schema names it declares.
    provides: *const std.StringHashMapUnmanaged(void),
};

/// What a generated file calls the base package.
const base_alias = "base";

/// Renders a model as a complete Zig package.
pub fn emit(arena: std.mem.Allocator, model: Model, options: Options) Error![]const File {
    var emitter: Emitter = .{ .arena = arena, .model = model, .options = options };
    return emitter.run();
}

/// Every qualified name a model's package declares.
///
/// This is what another package needs in order to refer to this one instead
/// of copying it, and it is computed here rather than by the caller so that
/// it cannot disagree with what `emit` actually writes -- actions included,
/// whose qualified name is assembled rather than carried.
pub fn provided(
    arena: std.mem.Allocator,
    model: Model,
) Error!std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    for (model.enum_types) |value| try out.put(arena, value.name, {});
    for (model.type_definitions) |value| try out.put(arena, value.name, {});
    for (model.complex_types) |value| try out.put(arena, value.name, {});
    for (model.entity_types) |value| try out.put(arena, value.name, {});
    for (model.actions) |action| {
        try out.put(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{
            action.namespace,
            try names.actionType(arena, action),
        }), {});
    }
    return out;
}

/// The declarations of one namespace, which become one file.
const Module = struct {
    /// The namespace as the schema writes it: `Chassis`.
    namespace: []const u8,
    /// The module as Zig writes it: `chassis`.
    name: []const u8,
    enum_types: std.ArrayList(*const codemodel.EnumType) = .empty,
    type_definitions: std.ArrayList(*const codemodel.TypeDefinition) = .empty,
    complex_types: std.ArrayList(*const codemodel.ComplexType) = .empty,
    entity_types: std.ArrayList(*const codemodel.EntityType) = .empty,
    /// Actions the namespace declares. An OEM action is declared in the
    /// vendor's namespace and bound to a standard resource, so this is not
    /// the same list as the actions the module's types offer.
    actions: std.ArrayList(*const codemodel.Action) = .empty,
    /// Sibling modules this one names, so the file can import them.
    imports: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Set when something in the module fell back to `std.json.Value`.
    uses_std: bool = false,
    /// Set when something in the module names a type the base package
    /// provides.
    uses_base: bool = false,

    fn isEmpty(self: Module) bool {
        return self.enum_types.items.len == 0 and
            self.type_definitions.items.len == 0 and
            self.complex_types.items.len == 0 and
            self.entity_types.items.len == 0 and
            self.actions.items.len == 0;
    }
};

const Emitter = struct {
    arena: std.mem.Allocator,
    model: Model,
    options: Options,
    modules: std.StringArrayHashMapUnmanaged(Module) = .empty,
    registry: names.Registry = .{},
    /// Every qualified name the model declares, so a reference out of the
    /// compiled surface is recognized as one instead of naming a type that
    /// was never emitted.
    declared: std.StringHashMapUnmanaged(void) = .empty,
    /// Which types a client may write, which the schema only implies.
    writable: permissions.Resolver = .{},
    /// Memoized answers from `hasWritable`, keyed `"<payload> <name>"`. The
    /// question is asked once per reference and the recursion is not cheap.
    write_shapes: std.StringHashMapUnmanaged(bool) = .empty,
    /// Names `hasWritable` is partway through, so a complex type that refers
    /// to itself is answered instead of recursed into forever.
    in_progress: std.StringHashMapUnmanaged(void) = .empty,

    fn run(self: *Emitter) Error![]const File {
        defer self.registry.deinit(self.arena);
        defer self.declared.deinit(self.arena);
        defer self.write_shapes.deinit(self.arena);
        defer self.in_progress.deinit(self.arena);

        self.writable = try .init(self.arena, &self.model);
        defer self.writable.deinit(self.arena);

        try self.collect();

        var files: std.ArrayList(File) = .empty;
        try files.append(self.arena, try self.buildZig());
        try files.append(self.arena, try self.buildZon());
        try files.append(self.arena, try self.readme());
        try files.append(self.arena, try self.rootFile());
        for (self.modules.values()) |*module| {
            try files.append(self.arena, try self.moduleFile(module));
        }
        return files.toOwnedSlice(self.arena);
    }

    /// Sorts every declaration into the module its namespace names.
    ///
    /// A declaration the base package provides is skipped: it is left out of
    /// `declared` too, so `resolve` has to decide what it is rather than
    /// assuming a name it can see is a name it emitted.
    fn collect(self: *Emitter) Error!void {
        for (self.model.enum_types) |*enum_type| {
            if (self.isExternal(enum_type.name)) continue;
            const module = try self.moduleFor(enum_type.name);
            try module.enum_types.append(self.arena, enum_type);
            try self.declared.put(self.arena, enum_type.name, {});
        }
        for (self.model.type_definitions) |*definition| {
            if (self.isExternal(definition.name)) continue;
            const module = try self.moduleFor(definition.name);
            try module.type_definitions.append(self.arena, definition);
            try self.declared.put(self.arena, definition.name, {});
        }
        for (self.model.complex_types) |*complex_type| {
            if (self.isExternal(complex_type.name)) continue;
            const module = try self.moduleFor(complex_type.name);
            try module.complex_types.append(self.arena, complex_type);
            try self.declared.put(self.arena, complex_type.name, {});
        }
        for (self.model.entity_types) |*entity_type| {
            if (self.isExternal(entity_type.name)) continue;
            const module = try self.moduleFor(entity_type.name);
            try module.entity_types.append(self.arena, entity_type);
            try self.declared.put(self.arena, entity_type.name, {});
        }
        for (self.model.actions) |*action| {
            const qualified = try self.actionQualified(action.*);
            if (self.isExternal(qualified)) continue;
            const module = try self.moduleFor(qualified);
            try module.actions.append(self.arena, action);
        }

        // Modules come out in namespace order, so a schema added to a profile
        // lands where it belongs instead of at the end.
        const Order = struct {
            fn lessThan(context: void, left: Module, right: Module) bool {
                _ = context;
                return std.mem.order(u8, left.namespace, right.namespace) == .lt;
            }
        };
        self.modules.sortUnstable(struct {
            values: []const Module,
            pub fn lessThan(context: @This(), left: usize, right: usize) bool {
                return Order.lessThan({}, context.values[left], context.values[right]);
            }
        }{ .values = self.modules.values() });
    }

    fn moduleFor(self: *Emitter, qualified: []const u8) Error!*Module {
        const namespace = QualifiedName.parse(qualified).namespace();
        const entry = try self.modules.getOrPut(self.arena, namespace.text);
        if (!entry.found_existing) entry.value_ptr.* = .{
            .namespace = namespace.text,
            .name = try names.module(self.arena, namespace),
        };
        return entry.value_ptr;
    }

    // -- Package scaffolding ------------------------------------------------

    fn buildZig(self: *Emitter) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;
        try self.banner(w, "//!");
        try w.print(
            \\
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{}});
            \\
            \\    const {0f} = b.dependency("{1s}", .{{ .target = target, .optimize = optimize }});
            \\
        , .{
            identifiers.fmt(self.options.dependency),
            self.options.dependency,
        });
        if (self.options.base) |base| {
            try w.print(
                \\    const {0f} = b.dependency("{1s}", .{{ .target = target, .optimize = optimize }});
                \\
            , .{ identifiers.fmt(base.dependency), base.dependency });
        }
        try w.print(
            \\
            \\    const module = b.addModule("{1s}", .{{
            \\        .root_source_file = b.path("src/root.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\        .imports = &.{{
            \\            .{{ .name = "{2s}", .module = {0f}.module("{2s}") }},
            \\
        , .{
            identifiers.fmt(self.options.dependency),
            self.model.package.name,
            self.options.core_module,
        });
        if (self.options.base) |base| {
            try w.print(
                \\            .{{ .name = "{0s}", .module = {1f}.module("{0s}") }},
                \\
            , .{ base.module, identifiers.fmt(base.dependency) });
        }
        try w.writeAll(
            \\        },
            \\    });
            \\
            \\    const tests = b.addTest(.{ .root_module = module });
            \\    b.step("test", "Run the package tests").dependOn(&b.addRunArtifact(tests).step);
            \\}
            \\
        );
        return .{ .path = "build.zig", .contents = try out.toOwnedSlice() };
    }

    fn buildZon(self: *Emitter) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;
        try w.print(
            \\.{{
            \\    .name = .{0f},
            \\    .version = "{1s}",
            \\    .fingerprint = 0x{2x:0>16},
            \\    .minimum_zig_version = "{3s}",
            \\    .dependencies = .{{
            \\        .{4f} = .{{ .path = "{5s}" }},
            \\
        , .{
            identifiers.fmt(self.model.package.name),
            self.model.package.version,
            fingerprint(self.model.package.name),
            self.options.minimum_zig_version,
            identifiers.fmt(self.options.dependency),
            self.options.dependency_path,
        });
        if (self.options.base) |base| {
            try w.print("        .{f} = .{{ .path = \"{s}\" }},\n", .{
                identifiers.fmt(base.dependency),
                base.dependency_path,
            });
        }
        try w.writeAll(
            \\    },
            \\    .paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "README.md",
            \\    },
            \\}
            \\
        );
        return .{ .path = "build.zig.zon", .contents = try out.toOwnedSlice() };
    }

    fn readme(self: *Emitter) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;
        const manifest = self.model.package;

        try w.print("# {s}\n\n", .{manifest.display_name orelse manifest.name});
        try w.print(
            \\Redfish schema types for the `{s}` profile, generated by
            \\`{s}` from DMTF CSDL.
            \\
            \\**Do not edit this package.** Every file in it is written by the
            \\generator; change the profile or the generator instead.
            \\
            \\
        , .{ manifest.profile orelse "default", self.options.generator });

        if (manifest.root) |root| {
            try w.print("The service starts at `{s}`.\n\n", .{root});
        }

        if (self.options.base) |base| {
            try w.print(
                \\It holds only what the vendor adds. Every standard type it refers to
                \\comes from `{s}`, which it depends on rather than copies -- a vendor
                \\resource read through this package and the same resource read through
                \\the standard one are the same Zig type.
                \\
                \\
            , .{base.module});
        }

        try w.writeAll("## Contents\n\n");
        try w.print("| Namespaces | {d} |\n", .{self.modules.count()});
        try w.writeAll("| --- | --- |\n");
        try w.print("| Resources | {d} |\n", .{self.mine(codemodel.EntityType, self.model.entity_types)});
        try w.print("| Structures | {d} |\n", .{self.mine(codemodel.ComplexType, self.model.complex_types)});
        try w.print("| Enumerations | {d} |\n", .{self.mine(codemodel.EnumType, self.model.enum_types)});
        try w.print("| Aliases | {d} |\n", .{self.mine(codemodel.TypeDefinition, self.model.type_definitions)});
        try w.print("| Actions | {d} |\n", .{self.model.actions.len});

        if (self.options.corpora.len > 0) {
            try w.writeAll(
                \\
                \\## Provenance
                \\
                \\These types are a function of the corpora below and of the generator
                \\that read them. The package version is not meaningful for generated
                \\code and is not maintained: a schema bump can add properties and
                \\rename a type DMTF renamed without anything here being edited, so what
                \\identifies this output is the commit, not a number chosen by hand.
                \\
                \\
            );
            try w.writeAll("| Corpus | Commit |\n");
            try w.writeAll("| --- | --- |\n");
            for (self.options.corpora) |corpus| {
                try w.print("| [{s}]({s}) | `{s}` |\n", .{ corpus.name, corpus.url, corpus.commit });
            }
        }

        return .{ .path = "README.md", .contents = try out.toOwnedSlice() };
    }

    /// How many of `declarations` this package declares itself.
    ///
    /// A package built on another keeps the base package's types in its model
    /// -- that is how a reference to one resolves -- but it does not emit
    /// them, and a count that included them would describe the wrong package.
    fn mine(self: *Emitter, comptime T: type, declarations: []const T) usize {
        var count: usize = 0;
        for (declarations) |declaration| {
            if (!self.isExternal(declaration.name)) count += 1;
        }
        return count;
    }

    fn rootFile(self: *Emitter) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;
        const manifest = self.model.package;

        try w.print("//! {s}\n//!\n", .{manifest.display_name orelse manifest.name});
        try self.banner(w, "//!");
        try w.print(
            \\
            \\const std = @import("std");
            \\
            \\pub const core = @import("{s}");
            \\
            \\
        , .{self.options.core_module});

        for (self.modules.values()) |module| {
            if (module.isEmpty()) continue;
            try w.print("pub const {f} = @import(\"{s}.zig\");\n", .{
                identifiers.fmt(module.name),
                module.name,
            });
        }

        if (manifest.root) |root| {
            const parsed: QualifiedName = .parse(root);
            try w.print(
                \\
                \\/// The resource a session starts at.
                \\pub const Root = {s};
                \\
            , .{try names.fullType(self.arena, parsed.text, .read)});
        }

        try w.writeAll(
            \\
            \\test {
            \\    std.testing.refAllDecls(@This());
            \\}
            \\
        );
        return .{ .path = "src/root.zig", .contents = try out.toOwnedSlice() };
    }

    // -- Declarations -------------------------------------------------------

    fn moduleFile(self: *Emitter, module: *Module) Error!File {
        // The body is written first because writing it is what discovers
        // which sibling modules this one names, and the imports have to come
        // before the declarations that use them.
        var body: Writer = .init(self.arena);
        for (module.type_definitions.items) |definition| {
            try self.typeDefinition(&body.writer, module, definition);
        }
        for (module.enum_types.items) |enum_type| {
            try self.enumType(&body.writer, module, enum_type);
        }
        for (module.actions.items) |action| {
            try self.actionType(&body.writer, module, action);
        }
        for (module.complex_types.items) |complex_type| {
            try self.complexType(&body.writer, module, complex_type);
        }
        for (module.entity_types.items) |entity_type| {
            try self.entityType(&body.writer, module, entity_type);
        }

        // Referencing every declaration is what turns `zig build test` into
        // a check that the emitter produced types that resolve, not just
        // text that parses. A struct's field types stay unanalyzed until
        // something asks for them.
        module.uses_std = true;
        try body.writer.writeAll(
            \\
            \\test {
            \\    std.testing.refAllDecls(@This());
            \\}
            \\
        );

        var out: Writer = .init(self.arena);
        const w = &out.writer;

        try w.print("//! Namespace `{s}`.\n//!\n", .{module.namespace});
        try self.banner(w, "//!");
        if (module.uses_std) try w.writeAll(
            \\
            \\const std = @import("std");
            \\
        );
        try w.print(
            \\
            \\const core = @import("{s}");
            \\
        , .{self.options.core_module});
        if (module.uses_base) {
            if (self.options.base) |base| {
                try w.print("const {s} = @import(\"{s}\");\n", .{ base_alias, base.module });
            }
        }

        const Order = struct {
            fn lessThan(context: void, left: []const u8, right: []const u8) bool {
                _ = context;
                return std.mem.order(u8, left, right) == .lt;
            }
        };
        const imported = module.imports.keys();
        std.mem.sort([]const u8, imported, {}, Order.lessThan);
        for (imported) |name| {
            try w.print("const {f} = @import(\"{s}.zig\");\n", .{ identifiers.fmt(name), name });
        }

        try w.writeAll(body.written());
        return .{
            .path = try std.fmt.allocPrint(self.arena, "src/{s}.zig", .{module.name}),
            .contents = try out.toOwnedSlice(),
        };
    }

    /// What to call a referenced type from inside `module`.
    ///
    /// Returns the empty string for anything the emitter does not name: a
    /// primitive, which `types.zig` maps on its own, and a reference out of
    /// the compiled surface, which becomes `std.json.Value` rather than a
    /// dangling name.
    fn resolve(
        self: *Emitter,
        module: *Module,
        type_ref: codemodel.TypeRef,
        shape: names.Shape,
    ) Error![]const u8 {
        if (types.primitiveType(type_ref.name) != null) return "";

        // Checked before `declared`, which holds only what this package
        // emits: a type the base package provides is in the model and not in
        // `declared`, which is exactly what an unreachable type looks like.
        if (self.isExternal(type_ref.name)) {
            module.uses_base = true;
            return std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                base_alias,
                try names.fullType(self.arena, type_ref.name, shape),
            });
        }

        if (!self.declared.contains(type_ref.name)) {
            module.uses_std = true;
            return "";
        }

        const parsed: QualifiedName = .parse(type_ref.name);
        if (std.mem.eql(u8, parsed.namespace().text, module.namespace)) {
            return names.localType(self.arena, type_ref.name, shape);
        }
        const other = try names.module(self.arena, parsed.namespace());
        try module.imports.put(self.arena, other, {});
        return names.fullType(self.arena, type_ref.name, shape);
    }

    /// Whether the base package declares `qualified`, so this one refers to
    /// it rather than emitting it.
    fn isExternal(self: *const Emitter, qualified: []const u8) bool {
        const base = self.options.base orelse return false;
        return base.provides.contains(qualified);
    }

    /// A claim is identified by both the declaration's kind and its schema
    /// name: two different declarations may share a name in CSDL (they live in
    /// separate symbol spaces there), but they cannot share one in Zig.
    fn claim(
        self: *Emitter,
        module: *Module,
        local: []const u8,
        kind: []const u8,
        source: []const u8,
    ) Error!void {
        const origin = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ kind, source });
        try self.registry.claim(self.arena, module.name, local, origin);
    }

    fn typeDefinition(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        definition: *const codemodel.TypeDefinition,
    ) Error!void {
        const local = try names.localType(self.arena, definition.name, .read);
        try self.claim(module, local, "type definition", definition.name);

        try w.writeByte('\n');
        try docs(w, "", definition.docs);
        try w.print("pub const {f} = {s};\n", .{
            identifiers.fmt(local),
            types.elementType(definition.underlying_type, ""),
        });
    }

    fn enumType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        enum_type: *const codemodel.EnumType,
    ) Error!void {
        const local = try names.localType(self.arena, enum_type.name, .read);
        try self.claim(module, local, "enum", enum_type.name);

        // An explicit value on any member makes the whole enum an integer
        // enum, so the values the schema chose are the values Zig uses.
        var tag: ?[]const u8 = null;
        for (enum_type.members) |member| {
            if (member.value != null) tag = "(i64)";
        }

        try w.writeByte('\n');
        try docs(w, "", enum_type.docs);
        try w.print("pub const {f} = enum{s} {{\n", .{ identifiers.fmt(local), tag orelse "" });

        var declares_fallback = false;
        for (enum_type.members) |member| {
            if (std.mem.eql(u8, member.name, core_open_enum_fallback)) declares_fallback = true;
            try docs(w, "    ", member.docs);
            if (member.value) |value| {
                try w.print("    {f} = {d},\n", .{ names.enumMember(member.name), value });
            } else {
                try w.print("    {f},\n", .{names.enumMember(member.name)});
            }
        }
        if (!declares_fallback) {
            try w.print(
                \\
                \\    /// A value this package's schema version does not name.
                \\    {s}{s},
                \\
            , .{
                core_open_enum_fallback,
                if (tag == null) "" else " = -1",
            });
        }

        try w.writeAll(
            \\
            \\    const open = core.OpenEnum(@This());
            \\    pub const jsonParse = open.jsonParse;
            \\    pub const jsonParseFromValue = open.jsonParseFromValue;
            \\};
            \\
        );
    }

    /// A struct field, resolved down to the text that will be written.
    ///
    /// Fields are collected before any of them is emitted because a derived
    /// type may redeclare one of its base's properties, and the emitter has
    /// to keep the last declaration while leaving the field where the base
    /// put it.
    const Field = struct {
        /// The wire name, which is also the Zig field name.
        name: []const u8,
        type_text: []const u8,
        docs: codemodel.Docs = .{},
        /// Whether this field reads an empty string as absent, which is what
        /// decides whether its struct needs a parser of its own.
        empty_is_absent: bool = false,

        /// What the field is worth when the caller does not set it, which
        /// follows from its type: an optional is null, a `Nullable` is
        /// absent, and anything else has to be supplied.
        fn default(self: Field) []const u8 {
            if (std.mem.startsWith(u8, self.type_text, "?")) return " = null";
            if (std.mem.startsWith(u8, self.type_text, types.core_prefix ++ ".Nullable(")) {
                return " = .absent";
            }
            return "";
        }
    };

    const Fields = struct {
        list: std.ArrayList(Field) = .empty,
        index: std.StringHashMapUnmanaged(usize) = .empty,

        fn put(self: *Fields, arena: std.mem.Allocator, value: Field) Error!void {
            const entry = try self.index.getOrPut(arena, value.name);
            if (entry.found_existing) {
                self.list.items[entry.value_ptr.*] = value;
                return;
            }
            entry.value_ptr.* = self.list.items.len;
            try self.list.append(arena, value);
        }
    };

    fn complexType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        complex: *const codemodel.ComplexType,
    ) Error!void {
        const local = try names.localType(self.arena, complex.name, .read);
        try self.claim(module, local, "complex type", complex.name);

        var fields: Fields = .{};
        defer fields.index.deinit(self.arena);

        var open = false;
        const chain = try self.complexChain(complex.name);
        for (chain.items) |level| {
            if (level.additional_properties or level.dynamic_properties != null) open = true;
            try self.collectProperties(module, &fields, level.properties, null);
            try self.collectNavProperties(module, &fields, level.navigation_properties);
        }

        const bound = try self.collectActions(module, chain.items);
        try self.structType(w, local, complex.docs, fields.list.items, .{
            .open = open,
            .actions = bound,
        });

        // A structure nothing can write needs no shape to write it in, and
        // an empty one would only be a trap: a caller could construct it and
        // watch the service reject the PATCH.
        if (!try self.writable.readOnly(self.arena, complex.name) and
            try self.hasWritable(complex.name, .update))
        {
            try self.writeShape(w, module, complex.name, complex.docs, chain.items, .update, open);
        }
    }

    fn entityType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        entity: *const codemodel.EntityType,
    ) Error!void {
        const local = try names.localType(self.arena, entity.name, .read);
        try self.claim(module, local, "entity type", entity.name);

        var fields: Fields = .{};
        defer fields.index.deinit(self.arena);

        const chain = try self.entityChain(entity.name);
        var must_have_id = false;
        var must_have_type = false;
        for (chain.items) |level| {
            must_have_id = must_have_id or level.must_have_id;
            must_have_type = must_have_type or level.must_have_type;
        }

        // A resource is identified by these, and `redfish_core` recognizes an
        // entity by the presence of the id field, so they lead. All three are
        // optional: an event, a registry document and an action response all
        // name their type and carry no id, because none of them lives at a URI.
        if (must_have_id) {
            try fields.put(self.arena, .{
                .name = "@odata.id",
                .type_text = "?" ++ types.core_prefix ++ ".ODataId",
                .docs = .{ .description = "Where the resource lives." },
            });
            try fields.put(self.arena, .{
                .name = "@odata.etag",
                .type_text = "?" ++ types.core_prefix ++ ".ODataETag",
                .docs = .{ .description = "The version of the resource this value was read at." },
            });
        }
        if (must_have_type) {
            try fields.put(self.arena, .{
                .name = "@odata.type",
                .type_text = "?[]const u8",
                .docs = .{ .description = "The schema version the service implements." },
            });
        }
        if (must_have_id) try self.pendingSettings(module, &fields);

        for (chain.items) |level| {
            try self.collectProperties(module, &fields, level.properties, null);
            try self.collectNavProperties(module, &fields, level.navigation_properties);
        }

        try self.structType(w, local, entity.docs, fields.list.items, .{});

        // A resource says for itself whether it takes a PATCH or a POST;
        // `Capabilities.*Restrictions` on the collection holding it is where
        // the compiler read that from.
        var updatable = false;
        var creatable = false;
        for (chain.items) |level| {
            updatable = updatable or level.updatable;
            creatable = creatable or level.creatable;
        }
        if (updatable and try self.anyWritable(chain.items, .update)) {
            try self.writeShape(w, module, entity.name, entity.docs, chain.items, .update, false);
        }
        if (creatable and try self.anyWritable(chain.items, .create)) {
            try self.writeShape(w, module, entity.name, entity.docs, chain.items, .create, false);
        }

        for (entity.excerpt_copies) |copy| {
            try self.excerptType(w, module, entity, chain.items, copy);
        }
    }

    /// The shape a link inlines instead of following.
    ///
    /// An excerpt is a projection of the resource, not a resource: it has no
    /// identity of its own, so it gets neither the `@odata` fields nor the
    /// links.
    fn excerptType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        entity: *const codemodel.EntityType,
        chain: []const *const codemodel.EntityType,
        copy: codemodel.ExcerptCopy,
    ) Error!void {
        const local = try names.localType(self.arena, entity.name, .{ .excerpt = copy });
        try self.claim(module, local, "excerpt of entity type", entity.name);

        var fields: Fields = .{};
        defer fields.index.deinit(self.arena);
        for (chain) |level| {
            try self.collectProperties(module, &fields, level.properties, copy);
        }

        try self.structType(w, local, entity.docs, fields.list.items, .{});
    }

    // -- Actions ------------------------------------------------------------

    /// An action as the structure that offers it sees it: the property the
    /// service advertises it under, the argument struct to POST, and what
    /// comes back.
    const Binding = struct {
        action: codemodel.Action,
        /// The wire name, `#Chassis.Reset`.
        property: []const u8,
        /// The Zig method, `reset`.
        method: []const u8,
        parameters: []const u8,
        result: []const u8,
    };

    /// Where an action's argument struct lives.
    ///
    /// The namespace that declares the action, which for an OEM action is not
    /// the namespace of the resource it is bound to: `NvidiaChassis` declares
    /// `Reset` and binds it to `Chassis.Actions`.
    fn actionQualified(self: *Emitter, action: codemodel.Action) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{
            action.namespace,
            try names.actionType(self.arena, action),
        });
    }

    /// The struct a client fills in to invoke an action.
    ///
    /// It is a write payload like any other, so the same rules apply: a
    /// parameter of a type the service will not accept is left out, and what
    /// the action requires is not optional.
    fn actionType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        action: *const codemodel.Action,
    ) Error!void {
        const local = try names.actionType(self.arena, action.*);
        try self.claim(module, local, "action", try self.actionQualified(action.*));

        var fields: Fields = .{};
        defer fields.index.deinit(self.arena);

        for (action.parameters) |parameter| {
            if (try self.writable.readOnly(self.arena, parameter.type.name)) continue;

            // A parameter naming a resource is a pointer to one, not a copy:
            // the client sends the `@odata.id` it already has.
            //
            // A complex parameter is sent, so it takes the write shape --
            // unless there is none, because nothing in the type is writable
            // by the property rules. The parameter still has to be sent, so
            // it falls back to the read shape, which names the same members.
            const named = if (parameter.type.kind == .entity)
                types.core_prefix ++ ".Reference"
            else if (self.model.complexType(parameter.type.name) != null and
                try self.hasWritable(parameter.type.name, .update))
                try self.resolve(module, parameter.type, .update)
            else
                try self.resolve(module, parameter.type, .read);

            try fields.put(self.arena, .{
                .name = parameter.name,
                .type_text = try types.parameterType(self.arena, parameter, named),
                .docs = parameter.docs,
            });
        }

        try self.structType(w, local, .{
            .description = try std.fmt.allocPrint(
                self.arena,
                "Arguments to `{s}.{s}`.",
                .{ action.namespace, action.name },
            ),
            .long_description = action.docs.description,
            .deprecated = action.docs.deprecated,
        }, fields.list.items, .{ .direction = .write });
    }

    /// The actions an `Actions` structure offers, prepared for emission.
    ///
    /// An action bound to a base type is offered by the derived one, for the
    /// same reason a base type's properties are copied in.
    fn collectActions(
        self: *Emitter,
        module: *Module,
        chain: []const *const codemodel.ComplexType,
    ) Error![]const Binding {
        var bound: std.ArrayList(Binding) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.arena);

        for (chain) |level| {
            for (try self.model.actionsFor(self.arena, level.name)) |action| {
                const property = try std.fmt.allocPrint(self.arena, "#{s}.{s}", .{
                    action.namespace,
                    action.name,
                });
                if ((try seen.getOrPut(self.arena, property)).found_existing) continue;

                // An action with no declared return type may still answer with
                // a body. `void` would fail to parse one; a JSON value cannot.
                const result = if (action.return_type) |returns|
                    try types.returnType(
                        self.arena,
                        returns,
                        try self.resolve(module, returns, .read),
                    )
                else blk: {
                    module.uses_std = true;
                    break :blk types.unknown_type;
                };

                // The generated method takes an allocator, so a module with
                // any action needs `std` whether or not anything in it fell
                // back to `std.json.Value`.
                module.uses_std = true;

                try bound.append(self.arena, .{
                    .action = action,
                    .property = property,
                    .method = try names.method(self.arena, action.name),
                    .parameters = try self.resolveAction(module, action),
                    .result = result,
                });
            }
        }
        return bound.toOwnedSlice(self.arena);
    }

    /// What to call an action's argument struct from inside `module`.
    fn resolveAction(self: *Emitter, module: *Module, action: codemodel.Action) Error![]const u8 {
        const local = try names.actionType(self.arena, action);
        if (std.mem.eql(u8, action.namespace, module.namespace)) return local;

        const qualified = try self.actionQualified(action);
        const other = try names.module(self.arena, QualifiedName.parse(qualified).namespace());
        if (self.isExternal(qualified)) {
            module.uses_base = true;
            return std.fmt.allocPrint(self.arena, "{s}.{f}.{f}", .{
                base_alias,
                identifiers.fmt(other),
                identifiers.fmt(local),
            });
        }
        try module.imports.put(self.arena, other, {});
        return std.fmt.allocPrint(self.arena, "{f}.{f}", .{
            identifiers.fmt(other),
            identifiers.fmt(local),
        });
    }

    /// The method that invokes an action.
    ///
    /// There is no flattened-argument variant. The reference generator emits
    /// one when an action has few enough parameters, because a Rust caller
    /// cannot omit struct fields; a Zig caller can, so the struct is the
    /// friendlier form at every size.
    fn actionMethod(self: *Emitter, w: *std.Io.Writer, binding: Binding) Error!void {
        try w.writeByte('\n');
        try docs(w, "    ", binding.action.docs);
        try w.print(
            \\    ///
            \\    /// Returns `error.ActionNotSupported` if the service did not
            \\    /// advertise this action on the resource.
            \\    pub fn {0f}(
            \\        self: @This(),
            \\        gpa: std.mem.Allocator,
            \\        transport: *{1s}.BmcTransport,
            \\        params: {2s},
            \\    ) !{1s}.Owned({1s}.ModificationResponse({3s})) {{
            \\        const target = self.{4f} orelse return error.ActionNotSupported;
            \\        return {1s}.bmc.invokeAction(gpa, transport, target, params);
            \\    }}
            \\
        , .{
            identifiers.fmt(binding.method),
            types.core_prefix,
            binding.parameters,
            binding.result,
            names.field(binding.property),
        });
        _ = self;
    }

    /// Which payload a write shape is for.
    const Payload = enum {
        /// A PATCH body. Nothing is mandatory, because a PATCH that sends
        /// only the property it means to change is the whole point.
        update,
        /// A POST body. What the service demands on create is mandatory,
        /// because the request is rejected without it.
        create,

        fn shape(self: Payload) names.Shape {
            return switch (self) {
                .update => .update,
                .create => .create,
            };
        }
    };

    /// The shape a client fills in to change or create a resource.
    ///
    /// It is not the read shape with everything made optional: a property the
    /// service will not accept is left out entirely, so a caller cannot write
    /// a PATCH that was never going to work.
    fn writeShape(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *Module,
        qualified: []const u8,
        documentation: codemodel.Docs,
        chain: anytype,
        payload: Payload,
        open: bool,
    ) Error!void {
        const local = try names.localType(self.arena, qualified, payload.shape());
        try self.claim(module, local, switch (payload) {
            .update => "update shape of",
            .create => "create shape of",
        }, qualified);

        var fields: Fields = .{};
        defer fields.index.deinit(self.arena);
        for (chain) |level| {
            try self.collectWritable(module, &fields, level.properties, payload);
        }

        try self.structType(w, local, .{
            .description = try std.fmt.allocPrint(self.arena, "What a client may {s} of `{s}`.", .{
                switch (payload) {
                    .update => "change",
                    .create => "supply when creating an instance",
                },
                qualified,
            }),
            .long_description = documentation.description,
            .deprecated = documentation.deprecated,
        }, fields.list.items, .{ .open = open, .direction = .write });
    }

    /// Whether a write shape for `qualified` would have any fields at all.
    ///
    /// It can fail to: a complex type that holds only links is writable by
    /// the permission rules — a link is a way in — but write shapes leave
    /// links out, so what is left is an empty struct. Emitting one would be
    /// worse than emitting nothing, because a caller could construct it and
    /// only find out from the service that the PATCH said nothing.
    ///
    /// The answer recurses, since a property counts only if the shape *it*
    /// names is itself worth emitting.
    fn hasWritable(self: *Emitter, qualified: []const u8, payload: Payload) Error!bool {
        const key = try std.fmt.allocPrint(self.arena, "{t} {s}", .{ payload, qualified });
        if (self.write_shapes.get(key)) |cached| return cached;

        // A type reached from itself contributes nothing on its own: if
        // anything else in it is writable that answer stands without this
        // one, and if nothing is, the recursion has to end somewhere.
        if (self.in_progress.contains(key)) return false;
        try self.in_progress.put(self.arena, key, {});
        defer _ = self.in_progress.remove(key);

        const chain = try self.complexChain(qualified);
        var any = try self.anyWritable(chain.items, payload);

        // An open type is never empty to write: its shape carries the
        // members the schema does not name, which is the whole point of a
        // vendor extension.
        if (!any) for (chain.items) |level| {
            if (level.additional_properties or level.dynamic_properties != null) {
                any = true;
                break;
            }
        };

        try self.write_shapes.put(self.arena, key, any);
        return any;
    }

    /// Whether any level of an inheritance chain contributes a write field.
    ///
    /// Entities and complex types have different chain element types but the
    /// same rule, so this takes whatever has `properties`.
    fn anyWritable(self: *Emitter, levels: anytype, payload: Payload) Error!bool {
        for (levels) |level| {
            for (level.properties) |property| {
                const required = payload == .create and property.required_on_create;
                if (!required and !try self.writable.propertyWritable(self.arena, property)) {
                    continue;
                }
                if (self.model.complexType(property.type.name) != null and
                    !try self.hasWritable(property.type.name, payload)) continue;
                return true;
            }
        }
        return false;
    }

    /// Adds the properties a client may send.
    ///
    /// Links are not among them. A navigation property is a link the service
    /// owns; changing one is a different operation from changing a value, and
    /// the reference generator leaves them out of write shapes too.
    fn collectWritable(
        self: *Emitter,
        module: *Module,
        fields: *Fields,
        properties: []const codemodel.Property,
        payload: Payload,
    ) Error!void {
        for (properties) |property| {
            const required = payload == .create and property.required_on_create;
            if (!required and !try self.writable.propertyWritable(self.arena, property)) {
                continue;
            }

            // Only a complex type has a shape of its own to write. An enum,
            // an alias and a primitive are written exactly as they are read.
            const complex = self.model.complexType(property.type.name) != null;

            // A complex type with nothing writable in it has no write shape
            // to name, so the property that holds it has nothing to say.
            if (complex and !try self.hasWritable(property.type.name, payload)) continue;

            const shape: names.Shape = if (complex) .update else .read;
            const named = try self.resolve(module, property.type, shape);
            const type_text = try types.propertyType(
                self.arena,
                property,
                named,
                if (required) .write_required else .write,
            );
            try fields.put(self.arena, .{
                .name = property.name,
                .type_text = type_text,
                .docs = property.docs,
            });
        }
    }

    /// Whether a struct is what the service sends or what the client does.
    const Direction = enum { read, write };

    /// Everything about a struct that is not its name, its docs or its
    /// fields. Four callers emit structs and each varies a different part of
    /// this, which is more than a positional argument list carries readably.
    const Body = struct {
        /// The schema lets the service add members, so the struct keeps what
        /// it cannot name.
        open: bool = false,
        direction: Direction = .read,
        /// Actions the resource offers through this structure.
        actions: []const Binding = &.{},
    };

    fn structType(
        self: *Emitter,
        w: *std.Io.Writer,
        local: []const u8,
        documentation: codemodel.Docs,
        fields: []const Field,
        body: Body,
    ) Error!void {
        const open = body.open;
        const direction = body.direction;
        try w.writeByte('\n');
        try docs(w, "", documentation);
        try w.print("pub const {f} = struct {{\n", .{identifiers.fmt(local)});
        for (fields) |field| {
            try docs(w, "    ", field.docs);
            try w.print("    {f}: {s}{s},\n", .{
                names.field(field.name),
                field.type_text,
                field.default(),
            });
        }
        for (body.actions) |binding| {
            try docs(w, "    ", binding.action.docs);
            try w.print("    {f}: ?{s}.Action({s}, {s}) = null,\n", .{
                names.field(binding.property),
                types.core_prefix,
                binding.parameters,
                binding.result,
            });
        }
        if (open) {
            try w.print(
                \\
                \\    /// {0s}
                \\    {1s}: {2s}.AdditionalProperties = .{{}},
                \\
            , .{
                switch (direction) {
                    .read => "Whatever the service sent that this schema version does not name.",
                    .write => "Members to send that this schema version does not name.",
                },
                extras_field,
                types.core_prefix,
            });
        }
        switch (direction) {
            .read => if (open) try w.print(
                \\
                \\    const open = {0s}.OpenStruct(@This());
                \\    pub const jsonParse = open.jsonParse;
                \\    pub const jsonParseFromValue = open.jsonParseFromValue;
                \\    pub const jsonStringify = open.jsonStringify;
                \\
            , .{types.core_prefix}) else if (emptyIsAbsent(fields)) try w.print(
                \\
                \\    const closed = {0s}.ClosedStruct(@This());
                \\    pub const jsonParse = closed.jsonParse;
                \\    pub const jsonParseFromValue = closed.jsonParseFromValue;
                \\
            , .{types.core_prefix}),
            // Every field of a payload can leave itself out, whether the
            // shape is open or not.
            .write => try w.print(
                \\
                \\    pub const jsonStringify = {0s}.Payload(@This()).jsonStringify;
                \\
            , .{types.core_prefix}),
        }
        for (body.actions) |binding| try self.actionMethod(w, binding);
        try w.writeAll("};\n");
    }

    /// Whether any field of a struct reads an empty string as absent.
    ///
    /// Only a struct that *declares* one needs a parser: `std.json` asks a
    /// nested type to parse itself, so a struct that merely contains one
    /// inherits the tolerance without saying anything. That is the difference
    /// between about ninety parsers and about nineteen hundred.
    fn emptyIsAbsent(fields: []const Field) bool {
        for (fields) |field| if (field.empty_is_absent) return true;
        return false;
    }

    /// Whether a read of this property reads an empty string as absent.
    ///
    /// The type has to be resolved through any `TypeDefinition` first:
    /// `Chassis.UUID` is declared as `Resource.UUID`, which is an alias for
    /// `Edm.Guid`, and it is the property this whole rule exists for.
    /// Aliases are always of a primitive, so one hop is all there is.
    fn readsEmptyAsAbsent(self: *const Emitter, type_ref: codemodel.TypeRef) bool {
        // A collection's empty string is a member the service said exists,
        // which is not the same statement as a property it does not have.
        if (type_ref.collection) return false;

        const name = if (self.model.typeDefinition(type_ref.name)) |alias|
            alias.underlying_type.name
        else
            type_ref.name;
        return types.isFormattedScalar(name);
    }

    /// Adds a level's structural properties, filtered by what the shape shows.
    ///
    /// A write-only property is never in a read shape -- the service will not
    /// send it, and a field that is always null is worse than no field. An
    /// excerpt-only property is the mirror image: it exists only in the
    /// projection, so it is dropped unless one is being written.
    fn collectProperties(
        self: *Emitter,
        module: *Module,
        fields: *Fields,
        properties: []const codemodel.Property,
        excerpt: ?codemodel.ExcerptCopy,
    ) Error!void {
        for (properties) |property| {
            if (property.permissions == .write) continue;
            if (excerpt) |copy| {
                if (!property.inExcerpt(copy)) continue;
            } else if (property.excerpt_only) continue;

            const named = try self.resolve(module, property.type, .read);
            const type_text = try types.propertyType(self.arena, property, named, .read);
            try fields.put(self.arena, .{
                .name = property.name,
                .type_text = type_text,
                .docs = property.docs,
                .empty_is_absent = self.readsEmptyAsAbsent(property.type),
            });
        }
    }

    fn collectNavProperties(
        self: *Emitter,
        module: *Module,
        fields: *Fields,
        properties: []const codemodel.NavProperty,
    ) Error!void {
        for (properties) |property| {
            if (property.permissions == .write) continue;

            const shape: names.Shape = if (property.excerpt_copy) |copy|
                .{ .excerpt = copy }
            else
                .read;
            const named = try self.resolve(module, property.type, shape);
            const type_text = try types.navPropertyType(self.arena, property, named);
            try fields.put(self.arena, .{
                .name = property.name,
                .type_text = type_text,
                .docs = property.docs,
            });

            if (property.type.collection) try self.collectionAnnotations(fields, property.name);

            // A resource collection is the one shape services page in two
            // different ways; see `resourceCollectionNextLink`.
            if (property.type.collection and std.mem.eql(u8, property.name, "Members")) {
                try self.resourceCollectionNextLink(fields);
            }
        }
    }

    /// The second, non-conformant place a service puts a collection's next
    /// page.
    ///
    /// DSP0266 says a resource collection pages through
    /// `Members@odata.nextLink`, annotating the property that was truncated.
    /// OData v4 also defines a bare top-level `@odata.nextLink`, for a
    /// response that *is* a collection rather than a resource holding one.
    ///
    /// Redfish collections are the latter, so the annotated form is correct --
    /// and it is not the one DMTF publishes. Of the 3,966 recorded mockups,
    /// **none** uses `Members@odata.nextLink` and eight use the bare form, all
    /// of them log entry collections, which is exactly the resource most
    /// likely to be paged in the field.
    ///
    /// Reading only the conformant spelling would therefore page none of the
    /// examples the specification's own authors publish. Both are emitted, and
    /// `core.Walker` accepts either.
    ///
    /// Only a resource collection gets this. The bare annotation names no
    /// property, so on a resource with several collections there would be no
    /// saying which it paged; `Members` is what makes a resource a collection,
    /// and a resource collection has just the one.
    fn resourceCollectionNextLink(self: *Emitter, fields: *Fields) Error!void {
        try fields.put(self.arena, .{
            .name = "@odata.nextLink",
            .type_text = "?" ++ types.core_prefix ++ ".ODataId",
            .docs = .{ .description = "The next page of `Members`, spelled the way OData spells it for a response that is itself a collection. Services use this in place of `Members@odata.nextLink`; read both." },
        });
    }

    /// The link to a resource's *pending* settings.
    ///
    /// This is the whole write path for a resource that does not take a PATCH
    /// directly. `Bios` is the clearest case: its `Attributes` are read-only on
    /// the resource itself, and a client that PATCHes them there is either
    /// refused or silently ignored. What it must PATCH instead is the URI in
    /// `@Redfish.Settings.SettingsObject`, which the service applies at the
    /// next reset. Without this field the generated `Bios` parses perfectly and
    /// gives a caller no way to reach the only writable copy of itself.
    ///
    /// Like the collection annotations, this annotates a resource rather than
    /// being a property of one, so no entity type declares it and the emitter
    /// has to know it exists. DMTF's own mockups carry it 22 times, on `Bios`,
    /// `EthernetInterface`, `MemoryChunks` and `AutomationInstrumentation`.
    ///
    /// Every resource gets it, not those four. `RedfishExtensions_v1.xml`
    /// declares the term with no `AppliesTo`, so any resource may carry it, and
    /// which ones defer their writes is an implementation's choice: real BMCs
    /// apply it to managers, network device functions and storage controllers
    /// that DMTF's examples never show. Restricting the field to the types seen
    /// carrying it in a corpus is the `features.toml` mistake again.
    ///
    /// A model that does not declare `Settings.Settings` -- an OEM bundle
    /// compiled on its own -- gets no field rather than a broken reference.
    fn pendingSettings(self: *Emitter, module: *Module, fields: *Fields) Error!void {
        const term = "Settings.Settings";
        if (!self.declared.contains(term)) return;

        const named = try self.resolve(module, .{ .name = term }, .read);
        if (named.len == 0) return;

        try fields.put(self.arena, .{
            .name = "@Redfish.Settings",
            .type_text = try std.fmt.allocPrint(self.arena, "?{s}", .{named}),
            .docs = .{ .description = "The pending settings for this resource. PATCH `SettingsObject` rather than the resource itself; the service applies the result on the schedule this names." },
        });
    }

    /// The two OData annotations a service applies to a collection it returns.
    ///
    /// CSDL cannot declare these, because they annotate a property rather than
    /// being one, so nothing in the schema says they exist -- and a struct
    /// without them silently drops what they carry. `@odata.count` is dropped
    /// 882 times by DMTF's own recorded mockups.
    ///
    /// `@odata.nextLink` matters more than the count does, and no recorded
    /// payload can show it: mockups are single-page snapshots, while DSP0266
    /// requires the annotation exactly when a service has *not* returned every
    /// member. Without a field for it a client reads page one of a log and
    /// cannot tell that from having read the whole log.
    ///
    /// Every collection-valued link gets both, rather than an allowlist of the
    /// ones seen paginated. Which collections a service pages is its choice,
    /// not the schema's, and an unreferenced field costs a consumer nothing.
    fn collectionAnnotations(self: *Emitter, fields: *Fields, property: []const u8) Error!void {
        try fields.put(self.arena, .{
            .name = try std.fmt.allocPrint(self.arena, "{s}@odata.count", .{property}),
            .type_text = "?i64",
            .docs = .{ .description = try std.fmt.allocPrint(
                self.arena,
                "How many members `{s}` has in total, which is not how many this response carries.",
                .{property},
            ) },
        });
        try fields.put(self.arena, .{
            .name = try std.fmt.allocPrint(self.arena, "{s}@odata.nextLink", .{property}),
            .type_text = "?" ++ types.core_prefix ++ ".ODataId",
            .docs = .{ .description = try std.fmt.allocPrint(
                self.arena,
                "The next page of `{s}`. Present only when this response left members out.",
                .{property},
            ) },
        });
    }

    /// A type's inheritance chain, base first, so a derived declaration
    /// overwrites the one it narrows.
    ///
    /// Zig has no inheritance and `std.json` has no flattening, so a base
    /// type's properties are copied into the derived struct rather than
    /// nested under it. The wire has no nesting either -- Rust reaches the
    /// same layout with `#[serde(flatten)]`.
    fn entityChain(
        self: *Emitter,
        name: []const u8,
    ) Error!std.ArrayList(*const codemodel.EntityType) {
        var chain: std.ArrayList(*const codemodel.EntityType) = .empty;
        var current: ?[]const u8 = name;
        while (current) |qualified| {
            if (chain.items.len >= chain_limit) break;
            const found = self.model.entityType(qualified) orelse break;
            try chain.append(self.arena, found);
            current = found.base;
        }
        std.mem.reverse(*const codemodel.EntityType, chain.items);
        return chain;
    }

    fn complexChain(
        self: *Emitter,
        name: []const u8,
    ) Error!std.ArrayList(*const codemodel.ComplexType) {
        var chain: std.ArrayList(*const codemodel.ComplexType) = .empty;
        var current: ?[]const u8 = name;
        while (current) |qualified| {
            if (chain.items.len >= chain_limit) break;
            const found = self.model.complexType(qualified) orelse break;
            try chain.append(self.arena, found);
            current = found.base;
        }
        std.mem.reverse(*const codemodel.ComplexType, chain.items);
        return chain;
    }

    // -- Shared pieces ------------------------------------------------------

    /// The do-not-edit banner, as either a top-level or an ordinary comment.
    fn banner(self: *Emitter, w: *std.Io.Writer, prefix: []const u8) Error!void {
        try w.print("{s} Generated by `{s}`. DO NOT EDIT.\n", .{ prefix, self.options.generator });
        if (self.model.package.profile) |profile| {
            try w.print("{s}\n{s} Profile: `{s}`.\n", .{ prefix, prefix, profile });
        }
    }

    fn docs(
        w: *std.Io.Writer,
        indent: []const u8,
        documentation: codemodel.Docs,
    ) Error!void {
        if (documentation.description) |text| try comment(w, indent, text);
        if (documentation.long_description) |text| {
            if (documentation.description != null) try w.print("{s}///\n", .{indent});
            try comment(w, indent, text);
        }
        if (documentation.deprecated) |deprecation| {
            if (documentation.description != null or documentation.long_description != null) {
                try w.print("{s}///\n", .{indent});
            }
            if (deprecation.version) |version| {
                try w.print("{s}/// Deprecated in {s}.\n", .{ indent, version });
            } else {
                try w.print("{s}/// Deprecated.\n", .{indent});
            }
            if (deprecation.description) |text| try comment(w, indent, text);
        }
    }
};

const core_open_enum_fallback = "UnsupportedValue";

/// The field an open struct collects unrecognized members into. It has to
/// match `redfish_core`'s.
const extras_field = "additional_properties";

/// How far up an inheritance chain to walk. A chain this long is a compiler
/// bug, and stopping is better than looping on a cycle.
const chain_limit = 64;

/// Writes a doc comment, one line per line of the source text.
fn comment(w: *std.Io.Writer, indent: []const u8, text: []const u8) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \r\t");
        if (trimmed.len == 0) {
            try w.print("{s}///\n", .{indent});
        } else {
            try w.print("{s}/// {s}\n", .{ indent, trimmed });
        }
    }
}

/// A package fingerprint Zig accepts and the generator reproduces.
///
/// Zig's own `zig init` picks the low half at random, which would make every
/// regeneration a diff. The name decides it here instead: the high half is
/// the checksum Zig validates, and the low half is a stable hash of the same
/// name, kept away from the two values Zig reserves.
fn fingerprint(name: []const u8) u64 {
    const checksum: u64 = std.hash.Crc32.hash(name);
    var id: u32 = @truncate(std.hash.Wyhash.hash(0, name));
    if (id == 0x00000000 or id == 0xffffffff) id = 0x52656466;
    return (checksum << 32) | id;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const package: codemodel.Package = .{
    .name = "redfish_schema_test",
    .version = "0.2.0",
    .display_name = "Redfish test schema",
    .profile = "test",
};

fn find(files: []const File, path: []const u8) ?[]const u8 {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.contents;
    }
    return null;
}

fn render(arena: std.mem.Allocator, model: Model) ![]const File {
    return emit(arena, model, .{});
}

test "a package comes with everything needed to build it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{ .package = package });

    try testing.expect(find(files, "build.zig") != null);
    try testing.expect(find(files, "build.zig.zon") != null);
    try testing.expect(find(files, "README.md") != null);
    try testing.expect(find(files, "src/root.zig") != null);
}

test "every generated file says not to edit it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{ .name = "Chassis.ChassisType", .members = &.{.{ .name = "Rack" }} }},
    });

    for (files) |file| {
        if (std.mem.endsWith(u8, file.path, ".md")) continue;
        if (std.mem.endsWith(u8, file.path, ".zon")) continue;
        try testing.expect(std.mem.indexOf(u8, file.contents, "DO NOT EDIT") != null);
    }
}

test "the manifest names the package and pins the dependency that feeds it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{ .package = package });
    const zon = find(files, "build.zig.zon").?;

    try testing.expect(std.mem.indexOf(u8, zon, ".name = .redfish_schema_test,") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".version = \"0.2.0\",") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".redfish = .{ .path = \"../..\" },") != null);
}

test "the fingerprint follows from the name, so regenerating does not change it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const once = find(try render(arena.allocator(), .{ .package = package }), "build.zig.zon").?;
    const twice = find(try render(arena.allocator(), .{ .package = package }), "build.zig.zon").?;
    try testing.expectEqualStrings(once, twice);

    // The half Zig validates is the checksum of the name.
    try testing.expectEqual(
        @as(u64, std.hash.Crc32.hash("redfish_schema_test")),
        fingerprint("redfish_schema_test") >> 32,
    );
    try testing.expect(fingerprint("a") != fingerprint("b"));
}

test "a namespace becomes a file the root re-exports" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{
            .{ .name = "Chassis.ChassisType", .members = &.{.{ .name = "Rack" }} },
            .{ .name = "Resource.State", .members = &.{.{ .name = "Enabled" }} },
        },
    });

    try testing.expect(find(files, "src/chassis.zig") != null);
    try testing.expect(find(files, "src/resource.zig") != null);

    const root = find(files, "src/root.zig").?;
    try testing.expect(std.mem.indexOf(u8, root, "pub const chassis = @import(\"chassis.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, root, "pub const resource = @import(\"resource.zig\");") != null);
}

test "the root names the resource a session starts at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var rooted = package;
    rooted.root = "ServiceRoot.ServiceRoot";

    const files = try render(arena.allocator(), .{ .package = rooted });
    const root = find(files, "src/root.zig").?;
    try testing.expect(std.mem.indexOf(u8, root, "pub const Root = service_root.ServiceRoot;") != null);
}

test "an enum keeps the wire's spelling and takes a value it does not know" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{
            .name = "Resource.State",
            .docs = .{ .description = "The known state of the resource." },
            .members = &.{
                .{ .name = "Enabled", .docs = .{ .description = "This function is enabled." } },
                .{ .name = "Absent" },
            },
        }},
    });

    try testing.expectEqualStrings(
        \\//! Namespace `Resource`.
        \\//!
        \\//! Generated by `redfish-codegen`. DO NOT EDIT.
        \\//!
        \\//! Profile: `test`.
        \\
        \\const std = @import("std");
        \\
        \\const core = @import("redfish_core");
        \\
        \\/// The known state of the resource.
        \\pub const State = enum {
        \\    /// This function is enabled.
        \\    Enabled,
        \\    Absent,
        \\
        \\    /// A value this package's schema version does not name.
        \\    UnsupportedValue,
        \\
        \\    const open = core.OpenEnum(@This());
        \\    pub const jsonParse = open.jsonParse;
        \\    pub const jsonParseFromValue = open.jsonParseFromValue;
        \\};
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    , find(files, "src/resource.zig").?);
}

test "an enum the schema numbered keeps its numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{
            .name = "Resource.Flags",
            .is_flags = true,
            .members = &.{ .{ .name = "Read", .value = 1 }, .{ .name = "Write", .value = 2 } },
        }},
    });

    const source = find(files, "src/resource.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "pub const Flags = enum(i64) {") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    Read = 1,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    UnsupportedValue = -1,") != null);
}

test "a schema that names the fallback itself is not given a second one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{
            .name = "Resource.State",
            .members = &.{ .{ .name = "Enabled" }, .{ .name = "UnsupportedValue" } },
        }},
    });

    const source = find(files, "src/resource.zig").?;
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "UnsupportedValue,"),
    );
}

test "a member Zig would read as a keyword is quoted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{
            .name = "Resource.State",
            .members = &.{ .{ .name = "null" }, .{ .name = "error" } },
        }},
    });

    const source = find(files, "src/resource.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "    @\"null\",") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    @\"error\",") != null);
}

test "a type definition becomes an alias to what it renames" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .type_definitions = &.{
            .{
                .name = "Resource.Duration",
                .underlying_type = .{ .name = "Edm.Duration", .kind = .primitive },
                .docs = .{ .description = "A duration." },
            },
            .{ .name = "Resource.Id", .underlying_type = .{ .name = "Edm.String", .kind = .primitive } },
        },
    });

    const source = find(files, "src/resource.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "/// A duration.\npub const Duration = core.Duration;") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub const Id = []const u8;") != null);
}

test "documentation comes through as doc comments, one line at a time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{
            .name = "Resource.State",
            .docs = .{
                .description = "Short.",
                .long_description = "First line.\nSecond line.",
                .deprecated = .{ .version = "v1_4_0", .description = "Use Status instead." },
            },
            .members = &.{.{ .name = "Enabled" }},
        }},
    });

    const source = find(files, "src/resource.zig").?;
    try testing.expect(std.mem.indexOf(u8, source,
        \\/// Short.
        \\///
        \\/// First line.
        \\/// Second line.
        \\///
        \\/// Deprecated in v1_4_0.
        \\/// Use Status instead.
        \\pub const State
    ) != null);
}

test "two declarations wanting one Zig name is reported, not emitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.NameCollision, render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{ .name = "Resource.State", .members = &.{.{ .name = "Enabled" }} }},
        .type_definitions = &.{
            .{ .name = "Resource.State", .underlying_type = .{ .name = "Edm.String" } },
        },
    }));
}

test "the same model renders the same package every time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const model: Model = .{
        .package = package,
        .enum_types = &.{
            .{ .name = "Chassis.ChassisType", .members = &.{.{ .name = "Rack" }} },
            .{ .name = "Resource.State", .members = &.{.{ .name = "Enabled" }} },
        },
        .type_definitions = &.{
            .{ .name = "Resource.Duration", .underlying_type = .{ .name = "Edm.Duration" } },
        },
    };

    const once = try render(arena.allocator(), model);
    const twice = try render(arena.allocator(), model);
    try testing.expectEqual(once.len, twice.len);
    for (once, twice) |left, right| {
        try testing.expectEqualStrings(left.path, right.path);
        try testing.expectEqualStrings(left.contents, right.contents);
    }
}

test "the readme says what the package is and what is in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{ .name = "Resource.State", .members = &.{.{ .name = "Enabled" }} }},
    });

    const text = find(files, "README.md").?;
    try testing.expect(std.mem.indexOf(u8, text, "# Redfish test schema") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Do not edit this package") != null);
    try testing.expect(std.mem.indexOf(u8, text, "| Enumerations | 1 |") != null);
}

test "the readme names the corpus that produced the package" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try emit(arena.allocator(), .{ .package = package }, .{ .corpora = &.{
        .{
            .name = "DMTF Redfish-Publications",
            .url = "https://github.com/DMTF/Redfish-Publications",
            .commit = "0123456789abcdef0123456789abcdef01234567",
        },
    } });

    const text = find(files, "README.md").?;
    try testing.expect(std.mem.indexOf(u8, text, "## Provenance") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "| [DMTF Redfish-Publications](https://github.com/DMTF/Redfish-Publications) " ++
            "| `0123456789abcdef0123456789abcdef01234567` |",
    ) != null);

    // The version is the thing a reader would otherwise reach for, and it
    // means nothing here, so the package has to say so rather than leave the
    // number to be believed.
    try testing.expect(std.mem.indexOf(u8, text, "version is not meaningful") != null);
}

test "a package generated from no declared corpus keeps quiet about provenance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The fixture package is generated from a checked-in CSDL file with no
    // pin behind it. An empty section headed "Provenance" would be worse than
    // none, because it reads as a corpus nobody recorded.
    const files = try render(arena.allocator(), .{ .package = package });

    const text = find(files, "README.md").?;
    try testing.expect(std.mem.indexOf(u8, text, "Provenance") == null);
}

test "a resource carries the fields that identify it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{
            .name = "Chassis.v1_25_0.Chassis",
            .docs = .{ .description = "A chassis." },
            .must_have_id = true,
            .must_have_type = true,
            .properties = &.{
                .{ .name = "Id", .type = .{ .name = "Edm.String" }, .required = true, .nullable = false },
                .{ .name = "AssetTag", .type = .{ .name = "Edm.String" } },
            },
        }},
    });

    try testing.expectEqualStrings(
        \\//! Namespace `Chassis.v1_25_0`.
        \\//!
        \\//! Generated by `redfish-codegen`. DO NOT EDIT.
        \\//!
        \\//! Profile: `test`.
        \\
        \\const std = @import("std");
        \\
        \\const core = @import("redfish_core");
        \\
        \\/// A chassis.
        \\pub const Chassis = struct {
        \\    /// Where the resource lives.
        \\    @"@odata.id": ?core.ODataId = null,
        \\    /// The version of the resource this value was read at.
        \\    @"@odata.etag": ?core.ODataETag = null,
        \\    /// The schema version the service implements.
        \\    @"@odata.type": ?[]const u8 = null,
        \\    Id: ?[]const u8 = null,
        \\    AssetTag: ?[]const u8 = null,
        \\};
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    , find(files, "src/chassis_v1_25_0.zig").?);
}

test "a base type's properties are copied in, not nested under it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Resource.Resource",
                .abstract = true,
                .properties = &.{
                    .{ .name = "Id", .type = .{ .name = "Edm.String" } },
                    .{ .name = "Name", .type = .{ .name = "Edm.String" } },
                },
            },
            .{
                .name = "Resource.Chassis",
                .base = "Resource.Resource",
                .properties = &.{
                    // Redeclared by the derived type, which narrows it.
                    .{ .name = "Name", .type = .{ .name = "Edm.String" }, .required = true, .nullable = false },
                    .{ .name = "SKU", .type = .{ .name = "Edm.String" } },
                },
            },
        },
    });

    const source = find(files, "src/resource.zig").?;
    const derived = source[std.mem.indexOf(u8, source, "pub const Chassis").?..];
    try testing.expectEqualStrings(
        \\pub const Chassis = struct {
        \\    Id: ?[]const u8 = null,
        \\    Name: ?[]const u8 = null,
        \\    SKU: ?[]const u8 = null,
        \\};
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    , derived);
}

test "a link out of the module imports the module it points at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.Chassis",
                .navigation_properties = &.{
                    .{
                        .name = "Thermal",
                        .type = .{ .name = "Thermal.Thermal", .kind = .entity },
                        .expandable = true,
                    },
                    .{
                        .name = "Drives",
                        .type = .{ .name = "Drive.Drive", .kind = .entity, .collection = true },
                    },
                },
            },
            .{ .name = "Thermal.Thermal" },
        },
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "const thermal = @import(\"thermal.zig\");") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "    Thermal: ?core.NavProperty(thermal.Thermal) = null,\n",
    ) != null);
    // `Drive` is outside the compiled surface, so the link can only be an id.
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "    Drives: ?[]const core.ReferenceLeaf = null,\n",
    ) != null);
}

test "a type outside the compiled surface becomes a plain JSON value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Chassis.Links",
            .properties = &.{
                .{ .name = "Oem", .type = .{ .name = "Resource.Oem", .kind = .complex } },
            },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "const std = @import(\"std\");") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    Oem: ?std.json.Value = null,\n") != null);
}

test "an open type keeps what the schema does not name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Resource.Oem",
            .additional_properties = true,
        }},
    });

    try testing.expectEqualStrings(
        \\//! Namespace `Resource`.
        \\//!
        \\//! Generated by `redfish-codegen`. DO NOT EDIT.
        \\//!
        \\//! Profile: `test`.
        \\
        \\const std = @import("std");
        \\
        \\const core = @import("redfish_core");
        \\
        \\pub const Oem = struct {
        \\
        \\    /// Whatever the service sent that this schema version does not name.
        \\    additional_properties: core.AdditionalProperties = .{},
        \\
        \\    const open = core.OpenStruct(@This());
        \\    pub const jsonParse = open.jsonParse;
        \\    pub const jsonParseFromValue = open.jsonParseFromValue;
        \\    pub const jsonStringify = open.jsonStringify;
        \\};
        \\
        \\/// What a client may change of `Resource.Oem`.
        \\pub const OemUpdate = struct {
        \\
        \\    /// Members to send that this schema version does not name.
        \\    additional_properties: core.AdditionalProperties = .{},
        \\
        \\    pub const jsonStringify = core.Payload(@This()).jsonStringify;
        \\};
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    , find(files, "src/resource.zig").?);
}

test "a type with dynamic properties is open too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Message.MessageArgs",
            .dynamic_properties = .{ .pattern = "^[A-Za-z]+$", .type = "Edm.String" },
        }},
    });

    const source = find(files, "src/message.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "core.OpenStruct(@This())") != null);
}

test "a closed type that declares a formatted scalar parses itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Chassis.Location",
                .properties = &.{
                    .{ .name = "PartLocation", .type = .{ .name = "Edm.String" } },
                },
            },
            .{
                .name = "Chassis.Identity",
                .properties = &.{
                    .{ .name = "UUID", .type = .{ .name = "Edm.Guid" } },
                },
            },
        },
    });

    const source = find(files, "src/chassis.zig").?;

    // The struct that names the Guid gets a parser; the one beside it does
    // not, because nothing in it can read an empty string as absent.
    try testing.expect(std.mem.indexOf(u8, source, "core.ClosedStruct(@This())") != null);
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "core.ClosedStruct(@This())"),
    );
}

test "a formatted scalar behind an alias is still a formatted scalar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `Chassis.UUID` is really declared as `Resource.UUID`, and the whole
    // rule would miss the property it exists for if the alias hid the Guid.
    const files = try render(arena.allocator(), .{
        .package = package,
        .type_definitions = &.{
            .{ .name = "Resource.UUID", .underlying_type = .{ .name = "Edm.Guid" } },
        },
        .complex_types = &.{.{
            .name = "Chassis.Identity",
            .properties = &.{
                .{ .name = "UUID", .type = .{ .name = "Resource.UUID" } },
            },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "core.ClosedStruct(@This())") != null);
}

test "a collection of formatted scalars is not an empty string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Chassis.Identity",
            .properties = &.{
                .{ .name = "UUIDs", .type = .{ .name = "Edm.Guid", .collection = true } },
            },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "ClosedStruct") == null);
}

test "an open type needs no second parser" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `OpenStruct` reads its fields through the same helpers, so a type that
    // is already open has the tolerance and would only be given it twice.
    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Chassis.Identity",
            .additional_properties = true,
            .properties = &.{
                .{ .name = "UUID", .type = .{ .name = "Edm.Guid" } },
            },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "core.OpenStruct(@This())") != null);
    try testing.expect(std.mem.indexOf(u8, source, "ClosedStruct") == null);
}

test "a write-only property is not in the shape that reads it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Session.Session",
            .properties = &.{
                .{ .name = "UserName", .type = .{ .name = "Edm.String" } },
                .{ .name = "Password", .type = .{ .name = "Edm.String" }, .permissions = .write },
            },
        }},
    });

    const source = find(files, "src/session.zig").?;
    const read = source[std.mem.indexOf(u8, source, "pub const Session =").?..std.mem.indexOf(u8, source, "pub const SessionUpdate").?];
    try testing.expect(std.mem.indexOf(u8, read, "UserName") != null);
    try testing.expect(std.mem.indexOf(u8, read, "Password") == null);

    // It is still writable, so it is in the shape that writes it.
    const update = source[std.mem.indexOf(u8, source, "pub const SessionUpdate").?..];
    try testing.expect(std.mem.indexOf(u8, update, "Password") != null);
}

test "a structure of nothing but links has no shape to write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Chassis.Chassis" }},
        .complex_types = &.{.{
            .name = "Chassis.Links",
            .navigation_properties = &.{
                .{ .name = "ContainedBy", .type = .{ .name = "Chassis.Chassis", .kind = .entity }, .expandable = true },
            },
        }},
    });

    // A link is a way in, so the permission rules call `Links` writable. But
    // write shapes leave links out, so the shape would have no fields at all
    // and a caller could only use it to send an empty PATCH.
    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "pub const Links = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, source, "LinksUpdate") == null);
}

test "a property whose own write shape is empty is left out of the one holding it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Chassis.Chassis" }},
        .complex_types = &.{
            .{
                .name = "Chassis.Outer",
                .properties = &.{
                    .{ .name = "AssetTag", .type = .{ .name = "Edm.String" }, .permissions = .read_write },
                    .{ .name = "Links", .type = .{ .name = "Chassis.Links", .kind = .complex }, .permissions = .read_write },
                },
            },
            .{
                .name = "Chassis.Links",
                .navigation_properties = &.{
                    .{ .name = "ContainedBy", .type = .{ .name = "Chassis.Chassis", .kind = .entity }, .expandable = true },
                },
            },
        },
    });

    // Naming `LinksUpdate` would not compile, since it was never emitted.
    const source = find(files, "src/chassis.zig").?;
    const start = std.mem.indexOf(u8, source, "pub const OuterUpdate").?;
    const update = source[start..][0 .. std.mem.indexOf(u8, source[start..], "\n};").? + 3];
    try testing.expect(std.mem.indexOf(u8, update, "AssetTag") != null);
    try testing.expect(std.mem.indexOf(u8, update, "Links") == null);
}

test "an excerpt is the projection a link inlines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{
            .name = "Sensor.Sensor",
            .excerpt_copies = &.{ .{}, .{ .key = "Power" } },
            .properties = &.{
                .{ .name = "Reading", .type = .{ .name = "Edm.Double" }, .excerpts = &.{""} },
                .{ .name = "PowerWatts", .type = .{ .name = "Edm.Double" }, .excerpts = &.{"Power"} },
                .{ .name = "Notes", .type = .{ .name = "Edm.String" } },
                .{ .name = "DataSourceUri", .type = .{ .name = "Edm.String" }, .excerpt_only = true, .excerpts = &.{""} },
            },
        }},
    });

    const source = find(files, "src/sensor.zig").?;
    const read = source[std.mem.indexOf(u8, source, "pub const Sensor =").?..];
    try testing.expectEqualStrings(
        \\pub const Sensor = struct {
        \\    Reading: ?f64 = null,
        \\    PowerWatts: ?f64 = null,
        \\    Notes: ?[]const u8 = null,
        \\};
        \\
        \\pub const SensorExcerpt = struct {
        \\    Reading: ?f64 = null,
        \\    PowerWatts: ?f64 = null,
        \\    DataSourceUri: ?[]const u8 = null,
        \\};
        \\
        \\pub const SensorExcerptPower = struct {
        \\    Reading: ?f64 = null,
        \\    PowerWatts: ?f64 = null,
        \\    DataSourceUri: ?[]const u8 = null,
        \\};
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    , read);
}

test "a link annotated as an excerpt copy inlines the projection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.Chassis",
                .navigation_properties = &.{.{
                    .name = "PowerSensor",
                    .type = .{ .name = "Sensor.Sensor", .kind = .entity },
                    .expandable = true,
                    .excerpt_copy = .{ .key = "Power" },
                }},
            },
            .{
                .name = "Sensor.Sensor",
                .excerpt_copies = &.{.{ .key = "Power" }},
                .properties = &.{
                    .{ .name = "PowerWatts", .type = .{ .name = "Edm.Double" }, .excerpts = &.{"Power"} },
                },
            },
        },
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "    PowerSensor: ?sensor.SensorExcerptPower = null,\n",
    ) != null);
}

test "a client is only offered the properties the service will accept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Boot.Boot",
            .properties = &.{
                .{ .name = "BootOrder", .type = .{ .name = "Edm.String", .collection = true }, .permissions = .read_write },
                .{ .name = "BootSourceOverrideTarget", .type = .{ .name = "Edm.String" }, .permissions = .read_write },
                .{ .name = "UefiTargetBootSourceOverride", .type = .{ .name = "Edm.String" }, .permissions = .read },
            },
        }},
    });

    const source = find(files, "src/boot.zig").?;
    const update = source[std.mem.indexOf(u8, source, "pub const BootUpdate").?..];
    try testing.expect(std.mem.indexOf(u8, update, "BootOrder") != null);
    try testing.expect(std.mem.indexOf(u8, update, "BootSourceOverrideTarget") != null);
    try testing.expect(std.mem.indexOf(u8, update, "UefiTargetBootSourceOverride") == null);
}

test "a structure nothing can write gets no shape to write it in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Status.Status",
            .properties = &.{
                .{ .name = "Health", .type = .{ .name = "Edm.String" }, .permissions = .read },
                .{ .name = "State", .type = .{ .name = "Edm.String" }, .permissions = .read },
            },
        }},
    });

    const source = find(files, "src/status.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "pub const Status =") != null);
    try testing.expect(std.mem.indexOf(u8, source, "StatusUpdate") == null);
}

test "a resource says for itself whether it takes a PATCH or a POST" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.Chassis",
                .updatable = true,
                .properties = &.{.{ .name = "AssetTag", .type = .{ .name = "Edm.String" }, .permissions = .read_write }},
            },
            .{
                .name = "Session.Session",
                .creatable = true,
                .properties = &.{.{ .name = "UserName", .type = .{ .name = "Edm.String" }, .permissions = .write }},
            },
            .{
                .name = "Sensor.Sensor",
                .properties = &.{.{ .name = "Reading", .type = .{ .name = "Edm.Double" }, .permissions = .read_write }},
            },
        },
    });

    try testing.expect(std.mem.indexOf(u8, find(files, "src/chassis.zig").?, "pub const ChassisUpdate") != null);
    try testing.expect(std.mem.indexOf(u8, find(files, "src/chassis.zig").?, "ChassisCreate") == null);
    try testing.expect(std.mem.indexOf(u8, find(files, "src/session.zig").?, "pub const SessionCreate") != null);
    try testing.expect(std.mem.indexOf(u8, find(files, "src/session.zig").?, "SessionUpdate") == null);
    try testing.expect(std.mem.indexOf(u8, find(files, "src/sensor.zig").?, "Update") == null);
    try testing.expect(std.mem.indexOf(u8, find(files, "src/sensor.zig").?, "Create") == null);
}

test "what a create demands is not optional, and the rest of it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{
            .name = "Session.Session",
            .updatable = true,
            .creatable = true,
            .properties = &.{
                .{ .name = "UserName", .type = .{ .name = "Edm.String" }, .permissions = .write, .required_on_create = true },
                .{ .name = "Password", .type = .{ .name = "Edm.String" }, .permissions = .write, .required_on_create = true },
                .{ .name = "SessionType", .type = .{ .name = "Edm.String" }, .permissions = .read_write },
            },
        }},
    });

    const source = find(files, "src/session.zig").?;

    const create = source[std.mem.indexOf(u8, source, "pub const SessionCreate").?..];
    try testing.expect(std.mem.indexOf(u8, create, "    UserName: []const u8,\n") != null);
    try testing.expect(std.mem.indexOf(u8, create, "    Password: []const u8,\n") != null);
    try testing.expect(std.mem.indexOf(u8, create, "    SessionType: core.Nullable([]const u8) = .absent,\n") != null);

    // A PATCH that sends only what it means to change is the whole point,
    // so nothing is mandatory in the shape that updates.
    const update = source[std.mem.indexOf(u8, source, "pub const SessionUpdate").?..std.mem.indexOf(u8, source, "pub const SessionCreate").?];
    try testing.expect(std.mem.indexOf(u8, update, "    UserName: core.Nullable([]const u8) = .absent,\n") != null);
}

test "a property that may be sent as null says so in the write shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Boot.Boot",
            .properties = &.{
                .{ .name = "AssetTag", .type = .{ .name = "Edm.String" }, .nullable = true, .permissions = .read_write },
                .{ .name = "IndicatorLED", .type = .{ .name = "Edm.String" }, .nullable = false, .permissions = .read_write },
            },
        }},
    });

    const source = find(files, "src/boot.zig").?;
    const update = source[std.mem.indexOf(u8, source, "pub const BootUpdate").?..];
    try testing.expect(std.mem.indexOf(u8, update, "    AssetTag: core.Nullable([]const u8) = .absent,\n") != null);
    try testing.expect(std.mem.indexOf(u8, update, "    IndicatorLED: ?[]const u8 = null,\n") != null);
}

test "a write shape refers to the write shape of a complex type, not its read shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{ .name = "Boot.BootSource", .members = &.{.{ .name = "Pxe" }} }},
        .complex_types = &.{
            .{
                .name = "ComputerSystem.Boot",
                .properties = &.{
                    .{ .name = "Order", .type = .{ .name = "Boot.Boot", .kind = .complex }, .permissions = .read_write },
                    .{ .name = "Source", .type = .{ .name = "Boot.BootSource", .kind = .enumeration }, .permissions = .read_write },
                },
            },
            .{
                .name = "Boot.Boot",
                .properties = &.{.{ .name = "Target", .type = .{ .name = "Edm.String" }, .permissions = .read_write }},
            },
        },
    });

    const source = find(files, "src/computer_system.zig").?;
    const update = source[std.mem.indexOf(u8, source, "pub const BootUpdate").?..];

    // A complex type has a shape of its own to write; an enum is written
    // exactly as it is read.
    try testing.expect(std.mem.indexOf(u8, update, "    Order: core.Nullable(boot.BootUpdate) = .absent,\n") != null);
    try testing.expect(std.mem.indexOf(u8, update, "    Source: core.Nullable(boot.BootSource) = .absent,\n") != null);
}

test "a collection link carries the annotations that page it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "ChassisCollection.ChassisCollection",
                .navigation_properties = &.{
                    .{ .name = "Members", .type = .{ .name = "Chassis.Chassis", .kind = .entity, .collection = true } },
                    .{ .name = "Thermal", .type = .{ .name = "Chassis.Chassis", .kind = .entity } },
                },
            },
            .{ .name = "Chassis.Chassis" },
        },
    });

    const source = find(files, "src/chassis_collection.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "@\"Members@odata.count\": ?i64 = null") != null);
    try testing.expect(std.mem.indexOf(u8, source, "@\"Members@odata.nextLink\": ?core.ODataId = null") != null);

    // A single-valued link is one resource, so there is no next page of it.
    try testing.expect(std.mem.indexOf(u8, source, "Thermal@odata") == null);

    // A resource collection also gets the bare spelling, which is the one
    // every paged mockup DMTF publishes actually uses.
    try testing.expect(std.mem.indexOf(u8, source, "@\"@odata.nextLink\": ?core.ODataId = null") != null);
}

test "only a resource collection gets the bare next link" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A collection-valued link that is not `Members`: the bare annotation
    // names no property, so there would be no saying what it paged.
    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.Chassis",
                .navigation_properties = &.{
                    .{ .name = "Drives", .type = .{ .name = "Drive.Drive", .kind = .entity, .collection = true } },
                },
            },
            .{ .name = "Drive.Drive" },
        },
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "@\"Drives@odata.nextLink\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "@\"@odata.nextLink\"") == null);
}

test "a resource points at its pending settings, and a complex type does not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Bios.Bios", .must_have_id = true }},
        .complex_types = &.{.{ .name = "Settings.Settings" }},
    });

    const bios = find(files, "src/bios.zig").?;
    try testing.expect(std.mem.indexOf(u8, bios, "@\"@Redfish.Settings\": ?settings.Settings") != null);

    // The annotation goes on resources, and a complex type is not one.
    const settings = find(files, "src/settings.zig").?;
    try testing.expect(std.mem.indexOf(u8, settings, "@Redfish.Settings") == null);
}

test "a model without the settings schema gets no settings field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An OEM bundle compiled on its own: a field would name a type that the
    // package does not contain.
    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Bios.Bios", .must_have_id = true }},
    });

    try testing.expect(std.mem.indexOf(u8, find(files, "src/bios.zig").?, "@Redfish.Settings") == null);
}

test "a write shape leaves out the links the service owns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{
            .{
                .name = "Chassis.Chassis",
                .updatable = true,
                .properties = &.{.{ .name = "AssetTag", .type = .{ .name = "Edm.String" }, .permissions = .read_write }},
                .navigation_properties = &.{.{ .name = "Thermal", .type = .{ .name = "Thermal.Thermal", .kind = .entity } }},
            },
            .{ .name = "Thermal.Thermal" },
        },
    });

    const source = find(files, "src/chassis.zig").?;
    const update = source[std.mem.indexOf(u8, source, "pub const ChassisUpdate").?..];
    try testing.expect(std.mem.indexOf(u8, update, "AssetTag") != null);
    try testing.expect(std.mem.indexOf(u8, update, "Thermal") == null);
}

test "a write shape serializes only what was set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{
            .name = "Boot.Boot",
            .properties = &.{.{ .name = "Target", .type = .{ .name = "Edm.String" }, .permissions = .read_write }},
        }},
    });

    const source = find(files, "src/boot.zig").?;
    const update = source[std.mem.indexOf(u8, source, "pub const BootUpdate").?..];
    try testing.expect(std.mem.indexOf(u8, update, "pub const jsonStringify = core.Payload(@This()).jsonStringify;") != null);
    try testing.expect(std.mem.indexOf(u8, update, "jsonParse") == null);
}

test "an action becomes a request struct, a property and a method" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .enum_types = &.{.{ .name = "Resource.ResetType", .members = &.{ .{ .name = "On" }, .{ .name = "ForceOff" } } }},
        .complex_types = &.{.{ .name = "Chassis.Actions" }},
        .actions = &.{.{
            .name = "Reset",
            .binding = "Chassis.Actions",
            .namespace = "Chassis",
            .binding_parameter = "Chassis",
            .parameters = &.{
                .{ .name = "ResetType", .type = .{ .name = "Resource.ResetType", .kind = .enumeration }, .required = true, .nullable = false },
                .{ .name = "DelaySeconds", .type = .{ .name = "Edm.Int64" }, .nullable = false },
            },
            .docs = .{ .description = "Resets the chassis." },
        }},
    });

    const source = find(files, "src/chassis.zig").?;

    // The arguments, as a payload: what the action requires is not optional.
    try testing.expect(std.mem.indexOf(u8, source, "pub const ChassisResetAction = struct {\n") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    ResetType: resource.ResetType,\n") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    DelaySeconds: ?i64 = null,\n") != null);
    try testing.expect(std.mem.indexOf(u8, source, "core.Payload(@This()).jsonStringify") != null);

    // The property, under the name the service advertises it as.
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "    @\"#Chassis.Reset\": ?core.Action(ChassisResetAction, std.json.Value) = null,\n",
    ) != null);

    // And the method that invokes it.
    try testing.expect(std.mem.indexOf(u8, source, "    pub fn reset(\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "const target = self.@\"#Chassis.Reset\" orelse return error.ActionNotSupported;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        source,
        "return core.bmc.invokeAction(gpa, transport, target, params);",
    ) != null);
}

test "an action's return type is what the method hands back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Task.Task" }},
        .complex_types = &.{.{ .name = "Chassis.Actions" }},
        .actions = &.{.{
            .name = "Reset",
            .binding = "Chassis.Actions",
            .namespace = "Chassis",
            .binding_parameter = "Chassis",
            .return_type = .{ .name = "Task.Task", .kind = .entity },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "?core.Action(ChassisResetAction, task.Task) = null,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "!core.Owned(core.ModificationResponse(task.Task))") != null);
}

test "an OEM action lands in the namespace that declares it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{ .name = "Chassis.Actions" }},
        .actions = &.{.{
            .name = "ResetToDefaults",
            .binding = "Chassis.Actions",
            .namespace = "NvidiaChassis",
            .binding_parameter = "Chassis",
        }},
    });

    // The struct is declared where the schema declares the action ...
    const declaring = find(files, "src/nvidia_chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, declaring, "pub const ChassisResetToDefaultsAction = struct {") != null);

    // ... and the resource that offers it imports it and advertises it under
    // the declaring namespace, which is what the service sends.
    const binding = find(files, "src/chassis.zig").?;
    try testing.expect(std.mem.indexOf(u8, binding, "const nvidia_chassis = @import(\"nvidia_chassis.zig\");") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        binding,
        "    @\"#NvidiaChassis.ResetToDefaults\": ?core.Action(nvidia_chassis.ChassisResetToDefaultsAction, std.json.Value) = null,\n",
    ) != null);
}

test "an action a base type is bound to is offered by the derived one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{
            .{ .name = "Chassis.v1_0_0.Actions" },
            .{ .name = "Chassis.v1_5_0.Actions", .base = "Chassis.v1_0_0.Actions" },
        },
        .actions = &.{.{
            .name = "Reset",
            .binding = "Chassis.v1_0_0.Actions",
            .namespace = "Chassis",
            .binding_parameter = "Chassis",
        }},
    });

    const source = find(files, "src/chassis_v1_5_0.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "@\"#Chassis.Reset\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn reset(") != null);
}

test "an action parameter falls back to the read shape when there is no write shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{ .name = "Metric.Definition" }},
        .complex_types = &.{
            .{ .name = "Telemetry.Actions" },
            .{
                // Read-only members and a link. The permission rules call it
                // writable -- a link is a way in -- so it is not skipped as a
                // parameter, but write shapes drop links, so it has none.
                .name = "Telemetry.MetricValue",
                .properties = &.{.{ .name = "MetricId", .type = .{ .name = "Edm.String" }, .permissions = .read }},
                .navigation_properties = &.{
                    .{ .name = "MetricDefinition", .type = .{ .name = "Metric.Definition", .kind = .entity }, .expandable = true },
                },
            },
        },
        .actions = &.{.{
            .name = "SubmitMetricReport",
            .binding = "Telemetry.Actions",
            .namespace = "Telemetry",
            .binding_parameter = "Telemetry",
            .parameters = &.{
                .{ .name = "Values", .type = .{ .name = "Telemetry.MetricValue", .kind = .complex, .collection = true } },
            },
        }},
    });

    // Naming `MetricValueUpdate` would parse and not compile.
    const source = find(files, "src/telemetry.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "MetricValueUpdate") == null);
    // A collection is written whole, so it takes `?`, not `Nullable`: there
    // is no third state between "leave it out" and "send an empty one".
    try testing.expect(std.mem.indexOf(u8, source, "Values: ?[]const ?MetricValue = null,\n") != null);
}

test "an action parameter of a type the service will not accept is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try render(arena.allocator(), .{
        .package = package,
        .complex_types = &.{
            .{ .name = "Chassis.Actions" },
            .{
                .name = "Resource.Status",
                .properties = &.{.{ .name = "Health", .type = .{ .name = "Edm.String" }, .permissions = .read }},
            },
        },
        .actions = &.{.{
            .name = "Reset",
            .binding = "Chassis.Actions",
            .namespace = "Chassis",
            .binding_parameter = "Chassis",
            .parameters = &.{
                .{ .name = "Status", .type = .{ .name = "Resource.Status", .kind = .complex } },
                .{ .name = "Target", .type = .{ .name = "Task.Task", .kind = .entity } },
            },
        }},
    });

    const source = find(files, "src/chassis.zig").?;
    const request = source[std.mem.indexOf(u8, source, "pub const ChassisResetAction").?..];
    try testing.expect(std.mem.indexOf(u8, request, "Status") == null);

    // A parameter naming a resource is a pointer to one, not a copy.
    try testing.expect(std.mem.indexOf(u8, request, "    Target: core.Nullable(core.Reference) = .absent,\n") != null);
}

// -- Building on another package ------------------------------------------

/// Renders against a base package that already declares `Resource.Status`.
fn renderOnBase(arena: std.mem.Allocator, model: Model) ![]const File {
    const set = try arena.create(std.StringHashMapUnmanaged(void));
    set.* = .empty;
    try set.put(arena, "Resource.Status", {});
    try set.put(arena, "Resource.Oem", {});

    return emit(arena, model, .{
        .base = .{
            .module = "redfish_schema_std",
            .dependency = "redfish_schema_std",
            .dependency_path = "../redfish_schema_std",
            .provides = set,
        },
    });
}

test "a type the base package declares is imported, not emitted again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try renderOnBase(arena.allocator(), .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Resource.Status",
                .properties = &.{.{ .name = "Health", .type = .{ .name = "Edm.String" } }},
            },
        },
        .entity_types = &.{.{
            .name = "Contoso.Sensor",
            .properties = &.{.{
                .name = "Status",
                .type = .{ .name = "Resource.Status", .kind = .complex },
            }},
        }},
    });

    // Nothing of the base package's is re-emitted: not the type, not the
    // module that would have held it.
    try testing.expect(find(files, "src/resource.zig") == null);

    const source = find(files, "src/contoso.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "const base = @import(\"redfish_schema_std\");") != null);
    try testing.expect(std.mem.indexOf(u8, source, "    Status: ?base.resource.Status = null,\n") != null);
    try testing.expect(std.mem.indexOf(u8, source, "@import(\"resource.zig\")") == null);
}

test "a module that needs nothing from the base package does not import it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try renderOnBase(arena.allocator(), .{
        .package = package,
        .entity_types = &.{.{
            .name = "Contoso.Sensor",
            .properties = &.{.{ .name = "Reading", .type = .{ .name = "Edm.Decimal" } }},
        }},
    });

    const source = find(files, "src/contoso.zig").?;
    try testing.expect(std.mem.indexOf(u8, source, "@import(\"redfish_schema_std\")") == null);
}

test "building on a package makes it a dependency" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const files = try renderOnBase(arena.allocator(), .{ .package = package });

    const zon = find(files, "build.zig.zon").?;
    try testing.expect(std.mem.indexOf(
        u8,
        zon,
        ".redfish_schema_std = .{ .path = \"../redfish_schema_std\" },",
    ) != null);

    const zig = find(files, "build.zig").?;
    try testing.expect(std.mem.indexOf(u8, zig, "redfish_schema_std") != null);
}

test "everything a model declares is what it provides to a package built on it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const set = try provided(arena.allocator(), .{
        .package = package,
        .complex_types = &.{.{ .name = "Resource.Status" }},
        .entity_types = &.{.{ .name = "Chassis.Chassis" }},
        .enum_types = &.{.{ .name = "Resource.Health", .members = &.{.{ .name = "OK" }} }},
    });

    try testing.expect(set.contains("Resource.Status"));
    try testing.expect(set.contains("Chassis.Chassis"));
    try testing.expect(set.contains("Resource.Health"));
    try testing.expect(!set.contains("Contoso.Sensor"));
}
