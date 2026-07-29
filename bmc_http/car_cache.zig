//! CAR — Clock with Adaptive Replacement.
//!
//! Bansal & Modha, *CAR: Clock with Adaptive Replacement*, USENIX FAST 2004:
//! <https://www.usenix.org/legacy/publications/library/proceedings/fast04/tech/full_papers/bansal/bansal.pdf>
//!
//! CAR is ARC's clock-based cousin: two resident lists — `T1` for pages seen
//! once and `T2` for pages seen again — each swept by a clock hand, plus two
//! ghost lists `B1` and `B2` holding the keys of pages recently demoted out of
//! `T1` and `T2`. A hit on a ghost is evidence that the corresponding resident
//! list was too small, so the target size `p` for `T1` moves toward it. The
//! result is scan-resistant without the per-access list surgery LRU needs.
//!
//! This is a port of `nv-redfish-bmc-http`'s `cache.rs`, which follows the
//! paper's pseudocode line by line, with the same clock-native reading of
//! line 36: "make it the tail page in T2" is realized by clearing the
//! reference bit and letting the hand move on — in a circular list that
//! leaves the page as the last one the hand revisits.
//!
//! The cache is used by the Redfish transport to hold decoded response bodies
//! against their URIs, so that a `304 Not Modified` — which carries no
//! replacement body — can be answered from memory.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A CAR cache keyed by `K`, holding values of type `V`.
///
/// `Context` follows the `std.hash_map` convention and must provide:
///
/// - `hash(ctx, K) u64`
/// - `eql(ctx, K, K) bool`
///
/// It may additionally provide, to let the cache own its keys and values:
///
/// - `dupeKey(ctx, Allocator, K) Allocator.Error!K` — defaults to the identity
/// - `freeKey(ctx, Allocator, K) void` — defaults to a no-op
/// - `deinitValue(ctx, Allocator, *V) void` — defaults to a no-op
///
/// A key is duplicated once, when it first enters the cache, and freed once,
/// when it leaves the index. While it is resident the same copy is shared by
/// the index and by whichever list holds it, so a demotion from `T1` to `B1`
/// costs no allocation.
pub fn CarCache(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        /// Cache capacity, `c` in the paper. Zero disables the cache.
        c: usize,
        /// Target size for `T1`, `p` in the paper.
        p: usize = 0,

        /// Recent pages — seen once.
        t1: ClockList,
        /// Frequent pages — seen more than once.
        t2: ClockList,
        /// Keys demoted out of `T1`.
        b1: GhostList,
        /// Keys demoted out of `T2`.
        b2: GhostList,

        index: Index = .empty,
        ctx: Context,

        const Index = std.HashMapUnmanaged(K, Location, Context, std.hash_map.default_max_load_percentage);

        /// Where a key currently lives, and in which slot.
        const Location = union(enum) {
            t1: usize,
            t2: usize,
            b1: usize,
            b2: usize,

            fn isGhost(self: Location) bool {
                return switch (self) {
                    .b1, .b2 => true,
                    .t1, .t2 => false,
                };
            }
        };

        /// A resident page.
        const Entry = struct {
            key: K,
            value: V,
            /// The clock's reference bit. Always starts clear.
            ref_bit: bool = false,
        };

        /// An entry that left the cache to make room for a new one.
        ///
        /// The caller takes ownership of `value` and must release it, with
        /// `deinit` or otherwise. `key` is *borrowed* from the cache — the
        /// demoted key lives on in a ghost list — and is only valid until the
        /// next mutation.
        pub const Evicted = struct {
            key: K,
            value: V,

            pub fn deinit(self: *Evicted, gpa: Allocator, ctx: Context) void {
                deinitValue(ctx, gpa, &self.value);
                self.* = undefined;
            }
        };

        /// A node in a ghost list's doubly-linked chain.
        const GhostNode = struct {
            key: K,
            prev: ?usize,
            next: ?usize,
        };

        /// `B1` / `B2`: an LRU list of keys with no values attached.
        ///
        /// Slot storage grows on demand up to `capacity`, so an idle cache
        /// holds none.
        const GhostList = struct {
            entries: std.ArrayList(?GhostNode) = .empty,
            capacity: usize,
            /// LRU end.
            head: ?usize = null,
            /// MRU end.
            tail: ?usize = null,
            free_slots: std.ArrayList(usize) = .empty,
            size: usize = 0,

            fn deinit(self: *GhostList, gpa: Allocator) void {
                self.entries.deinit(gpa);
                self.free_slots.deinit(gpa);
                self.* = undefined;
            }

            fn acquireSlot(self: *GhostList) ?usize {
                if (self.free_slots.pop()) |slot| return slot;
                if (self.entries.items.len < self.capacity) {
                    self.entries.appendAssumeCapacity(null);
                    return self.entries.items.len - 1;
                }
                return null;
            }

            /// Pre-allocates every slot the list can ever need, so that no
            /// later operation on it can fail. See `CarCache.reserveStorage`.
            fn reserveStorage(self: *GhostList, gpa: Allocator) Allocator.Error!void {
                try self.entries.ensureTotalCapacity(gpa, self.capacity);
                try self.free_slots.ensureTotalCapacity(gpa, self.capacity);
            }

            /// Inserts at the MRU end. Null when the list is full.
            fn insertAtTail(self: *GhostList, key: K) ?usize {
                const slot = self.acquireSlot() orelse return null;

                if (self.tail) |old_tail| {
                    if (self.entries.items[old_tail]) |*node| node.next = slot;
                } else {
                    self.head = slot;
                }

                self.entries.items[slot] = .{ .key = key, .prev = self.tail, .next = null };
                self.tail = slot;
                self.size += 1;
                return slot;
            }

            /// Removes the LRU end, returning its key.
            fn removeLru(self: *GhostList) ?K {
                const head_slot = self.head orelse return null;
                const node = self.entries.items[head_slot] orelse return null;
                self.entries.items[head_slot] = null;

                self.free_slots.appendAssumeCapacity(head_slot);
                self.size -= 1;

                if (self.size == 0) {
                    self.head = null;
                    self.tail = null;
                } else {
                    self.head = node.next;
                    if (self.head) |new_head| {
                        if (self.entries.items[new_head]) |*new_head_node| new_head_node.prev = null;
                    }
                }
                return node.key;
            }

            fn remove(self: *GhostList, slot: usize) bool {
                const node = self.entries.items[slot] orelse return false;
                self.entries.items[slot] = null;

                self.free_slots.appendAssumeCapacity(slot);
                self.size -= 1;

                if (self.size == 0) {
                    self.head = null;
                    self.tail = null;
                    return true;
                }

                if (node.prev) |prev_slot| {
                    if (self.entries.items[prev_slot]) |*prev| prev.next = node.next;
                } else {
                    self.head = node.next;
                }
                if (node.next) |next_slot| {
                    if (self.entries.items[next_slot]) |*next| next.prev = node.prev;
                } else {
                    self.tail = node.prev;
                }
                return true;
            }

            fn len(self: GhostList) usize {
                return self.size;
            }
        };

        /// A node in a clock list's circular chain.
        const ClockNode = struct {
            entry: Entry,
            prev: usize,
            next: usize,
        };

        /// `T1` / `T2`: resident pages in a circular list.
        ///
        /// Occupied slots form a ring in insertion order and the hand points
        /// at the head — the next victim candidate — so reading the head,
        /// removing it, and advancing the hand are all O(1) no matter how
        /// sparsely the slot vector is populated.
        const ClockList = struct {
            nodes: std.ArrayList(?ClockNode) = .empty,
            capacity: usize,
            /// Slot of the current head; null when the list is empty.
            hand: ?usize = null,
            free_slots: std.ArrayList(usize) = .empty,
            size: usize = 0,

            fn deinit(self: *ClockList, gpa: Allocator) void {
                self.nodes.deinit(gpa);
                self.free_slots.deinit(gpa);
                self.* = undefined;
            }

            fn acquireSlot(self: *ClockList) ?usize {
                if (self.free_slots.pop()) |slot| return slot;
                if (self.nodes.items.len < self.capacity) {
                    self.nodes.appendAssumeCapacity(null);
                    return self.nodes.items.len - 1;
                }
                return null;
            }

            /// Pre-allocates every slot the list can ever need. See
            /// `CarCache.reserveStorage`.
            fn reserveStorage(self: *ClockList, gpa: Allocator) Allocator.Error!void {
                try self.nodes.ensureTotalCapacity(gpa, self.capacity);
                try self.free_slots.ensureTotalCapacity(gpa, self.capacity);
            }

            /// Inserts immediately behind the hand, so the new entry is the
            /// last one the clock will visit. Null when the list is full.
            fn insertAtTail(self: *ClockList, key: K, value: V) ?usize {
                const links: ?struct { usize, usize } = if (self.hand) |hand| links: {
                    const node = self.nodes.items[hand] orelse return null;
                    break :links .{ node.prev, hand };
                } else null;

                const slot = self.acquireSlot() orelse return null;
                const prev, const next = links orelse .{ slot, slot };

                self.nodes.items[slot] = .{
                    .entry = .{ .key = key, .value = value },
                    .prev = prev,
                    .next = next,
                };
                if (links != null) {
                    if (self.nodes.items[prev]) |*prev_node| prev_node.next = slot;
                    if (self.nodes.items[next]) |*next_node| next_node.prev = slot;
                } else {
                    self.hand = slot;
                }
                self.size += 1;
                return slot;
            }

            fn headPage(self: *ClockList) ?*Entry {
                const hand = self.hand orelse return null;
                if (self.nodes.items[hand]) |*node| return &node.entry;
                return null;
            }

            fn removeHeadPage(self: *ClockList) ?Entry {
                const hand = self.hand orelse return null;
                const node = self.nodes.items[hand] orelse return null;
                self.nodes.items[hand] = null;

                self.free_slots.appendAssumeCapacity(hand);
                self.size -= 1;

                if (self.size == 0) {
                    self.hand = null;
                } else {
                    if (self.nodes.items[node.prev]) |*prev| prev.next = node.next;
                    if (self.nodes.items[node.next]) |*next| next.prev = node.prev;
                    self.hand = node.next;
                }
                return node.entry;
            }

            /// Moves the hand past the current head.
            fn advanceHand(self: *ClockList) void {
                const hand = self.hand orelse return;
                if (self.nodes.items[hand]) |node| self.hand = node.next;
            }

            fn getMut(self: *ClockList, slot: usize) ?*Entry {
                if (slot >= self.nodes.items.len) return null;
                if (self.nodes.items[slot]) |*node| return &node.entry;
                return null;
            }

            fn get(self: *const ClockList, slot: usize) ?*const Entry {
                if (slot >= self.nodes.items.len) return null;
                if (self.nodes.items[slot]) |*node| return &node.entry;
                return null;
            }

            fn len(self: ClockList) usize {
                return self.size;
            }
        };

        /// A cache of `capacity` entries. Zero disables it: nothing is stored
        /// and every lookup misses.
        pub fn init(size: usize) Self {
            return initContext(size, undefined);
        }

        pub fn initContext(size: usize, ctx: Context) Self {
            return .{
                .c = size,
                .t1 = .{ .capacity = size },
                .t2 = .{ .capacity = size },
                // One slack slot: a put demotes at most one page into a ghost
                // list and ends with both at or below `c` — the guarded
                // discards on lines 6-9, or the requested ghost's own removal,
                // restore the bound. Only B2 can transiently reach `c + 1`,
                // which is what keeps the requested key's ghost alive long
                // enough for its adaptation hit. B1 peaks at `c` and is sized
                // alike.
                .b1 = .{ .capacity = size +| 1 },
                .b2 = .{ .capacity = size +| 1 },
                .ctx = ctx,
            };
        }

        /// Pre-allocates every slot the four lists can ever hold.
        ///
        /// Called on the first `put`, so an idle cache still holds no slot
        /// storage. After it, list operations cannot fail, which is what lets
        /// `put` do all of its allocation before it mutates anything.
        fn reserveStorage(self: *Self, gpa: Allocator) Allocator.Error!void {
            try self.t1.reserveStorage(gpa);
            try self.t2.reserveStorage(gpa);
            try self.b1.reserveStorage(gpa);
            try self.b2.reserveStorage(gpa);
        }

        /// Releases every key and every resident value.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.t1.nodes.items) |*maybe_node| {
                if (maybe_node.*) |*node| deinitValue(self.ctx, gpa, &node.entry.value);
            }
            for (self.t2.nodes.items) |*maybe_node| {
                if (maybe_node.*) |*node| deinitValue(self.ctx, gpa, &node.entry.value);
            }

            var keys = self.index.keyIterator();
            while (keys.next()) |key| freeKey(self.ctx, gpa, key.*);

            self.index.deinit(gpa);
            self.t1.deinit(gpa);
            self.t2.deinit(gpa);
            self.b1.deinit(gpa);
            self.b2.deinit(gpa);
            self.* = undefined;
        }

        /// The cached value for `key`, or null on a miss.
        ///
        /// Lines 1-3: a hit sets the page's reference bit. A ghost entry is
        /// not a hit — the key is remembered, the body is not.
        pub fn get(self: *Self, key: K) ?*V {
            const location = self.index.get(key) orelse return null;
            const entry = switch (location) {
                .t1 => |slot| self.t1.getMut(slot),
                .t2 => |slot| self.t2.getMut(slot),
                .b1, .b2 => null,
            } orelse return null;

            entry.ref_bit = true;
            return &entry.value;
        }

        /// Inserts or replaces the value for `key`.
        ///
        /// Returns the entry that had to leave to make room, if any. The
        /// caller owns its value; see `Evicted`.
        pub fn put(self: *Self, gpa: Allocator, key: K, value: V) Allocator.Error!?Evicted {
            if (self.c == 0) {
                var discarded = value;
                deinitValue(self.ctx, gpa, &discarded);
                return null;
            }

            // A hit on a resident page refreshes it in place. Line 2 sets the
            // reference bit whether the request reads or rewrites.
            if (self.index.get(key)) |location| {
                const entry = switch (location) {
                    .t1 => |slot| self.t1.getMut(slot),
                    .t2 => |slot| self.t2.getMut(slot),
                    .b1, .b2 => null,
                };
                if (entry) |resident| {
                    resident.ref_bit = true;
                    deinitValue(self.ctx, gpa, &resident.value);
                    resident.value = value;
                    return null;
                }
            }

            // Everything that can fail happens here, before a single list is
            // touched. `replace` moves a page into a ghost list, so a failure
            // partway through the rest of this function would leave the cache
            // one entry short of full with ghosts already present — breaking
            // invariant I5 for every later call. Reserving up front means the
            // remainder cannot fail at all.
            try self.reserveStorage(gpa);
            try self.index.ensureUnusedCapacity(gpa, 1);
            const owned = try dupeKey(self.ctx, gpa, key);

            var evicted: ?Entry = null;
            // The key's location after `replace`. When the cache is not full,
            // invariant I5 says B1 ∪ B2 is empty, so null is exact.
            var location: ?Location = null;

            std.debug.assert(self.t1.len() + self.t2.len() == self.c or
                self.b1.len() + self.b2.len() == 0);

            // Line 4: if (|T1| + |T2| = c)
            if (self.t1.len() + self.t2.len() == self.c) {
                // Line 5.
                evicted = self.replace(gpa);

                // `replace` can discard ghosts, so the lookup has to happen
                // after it. One lookup serves lines 6 and 8 and the B1/B2
                // dispatch below.
                location = self.index.get(key);
                const in_ghosts = if (location) |found| found.isGhost() else false;

                // Line 6: if ((x ∉ B1 ∪ B2) and (|T1| + |B1| = c))
                if (!in_ghosts and self.t1.len() + self.b1.len() == self.c) {
                    // Line 7: discard the LRU page in B1.
                    if (self.b1.removeLru()) |discarded| self.dropKey(gpa, discarded);
                }
                // Line 8: elseif ((|T1| + |T2| + |B1| + |B2| = 2c) and (x ∉ B1 ∪ B2))
                else if (!in_ghosts and
                    self.t1.len() + self.t2.len() + self.b1.len() + self.b2.len() == 2 * self.c)
                {
                    // Line 9: discard the LRU page in B2.
                    if (self.b2.removeLru()) |discarded| self.dropKey(gpa, discarded);
                }
            }

            if (location) |found| switch (found) {
                // Line 14: x is in B1.
                .b1 => |slot| {
                    // Line 15: p = min{p + max{1, |B2|/|B1|}, c}.
                    const delta = if (self.b1.len() > 0) @max(1, self.b2.len() / self.b1.len()) else 1;
                    self.p = @min(self.p + delta, self.c);

                    _ = self.b1.remove(slot);
                    // Line 16: move x to the tail of T2 with a clear reference
                    // bit. The cache already has its own copy of this key, so
                    // the one just duplicated is surplus.
                    freeKey(self.ctx, gpa, owned);
                    self.moveToT2(gpa, self.index.getKey(key).?, value);
                },
                // Line 17: x must be in B2.
                .b2 => |slot| {
                    // Line 18: p = max{p − max{1, |B1|/|B2|}, 0}.
                    const delta = if (self.b2.len() > 0) @max(1, self.b1.len() / self.b2.len()) else 1;
                    self.p -|= delta;

                    _ = self.b2.remove(slot);
                    // Line 19.
                    freeKey(self.ctx, gpa, owned);
                    self.moveToT2(gpa, self.index.getKey(key).?, value);
                },
                .t1, .t2 => unreachable, // Resident hits returned above.
            } else {
                // Line 12: x is in neither ghost list.
                // Line 13: insert x at the tail of T1 with a clear reference
                // bit. This is the only place a key enters the cache, and so
                // the only place the duplicate made above is kept.
                if (self.t1.insertAtTail(owned, value)) |slot| {
                    self.index.putAssumeCapacity(owned, .{ .t1 = slot });
                } else {
                    freeKey(self.ctx, gpa, owned);
                    var discarded = value;
                    deinitValue(self.ctx, gpa, &discarded);
                }
            }

            const entry = evicted orelse return null;
            return .{ .key = entry.key, .value = entry.value };
        }

        /// Moves an already-indexed key to the tail of `T2` and repoints its
        /// index entry. If `T2` cannot take it, the key leaves the cache
        /// entirely, so the index and the lists stay consistent.
        fn moveToT2(self: *Self, gpa: Allocator, key: K, value: V) void {
            if (self.t2.insertAtTail(key, value)) |slot| {
                if (self.index.getPtr(key)) |location| location.* = .{ .t2 = slot };
            } else {
                var discarded = value;
                deinitValue(self.ctx, gpa, &discarded);
                self.dropKey(gpa, key);
            }
        }

        /// Line 5: `replace()`.
        fn replace(self: *Self, gpa: Allocator) ?Entry {
            // Line 23: repeat.
            while (true) {
                // Line 24: if (|T1| >= max(1, p)).
                if (self.t1.len() >= @max(1, self.p)) {
                    if (self.tryReplaceFromT1(gpa)) |found| return found;
                    // No advance: a T1 pass that found no victim recirculated
                    // the head into T2, and removing it already moved the hand
                    // on. Advancing again would skip a page without ever
                    // examining its reference bit.
                } else {
                    // Line 31.
                    if (self.tryReplaceFromT2(gpa)) |found| return found;
                    // A T2 pass that found no victim only cleared the head's
                    // reference bit, so move the hand past it.
                    self.t2.advanceHand();
                }
            }
            // Line 39: until (found).
        }

        fn tryReplaceFromT1(self: *Self, gpa: Allocator) ?Entry {
            const head = self.t1.headPage() orelse return null;

            // Line 25: if the reference bit of T1's head page is 0.
            if (!head.ref_bit) {
                // Line 26-27: found; demote the head of T1 to the MRU end of B1.
                const entry = self.t1.removeHeadPage() orelse return null;
                const slot = self.ghostInsert(gpa, &self.b1, entry.key);
                // The key was already indexed, in T1; repoint it in place.
                if (self.index.getPtr(entry.key)) |location| location.* = .{ .b1 = slot };
                return entry;
            }

            // Line 28-29: clear the reference bit and make it the tail of T2.
            head.ref_bit = false;
            if (self.t1.removeHeadPage()) |entry| {
                self.moveToT2(gpa, entry.key, entry.value);
            }
            return null;
        }

        fn tryReplaceFromT2(self: *Self, gpa: Allocator) ?Entry {
            const head = self.t2.headPage() orelse return null;

            // Line 32: if the reference bit of T2's head page is 0.
            if (!head.ref_bit) {
                // Line 33-34: found; demote the head of T2 to the MRU end of B2.
                const entry = self.t2.removeHeadPage() orelse return null;
                const slot = self.ghostInsert(gpa, &self.b2, entry.key);
                if (self.index.getPtr(entry.key)) |location| location.* = .{ .b2 = slot };
                return entry;
            }

            // Line 35-36: clear the reference bit and make it the tail of T2.
            //
            // In a clock, "make it the tail" is just the hand passing over the
            // page: clear the bit and leave the entry where it is. Once the
            // caller advances the hand, this page is the last it will revisit.
            head.ref_bit = false;
            return null;
        }

        /// Inserts a demoted key at the MRU end of a ghost list.
        ///
        /// The `c + 1` sizing means the list cannot already be full here.
        /// Should that ever stop holding, evicting the ghost list's own LRU is
        /// the recoverable answer: it costs one forgotten key rather than an
        /// index that disagrees with the lists, and it keeps the demoted key
        /// — which `put` is about to hand back to the caller — alive.
        fn ghostInsert(self: *Self, gpa: Allocator, list: *GhostList, key: K) usize {
            if (list.insertAtTail(key)) |slot| return slot;

            if (list.removeLru()) |discarded| self.dropKey(gpa, discarded);
            return list.insertAtTail(key).?;
        }

        /// Removes a key from the index and releases the cache's copy of it.
        fn dropKey(self: *Self, gpa: Allocator, key: K) void {
            if (self.index.fetchRemove(key)) |removed| {
                freeKey(self.ctx, gpa, removed.key);
            }
        }

        /// Resident entries, `|T1| + |T2|`.
        pub fn len(self: Self) usize {
            return self.t1.len() + self.t2.len();
        }

        pub fn isEmpty(self: Self) bool {
            return self.len() == 0;
        }

        pub fn capacity(self: Self) usize {
            return self.c;
        }

        /// The adaptation parameter `p`: the current target size for `T1`.
        pub fn adaptationParameter(self: Self) usize {
            return self.p;
        }

        fn dupeKey(ctx: Context, gpa: Allocator, key: K) Allocator.Error!K {
            if (comptime @hasDecl(Context, "dupeKey")) return ctx.dupeKey(gpa, key);
            return key;
        }

        fn freeKey(ctx: Context, gpa: Allocator, key: K) void {
            if (comptime @hasDecl(Context, "freeKey")) return ctx.freeKey(gpa, key);
        }

        fn deinitValue(ctx: Context, gpa: Allocator, value: *V) void {
            if (comptime @hasDecl(Context, "deinitValue")) return ctx.deinitValue(gpa, value);
        }
    };
}

