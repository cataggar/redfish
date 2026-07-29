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

//! `zig fmt`, in process.
//!
//! The reference generator shells out to `rustfmt`, and azure-sdk-for-zig's
//! generator shells out to `zig fmt`. Neither is necessary here: `std.zig.Ast`
//! is the same parser and renderer the `zig fmt` subcommand drives, so the
//! generator can normalize its own output without finding a compiler on
//! `PATH` or spawning anything.
//!
//! That turns formatting into a correctness gate as well as a cosmetic one.
//! The emitter writes text, and text can be malformed; running it through the
//! parser means a generator bug surfaces here, naming the file and the line,
//! rather than as a compile error in a package that was already written to
//! disk.

const std = @import("std");

pub const Error = std.mem.Allocator.Error;

/// The outcome of formatting one file.
pub const Result = union(enum) {
    /// The source parsed. Formatted bytes, allocated from the arena.
    formatted: []u8,
    /// The source did not parse, which means the emitter produced something
    /// that is not Zig. Rendered diagnostics, one per line.
    invalid: []const u8,
};

/// Formats generated Zig source.
///
/// `path` appears in diagnostics only; nothing is read from disk.
pub fn zig(arena: std.mem.Allocator, path: []const u8, source: []const u8) Error!Result {
    var tree = try std.zig.Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
    if (tree.errors.len == 0) return .{ .formatted = try tree.renderAlloc(arena) };

    var out: std.Io.Writer.Allocating = .init(arena);
    for (tree.errors) |parse_error| {
        const location = tree.tokenLocation(0, parse_error.token);
        out.writer.print("{s}:{d}:{d}: ", .{
            path,
            location.line + 1,
            location.column + 1,
        }) catch return error.OutOfMemory;
        tree.renderError(parse_error, &out.writer) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return .{ .invalid = out.written() };
}

/// Formats a file only if it is Zig, leaving `README.md` and `build.zig.zon`
/// alone. `.zon` has its own grammar, which `std.zig.Ast` will not parse as
/// Zig, and the emitter already writes it in canonical form.
pub fn file(arena: std.mem.Allocator, path: []const u8, source: []const u8) Error!Result {
    if (!std.mem.endsWith(u8, path, ".zig")) return .{ .formatted = try arena.dupe(u8, source) };
    return zig(arena, path, source);
}

const testing = std.testing;

test "formatting normalizes whatever the emitter spelled loosely" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try zig(arena.allocator(), "src/chassis.zig",
        \\pub const Chassis = struct {
        \\Id : []const u8,
        \\};
    );
    try testing.expectEqualStrings(
        \\pub const Chassis = struct {
        \\    Id: []const u8,
        \\};
        \\
    , result.formatted);
}

test "source that is already formatted comes back unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\const std = @import("std");
        \\
        \\pub const value: u8 = 1;
        \\
    ;
    const result = try zig(arena.allocator(), "src/root.zig", source);
    try testing.expectEqualStrings(source, result.formatted);
}

test "source that is not Zig is reported, with the line that broke it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try zig(arena.allocator(), "src/chassis.zig",
        \\pub const Chassis = struct {
        \\    Id: []const u8,
    );
    try testing.expect(std.mem.startsWith(u8, result.invalid, "src/chassis.zig:"));
}

test "a file that is not Zig is passed through" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source = "# redfish_schema_test\n\nnot   zig.\n";
    const result = try file(arena.allocator(), "README.md", source);
    try testing.expectEqualStrings(source, result.formatted);

    const manifest = ".{\n    .name = .redfish_schema_test,\n}\n";
    const zon = try file(arena.allocator(), "build.zig.zon", manifest);
    try testing.expectEqualStrings(manifest, zon.formatted);
}

test "formatting is idempotent, so regeneration does not churn the diff" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const once = try zig(allocator, "src/chassis.zig",
        \\pub const Chassis=struct{Id:[]const u8,
        \\  @"@odata.id":  core.ODataId,};
    );
    const twice = try zig(allocator, "src/chassis.zig", once.formatted);
    try testing.expectEqualStrings(once.formatted, twice.formatted);
}
