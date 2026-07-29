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

//! Telling "not sent" apart from "sent as null".
//!
//! Reading a resource, the difference rarely matters: a service that omits a
//! property and one that sends it as null are both saying they have no value.
//! Writing one, it is the whole message. A PATCH that omits a property leaves
//! it alone; a PATCH that sends it as null clears it. A client that cannot
//! express the difference cannot clear anything.
//!
//! `?T` collapses the two, because `std.json` decodes a null token into the
//! same `null` an absent field defaults to. So a field that has to keep them
//! apart is declared `Nullable(T)` instead, defaulting to `.absent`.
//!
//! A value cannot leave itself out of an object, so the containing struct is
//! what skips absent fields -- generated update shapes emit a `jsonStringify`
//! that does exactly that.

const std = @import("std");

/// A property that may be absent, explicitly null, or set.
pub fn Nullable(comptime T: type) type {
    return union(enum) {
        /// The property was not in the payload, and will not be written.
        absent,
        /// The property was sent as null, or is being cleared.
        none,
        value: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// The value, treating an absent property and a null one alike --
        /// which is what a reader usually wants.
        pub fn get(self: Self) ?T {
            return switch (self) {
                .value => |value| value,
                else => null,
            };
        }

        /// Whether the property will appear in a serialized payload at all.
        pub fn isPresent(self: Self) bool {
            return self != .absent;
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return .none;
            }
            return .{ .value = try std.json.innerParse(T, allocator, source, options) };
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Self {
            if (source == .null) return .none;
            return .{ .value = try std.json.innerParseFromValue(T, allocator, source, options) };
        }

        /// An absent property serializes as null. Leaving it out is the
        /// containing struct's job, since a value cannot skip itself.
        pub fn jsonStringify(self: Self, jw: anytype) !void {
            switch (self) {
                .absent, .none => try jw.write(null),
                .value => |value| try jw.write(value),
            }
        }
    };
}

const testing = std.testing;

test "an absent property differs from a null one" {
    const Payload = struct {
        AssetTag: Nullable([]const u8) = .absent,
        Name: Nullable([]const u8) = .absent,
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Payload,
        arena.allocator(),
        \\{"AssetTag": null}
    ,
        .{},
    );

    try testing.expect(parsed.AssetTag == .none);
    try testing.expect(parsed.Name == .absent);
    try testing.expect(parsed.AssetTag.isPresent());
    try testing.expect(!parsed.Name.isPresent());
    try testing.expect(parsed.AssetTag.get() == null);
}

test "a set property keeps its value" {
    const Payload = struct {
        AssetTag: Nullable([]const u8) = .absent,
        Count: Nullable(i64) = .absent,
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Payload,
        arena.allocator(),
        \\{"AssetTag": "rack-1", "Count": 3}
    ,
        .{},
    );

    try testing.expectEqualStrings("rack-1", parsed.AssetTag.get().?);
    try testing.expectEqual(@as(i64, 3), parsed.Count.get().?);
}

test "a nested value parses through" {
    const Inner = struct { State: []const u8 = "" };
    const Payload = struct { Status: Nullable(Inner) = .absent };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Payload,
        arena.allocator(),
        \\{"Status": {"State": "Enabled"}}
    ,
        .{},
    );

    try testing.expectEqualStrings("Enabled", parsed.Status.get().?.State);
}

test "parsing from a value tells the two apart as well" {
    const Payload = struct {
        AssetTag: Nullable([]const u8) = .absent,
        Name: Nullable([]const u8) = .absent,
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"AssetTag": null}
    ,
        .{},
    );
    const parsed = try std.json.parseFromValueLeaky(Payload, arena.allocator(), value, .{});

    try testing.expect(parsed.AssetTag == .none);
    try testing.expect(parsed.Name == .absent);
}

test "clearing a property serializes as null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cleared: Nullable([]const u8) = .none;
    const set: Nullable([]const u8) = .init("rack-1");

    try testing.expectEqualStrings(
        "null",
        try std.json.Stringify.valueAlloc(arena.allocator(), cleared, .{}),
    );
    try testing.expectEqualStrings(
        "\"rack-1\"",
        try std.json.Stringify.valueAlloc(arena.allocator(), set, .{}),
    );
}