/// A CAR cache with `[]const u8` keys that the cache copies and owns.
pub fn StringCarCache(comptime V: type, comptime Context: type) type {
    return CarCache([]const u8, V, Context);
}

/// The `Context` for a cache with owned `[]const u8` keys and values that need
/// no cleanup.
pub const StringKeyContext = struct {
    pub fn hash(_: StringKeyContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StringKeyContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn dupeKey(_: StringKeyContext, gpa: Allocator, key: []const u8) Allocator.Error![]const u8 {
        return gpa.dupe(u8, key);
    }

    pub fn freeKey(_: StringKeyContext, gpa: Allocator, key: []const u8) void {
        gpa.free(key);
    }
};

const testing = std.testing;

/// Keys are plain integers, values need no cleanup.
const IntContext = struct {
    pub fn hash(_: IntContext, key: i32) u64 {
        return std.hash.int(@as(u32, @bitCast(key)));
    }
    pub fn eql(_: IntContext, a: i32, b: i32) bool {
        return a == b;
    }
};

const IntCache = CarCache(i32, i32, IntContext);
const StringCache = StringCarCache(i32, StringKeyContext);

fn putDiscard(cache: anytype, key: anytype, value: anytype) !void {
    var evicted = try cache.put(testing.allocator, key, value) orelse return;
    evicted.deinit(testing.allocator, cache.ctx);
}

/// Checks the invariants the paper states for CAR (I1-I7 in §III-B), plus the
/// index agreeing with the lists.
fn assertInvariants(cache: anytype) !void {
    const c = cache.c;

    // I1: T1 and T2 together never exceed the cache size.
    try testing.expect(cache.t1.len() + cache.t2.len() <= c);
    // I2/I3: T1 and B1 together never exceed the cache size.
    try testing.expect(cache.t1.len() + cache.b1.len() <= c);
    // I4: the whole directory never exceeds twice the cache size.
    try testing.expect(cache.t1.len() + cache.t2.len() + cache.b1.len() + cache.b2.len() <= 2 * c);
    // I5: ghosts only exist once the cache is full.
    if (cache.t1.len() + cache.t2.len() < c) {
        try testing.expectEqual(@as(usize, 0), cache.b1.len() + cache.b2.len());
    }
    // The adaptation parameter stays in range.
    try testing.expect(cache.p <= c);

    // The index holds exactly the keys the lists do.
    try testing.expectEqual(
        cache.t1.len() + cache.t2.len() + cache.b1.len() + cache.b2.len(),
        cache.index.count(),
    );

    var it = cache.index.iterator();
    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .t1 => |slot| try testing.expect(cache.t1.get(slot) != null),
            .t2 => |slot| try testing.expect(cache.t2.get(slot) != null),
            .b1 => |slot| try testing.expect(cache.b1.entries.items[slot] != null),
            .b2 => |slot| try testing.expect(cache.b2.entries.items[slot] != null),
        }
    }
}

