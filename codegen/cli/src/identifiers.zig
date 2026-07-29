//! Turning schema-derived names into Zig identifiers.
//!
//! Escaping is delegated to `std.zig`, which already knows the language's
//! keywords and primitive type names — a hand-maintained keyword list would
//! only drift. What this module adds is the handful of cases `std.zig` leaves
//! to the caller: an empty name, and a name that is only underscores.

const std = @import("std");

/// Whether `name` can be written into Zig source as-is.
///
/// Conservative on purpose: primitive type names (`bool`, `u8`, `type`, …)
/// and bare underscores are reported as needing escaping even though some
/// positions would accept them.
pub fn isBare(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.zig.isValidId(name)) return false;
    if (std.zig.isPrimitive(name)) return false;
    for (name) |c| if (c != '_') return true;
    return false;
}

/// Formats `name` as a Zig identifier, quoting it when it is not a valid bare
/// one. Intended for `{f}` in emitted source.
///
///     try w.print("{f}: []const u8,\n", .{identifiers.fmt("@odata.id")});
///     // @"@odata.id": []const u8,
///
/// An empty name formats as `@"_"`; the emitter should not produce one, but a
/// malformed schema should not produce unparsable output either.
pub fn fmt(name: []const u8) std.zig.FormatId {
    return std.zig.fmtId(if (name.len == 0) "_" else name);
}

/// `fmt` as an owned string. Prefer `fmt` when writing to a writer.
pub fn escape(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{fmt(name)});
}

test isBare {
    try std.testing.expect(isBare("reset"));
    try std.testing.expect(isBare("PowerState"));
    try std.testing.expect(isBare("_leading"));
    try std.testing.expect(isBare("Uuid"));

    try std.testing.expect(!isBare(""));
    try std.testing.expect(!isBare("_"));
    try std.testing.expect(!isBare("__"));
    try std.testing.expect(!isBare("error"));
    try std.testing.expect(!isBare("type"));
    try std.testing.expect(!isBare("bool"));
    // `i386` is a 386-bit integer, and every `i<n>` / `u<n>` name like it is
    // a primitive. Quoting them is the only safe rule.
    try std.testing.expect(!isBare("i386"));
    try std.testing.expect(!isBare("@odata.id"));
    try std.testing.expect(!isBare("32Bit"));
}

test "fmt leaves ordinary names alone" {
    try std.testing.expectFmt("reset", "{f}", .{fmt("reset")});
    try std.testing.expectFmt("PowerState", "{f}", .{fmt("PowerState")});
    try std.testing.expectFmt("v1_25_0", "{f}", .{fmt("v1_25_0")});
}

test "fmt quotes names Zig would reject" {
    try std.testing.expectFmt("@\"error\"", "{f}", .{fmt("error")});
    try std.testing.expectFmt("@\"type\"", "{f}", .{fmt("type")});
    try std.testing.expectFmt("@\"bool\"", "{f}", .{fmt("bool")});
    try std.testing.expectFmt("@\"_\"", "{f}", .{fmt("_")});
    try std.testing.expectFmt("@\"_\"", "{f}", .{fmt("")});
}

test "fmt quotes the Redfish names that are not identifiers at all" {
    try std.testing.expectFmt("@\"@odata.id\"", "{f}", .{fmt("@odata.id")});
    try std.testing.expectFmt("@\"@odata.type\"", "{f}", .{fmt("@odata.type")});
    try std.testing.expectFmt("@\"Members@odata.count\"", "{f}", .{fmt("Members@odata.count")});
    try std.testing.expectFmt("@\"32Bit\"", "{f}", .{fmt("32Bit")});
}

test escape {
    const a = std.testing.allocator;

    const plain = try escape(a, "reset");
    defer a.free(plain);
    try std.testing.expectEqualStrings("reset", plain);

    const quoted = try escape(a, "@odata.id");
    defer a.free(quoted);
    try std.testing.expectEqualStrings("@\"@odata.id\"", quoted);
}
