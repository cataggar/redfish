//! Case conversion for schema-derived names.
//!
//! Ported from `nv-redfish`'s `generator/casemungler.rs`, including its test
//! table, because Redfish names are full of acronyms that a naive converter
//! mangles: `NVMe`, `iSCSI`, `PCIeFunctions`, `PFFunctionNumber`. The rules
//! that make those work:
//!
//!   * An uppercase letter after a lowercase one starts a word
//!     (`fooBar` → `foo_bar`).
//!   * An uppercase letter inside a run of uppercase letters starts a word
//!     only when at least two lowercase letters follow it, so the run is a
//!     word of its own and not a stray capital
//!     (`nVMEFoobar` → `nvme_foobar`, but `NVMe` → `nvme`).
//!   * A word boundary is ignored while the current word is a single
//!     character, which keeps a leading initial attached
//!     (`iSCSIDriveName` → `iscsi_drive_name`).
//!   * `_` separates words for PascalCase but not for snake_case, so a
//!     leading or trailing underscore survives the round trip.
//!
//! A name made only of separators is returned unchanged rather than emptied.

const std = @import("std");

const snake_separators = "~!#%^&*()+-:<>?,./ ";
const pascal_separators = "_" ++ snake_separators;

/// `PCIeFunctions` → `pcie_functions`. Caller owns the result.
pub fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return convert(allocator, input, .snake);
}

/// `pcie_functions` → `PcieFunctions`. Caller owns the result.
pub fn toPascalCase(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return convert(allocator, input, .pascal);
}

/// `pcie_functions` → `pcieFunctions`, for function names. Caller owns the
/// result.
pub fn toCamelCase(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const pascal = try toPascalCase(allocator, input);
    if (pascal.len > 0) pascal[0] = std.ascii.toLower(pascal[0]);
    return pascal;
}

const Case = enum { snake, pascal };

