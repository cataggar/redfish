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

//! `redfish-codegen` — compiles Redfish CSDL into a Zig package.
//!
//! The whole pipeline in one process, with no compiler on `PATH` and nothing
//! spawned:
//!
//!     XML  →  csdl.parse       one document per file
//!          →  schema_index     namespaces, aliases, inheritance
//!          →  compile          root set, traversal, annotations  →  IR
//!          →  optimize         prune what the profile cannot reach
//!          →  emit             a package, in memory
//!          →  format           `std.zig.Ast`, which is what `zig fmt` is
//!          →  disk
//!
//! Everything before the last step is a pure function of the input bytes, so
//! `--dry-run` runs all of it and writes nothing, and the fixtures test the
//! same code the CLI does.

const std = @import("std");

const codegen = @import("redfish_codegen");
const codemodel = codegen.codemodel;
const compile = codegen.compile;
const csdl = codegen.csdl;
const emit = codegen.emit;
const filter = codegen.filter;
const format = codegen.format;
const optimize = codegen.optimize;
const schema_index = codegen.schema_index;

pub const usage =
    \\redfish-codegen — compiles Redfish CSDL into a Zig package.
    \\
    \\Usage:
    \\  redfish-codegen compile <out-dir> --package-name <name> [options]
    \\  redfish-codegen compile-oem <out-dir> --package-name <name> [options]
    \\
    \\`compile` roots the surface in the standard schemas. `compile-oem` roots
    \\it in the vendor schemas given by --oem-csdl and resolves their
    \\references against the standard corpus, which contributes no roots of
    \\its own.
    \\
    \\Schemas:
    \\  --csdl <path>              A CSDL file, or a directory to read `.xml`
    \\                             from. Repeatable.
    \\  --oem-csdl <path>          As --csdl, but rooted. `compile-oem` only.
    \\
    \\Package:
    \\  --package-name <name>      Required, e.g. `redfish_schema_chassis`.
    \\  --package-version <ver>    Default `0.1.0`.
    \\  --display-name <label>
    \\  --profile <name>           Recorded in the package, for the README.
    \\  --redfish-core-path <path> Where `redfish` is, relative to the
    \\                             generated package. Default `../..`.
    \\  --base-package <name>      A package that already emits the standard
    \\                             types, e.g. `redfish_schema_std`. Its types
    \\                             are imported rather than copied.
    \\                             `compile-oem` only.
    \\  --base-package-path <path> Where it is, relative to the generated
    \\                             package. Default `../redfish_schema_std`.
    \\
    \\Surface:
    \\  --root <name>              An entity-container singleton to root from,
    \\                             usually `Service`. Repeatable.
    \\  --entity-type-pattern <p>  A type to root beyond what the singletons
    \\                             reach, e.g. `Chassis.*`. Repeatable.
    \\  --navigation-pattern <p>   Which links are followed and expandable.
    \\                             Saying nothing follows every link.
    \\                             Repeatable.
    \\  --everything               Root every type in the corpus, ignoring
    \\                             --root and --entity-type-pattern.
    \\
    \\Output:
    \\  --emit-model <path>        Also write the IR as JSON, for a fixture.
    \\  --no-optimize              Skip the pruning passes.
    \\  --no-fmt                   Write the emitter's text verbatim.
    \\  --dry-run                  Run everything; write nothing.
    \\  -h, --help                 This message.
    \\
;

/// Which corpus is allowed to root the compile.
pub const Mode = enum { compile, compile_oem };

/// What the command line asked for.
pub const Command = struct {
    mode: Mode,
    out_dir: []const u8,
    csdl_paths: []const []const u8 = &.{},
    oem_csdl_paths: []const []const u8 = &.{},

    package_name: []const u8,
    package_version: []const u8 = "0.1.0",
    display_name: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    redfish_core_path: []const u8 = "../..",
    /// A package that already emits the standard types this one refers to,
    /// so this one imports them instead of copying them. `compile-oem` only.
    base_package: ?[]const u8 = null,
    /// Where that package is, relative to the generated one.
    base_package_path: []const u8 = "../redfish_schema_std",
    /// The singletons that root the base package's own surface, which have to
    /// match how it was generated.
    base_roots: []const []const u8 = &.{"Service"},

    roots: []const []const u8 = &.{},
    entity_type_patterns: []const []const u8 = &.{},
    navigation_patterns: []const []const u8 = &.{},
    everything: bool = false,

    emit_model: ?[]const u8 = null,
    run_optimize: bool = true,
    run_fmt: bool = true,
    dry_run: bool = false,
};