test "a miss returns null" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(?*i32, null), cache.get(1));
    try testing.expect(cache.isEmpty());
    try testing.expectEqual(@as(usize, 4), cache.capacity());
}

test "a value round-trips" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try testing.expectEqual(@as(i32, 100), cache.get(1).?.*);
    try testing.expectEqual(@as(usize, 1), cache.len());
    try assertInvariants(&cache);
}

test "a repeat put replaces the value in place" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try putDiscard(&cache, 1, 200);

    try testing.expectEqual(@as(i32, 200), cache.get(1).?.*);
    try testing.expectEqual(@as(usize, 1), cache.len());
}

test "a zero-capacity cache is disabled" {
    var cache: IntCache = .init(0);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try testing.expectEqual(@as(?*i32, null), cache.get(1));
    try testing.expect(cache.isEmpty());
    try testing.expectEqual(@as(usize, 0), cache.index.count());
}

test "a new entry starts in T1" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try testing.expectEqual(@as(usize, 1), cache.t1.len());
    try testing.expectEqual(@as(usize, 0), cache.t2.len());
}

test "a hit sets the reference bit" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try testing.expect(!cache.t1.headPage().?.ref_bit);

    _ = cache.get(1);
    try testing.expect(cache.t1.headPage().?.ref_bit);
}

