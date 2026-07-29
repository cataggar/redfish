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
};

/// Renders a model as a complete Zig package.
pub fn emit(arena: std.mem.Allocator, model: Model, options: Options) Error![]const File {
    var emitter: Emitter = .{ .arena = arena, .model = model, .options = options };
    return emitter.run();
}

/// The declarations of one namespace, which become one file.
const Module = struct {
    /// The namespace as the schema writes it: `Chassis`.
    namespace: []const u8,
    /// The module as Zig writes it: `chassis`.
    name: []const u8,
    enum_types: std.ArrayList(*const codemodel.EnumType) = .empty,
    type_definitions: std.ArrayList(*const codemodel.TypeDefinition) = .empty,

    fn isEmpty(self: Module) bool {
        return self.enum_types.items.len == 0 and self.type_definitions.items.len == 0;
    }
};

const Emitter = struct {
    arena: std.mem.Allocator,
    model: Model,
    options: Options,
    modules: std.StringArrayHashMapUnmanaged(Module) = .empty,
    registry: names.Registry = .{},

    fn run(self: *Emitter) Error![]const File {
        defer self.registry.deinit(self.arena);
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
    fn collect(self: *Emitter) Error!void {
        for (self.model.enum_types) |*enum_type| {
            const module = try self.moduleFor(enum_type.name);
            try module.enum_types.append(self.arena, enum_type);
        }
        for (self.model.type_definitions) |*definition| {
            const module = try self.moduleFor(definition.name);
            try module.type_definitions.append(self.arena, definition);
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
        try self.banner(w, "//!", null);
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
            \\    const module = b.addModule("{2s}", .{{
            \\        .root_source_file = b.path("src/root.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\        .imports = &.{{
            \\            .{{ .name = "{3s}", .module = {0f}.module("{3s}") }},
            \\        }},
            \\    }});
            \\
            \\    const tests = b.addTest(.{{ .root_module = module }});
            \\    b.step("test", "Run the package tests").dependOn(&b.addRunArtifact(tests).step);
            \\}}
            \\
        , .{
            identifiers.fmt(self.options.dependency),
            self.options.dependency,
            self.model.package.name,
            self.options.core_module,
        });
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
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "README.md",
            \\    }},
            \\}}
            \\
        , .{
            identifiers.fmt(self.model.package.name),
            self.model.package.version,
            fingerprint(self.model.package.name),
            self.options.minimum_zig_version,
            identifiers.fmt(self.options.dependency),
            self.options.dependency_path,
        });
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

        try w.writeAll("## Contents\n\n");
        try w.print("| Namespaces | {d} |\n", .{self.modules.count()});
        try w.print("| --- | --- |\n", .{});
        try w.print("| Resources | {d} |\n", .{self.model.entity_types.len});
        try w.print("| Structures | {d} |\n", .{self.model.complex_types.len});
        try w.print("| Enumerations | {d} |\n", .{self.model.enum_types.len});
        try w.print("| Aliases | {d} |\n", .{self.model.type_definitions.len});
        try w.print("| Actions | {d} |\n", .{self.model.actions.len});
        return .{ .path = "README.md", .contents = try out.toOwnedSlice() };
    }

    fn rootFile(self: *Emitter) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;
        const manifest = self.model.package;

        try w.print("//! {s}\n//!\n", .{manifest.display_name orelse manifest.name});
        try self.banner(w, "//!", null);
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

    fn moduleFile(self: *Emitter, module: *const Module) Error!File {
        var out: Writer = .init(self.arena);
        const w = &out.writer;

        try w.print("//! Namespace `{s}`.\n//!\n", .{module.namespace});
        try self.banner(w, "//!", null);
        try w.print(
            \\
            \\const core = @import("{s}");
            \\
        , .{self.options.core_module});

        for (module.type_definitions.items) |definition| {
            try self.typeDefinition(w, module, definition);
        }
        for (module.enum_types.items) |enum_type| {
            try self.enumType(w, module, enum_type);
        }

        return .{
            .path = try std.fmt.allocPrint(self.arena, "src/{s}.zig", .{module.name}),
            .contents = try out.toOwnedSlice(),
        };
    }

    /// A claim is identified by both the declaration's kind and its schema
    /// name: two different declarations may share a name in CSDL (they live in
    /// separate symbol spaces there), but they cannot share one in Zig.
    fn claim(
        self: *Emitter,
        module: *const Module,
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
        module: *const Module,
        definition: *const codemodel.TypeDefinition,
    ) Error!void {
        const local = try names.localType(self.arena, definition.name, .read);
        try self.claim(module, local, "type definition", definition.name);

        try w.writeByte('\n');
        try self.docs(w, "", definition.docs);
        try w.print("pub const {f} = {s};\n", .{
            identifiers.fmt(local),
            types.elementType(definition.underlying_type, ""),
        });
    }

    fn enumType(
        self: *Emitter,
        w: *std.Io.Writer,
        module: *const Module,
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
        try self.docs(w, "", enum_type.docs);
        try w.print("pub const {f} = enum{s} {{\n", .{ identifiers.fmt(local), tag orelse "" });

        var declares_fallback = false;
        for (enum_type.members) |member| {
            if (std.mem.eql(u8, member.name, core_open_enum_fallback)) declares_fallback = true;
            try self.docs(w, "    ", member.docs);
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

    // -- Shared pieces ------------------------------------------------------

    /// The do-not-edit banner, as either a top-level or an ordinary comment.
    fn banner(self: *Emitter, w: *std.Io.Writer, prefix: []const u8, _: ?void) Error!void {
        try w.print("{s} Generated by `{s}`. DO NOT EDIT.\n", .{ prefix, self.options.generator });
        if (self.model.package.profile) |profile| {
            try w.print("{s}\n{s} Profile: `{s}`.\n", .{ prefix, prefix, profile });
        }
    }

    fn docs(
        self: *Emitter,
        w: *std.Io.Writer,
        indent: []const u8,
        documentation: codemodel.Docs,
    ) Error!void {
        _ = self;
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
