//! OData identifiers used by generated types.
//!
//! Minimal wrappers for the Redfish/OData identifiers that appear throughout
//! generated code:
//!
//!   * `ODataId`   — value of `@odata.id`, the canonical resource path
//!   * `ODataETag` — value of `@odata.etag`, the HTTP entity tag
//!   * `ODataType` — parsed form of `@odata.type`
//!
//! `ODataId` and `ODataETag` are intentionally semantics-unaware: they do not
//! validate or normalize their contents. Both are **non-owning** views over a
//! string whose lifetime belongs to whoever decoded it — in practice the
//! arena inside an `Owned(T)`.
//!
//! References:
//!   * OASIS OData 4.01 — `@odata.id`, `@odata.etag`, `@odata.type`
//!   * DMTF DSP0266 — Redfish Specification

const std = @import("std");

/// Value of an `@odata.id` property: a Redfish resource path.
///
/// Serializes as a bare JSON string rather than as an object.
pub const ODataId = struct {
    value: []const u8,

    /// Conventional Redfish service root path.
    pub const service_root: ODataId = .{ .value = "/redfish/v1" };

    pub fn init(value: []const u8) ODataId {
        return .{ .value = value };
    }

    pub fn eql(self: ODataId, other: ODataId) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    /// Last path segment, or null when the path has no segments.
    ///
    ///   * `/redfish/v1/Systems/1`  → `1`
    ///   * `/redfish/v1/Systems/1/` → `1`
    ///   * `redfish`                → `redfish`
    ///   * `` and `/` and `///`     → null
    pub fn lastSegment(self: ODataId) ?[]const u8 {
        const path = std.mem.trimEnd(u8, self.value, "/");
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
        return if (path.len == 0) null else path;
    }

    /// Whether this path is a segment-aware prefix of `other`. Equal paths
    /// return true.
    ///
    /// `/redfish/v1/TaskService/Tasks` is a prefix of
    /// `/redfish/v1/TaskService/Tasks/42` but not of
    /// `/redfish/v1/TaskService/TasksExtra/42`, because the match must land on
    /// a segment boundary.
    pub fn isPathPrefix(self: ODataId, other: ODataId) bool {
        const prefix = std.mem.trimEnd(u8, self.value, "/");
        if (prefix.len == 0) {
            return std.mem.startsWith(u8, self.value, "/") and
                std.mem.startsWith(u8, other.value, "/");
        }
        if (!std.mem.startsWith(u8, other.value, prefix)) return false;
        const suffix = other.value[prefix.len..];
        return suffix.len == 0 or suffix[0] == '/';
    }

    pub fn format(self: ODataId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.value);
    }

    pub fn jsonStringify(self: ODataId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ODataId {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ODataId {
        return .{
            .value = try std.json.innerParseFromValue([]const u8, allocator, source, options),
        };
    }
};

/// Value of an `@odata.etag` property: an opaque HTTP entity tag.
///
/// Serializes as a bare JSON string rather than as an object.
pub const ODataETag = struct {
    value: []const u8,

    pub fn init(value: []const u8) ODataETag {
        return .{ .value = value };
    }

    pub fn eql(self: ODataETag, other: ODataETag) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    pub fn format(self: ODataETag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.value);
    }

    pub fn jsonStringify(self: ODataETag, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ODataETag {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ODataETag {
        return .{
            .value = try std.json.innerParseFromValue([]const u8, allocator, source, options),
        };
    }
};

/// Parsed form of an `@odata.type` property.
///
/// `#Chassis.v1_22_0.Chassis` parses to namespace `Chassis.v1_22_0` and type
/// name `Chassis`. Both fields borrow from the input string.
pub const ODataType = struct {
    /// Dot-separated namespace, e.g. `Chassis.v1_22_0`. May be empty for an
    /// unversioned, unqualified type.
    namespace: []const u8,
    /// Unqualified type name, e.g. `Chassis`.
    type_name: []const u8,

    /// Parse the value of an `@odata.type` property.
    ///
    /// Returns null when the leading `#` is missing or the remainder is empty.
    pub fn parse(value: []const u8) ?ODataType {
        const body = if (std.mem.startsWith(u8, value, "#")) value[1..] else return null;
        if (body.len == 0) return null;
        if (std.mem.lastIndexOfScalar(u8, body, '.')) |i| {
            return .{ .namespace = body[0..i], .type_name = body[i + 1 ..] };
        }
        return .{ .namespace = "", .type_name = body };
    }

    /// Parse the `@odata.type` property of a decoded JSON object.
    pub fn parseFrom(value: std.json.Value) ?ODataType {
        const object = switch (value) {
            .object => |o| o,
            else => return null,
        };
        const raw = object.get("@odata.type") orelse return null;
        return switch (raw) {
            .string => |s| parse(s),
            else => null,
        };
    }

    /// Iterate the namespace's dot-separated segments, e.g. `Chassis` then
    /// `v1_22_0`.
    pub fn namespaceSegments(self: ODataType) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.namespace, '.');
    }
};

const testing = std.testing;

test "lastSegment returns the last path segment" {
    try testing.expectEqualStrings("1", ODataId.init("/redfish/v1/Systems/1").lastSegment().?);
}

test "lastSegment ignores trailing slashes" {
    try testing.expectEqualStrings("1", ODataId.init("/redfish/v1/Systems/1/").lastSegment().?);
    try testing.expectEqualStrings("1", ODataId.init("/redfish/v1/Systems/1///").lastSegment().?);
}