test "a put onto a resident page also sets the reference bit" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 100);
    try testing.expect(!cache.t1.headPage().?.ref_bit);

    try putDiscard(&cache, 1, 200);
    try testing.expect(cache.t1.headPage().?.ref_bit);
}

test "filling to capacity evicts nothing" {
    var cache: IntCache = .init(3);
    defer cache.deinit(testing.allocator);

    for (0..3) |i| {
        const key: i32 = @intCast(i);
        try testing.expectEqual(
            @as(?IntCache.Evicted, null),
            try cache.put(testing.allocator, key, key * 10),
        );
    }
    try testing.expectEqual(@as(usize, 3), cache.len());
    try assertInvariants(&cache);
}

test "overflowing capacity evicts the clock head" {
    var cache: IntCache = .init(3);
    defer cache.deinit(testing.allocator);

    for (0..3) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)) * 10);

    var evicted = (try cache.put(testing.allocator, 3, 30)).?;
    defer evicted.deinit(testing.allocator, cache.ctx);

    // Nothing was referenced, so the first page inserted is the first out.
    try testing.expectEqual(@as(i32, 0), evicted.key);
    try testing.expectEqual(@as(i32, 0), evicted.value);
    try testing.expectEqual(@as(usize, 3), cache.len());
    try assertInvariants(&cache);
}

