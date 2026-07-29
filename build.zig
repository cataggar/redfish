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

/// The generated package built from the fixture corpus.
const fixture_package = "redfish_schema_fixture";

/// The corpus it is generated from.
const fixture_csdl = "codegen/fixtures/csdl";

/// The profile that corpus describes: rooted at the service singleton, with
/// every namespace in it followed except `ThermalMetrics`, which is left out
/// so the out-of-surface link path is exercised too.
const fixture_args = [_][]const u8{
    "--package-name",        fixture_package,
    "--display-name",        "Redfish fixture schema",
    "--profile",             "fixture",
    "--root",                "Service",
    "--navigation-pattern",  "ServiceRoot.*",
    "--navigation-pattern",  "ChassisCollection.*",
    "--navigation-pattern",  "Chassis.*",
    "--navigation-pattern",  "SessionCollection.*",
    "--navigation-pattern",  "Session.*",
    "--navigation-pattern",  "Sensor.*",
    "--rigid-array-pattern", "Chassis.*.Chassis/Sensors",
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
