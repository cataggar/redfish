//! The transport's response cache.
//!
//! A Redfish service answers a conditional `GET` with `304 Not Modified`,
//! which carries no replacement body. That saves a body transfer only for a
//! client that kept the previous one, so this is where they are kept: a URI
//! maps to the `ETag` it was last served with and the bytes that came with it.
//!
//! Unlike `nv-redfish`, which caches deserialized values behind `Box<dyn Any>`,
//! this cache holds the raw response body. The typed layer in `redfish_core` is
//! a set of generic free functions over a byte-oriented `BmcTransport` vtable,
//! which cannot carry a type-erased value without a runtime type tag; and every
//! decoded value owns an arena, so handing the same one to two callers would
//! need reference counting. Caching bytes keeps both the vtable and `Owned(T)`
//! simple, and still avoids the part that costs a BMC the most — the transfer.
//!
//! Writes are not invalidated, and do not need to be. A `PATCH` that changes a
//! resource changes its `ETag`, so the stale one this cache holds no longer
//! matches and the next conditional `GET` is answered with `200` and a fresh
//! body. A `PATCH` that changes nothing leaves the `ETag` alone, and the
//! cached body is still correct.

const std = @import("std");

const car_cache = @import("car_cache.zig");

const Allocator = std.mem.Allocator;

/// How much the transport is willing to remember.
pub const CacheSettings = struct {
    /// Responses the cache can hold. Zero disables caching entirely: no
    /// `If-None-Match` is ever sent, so a `304` that could not be answered
    /// cannot be provoked.
    capacity: usize = 100,

    pub const default: CacheSettings = .{};
    pub const disabled: CacheSettings = .{ .capacity = 0 };
};

/// A response body and the `ETag` it was served with.
///
/// Borrowed from the cache; valid until the next `store`.
pub const CachedResponse = struct {
    etag: []const u8,
    body: []const u8,
};