/// B1 only grows once T1 has given room back: `|T1| + |B1|` is capped at `c`,
/// so a page has to migrate into T2 before a demoted key can be remembered.
/// Capacity 4, with 1 recirculated into T2, leaves room for 2 as a ghost.
fn cacheWithB1Ghost() !IntCache {
    var cache: IntCache = .init(4);
    errdefer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 10);
    try putDiscard(&cache, 2, 20);
    try putDiscard(&cache, 3, 30);
    _ = cache.get(1);

    try putDiscard(&cache, 5, 50);
    // Fills the cache; the next put replaces, recirculating the referenced 1
    // into T2 and demoting 2 into B1.
    try putDiscard(&cache, 6, 60);
    return cache;
}

test "an evicted key becomes a B1 ghost" {
    var cache = try cacheWithB1Ghost();
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cache.b1.len());
    try testing.expect(cache.index.get(2).? == .b1);
    // A ghost remembers the key but not the body.
    try testing.expectEqual(@as(?*i32, null), cache.get(2));
    try assertInvariants(&cache);
}

test "a full cache with no reuse keeps its ghost lists empty" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    // |T1| + |B1| <= c, so while every resident page is in T1 a demotion into
    // B1 is immediately undone by the line 7 discard.
    for (0..20) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));

    try testing.expectEqual(@as(usize, 4), cache.t1.len());
    try testing.expectEqual(@as(usize, 0), cache.b1.len());
    try testing.expectEqual(@as(usize, 0), cache.b2.len());
    try assertInvariants(&cache);
}

