//! Workspace build for the Zig Redfish client stack.
//!
//! Steps:
//!   zig build            build every module
//!   zig build test       run the whole workspace test suite
//!   zig build fmt        rewrite source with `zig fmt`
//!   zig build fmt-check  verify formatting without rewriting
//!
//! Formatting covers the whole repository, generated schema packages
//! included, so emitter output is normalized before it is committed.

const std = @import("std");

const fmt_paths = [_][]const u8{"."};

/// Build products, not source.
const fmt_exclude_paths = [_][]const u8{
    ".zig-cache",
    "zig-out",
};

/// Where checked-in generator output lives.
const schema_packages = "schema_packages";

/// A schema package this repository owns: what it is called, what it is
/// generated from, and how it is rooted.
///
/// There is no `profiles.yaml`. The reference project's `features.toml` cuts
/// the corpus into thirty overlapping slices because a Rust crate pays to
/// compile every item it declares. Zig analyzes a declaration only when
/// something references it, so a consumer of the whole standard schema pays
/// for the types it names and nothing else -- see `doc/architecture.md`. What
/// is left is one standard package and one package per vendor, which is a
/// list short enough to be a list.
const SchemaPackage = struct {
    /// The package name, and the directory under `schema_packages/`.
    name: []const u8,
    display_name: []const u8,
    /// Vendor documents to root the surface in. Empty means the standard
    /// corpus rooted at the service singleton.
    oem: []const []const u8 = &.{},
    /// Extra arguments, appended after the generated ones.
    args: []const []const u8 = &.{},
};

/// Collections a service keeps at a fixed length, so a client PATCHes a slot
/// rather than resizing the array. Ported from the reference project's
/// `features.toml`, which after thirty features names exactly these two.
const packages = [_]SchemaPackage{
    .{
        .name = "redfish_schema_std",
        .display_name = "Redfish and Swordfish schemas",
    },
    .{
        // DMTF's fictional vendor, published alongside the standard schemas.
        // It covers all three shapes an extension takes: a complex type
        // behind `Oem`, a whole OEM resource behind a link, and a bare action.
        .name = "redfish_schema_oem_contoso",
        .display_name = "Contoso OEM extensions",
        .oem = &.{"mockups/public-oem-examples/Contoso.com"},
    },
};

/// The generated package built from the fixture corpus.
const fixture_package = "redfish_schema_fixture";

/// The corpus it is generated from.
const fixture_csdl = "codegen/fixtures/csdl";