fn convert(allocator: std.mem.Allocator, input: []const u8, case: Case) ![]u8 {
    const separators = switch (case) {
        .snake => snake_separators,
        .pascal => pascal_separators,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    // Length of the word being accumulated, which is what decides whether a
    // boundary is honored — a word of one character absorbs the next one.
    var word_len: usize = 0;

    for (input, 0..) |c, i| {
        if (isWordBoundary(input, i, separators) and word_len > 1) {
            if (case == .snake) try out.append(allocator, '_');
            word_len = 0;
        }
        if (std.mem.indexOfScalar(u8, separators, c) != null) continue;

        try out.append(allocator, switch (case) {
            .snake => std.ascii.toLower(c),
            .pascal => if (word_len == 0) std.ascii.toUpper(c) else std.ascii.toLower(c),
        });
        word_len += 1;
    }

    // Nothing but separators: hand back what we were given rather than "".
    if (out.items.len == 0) return allocator.dupe(u8, input);
    return out.toOwnedSlice(allocator);
}

fn isWordBoundary(input: []const u8, i: usize, separators: []const u8) bool {
    const c = input[i];
    if (std.mem.indexOfScalar(u8, separators, c) != null) return true;
    if (i == 0) return false;
    if (!std.ascii.isUpper(c)) return false;

    const previous = input[i - 1];
    if (std.ascii.isLower(previous)) return true;
    return isAcronymEnd(input, i);
}

/// Whether position `i` is the first letter of a word that follows an
/// acronym: `…MEFoobar` breaks before `F`, `NVMe` does not break before `M`.
fn isAcronymEnd(input: []const u8, i: usize) bool {
    if (!std.ascii.isUpper(input[i - 1])) return false;
    if (i + 1 >= input.len) return false;
    if (!std.ascii.isLower(input[i + 1])) return false;

    var lowercase: usize = 0;
    for (input[i + 1 ..]) |c| {
        if (!std.ascii.isLower(c)) break;
        lowercase += 1;
    }
    return lowercase >= 2;
}

const Expected = struct { input: []const u8, snake: []const u8, pascal: []const u8 };

/// The table from `casemungler.rs`, minus its `to_camel` short-circuit for
/// inputs under two characters: this port uppercases them (`"f"` → `"F"`)
/// instead of passing them through, so a one-letter type name is still a
/// type name.
const patterns = [_]Expected{
    .{ .input = "", .snake = "", .pascal = "" },
    .{ .input = "_", .snake = "_", .pascal = "_" },
    .{ .input = "___", .snake = "___", .pascal = "___" },
    .{ .input = ".", .snake = ".", .pascal = "." },

    .{ .input = "F", .snake = "f", .pascal = "F" },
    .{ .input = "PF", .snake = "pf", .pascal = "Pf" },
    .{ .input = "pF", .snake = "pf", .pascal = "Pf" },

    .{ .input = "_SomeThing", .snake = "_some_thing", .pascal = "SomeThing" },
    .{ .input = "_SomeBadMojo", .snake = "_some_bad_mojo", .pascal = "SomeBadMojo" },
    .{ .input = "_Some_Bad_Mojo", .snake = "_some_bad_mojo", .pascal = "SomeBadMojo" },
    .{ .input = "_Some_Bad_Mojo__", .snake = "_some_bad_mojo__", .pascal = "SomeBadMojo" },

    .{ .input = "$SomeThing", .snake = "$some_thing", .pascal = "$someThing" },
    .{ .input = "@SomeThing", .snake = "@some_thing", .pascal = "@someThing" },

    .{ .input = "Some Thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "Some thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "some thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "some Thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "some     thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "some.thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "some:thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "Some::Thing", .snake = "some_thing", .pascal = "SomeThing" },
    .{ .input = "$Some::Thing", .snake = "$some_thing", .pascal = "$someThing" },
    .{ .input = "$some::Thing", .snake = "$some_thing", .pascal = "$someThing" },

    .{ .input = "NVMe", .snake = "nvme", .pascal = "Nvme" },
    .{ .input = "NVME", .snake = "nvme", .pascal = "Nvme" },
    .{ .input = "nVMEFoobar", .snake = "nvme_foobar", .pascal = "NvmeFoobar" },
    .{ .input = "iSCSI", .snake = "iscsi", .pascal = "Iscsi" },
    .{ .input = "iSCSIDriveName", .snake = "iscsi_drive_name", .pascal = "IscsiDriveName" },
    .{ .input = "PCIe_Functions", .snake = "pcie_functions", .pascal = "PcieFunctions" },
    .{ .input = "PCIeFunctions", .snake = "pcie_functions", .pascal = "PcieFunctions" },
    .{ .input = "PCIEFunctions", .snake = "pcie_functions", .pascal = "PcieFunctions" },
    .{ .input = "PFFunctionNumber", .snake = "pf_function_number", .pascal = "PfFunctionNumber" },

    .{ .input = "FOO_BAR", .snake = "foo_bar", .pascal = "FooBar" },
    .{ .input = "Foo_Bar", .snake = "foo_bar", .pascal = "FooBar" },
    .{ .input = "Foo_bar", .snake = "foo_bar", .pascal = "FooBar" },
    .{ .input = "Foobar", .snake = "foobar", .pascal = "Foobar" },
    .{ .input = "FooBarBaz", .snake = "foo_bar_baz", .pascal = "FooBarBaz" },
    .{ .input = "fooBarBaz", .snake = "foo_bar_baz", .pascal = "FooBarBaz" },
    .{ .input = "PhysFuncNum", .snake = "phys_func_num", .pascal = "PhysFuncNum" },
    .{ .input = "physFuncNum", .snake = "phys_func_num", .pascal = "PhysFuncNum" },
};

test "the nv-redfish case table" {
    const a = std.testing.allocator;
    for (patterns) |pattern| {
        const snake = try toSnakeCase(a, pattern.input);
        defer a.free(snake);
        try std.testing.expectEqualStrings(pattern.snake, snake);

        const pascal = try toPascalCase(a, pattern.input);
        defer a.free(pascal);
        try std.testing.expectEqualStrings(pattern.pascal, pascal);
    }
}

test "Redfish schema names" {
    const a = std.testing.allocator;

    const cases = [_]Expected{
        .{ .input = "ServiceRoot", .snake = "service_root", .pascal = "ServiceRoot" },
        .{ .input = "ComputerSystem", .snake = "computer_system", .pascal = "ComputerSystem" },
        .{ .input = "EthernetInterface", .snake = "ethernet_interface", .pascal = "EthernetInterface" },
        .{ .input = "PCIeDevice", .snake = "pcie_device", .pascal = "PcieDevice" },
        .{ .input = "IndicatorLED", .snake = "indicator_led", .pascal = "IndicatorLed" },
        .{ .input = "UUID", .snake = "uuid", .pascal = "Uuid" },
        // A digit is neither upper nor lower, so it ends any acronym run and
        // the next capital does not start a word. `IPv4Address` stays whole.
        // Redfish uses this shape often enough to be worth pinning.
        .{ .input = "IPv4Address", .snake = "ipv4address", .pascal = "Ipv4address" },
        .{ .input = "v1_25_0", .snake = "v1_25_0", .pascal = "V1250" },
    };

    for (cases) |case| {
        const snake = try toSnakeCase(a, case.input);
        defer a.free(snake);
        try std.testing.expectEqualStrings(case.snake, snake);

        const pascal = try toPascalCase(a, case.input);
        defer a.free(pascal);
        try std.testing.expectEqualStrings(case.pascal, pascal);
    }
}

test toCamelCase {
    const a = std.testing.allocator;

    const cases = [_][2][]const u8{
        .{ "Reset", "reset" },
        // Same digit limitation: `DHCPv6` does not split from `Config`.
        .{ "GetDHCPv6Config", "getDhcpv6config" },
        .{ "get_secret", "getSecret" },
        .{ "SubmitTestEvent", "submitTestEvent" },
    };

    for (cases) |case| {
        const actual = try toCamelCase(a, case[0]);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case[1], actual);
    }
}