/// What parsing the command line produced.
pub const Parsed = union(enum) {
    command: Command,
    help,
    /// A message to print. The caller decides where.
    invalid: []const u8,
};

/// Parses argv, without the program name.
///
/// Returns a message rather than an error so the caller can print it: a bad
/// command line is the user's mistake, not an exceptional condition.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Parsed {
    var mode: ?Mode = null;
    var out_dir: ?[]const u8 = null;
    var package_name: ?[]const u8 = null;

    var command: Command = .{ .mode = .compile, .out_dir = "", .package_name = "" };

    var csdl_paths: std.ArrayList([]const u8) = .empty;
    var oem_csdl_paths: std.ArrayList([]const u8) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    var entity_type_patterns: std.ArrayList([]const u8) = .empty;
    var navigation_patterns: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;

        if (!std.mem.startsWith(u8, arg, "-")) {
            if (mode == null) {
                mode = std.meta.stringToEnum(Mode, if (std.mem.eql(u8, arg, "compile-oem"))
                    "compile_oem"
                else
                    arg) orelse return message(arena, "unknown subcommand: {s}", .{arg});
                continue;
            }
            if (out_dir == null) {
                out_dir = arg;
                continue;
            }
            return message(arena, "unexpected argument: {s}", .{arg});
        }

        // Every flag below this point takes a value, so read it once.
        const Flag = enum {
            @"--csdl",
            @"--oem-csdl",
            @"--package-name",
            @"--package-version",
            @"--display-name",
            @"--profile",
            @"--redfish-core-path",
            @"--base-package",
            @"--base-package-path",
            @"--root",
            @"--entity-type-pattern",
            @"--navigation-pattern",
            @"--emit-model",
            @"--everything",
            @"--no-optimize",
            @"--no-fmt",
            @"--dry-run",
        };
        const flag = std.meta.stringToEnum(Flag, arg) orelse
            return message(arena, "unknown flag: {s}", .{arg});

        switch (flag) {
            .@"--everything" => {
                command.everything = true;
                continue;
            },
            .@"--no-optimize" => {
                command.run_optimize = false;
                continue;
            },
            .@"--no-fmt" => {
                command.run_fmt = false;
                continue;
            },
            .@"--dry-run" => {
                command.dry_run = true;
                continue;
            },
            else => {},
        }

        index += 1;
        if (index == args.len) return message(arena, "{s} requires a value", .{arg});
        const value = args[index];

        switch (flag) {
            .@"--csdl" => try csdl_paths.append(arena, value),
            .@"--oem-csdl" => try oem_csdl_paths.append(arena, value),
            .@"--package-name" => package_name = value,
            .@"--package-version" => command.package_version = value,
            .@"--display-name" => command.display_name = value,
            .@"--profile" => command.profile = value,
            .@"--redfish-core-path" => command.redfish_core_path = value,
            .@"--base-package" => command.base_package = value,
            .@"--base-package-path" => command.base_package_path = value,
            .@"--root" => try roots.append(arena, value),
            .@"--entity-type-pattern" => try entity_type_patterns.append(arena, value),
            .@"--navigation-pattern" => try navigation_patterns.append(arena, value),
            .@"--emit-model" => command.emit_model = value,
            else => unreachable,
        }
    }

    command.mode = mode orelse return message(arena, "missing subcommand; try --help", .{});
    command.out_dir = out_dir orelse return message(arena, "missing <out-dir>", .{});
    command.package_name = package_name orelse
        return message(arena, "--package-name is required", .{});

    command.csdl_paths = try csdl_paths.toOwnedSlice(arena);
    command.oem_csdl_paths = try oem_csdl_paths.toOwnedSlice(arena);
    command.roots = try roots.toOwnedSlice(arena);
    command.entity_type_patterns = try entity_type_patterns.toOwnedSlice(arena);
    command.navigation_patterns = try navigation_patterns.toOwnedSlice(arena);

    if (command.csdl_paths.len == 0 and command.oem_csdl_paths.len == 0) {
        return message(arena, "no schemas: pass --csdl", .{});
    }
    if (command.mode == .compile and command.oem_csdl_paths.len != 0) {
        return message(arena, "--oem-csdl needs the compile-oem subcommand", .{});
    }
    if (command.mode == .compile_oem and command.oem_csdl_paths.len == 0) {
        return message(arena, "compile-oem needs --oem-csdl", .{});
    }
    if (command.mode == .compile and command.base_package != null) {
        return message(arena, "--base-package needs the compile-oem subcommand", .{});
    }
    return .{ .command = command };
}