test "lastSegment returns null when there is no segment" {
    try testing.expectEqual(@as(?[]const u8, null), ODataId.init("").lastSegment());
    try testing.expectEqual(@as(?[]const u8, null), ODataId.init("/").lastSegment());
    try testing.expectEqual(@as(?[]const u8, null), ODataId.init("///").lastSegment());
}

test "lastSegment handles relative paths" {
    try testing.expectEqualStrings("redfish", ODataId.init("redfish").lastSegment().?);
    try testing.expectEqualStrings("1", ODataId.init("redfish/v1/Systems/1").lastSegment().?);
    try testing.expectEqualStrings("redfish", ODataId.init("/redfish").lastSegment().?);
}

test "service root last segment is v1" {
    try testing.expectEqualStrings("v1", ODataId.service_root.lastSegment().?);
}

test "isPathPrefix accepts a child path" {
    const prefix = ODataId.init("/redfish/v1/TaskService/Tasks");
    try testing.expect(prefix.isPathPrefix(ODataId.init("/redfish/v1/TaskService/Tasks/42")));
}

test "isPathPrefix accepts a prefix with a trailing slash" {
    const prefix = ODataId.init("/redfish/v1/TaskService/Tasks/");
    try testing.expect(prefix.isPathPrefix(ODataId.init("/redfish/v1/TaskService/Tasks/42")));
}

test "isPathPrefix rejects a match that is not on a segment boundary" {
    const prefix = ODataId.init("/redfish/v1/TaskService/Tasks");
    try testing.expect(!prefix.isPathPrefix(ODataId.init("/redfish/v1/TaskService/TasksExtra/42")));
}

test "isPathPrefix accepts an exact path" {
    const prefix = ODataId.init("/redfish/v1/TaskService/Tasks");
    try testing.expect(prefix.isPathPrefix(ODataId.init("/redfish/v1/TaskService/Tasks")));
}

test "isPathPrefix accepts the root path and its children" {
    const root = ODataId.init("/");
    try testing.expect(root.isPathPrefix(ODataId.init("/")));
    try testing.expect(root.isPathPrefix(ODataId.init("/redfish")));
}

test "isPathPrefix rejects an unrelated path" {
    const prefix = ODataId.init("/redfish/v1/Chassis");
    try testing.expect(!prefix.isPathPrefix(ODataId.init("/redfish/v1/Systems/1")));
}

test "ODataId round-trips as a bare JSON string" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(ODataId.init("/redfish/v1/Chassis/1"), .{}, &w);
    try testing.expectEqualStrings("\"/redfish/v1/Chassis/1\"", w.buffered());

    const parsed = try std.json.parseFromSlice(ODataId, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", parsed.value.value);
}

test "ODataId parses from a decoded JSON value" {
    const doc = "{\"@odata.id\":\"/redfish/v1/Systems/1\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
    defer parsed.deinit();

    const field = parsed.value.object.get("@odata.id").?;
    const id = try std.json.parseFromValue(ODataId, testing.allocator, field, .{});
    defer id.deinit();
    try testing.expectEqualStrings("/redfish/v1/Systems/1", id.value.value);
}

test "ODataETag round-trips as a bare JSON string" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(ODataETag.init("W/\"abc\""), .{}, &w);

    const parsed = try std.json.parseFromSlice(ODataETag, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("W/\"abc\"", parsed.value.value);
}

test "format writes the raw value" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "/redfish/v1",
        try std.fmt.bufPrint(&buf, "{f}", .{ODataId.service_root}),
    );
}

test "eql compares by value" {
    try testing.expect(ODataId.init("/redfish/v1").eql(ODataId.service_root));
    try testing.expect(!ODataId.init("/redfish/v2").eql(ODataId.service_root));
    try testing.expect(ODataETag.init("abc").eql(ODataETag.init("abc")));
}

test "ODataType parses a versioned type" {
    const t = ODataType.parse("#Chassis.v1_22_0.Chassis").?;
    try testing.expectEqualStrings("Chassis.v1_22_0", t.namespace);
    try testing.expectEqualStrings("Chassis", t.type_name);

    var it = t.namespaceSegments();
    try testing.expectEqualStrings("Chassis", it.next().?);
    try testing.expectEqualStrings("v1_22_0", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "ODataType parses an unversioned type" {
    const t = ODataType.parse("#ServiceRoot.ServiceRoot").?;
    try testing.expectEqualStrings("ServiceRoot", t.namespace);
    try testing.expectEqualStrings("ServiceRoot", t.type_name);
}

test "ODataType parses a bare type name" {
    const t = ODataType.parse("#Chassis").?;
    try testing.expectEqualStrings("", t.namespace);
    try testing.expectEqualStrings("Chassis", t.type_name);
}

test "ODataType rejects empty and unprefixed values" {
    try testing.expectEqual(@as(?ODataType, null), ODataType.parse(""));
    try testing.expectEqual(@as(?ODataType, null), ODataType.parse("#"));
    try testing.expectEqual(@as(?ODataType, null), ODataType.parse("Chassis.v1_22_0.Chassis"));
}

test "parseFrom reads @odata.type out of a JSON object" {
    const doc = "{\"@odata.type\":\"#Chassis.v1_22_0.Chassis\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
    defer parsed.deinit();

    const t = ODataType.parseFrom(parsed.value).?;
    try testing.expectEqualStrings("Chassis.v1_22_0", t.namespace);
    try testing.expectEqualStrings("Chassis", t.type_name);
}

test "parseFrom returns null for a missing, empty, or non-string @odata.type" {
    inline for (.{
        "{}",
        "{\"@odata.type\":\"\"}",
        "{\"@odata.type\":42}",
        "[]",
    }) |doc| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(?ODataType, null), ODataType.parseFrom(parsed.value));
    }
}