/// The profile that corpus describes: rooted at the service singleton, with
/// every namespace in it followed except `ThermalMetrics`, which is left out
/// so the out-of-surface link path is exercised too.
const fixture_args = [_][]const u8{
    "--package-name",       fixture_package,
    "--display-name",       "Redfish fixture schema",
    "--profile",            "fixture",
    "--root",               "Service",
    "--navigation-pattern", "ServiceRoot.*",
    "--navigation-pattern", "ChassisCollection.*",
    "--navigation-pattern", "Chassis.*",
    "--navigation-pattern", "SessionCollection.*",
    "--navigation-pattern", "Session.*",
    "--navigation-pattern", "Sensor.*",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all workspace tests");

    const core_mod = b.addModule("redfish_core", .{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addTests(b, test_step, core_mod);

    const bmc_http_mod = b.addModule("redfish_bmc_http", .{
        .root_source_file = b.path("bmc_http/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "redfish_core", .module = core_mod }},
    });
    addTests(b, test_step, bmc_http_mod);

    const bmc_mock_mod = b.addModule("redfish_bmc_mock", .{
        .root_source_file = b.path("bmc_mock/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "redfish_core", .module = core_mod }},
    });
    addTests(b, test_step, bmc_mock_mod);

    const redfish_mod = b.addModule("redfish", .{
        .root_source_file = b.path("redfish/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "redfish_core", .module = core_mod }},
    });
    addTests(b, test_step, redfish_mod);

    const serde = b.dependency("serde", .{ .target = target, .optimize = optimize });

    const codegen_mod = b.addModule("redfish_codegen", .{
        .root_source_file = b.path("codegen/cli/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "serde", .module = serde.module("serde") }},
    });
    addTests(b, test_step, codegen_mod);

    const codegen_cli_mod = b.createModule(.{
        .root_source_file = b.path("codegen/cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "redfish_codegen", .module = codegen_mod }},
    });
    addTests(b, test_step, codegen_cli_mod);

    const codegen_exe = b.addExecutable(.{
        .name = "redfish-codegen",
        .root_module = codegen_cli_mod,
    });
    b.installArtifact(codegen_exe);

    addFixture(b, test_step, codegen_exe, core_mod, target, optimize);
    addSchemaPackages(b, test_step, codegen_exe, core_mod, target, optimize);
    addPayloadTests(b, test_step, core_mod, bmc_mock_mod, redfish_mod, target, optimize);

    const fmt = b.addFmt(.{
        .paths = &fmt_paths,
        .exclude_paths = &fmt_exclude_paths,
    });
    b.step("fmt", "Format all Zig source, generated packages included").dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{
        .paths = &fmt_paths,
        .exclude_paths = &fmt_exclude_paths,
        .check = true,
    });
    b.step("fmt-check", "Verify formatting without rewriting").dependOn(&fmt_check.step);
}

/// Adds a `generate-<name>` step per schema package, and compiles whatever
/// output is already checked in.
///
/// Generation writes into the source tree rather than the cache, because the
/// packages are committed: a consumer of this repository gets the schemas
/// without fetching 44 MB of XML or running a compiler over it, and a schema
/// bump is a reviewable diff rather than an invisible change of behaviour.
/// `zig build generate` followed by a clean `git diff` is the whole gate.
fn addSchemaPackages(
    b: *std.Build,
    test_step: *std.Build.Step,
    codegen: *std.Build.Step.Compile,
    core_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const all = b.step("generate", "Regenerate every schema package in place");

    // `lazyDependency` marks a dependency as needed the moment it is called,
    // not when the step that uses it runs, so calling it unconditionally
    // makes every `zig build` fetch 44 MB of XML. That is merely wasteful on
    // Linux and fatal elsewhere: 196 paths in the Swordfish bundle differ
    // only by case and cannot be unpacked onto a case-insensitive
    // filesystem. The build runner does not tell `build` which steps were
    // asked for, so the ask has to be explicit.
    const wanted = b.option(
        bool,
        "corpora",
        "Fetch the pinned CSDL corpora. Required by `generate`, useless otherwise.",
    ) orelse false;

    for (packages) |package| {
        const out = b.pathJoin(&.{ schema_packages, package.name });

        const step = b.step(
            b.fmt("generate-{s}", .{package.name}),
            b.fmt("Regenerate {s} in place", .{package.display_name}),
        );

        if (!wanted) {
            const explain = b.addFail(
                \\regenerating needs the pinned CSDL corpora, which are lazy dependencies:
                \\
                \\    zig build -Dcorpora generate
                \\
                \\They are 44 MB of XML that nothing else in this repository reads, and
                \\196 paths in the Swordfish bundle differ only by case, so fetching them
                \\onto a case-insensitive filesystem fails. Regenerate on Linux.
            );
            step.dependOn(&explain.step);
            all.dependOn(&explain.step);
        } else if (b.lazyDependency("dmtf_redfish", .{})) |dmtf| {
            if (b.lazyDependency("snia_swordfish", .{})) |snia| {
                const run = b.addRunArtifact(codegen);
                run.addArg(if (package.oem.len == 0) "compile" else "compile-oem");
                run.addArg(b.pathFromRoot(out));

                for (package.oem) |relative| {
                    run.addArg("--oem-csdl");
                    run.addDirectoryArg(dmtf.path(relative));
                }

                run.addArg("--csdl");
                run.addDirectoryArg(dmtf.path("csdl"));
                run.addArg("--csdl");
                run.addDirectoryArg(snia.path("csdl-schema"));

                run.addArgs(&.{
                    "--package-name",      package.name,
                    "--display-name",      package.display_name,
                    "--profile",           package.name,
                    "--redfish-core-path", "../..",
                });
                if (package.oem.len == 0) run.addArgs(&.{ "--root", "Service" });
                run.addArgs(package.args);

                // It writes into the source tree, so it is never up to date.
                run.has_side_effects = true;

                step.dependOn(&run.step);
                all.dependOn(&run.step);
            }
        }

        // Checked in or not yet generated; either is a valid state of the
        // tree, and only the former has anything to compile.
        const root_source = b.pathJoin(&.{ out, "src/root.zig" });
        if (b.build_root.handle.access(b.graph.io, root_source, .{})) |_| {
            const module = b.addModule(package.name, .{
                .root_source_file = b.path(root_source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "redfish_core", .module = core_mod }},
            });
            addTests(b, test_step, module);
        } else |_| {}
    }
}

/// Adds the recorded-payload suite, which deserializes real DMTF responses
/// into the checked-in standard package.
///
/// It is skipped when that package has not been generated yet, for the same
/// reason `addSchemaPackages` skips it: an ungenerated tree is a valid state.
/// Adds the test modules under `tests/`, which drive the real generated
/// package rather than a type written to suit the code under test.
///
/// These are skipped when no schema package is checked in, so the repository
/// still builds before its first generation.
fn addPayloadTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    core_mod: *std.Build.Module,
    bmc_mock_mod: *std.Build.Module,
    redfish_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const std_package = b.modules.get("redfish_schema_std") orelse return;

    for ([_][]const u8{
        "tests/round_trip.zig",
        "tests/pagination.zig",
        "tests/navigation.zig",
        "tests/service.zig",
        "tests/writes.zig",
    }) |path| {
        addTests(b, test_step, b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "redfish_core", .module = core_mod },
                .{ .name = "redfish_bmc_mock", .module = bmc_mock_mod },
                .{ .name = "redfish", .module = redfish_mod },
                .{ .name = "redfish_schema_std", .module = std_package },
            },
        }));
    }
}

