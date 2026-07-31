//! Workspace build for the Zig Redfish client stack.
//!
//! Steps:
//!   zig build            build every module
//!   zig build test       run the whole workspace test suite
//!   zig build examples   build and install the example programs
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
    oem: []const OemSource = &.{},
    /// Extra arguments, appended after the generated ones.
    args: []const []const u8 = &.{},
};

/// Where a vendor's CSDL comes from, which is not the same question for every
/// vendor.
const OemSource = union(enum) {
    /// A directory inside the pinned DMTF corpus. Only Contoso, which DMTF
    /// publishes itself.
    corpus: []const u8,
    /// A directory in this repository, under `schema/oem/`. See
    /// `schema/oem/README.md` for why a real vendor's schemas are not
    /// fetched the way the standard ones are.
    vendored: []const u8,
};

/// A test file under `tests/`, and the OEM packages it reads beyond the
/// standard one.
///
/// The vendor packages are named per file rather than handed to every test.
/// Zig analyzes a declaration only when something references it, so an unused
/// import costs little, but naming them keeps a file's dependencies where a
/// reader looks for them and keeps a missing package from failing a test that
/// never wanted it.
const TestFile = struct {
    path: []const u8,
    oem: []const []const u8 = &.{},
};

/// One standard package, and one per vendor whose extensions we can describe.
///
/// A vendor package is small -- tens of properties against the standard
/// corpus's tens of thousands -- because it holds only the extension, and
/// resolves everything it refers to against the standard schemas.
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
        .oem = &.{.{ .corpus = "mockups/public-oem-examples/Contoso.com" }},
    },
    .{
        .name = "redfish_schema_oem_ami",
        .display_name = "AMI OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/ami" }},
    },
    .{
        .name = "redfish_schema_oem_dell",
        .display_name = "Dell OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/dell" }},
    },
    .{
        .name = "redfish_schema_oem_delta",
        .display_name = "Delta Energy Systems OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/delta" }},
    },
    .{
        .name = "redfish_schema_oem_hpe",
        .display_name = "HPE OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/hpe" }},
    },
    .{
        .name = "redfish_schema_oem_lenovo",
        .display_name = "Lenovo OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/lenovo" }},
    },
    .{
        .name = "redfish_schema_oem_liteon",
        .display_name = "Liteon OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/liteon" }},
    },
    .{
        // Two NVIDIA packages and not one: the baseboard and BlueField
        // firmwares are separate products that extend different resources,
        // and a service is one or the other.
        .name = "redfish_schema_oem_nvidia_baseboard",
        .display_name = "NVIDIA baseboard OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/nvidia_baseboard" }},
    },
    .{
        .name = "redfish_schema_oem_nvidia_bluefield",
        .display_name = "NVIDIA BlueField OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/nvidia_bluefield" }},
    },
    .{
        .name = "redfish_schema_oem_supermicro",
        .display_name = "Supermicro OEM extensions",
        .oem = &.{.{ .vendored = "schema/oem/supermicro" }},
    },
};

/// An example program under `examples/`, at `examples/<name>.zig`, and the
/// OEM packages it reads beyond the standard one.
///
/// Named per program for the same reason `TestFile` names them per file: an
/// unused import costs little, but naming the vendor packages keeps a
/// program's dependencies where a reader looks for them.
const Example = struct {
    name: []const u8,
    oem: []const []const u8 = &.{},
};

/// The programs under `examples/`.
///
/// `cli.zig` is not here: it is shared support rather than a program, and has
/// no `main`. It is registered for its own tests in `addExamples`.
const examples = [_]Example{
    .{ .name = "explore" },
    .{ .name = "session_login" },
    .{ .name = "event_stream" },
    .{ .name = "firmware_push" },
    .{ .name = "parse_payload" },
    .{ .name = "readme" },
    .{
        .name = "power_shelf",
        .oem = &.{ "redfish_schema_oem_delta", "redfish_schema_oem_liteon" },
    },
};