test "a referenced page is recirculated into T2 instead of evicted" {
    var cache: IntCache = .init(3);
    defer cache.deinit(testing.allocator);

    for (0..3) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)) * 10);
    // Reference the clock head so the T1 pass demotes it to T2 instead.
    _ = cache.get(0);

    try putDiscard(&cache, 3, 30);

    try testing.expect(cache.t2.len() >= 1);
    try testing.expectEqual(@as(i32, 0), cache.get(0).?.*);
    try assertInvariants(&cache);
}

test "a B1 hit raises the adaptation parameter" {
    var cache = try cacheWithB1Ghost();
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), cache.adaptationParameter());

    // Reinserting the ghost is the evidence that T1 was too small.
    try putDiscard(&cache, 2, 999);

    try testing.expect(cache.adaptationParameter() > 0);
    try testing.expect(cache.adaptationParameter() <= cache.capacity());
    // Line 16: a ghost hit lands in T2, not T1.
    try testing.expect(cache.index.get(2).? == .t2);
    try testing.expectEqual(@as(i32, 999), cache.get(2).?.*);
    try assertInvariants(&cache);
}

test "a B2 hit lowers the adaptation parameter" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    // Promote everything to T2 by referencing it, then push it all out.
    for (0..4) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));
    for (0..4) |i| _ = cache.get(@intCast(i));
    for (4..12) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));

    try testing.expect(cache.b2.len() > 0);
    const before = cache.adaptationParameter();

    var ghost: i32 = -1;
    var it = cache.index.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .b2) {
            ghost = kv.key_ptr.*;
            break;
        }
    }
    try testing.expect(ghost >= 0);

    try putDiscard(&cache, ghost, 777);
    try testing.expect(cache.adaptationParameter() <= before);
    try testing.expectEqual(@as(i32, 777), cache.get(ghost).?.*);
    try assertInvariants(&cache);
}

test "the adaptation parameter never exceeds capacity" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    // Alternate between filling and reviving ghosts to drive p upward.
    for (0..40) |round| {
        for (0..8) |i| {
            const key: i32 = @intCast(round % 2 * 8 + i);
            try putDiscard(&cache, key, key);
            try testing.expect(cache.adaptationParameter() <= cache.capacity());
        }
    }
    try assertInvariants(&cache);
}

test "the clock examines every page before choosing a victim" {
    var cache: IntCache = .init(4);
    defer cache.deinit(testing.allocator);

    for (0..4) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));
    // Every page is referenced, so the first sweep can evict nothing; the
    // second must.
    for (0..4) |i| _ = cache.get(@intCast(i));

    var evicted = (try cache.put(testing.allocator, 99, 99)).?;
    defer evicted.deinit(testing.allocator, cache.ctx);

    try testing.expectEqual(@as(usize, 4), cache.len());
    try assertInvariants(&cache);
}