fn message(
    arena: std.mem.Allocator,
    comptime template: []const u8,
    args: anytype,
) std.mem.Allocator.Error!Parsed {
    return .{ .invalid = try std.fmt.allocPrint(arena, template, args) };
}

/// One CSDL file, kept with its path so a diagnostic can name it.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
};

/// What the pipeline produced: the IR and the package rendered from it.
pub const Output = struct {
    model: codemodel.Model,
    files: []const emit.File,
};

/// Runs the pipeline over already-read sources.
///
/// `sources` must be ordered: for `compile-oem`, the vendor documents first
/// and the standard corpus after, which is what lets the standard schemas
/// resolve references without rooting anything.
///
/// A corpus is hundreds of documents referring to each other by qualified
/// name, so a failure that does not say what it was about is not actionable.
/// `blame`, when given, is set before the error is returned: to the path of
/// the document that would not parse, or to the name that would not resolve.
pub fn generate(
    arena: std.mem.Allocator,
    command: Command,
    sources: []const Source,
    rooted: usize,
    blame: ?*[]const u8,
) !Output {
    const documents = try arena.alloc(csdl.Document, sources.len);
    for (sources, documents) |source, *document| {
        document.* = csdl.parse(arena, source.text) catch |err| {
            if (blame) |out| out.* = source.path;
            return err;
        };
    }

    var indexed: schema_index.Diagnostics = .{};
    const index = schema_index.SchemaIndex.build(arena, documents, &indexed) catch |err| {
        if (blame) |out| {
            if (indexed.duplicate) |duplicate| out.* = duplicate.text;
            if (indexed.cycle.len != 0) out.* = indexed.cycle[0].text;
        }
        return err;
    };

    var compiled: compile.Diagnostics = .{};
    const surface: compile.Options = .{
        .package = .{
            .name = command.package_name,
            .version = command.package_version,
            .display_name = command.display_name,
            .profile = command.profile,
        },
        .singletons = command.roots,
        .roots = try filter.TypeFilter.parse(arena, command.entity_type_patterns, .restrictive),
        .navigations = try filter.TypeFilter.parse(arena, command.navigation_patterns, .permissive),
        .everything = command.everything,
        .root_documents = if (command.mode == .compile_oem) rooted else null,
        .diagnostics = &compiled,
    };

    var model = compile.compile(arena, &index, surface) catch |err| {
        if (blame) |out| {
            if (compiled.unresolved) |name| out.* = name;
        }
        return err;
    };

    // What the base package turned out to hold, if this package builds on
    // one. Compiled by the same passes, because the two have to agree on
    // every name they share and the only way to be sure of that is to have
    // computed it the same way.
    var base: ?emit.Base = null;
    var frozen: optimize.Frozen = .empty;
    if (command.base_package) |base_package| {
        // Over its own index, holding the standard documents and not the
        // vendor ones. Sharing this index would not do: the vendor documents
        // are in it, and a standard type resolves to the most derived type
        // that extends it, so `PowerSupply` would come out as
        // `LiteonPowerSupply` and the vendor's own type would land in the
        // package that is supposed to know nothing about it.
        var base_indexed: schema_index.Diagnostics = .{};
        const base_index = schema_index.SchemaIndex.build(
            arena,
            documents[rooted..],
            &base_indexed,
        ) catch |err| {
            if (blame) |out| {
                if (base_indexed.duplicate) |duplicate| out.* = duplicate.text;
                if (base_indexed.cycle.len != 0) out.* = base_indexed.cycle[0].text;
            }
            return err;
        };

        var base_diagnostics: compile.Diagnostics = .{};
        var base_model = compile.compile(arena, &base_index, .{
            .package = .{ .name = base_package },
            .singletons = command.base_roots,
            .roots = .{ .mode = .restrictive },
            .navigations = .{ .mode = .permissive },
            .diagnostics = &base_diagnostics,
        }) catch |err| {
            if (blame) |out| {
                if (base_diagnostics.unresolved) |name| out.* = name;
            }
            return err;
        };

        var trace: optimize.Renames = .empty;
        if (command.run_optimize) {
            base_model = try optimize.optimize(arena, base_model, options: {
                var base_options: optimize.Options = try .default(arena);
                base_options.trace = &trace;
                break :options base_options;
            });
            model = try optimize.adopt(arena, model, &trace);
        }

        const provides = try arena.create(std.StringHashMapUnmanaged(void));
        provides.* = try emit.provided(arena, base_model);
        frozen = provides.*;

        base = .{
            .module = base_package,
            .dependency = base_package,
            .dependency_path = command.base_package_path,
            .provides = provides,
        };
    }

    if (command.run_optimize) {
        model = try optimize.optimize(arena, model, options: {
            var package_options: optimize.Options = try .default(arena);
            if (base != null) package_options.frozen = &frozen;
            break :options package_options;
        });
    }

    return .{
        .model = model,
        .files = try emit.emit(arena, model, .{
            .dependency_path = command.redfish_core_path,
            .base = base,
        }),
    };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.next();
    while (it.next()) |arg| try argv.append(arena, try arena.dupe(u8, arg));

    const command = switch (try parse(arena, argv.items)) {
        .help => {
            try err.writeAll(usage);
            return 0;
        },
        .invalid => |text| {
            try err.print("redfish-codegen: {s}\n\n{s}", .{ text, usage });
            return 2;
        },
        .command => |value| value,
    };

    // The vendor schemas lead, because only the documents before
    // `root_documents` may contribute roots.
    var sources: std.ArrayList(Source) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (command.oem_csdl_paths) |path| try read(arena, io, path, &sources, &seen);
    const rooted = sources.items.len;
    for (command.csdl_paths) |path| try read(arena, io, path, &sources, &seen);

    if (sources.items.len == 0) {
        try err.print("redfish-codegen: no `.xml` found under the given paths\n", .{});
        return 2;
    }

    var blamed: []const u8 = "";
    const output = generate(arena, command, sources.items, rooted, &blamed) catch |e| {
        if (blamed.len != 0) {
            try err.print("redfish-codegen: {s}: {t}\n", .{ blamed, e });
            try err.flush();
            return 1;
        }
        return e;
    };

    var written: std.ArrayList(emit.File) = .empty;
    try written.ensureTotalCapacity(arena, output.files.len);
    for (output.files) |file| {
        if (!command.run_fmt) {
            written.appendAssumeCapacity(file);
            continue;
        }
        switch (try format.file(arena, file.path, file.contents)) {
            .formatted => |text| written.appendAssumeCapacity(.{
                .path = file.path,
                .contents = text,
            }),
            // The generator wrote something that is not Zig. Reporting it here
            // beats writing a package that will not compile.
            .invalid => |diagnostics| {
                try err.print("redfish-codegen: generated source is not valid Zig\n{s}", .{
                    diagnostics,
                });
                return 1;
            },
        }
    }

    if (command.dry_run) {
        for (written.items) |file| {
            try err.print("{s}/{s} ({d} bytes)\n", .{ command.out_dir, file.path, file.contents.len });
        }
        return 0;
    }

    var out = try std.Io.Dir.cwd().createDirPathOpen(io, command.out_dir, .{});
    defer out.close(io);
    for (written.items) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try out.createDirPath(io, parent);
        try out.writeFile(io, .{ .sub_path = file.path, .data = file.contents });
    }
    try prune(arena, io, out, written.items);

    if (command.emit_model) |path| {
        const json = try output.model.stringify(arena);
        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }

    return 0;
}

