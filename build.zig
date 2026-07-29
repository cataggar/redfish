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

    b.installArtifact(b.addExecutable(.{
        .name = "redfish-codegen",
        .root_module = codegen_cli_mod,
    }));

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

/// Register the tests of an already-declared module so each module is
/// described exactly once.
fn addTests(b: *std.Build, test_step: *std.Build.Step, module: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