test "a scan does not flush the frequently used set" {
    var cache: IntCache = .init(8);
    defer cache.deinit(testing.allocator);

    // A working set that is touched twice lands in T2.
    for (0..4) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));
    for (0..4) |i| _ = cache.get(@intCast(i));
    for (0..4) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));

    // A long one-shot scan over keys that are never revisited.
    for (100..200) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));

    var survivors: usize = 0;
    for (0..4) |i| {
        if (cache.get(@intCast(i)) != null) survivors += 1;
    }
    try testing.expect(survivors > 0);
    try assertInvariants(&cache);
}

test "the directory stays within bounds under churn" {
    var cache: IntCache = .init(6);
    defer cache.deinit(testing.allocator);

    var key: i32 = 0;
    for (0..300) |round| {
        try putDiscard(&cache, key, key);
        // Revisit an older key now and then to keep T2 and the ghosts busy.
        if (round % 3 == 0) _ = cache.get(@mod(key - 4, 20));
        if (round % 7 == 0) try putDiscard(&cache, @mod(key - 9, 20), key);
        key = @mod(key + 1, 20);
        try assertInvariants(&cache);
    }
}

test "the cache stays full once it fills" {
    var cache: IntCache = .init(5);
    defer cache.deinit(testing.allocator);

    for (0..5) |i| try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));
    try testing.expectEqual(@as(usize, 5), cache.len());

    // Invariant I7: once |T1| + |T2| = c it stays there.
    for (5..60) |i| {
        try putDiscard(&cache, @as(i32, @intCast(i)), @as(i32, @intCast(i)));
        try testing.expectEqual(@as(usize, 5), cache.len());
    }
    try assertInvariants(&cache);
}

test "every put past capacity reports an eviction" {
    var cache: IntCache = .init(3);
    defer cache.deinit(testing.allocator);

    for (0..3) |i| {
        try testing.expectEqual(
            @as(?IntCache.Evicted, null),
            try cache.put(testing.allocator, @as(i32, @intCast(i)), @as(i32, @intCast(i))),
        );
    }
    for (3..20) |i| {
        var evicted = (try cache.put(testing.allocator, @as(i32, @intCast(i)), @as(i32, @intCast(i)))).?;
        evicted.deinit(testing.allocator, cache.ctx);
    }
}

test "owned string keys survive eviction and are not leaked" {
    var cache: StringCache = .init(3);
    defer cache.deinit(testing.allocator);

    var buf: [16]u8 = undefined;
    for (0..64) |i| {
        const key = try std.fmt.bufPrint(&buf, "/redfish/v1/{d}", .{i});
        var evicted = try cache.put(testing.allocator, key, @intCast(i));
        if (evicted) |*entry| {
            // The demoted key is still the cache's, living on as a ghost.
            try testing.expect(entry.key.len != 0);
            entry.deinit(testing.allocator, cache.ctx);
        }
        try assertInvariants(&cache);
    }

    // A caller's transient buffer must not be what the cache remembers.
    const key = try std.fmt.bufPrint(&buf, "/redfish/v1/{d}", .{63});
    try testing.expectEqual(@as(i32, 63), cache.get(key).?.*);
}

test "string keys compare by value, not by pointer" {
    var cache: StringCache = .init(4);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, "/redfish/v1/Chassis/1", 1);

    const other = try testing.allocator.dupe(u8, "/redfish/v1/Chassis/1");
    defer testing.allocator.free(other);

    try testing.expectEqual(@as(i32, 1), cache.get(other).?.*);
    try testing.expectEqual(@as(usize, 1), cache.len());
}

test "values are released when the cache is torn down" {
    const Counting = struct {
        var live: usize = 0;

        const Value = struct {
            id: usize,

            fn create(id: usize) Value {
                live += 1;
                return .{ .id = id };
            }
        };

        pub fn hash(_: @This(), key: i32) u64 {
            return std.hash.int(@as(u32, @bitCast(key)));
        }
        pub fn eql(_: @This(), a: i32, b: i32) bool {
            return a == b;
        }
        pub fn deinitValue(_: @This(), _: Allocator, _: *Value) void {
            live -= 1;
        }
    };

    Counting.live = 0;
    var cache: CarCache(i32, Counting.Value, Counting) = .init(4);

    for (0..20) |i| {
        const key: i32 = @intCast(i);
        var evicted = try cache.put(testing.allocator, key, Counting.Value.create(i));
        if (evicted) |*entry| entry.deinit(testing.allocator, cache.ctx);
    }
    // Replacing a resident value releases the one it displaces.
    try testing.expectEqual(@as(usize, 4), Counting.live);

    var evicted = try cache.put(testing.allocator, 19, Counting.Value.create(99));
    if (evicted) |*entry| entry.deinit(testing.allocator, cache.ctx);
    try testing.expectEqual(@as(usize, 4), Counting.live);

    cache.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), Counting.live);
}

test "a disabled cache releases the value it refuses to store" {
    const Counting = struct {
        var live: usize = 0;

        pub fn hash(_: @This(), key: i32) u64 {
            return std.hash.int(@as(u32, @bitCast(key)));
        }
        pub fn eql(_: @This(), a: i32, b: i32) bool {
            return a == b;
        }
        pub fn deinitValue(_: @This(), _: Allocator, _: *usize) void {
            live -= 1;
        }
    };

    Counting.live = 0;
    var cache: CarCache(i32, usize, Counting) = .init(0);
    defer cache.deinit(testing.allocator);

    Counting.live += 1;
    try putDiscard(&cache, 1, 5);
    try testing.expectEqual(@as(usize, 0), Counting.live);
}