/// Deletes generated files the run did not write.
///
/// The emitter owns every file in a generated package, so a name that is no
/// longer emitted has to go. It matters most when a package shrinks: an OEM
/// package that stops re-emitting the standard types drops hundreds of
/// modules, and a stale one left in `src/` still compiles, still holds a
/// duplicate of a standard type, and never shows up as a diff.
///
/// Only `.zig` files are considered. A wrong `--out` should not be able to
/// empty a directory that was never a package.
fn prune(
    arena: std.mem.Allocator,
    io: std.Io,
    out: std.Io.Dir,
    written: []const emit.File,
) !void {
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    for (written) |file| try keep.put(arena, file.path, {});

    var dir = out.openDir(io, "src", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);

    var stale: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        // The emitter writes `/` on every host, and a walk on Windows hands
        // back `\`. Comparing the two unnormalized makes every file look
        // stale, which deletes the package the run just wrote.
        const path = try std.mem.concat(arena, u8, &.{ "src/", entry.path });
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        if (keep.contains(path)) continue;
        try stale.append(arena, path);
    }

    for (stale.items) |path| try out.deleteFile(io, path);
}

/// Reads one `--csdl` path: a file, or every `.xml` under a directory.
///
/// Directory order is whatever the filesystem returns, which differs between
/// machines, so the names are sorted. The compile depends on document order
/// through `root_documents`, and a package that depends on the order `readdir`
/// happened to use is not reproducible.
///
/// `seen` holds the base names already read, and a repeat is skipped. The
/// Redfish and Swordfish bundles ship nine of the same documents — the same
/// namespace declared twice is an error, and there is no reason to make the
/// operator name every file to avoid it. Paths are searched in the order
/// given, so the first `--csdl` wins, and an `--oem-csdl` wins over both.
fn read(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    into: *std.ArrayList(Source),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const cwd: std.Io.Dir = .cwd();

    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            if (try seen.fetchPut(arena, std.fs.path.basename(path), {}) != null) return;
            try into.append(arena, .{
                .path = path,
                .text = try cwd.readFileAlloc(io, path, arena, .limited(max_file_bytes)),
            });
            return;
        },
        else => return e,
    };
    defer dir.close(io);

    var found: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".xml")) continue;
        try found.append(arena, try arena.dupe(u8, entry.path));
    }

    std.mem.sort([]const u8, found.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    for (found.items) |name| {
        if (try seen.fetchPut(arena, std.fs.path.basename(name), {}) != null) continue;
        try into.append(arena, .{
            .path = try std.fs.path.join(arena, &.{ path, name }),
            .text = try dir.readFileAlloc(io, name, arena, .limited(max_file_bytes)),
        });
    }
}