/// The `CarCache` context: URIs are copied and owned, and so are the bodies.
const Context = struct {
    pub fn hash(_: Context, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn dupeKey(_: Context, gpa: Allocator, key: []const u8) Allocator.Error![]const u8 {
        return gpa.dupe(u8, key);
    }

    pub fn freeKey(_: Context, gpa: Allocator, key: []const u8) void {
        gpa.free(key);
    }

    pub fn deinitValue(_: Context, gpa: Allocator, value: *CachedResponse) void {
        gpa.free(value.etag);
        gpa.free(value.body);
    }
};

const Cache = car_cache.CarCache([]const u8, CachedResponse, Context);

/// Response bodies held against their request URIs, under CAR replacement.
///
/// Owns everything it holds. A failure to store is not an error the caller
/// needs to see — the request already succeeded — so `store` swallows
/// allocation failures and simply remembers less.
pub const ResponseCache = struct {
    gpa: Allocator,
    entries: Cache,

    pub fn init(gpa: Allocator, settings: CacheSettings) ResponseCache {
        return .{ .gpa = gpa, .entries = .init(settings.capacity) };
    }

    pub fn deinit(self: *ResponseCache) void {
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn isEnabled(self: ResponseCache) bool {
        return self.entries.capacity() != 0;
    }

    pub fn count(self: ResponseCache) usize {
        return self.entries.len();
    }

    /// What was last served for `uri`, if anything. Also marks the entry as
    /// recently used.
    pub fn lookup(self: *ResponseCache, uri: []const u8) ?CachedResponse {
        return (self.entries.get(uri) orelse return null).*;
    }

    /// Remembers `body` against `uri`, replacing whatever was there.
    ///
    /// Copies both `etag` and `body`; neither has to outlive the call.
    pub fn store(self: *ResponseCache, uri: []const u8, etag: []const u8, body: []const u8) void {
        if (!self.isEnabled()) return;

        const owned_etag = self.gpa.dupe(u8, etag) catch return;
        const owned_body = self.gpa.dupe(u8, body) catch {
            self.gpa.free(owned_etag);
            return;
        };

        var evicted = self.entries.put(
            self.gpa,
            uri,
            .{ .etag = owned_etag, .body = owned_body },
        ) catch {
            self.gpa.free(owned_etag);
            self.gpa.free(owned_body);
            return;
        };
        if (evicted) |*entry| entry.deinit(self.gpa, self.entries.ctx);
    }
};

const testing = std.testing;

test "a disabled cache stores nothing" {
    var cache: ResponseCache = .init(testing.allocator, .disabled);
    defer cache.deinit();

    try testing.expect(!cache.isEnabled());
    cache.store("/redfish/v1/", "W/\"1\"", "{}");
    try testing.expectEqual(@as(?CachedResponse, null), cache.lookup("/redfish/v1/"));
    try testing.expectEqual(@as(usize, 0), cache.count());
}

test "the default settings enable a bounded cache" {
    try testing.expectEqual(@as(usize, 100), CacheSettings.default.capacity);

    var cache: ResponseCache = .init(testing.allocator, .default);
    defer cache.deinit();
    try testing.expect(cache.isEnabled());
}

test "a stored response round-trips" {
    var cache: ResponseCache = .init(testing.allocator, .default);
    defer cache.deinit();

    cache.store("/redfish/v1/Chassis/1", "W/\"abc\"", "{\"Id\":\"1\"}");

    const entry = cache.lookup("/redfish/v1/Chassis/1").?;
    try testing.expectEqualStrings("W/\"abc\"", entry.etag);
    try testing.expectEqualStrings("{\"Id\":\"1\"}", entry.body);
    try testing.expectEqual(@as(?CachedResponse, null), cache.lookup("/redfish/v1/Chassis/2"));
}

test "the cache owns its copies" {
    var cache: ResponseCache = .init(testing.allocator, .default);
    defer cache.deinit();

    {
        var uri: [32]u8 = undefined;
        var etag: [32]u8 = undefined;
        var body: [32]u8 = undefined;
        cache.store(
            try std.fmt.bufPrint(&uri, "/redfish/v1/Chassis/{d}", .{1}),
            try std.fmt.bufPrint(&etag, "W/\"{d}\"", .{7}),
            try std.fmt.bufPrint(&body, "{{\"Id\":\"{d}\"}}", .{1}),
        );
        @memset(&uri, 0);
        @memset(&etag, 0);
        @memset(&body, 0);
    }

    const entry = cache.lookup("/redfish/v1/Chassis/1").?;
    try testing.expectEqualStrings("W/\"7\"", entry.etag);
    try testing.expectEqualStrings("{\"Id\":\"1\"}", entry.body);
}

test "storing again replaces the entry" {
    var cache: ResponseCache = .init(testing.allocator, .default);
    defer cache.deinit();

    cache.store("/redfish/v1/Chassis/1", "W/\"1\"", "{\"AssetTag\":\"a\"}");
    cache.store("/redfish/v1/Chassis/1", "W/\"2\"", "{\"AssetTag\":\"b\"}");

    const entry = cache.lookup("/redfish/v1/Chassis/1").?;
    try testing.expectEqualStrings("W/\"2\"", entry.etag);
    try testing.expectEqualStrings("{\"AssetTag\":\"b\"}", entry.body);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "the cache is bounded and evicts" {
    var cache: ResponseCache = .init(testing.allocator, .{ .capacity = 4 });
    defer cache.deinit();

    var uri: [40]u8 = undefined;
    for (0..64) |i| {
        cache.store(
            try std.fmt.bufPrint(&uri, "/redfish/v1/Chassis/{d}", .{i}),
            "W/\"1\"",
            "{}",
        );
        try testing.expect(cache.count() <= 4);
    }
    try testing.expectEqual(@as(usize, 4), cache.count());
}

test "a query string is part of the key" {
    var cache: ResponseCache = .init(testing.allocator, .default);
    defer cache.deinit();

    // `$expand` returns a different representation of the same resource, so
    // the two must not share an entry.
    cache.store("/redfish/v1/Chassis", "W/\"1\"", "{\"Members@odata.count\":2}");
    cache.store("/redfish/v1/Chassis?$expand=.", "W/\"2\"", "{\"Members\":[{},{}]}");

    try testing.expectEqualStrings("W/\"1\"", cache.lookup("/redfish/v1/Chassis").?.etag);
    try testing.expectEqualStrings("W/\"2\"", cache.lookup("/redfish/v1/Chassis?$expand=.").?.etag);
    try testing.expectEqual(@as(usize, 2), cache.count());
}