test "ghost list slots are reused" {
    var list: IntCache.GhostList = .{ .capacity = 3 };
    defer list.deinit(testing.allocator);
    try list.reserveStorage(testing.allocator);

    try testing.expectEqual(@as(?usize, 0), list.insertAtTail(1));
    try testing.expectEqual(@as(?usize, 1), list.insertAtTail(2));
    try testing.expectEqual(@as(?usize, 2), list.insertAtTail(3));
    try testing.expectEqual(@as(?usize, null), list.insertAtTail(4));

    // LRU order: 1 was inserted first.
    try testing.expectEqual(@as(?i32, 1), list.removeLru());
    try testing.expectEqual(@as(usize, 2), list.len());

    // The freed slot comes back.
    try testing.expectEqual(@as(?usize, 0), list.insertAtTail(5));
    try testing.expectEqual(@as(?i32, 2), list.removeLru());
    try testing.expectEqual(@as(?i32, 3), list.removeLru());
    try testing.expectEqual(@as(?i32, 5), list.removeLru());
    try testing.expectEqual(@as(?i32, null), list.removeLru());
}

test "removing from the middle of a ghost list keeps it linked" {
    var list: IntCache.GhostList = .{ .capacity = 4 };
    defer list.deinit(testing.allocator);
    try list.reserveStorage(testing.allocator);

    for (1..5) |i| _ = list.insertAtTail(@intCast(i));

    try testing.expect(list.remove(1));
    try testing.expect(!list.remove(1));
    try testing.expectEqual(@as(usize, 3), list.len());

    try testing.expectEqual(@as(?i32, 1), list.removeLru());
    try testing.expectEqual(@as(?i32, 3), list.removeLru());
    try testing.expectEqual(@as(?i32, 4), list.removeLru());
}

test "a clock list is circular and the hand walks it" {
    var list: IntCache.ClockList = .{ .capacity = 3 };
    defer list.deinit(testing.allocator);
    try list.reserveStorage(testing.allocator);

    for (1..4) |i| _ = list.insertAtTail(@intCast(i), @intCast(i * 10));
    try testing.expectEqual(@as(usize, 3), list.len());

    // The hand starts at the first page inserted and visits them in order.
    try testing.expectEqual(@as(i32, 1), list.headPage().?.key);
    list.advanceHand();
    try testing.expectEqual(@as(i32, 2), list.headPage().?.key);
    list.advanceHand();
    try testing.expectEqual(@as(i32, 3), list.headPage().?.key);
    // And then wraps.
    list.advanceHand();
    try testing.expectEqual(@as(i32, 1), list.headPage().?.key);

    const removed = list.removeHeadPage().?;
    try testing.expectEqual(@as(i32, 1), removed.key);
    try testing.expectEqual(@as(i32, 2), list.headPage().?.key);
    try testing.expectEqual(@as(usize, 2), list.len());
}

test "a clock list refuses to grow past capacity" {
    var list: IntCache.ClockList = .{ .capacity = 2 };
    defer list.deinit(testing.allocator);
    try list.reserveStorage(testing.allocator);

    try testing.expect(list.insertAtTail(1, 1) != null);
    try testing.expect(list.insertAtTail(2, 2) != null);
    try testing.expectEqual(@as(?usize, null), list.insertAtTail(3, 3));
}

test "a capacity-one cache still adapts" {
    var cache: IntCache = .init(1);
    defer cache.deinit(testing.allocator);

    try putDiscard(&cache, 1, 10);
    try putDiscard(&cache, 2, 20);
    try putDiscard(&cache, 1, 30);

    try testing.expectEqual(@as(usize, 1), cache.len());
    try assertInvariants(&cache);
}

test "an allocation failure leaves the cache consistent" {
    // Every put is a sequence of allocations; failing at each one in turn
    // exercises all the partial-progress paths. What matters is that the
    // index still agrees with the lists afterwards and that nothing leaks.
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();

        var cache: StringCache = .init(4);
        defer cache.deinit(gpa);

        var buf: [24]u8 = undefined;
        for (0..24) |i| {
            const key = try std.fmt.bufPrint(&buf, "/redfish/v1/{d}", .{i % 9});
            var evicted = cache.put(gpa, key, @intCast(i)) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            };
            if (evicted) |*entry| entry.deinit(gpa, cache.ctx);
            _ = cache.get(key);
        }

        try assertInvariants(&cache);

        // And the cache still works once memory is available again.
        failing.fail_index = std.math.maxInt(usize);
        var evicted = try cache.put(gpa, "/redfish/v1/recovered", 1);
        if (evicted) |*entry| entry.deinit(gpa, cache.ctx);
        try testing.expectEqual(@as(i32, 1), cache.get("/redfish/v1/recovered").?.*);
        try assertInvariants(&cache);
    }
}

test "an idle cache holds no slot storage" {
    var cache: IntCache = .init(1024);
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), cache.t1.nodes.capacity);
    try testing.expectEqual(@as(usize, 0), cache.b1.entries.capacity);

    // The first put reserves it all at once.
    try putDiscard(&cache, 1, 1);
    try testing.expect(cache.t1.nodes.capacity >= 1024);
    try testing.expect(cache.b1.entries.capacity >= 1025);
}