/// No CSDL document in the corpus is close to this; the largest is under 2 MB.
const max_file_bytes = 32 << 20;

const testing = std.testing;

test "a compile names its schemas, its package and where to write them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse(arena.allocator(), &.{
        "compile",
        "schema_packages/redfish_schema_std",
        "--csdl",
        "schema/redfish-csdl",
        "--package-name",
        "redfish_schema_std",
        "--package-version",
        "0.3.0",
        "--profile",
        "std",
        "--root",
        "Service",
    });

    const command = parsed.command;
    try testing.expectEqual(Mode.compile, command.mode);
    try testing.expectEqualStrings("schema_packages/redfish_schema_std", command.out_dir);
    try testing.expectEqualStrings("schema/redfish-csdl", command.csdl_paths[0]);
    try testing.expectEqualStrings("redfish_schema_std", command.package_name);
    try testing.expectEqualStrings("0.3.0", command.package_version);
    try testing.expectEqualStrings("std", command.profile.?);
    try testing.expectEqualStrings("Service", command.roots[0]);

    // Everything not named takes the value a profile usually wants.
    try testing.expect(command.run_fmt);
    try testing.expect(command.run_optimize);
    try testing.expect(!command.dry_run);
    try testing.expectEqualStrings("../..", command.redfish_core_path);
}

test "a repeated flag accumulates instead of replacing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse(arena.allocator(), &.{
        "compile",               "out",
        "--csdl",                "a.xml",
        "--csdl",                "b.xml",
        "--package-name",        "p",
        "--entity-type-pattern", "Chassis.*",
        "--entity-type-pattern", "Manager.*",
    });

    const command = parsed.command;
    try testing.expectEqual(@as(usize, 2), command.csdl_paths.len);
    try testing.expectEqualStrings("b.xml", command.csdl_paths[1]);
    try testing.expectEqual(@as(usize, 2), command.entity_type_patterns.len);
}

test "the flags that turn a step off are flags, not values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse(arena.allocator(), &.{
        "compile",  "out",           "--csdl",    "a.xml",        "--package-name", "p",
        "--no-fmt", "--no-optimize", "--dry-run", "--everything",
    });

    const command = parsed.command;
    try testing.expect(!command.run_fmt);
    try testing.expect(!command.run_optimize);
    try testing.expect(command.dry_run);
    try testing.expect(command.everything);
}