/// The standard package. A vendor package imports it rather than re-emitting
/// the slice of the corpus its own types happen to reach.
const base_package = "redfish_schema_std";

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
    addExamples(b, test_step, core_mod, bmc_http_mod, bmc_mock_mod, redfish_mod, target, optimize);

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

                for (package.oem) |source| switch (source) {
                    .corpus => |relative| {
                        run.addArg("--oem-csdl");
                        run.addDirectoryArg(dmtf.path(relative));
                    },
                    .vendored => |relative| {
                        run.addArg("--oem-csdl");
                        run.addDirectoryArg(b.path(relative));
                    },
                };

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
                if (package.oem.len == 0) {
                    run.addArgs(&.{ "--root", "Service" });
                } else {
                    // A vendor package refers to the standard types rather
                    // than copying them, which is what keeps it small and
                    // what makes its `Assembly` the same Zig type as
                    // everyone else's.
                    run.addArgs(&.{ "--base-package", base_package });
                }
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
            var imports: std.ArrayList(std.Build.Module.Import) = .empty;
            imports.append(b.allocator, .{
                .name = "redfish_core",
                .module = core_mod,
            }) catch @panic("OOM");

            // The standard package is first in `packages`, so a vendor
            // package registered later can already find it. A vendor package
            // that reached nothing standard imports nothing standard, which
            // is why this asks the module rather than the list.
            if (package.oem.len != 0) {
                if (b.modules.get(base_package)) |std_package| {
                    imports.append(b.allocator, .{
                        .name = base_package,
                        .module = std_package,
                    }) catch @panic("OOM");
                }
            }

            const module = b.addModule(package.name, .{
                .root_source_file = b.path(root_source),
                .target = target,
                .optimize = optimize,
                .imports = imports.items,
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

    for ([_]TestFile{
        .{ .path = "tests/round_trip.zig" },
        .{ .path = "tests/pagination.zig" },
        .{ .path = "tests/navigation.zig" },
        .{ .path = "tests/service.zig" },
        .{ .path = "tests/writes.zig" },
        .{ .path = "tests/base_operations.zig" },
        .{ .path = "tests/chassis.zig" },
        .{ .path = "tests/assembly.zig" },
        .{ .path = "tests/vera_rubin.zig" },
        .{ .path = "tests/computer_system.zig" },
        .{ .path = "tests/bios.zig" },
        .{ .path = "tests/manager.zig" },
        .{ .path = "tests/session_service.zig" },
        .{ .path = "tests/account_service.zig" },
        .{ .path = "tests/update_service.zig" },
        .{ .path = "tests/task_service.zig" },
        .{ .path = "tests/telemetry_service.zig" },
        .{ .path = "tests/power_equipment.zig" },
        .{
            .path = "tests/oem_service_root.zig",
            .oem = &.{ "redfish_schema_oem_ami", "redfish_schema_oem_hpe" },
        },
        .{
            .path = "tests/oem_chassis.zig",
            .oem = &.{
                "redfish_schema_oem_delta",
                "redfish_schema_oem_liteon",
                "redfish_schema_oem_nvidia_baseboard",
            },
        },
        .{
            .path = "tests/oem_computer_system.zig",
            .oem = &.{
                "redfish_schema_oem_lenovo",
                "redfish_schema_oem_nvidia_bluefield",
            },
        },
        .{
            .path = "tests/oem_manager.zig",
            .oem = &.{
                "redfish_schema_oem_ami",
                "redfish_schema_oem_dell",
                "redfish_schema_oem_hpe",
                "redfish_schema_oem_lenovo",
                "redfish_schema_oem_supermicro",
            },
        },
    }) |file| {
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.appendSlice(b.allocator, &.{
            .{ .name = "redfish_core", .module = core_mod },
            .{ .name = "redfish_bmc_mock", .module = bmc_mock_mod },
            .{ .name = "redfish", .module = redfish_mod },
            .{ .name = "redfish_schema_std", .module = std_package },
        }) catch @panic("OOM");
        for (file.oem) |name| {
            // A vendor package that is not checked in takes its test with it,
            // for the same reason the standard one does.
            const package = b.modules.get(name) orelse break;
            imports.append(b.allocator, .{ .name = name, .module = package }) catch @panic("OOM");
        } else {
            addTests(b, test_step, b.createModule(.{
                .root_source_file = b.path(file.path),
                .target = target,
                .optimize = optimize,
                .imports = imports.items,
            }));
        }
    }
}

/// Adds the programs under `examples/`.
///
/// Each is built twice, because an example's two halves are checked by
/// different things. `run` — the body of the example — is exercised by the
/// test at the bottom of its own file, against `redfish_bmc_mock`. `main` is
/// not reached from any test, so nothing in the test build would type-check
/// it; building the executable is what does. `test` depends on both.
///
/// Installing is left to `zig build examples`, so a plain `zig build` still
/// installs one binary.
///
/// Skipped when no standard schema package is checked in, for the same reason
/// `addPayloadTests` skips: an ungenerated tree is a valid state.
fn addExamples(
    b: *std.Build,
    test_step: *std.Build.Step,
    core_mod: *std.Build.Module,
    bmc_http_mod: *std.Build.Module,
    bmc_mock_mod: *std.Build.Module,
    redfish_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const std_package = b.modules.get("redfish_schema_std") orelse return;

    const step = b.step("examples", "Build and install the example programs");

    const base_imports = [_]std.Build.Module.Import{
        .{ .name = "redfish_core", .module = core_mod },
        .{ .name = "redfish_bmc_http", .module = bmc_http_mod },
        .{ .name = "redfish_bmc_mock", .module = bmc_mock_mod },
        .{ .name = "redfish", .module = redfish_mod },
        .{ .name = "redfish_schema_std", .module = std_package },
    };

    // Shared support, so its tests belong to no one example.
    addTests(b, test_step, b.createModule(.{
        .root_source_file = b.path("examples/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &base_imports,
    }));

    for (examples) |example| {
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.appendSlice(b.allocator, &base_imports) catch @panic("OOM");
        for (example.oem) |name| {
            // A vendor package that is not checked in takes its example with
            // it, exactly as it takes its test.
            const package = b.modules.get(name) orelse break;
            imports.append(b.allocator, .{ .name = name, .module = package }) catch @panic("OOM");
        } else {
            const module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
                .target = target,
                .optimize = optimize,
                .imports = imports.items,
            });

            // `readme.zig` is the program the README shows, and checks that it
            // still is. `@embedFile` cannot reach outside its own module, so
            // the file it has to read against is handed to it here.
            if (std.mem.eql(u8, example.name, "readme")) {
                module.addAnonymousImport("README.md", .{ .root_source_file = b.path("README.md") });
            }

            addTests(b, test_step, module);

            const exe = b.addExecutable(.{ .name = example.name, .root_module = module });
            step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            test_step.dependOn(&exe.step);
        }
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