/// Generates the fixture schema package from its checked-in CSDL and adds
/// the result to the test suite.
///
/// Parsing the emitter's output is not the same as compiling it: a name that
/// resolves to nothing, or a field whose type was never emitted, is still
/// valid Zig text. Building the generated package is the only check that
/// catches those, so it runs on every `zig build test`.
fn addFixture(
    b: *std.Build,
    test_step: *std.Build.Step,
    codegen: *std.Build.Step.Compile,
    core_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const run = b.addRunArtifact(codegen);
    run.addArg("compile");
    const generated = run.addOutputDirectoryArg(fixture_package);
    run.addArg("--csdl");
    run.addDirectoryArg(b.path(fixture_csdl));
    run.addArgs(&fixture_args);

    // A directory argument is a path, not its contents: the run step's cache
    // key would not change when a schema in it did, and editing the corpus
    // would silently leave the package built from the old one. Naming each
    // document makes the dependency real.
    var dir = b.build_root.handle.openDir(b.graph.io, fixture_csdl, .{ .iterate = true }) catch
        std.debug.panic("cannot open {s}", .{fixture_csdl});
    defer dir.close(b.graph.io);

    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ fixture_csdl, entry.name })));
    }

    const module = b.createModule(.{
        .root_source_file = generated.path(b, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "redfish_core", .module = core_mod }},
    });
    addTests(b, test_step, module);

    const step = b.step("fixture", "Generate the fixture schema package");
    step.dependOn(&run.step);
}

/// Register the tests of an already-declared module so each module is
/// described exactly once.
fn addTests(b: *std.Build, test_step: *std.Build.Step, module: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