test "an OEM compile takes its roots from the vendor schemas" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse(arena.allocator(), &.{
        "compile-oem",    "out",
        "--oem-csdl",     "schema/oem/dell",
        "--csdl",         "schema/redfish-csdl",
        "--package-name", "redfish_schema_oem_dell",
    });

    const command = parsed.command;
    try testing.expectEqual(Mode.compile_oem, command.mode);
    try testing.expectEqualStrings("schema/oem/dell", command.oem_csdl_paths[0]);
    try testing.expectEqualStrings("schema/redfish-csdl", command.csdl_paths[0]);
}

test "a command line that cannot be run says why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expect((try parse(allocator, &.{"--help"})) == .help);
    try testing.expect((try parse(allocator, &.{"-h"})) == .help);

    const cases = [_]struct { args: []const []const u8, expected: []const u8 }{
        .{ .args = &.{}, .expected = "missing subcommand" },
        .{ .args = &.{"publish"}, .expected = "unknown subcommand" },
        .{ .args = &.{"compile"}, .expected = "missing <out-dir>" },
        .{
            .args = &.{ "compile", "out", "--csdl", "a.xml" },
            .expected = "--package-name is required",
        },
        .{
            .args = &.{ "compile", "out", "--package-name", "p" },
            .expected = "no schemas",
        },
        .{ .args = &.{ "compile", "out", "--csdl" }, .expected = "--csdl requires a value" },
        .{ .args = &.{ "compile", "out", "--nope", "x" }, .expected = "unknown flag" },
        .{
            .args = &.{ "compile", "out", "extra", "--csdl", "a.xml", "--package-name", "p" },
            .expected = "unexpected argument",
        },
        .{
            .args = &.{ "compile", "out", "--oem-csdl", "o.xml", "--package-name", "p" },
            .expected = "--oem-csdl needs the compile-oem subcommand",
        },
        .{
            .args = &.{ "compile-oem", "out", "--csdl", "a.xml", "--package-name", "p" },
            .expected = "compile-oem needs --oem-csdl",
        },
    };

    for (cases) |case| {
        const parsed = try parse(allocator, case.args);
        try testing.expect(std.mem.indexOf(u8, parsed.invalid, case.expected) != null);
    }
}

test "the pipeline turns CSDL into a package without touching the disk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis">
        \\      <EntityType Name="Chassis" Abstract="true"/>
        \\    </Schema>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis.v1_0_0">
        \\      <EntityType Name="Chassis" BaseType="Chassis.Chassis">
        \\        <Property Name="AssetTag" Type="Edm.String" Nullable="false"/>
        \\      </EntityType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;

    const output = try generate(allocator, .{
        .mode = .compile,
        .out_dir = "out",
        .package_name = "redfish_schema_test",
        .profile = "test",
        .everything = true,
    }, &.{.{ .path = "Chassis_v1.xml", .text = document }}, 0, null);

    var seen = false;
    for (output.files) |file| {
        // Whatever the emitter produced has to be Zig, which is the only
        // thing `--no-fmt` would let through unchecked.
        if (!std.mem.endsWith(u8, file.path, ".zig")) continue;
        const result = try format.zig(allocator, file.path, file.contents);
        try testing.expect(result == .formatted);
        if (std.mem.indexOf(u8, file.contents, "AssetTag") != null) seen = true;
    }
    try testing.expect(seen);
}

test "regenerating a package removes what it no longer emits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var src = try tmp.dir.createDirPathOpen(io, "src", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "root.zig", .data = "old" });
    try src.writeFile(io, .{ .sub_path = "resource.zig", .data = "copied from the base package" });
    try src.writeFile(io, .{ .sub_path = "notes.txt", .data = "not the generator's" });

    // What a run that no longer emits `resource.zig` wrote. Paths use `/` on
    // every host, which is not what a directory walk hands back on Windows.
    try prune(arena.allocator(), io, tmp.dir, &.{
        .{ .path = "src/root.zig", .contents = "new" },
    });

    try src.access(io, "root.zig", .{});
    try testing.expectError(error.FileNotFound, src.access(io, "resource.zig", .{}));

    // Only generated files are the generator's to remove.
    try src.access(io, "notes.txt", .{});
}
