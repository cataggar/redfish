//! Walking a resource collection the service is allowed to truncate.
//!
//! A Redfish collection is not necessarily all of itself. DSP0266 lets a
//! service answer a `GET` on a collection with only part of it, saying so with
//! `Members@odata.nextLink` — a URI for the rest. Nothing else in the response
//! distinguishes a complete collection from the first page of a long one, so
//! code that reads `Members` and stops is silently wrong on exactly the
//! collections where it matters most: log entries, journal records, the event
//! destinations of a busy service.
//!
//! `Walker` closes that gap. It yields members across page boundaries and
//! stops when the service stops offering a next page.
//!
//! This lives in `redfish_core` for the same reason `sse.zig` does: it is a
//! protocol mechanism rather than a convenience. It knows nothing about HTTP
//! beyond the `BmcTransport` vtable, and nothing about any generated type
//! beyond the two fields DSP0266 requires a collection to have — so a mock
//! transport drives it exactly as a real one does.

const std = @import("std");

const bmc = @import("bmc.zig");
const nav_property = @import("nav_property.zig");
const odata = @import("odata.zig");

const BmcTransport = bmc.BmcTransport;
const ODataId = odata.ODataId;
const Owned = @import("owned.zig").Owned;

/// The member type of a collection resource.
///
/// A generated collection declares `Members: ?[]const NavProperty(M)`, so `M`
/// is recoverable from the type alone and a caller never has to name it twice.
pub fn Member(comptime Collection: type) type {
    const field = @FieldType(Collection, "Members");
    const slice = @typeInfo(field).optional.child;
    return @typeInfo(slice).pointer.child;
}

/// Yields every member of a collection, fetching further pages as needed.
///
/// ## Lifetime
///
/// A yielded member borrows from the page it came from, and a page is freed
/// once the walk leaves it. **A value from `next` is valid until the following
/// call to `next`**, which is the same contract `std.Io.Dir.Iterator` offers
/// for an entry's name. Holding every page instead would be safer to describe
/// and would defeat the point: a service pages a collection precisely when
/// holding all of it at once is a bad idea.
///
/// In practice the borrow is not a burden, because what a caller wants from a
/// member is its `@odata.id`, and what it does with that is fetch the resource
/// — before going round the loop again.
///
/// ```zig
/// var walker = core.collection.Walker(ChassisCollection).init(gpa, transport, id);
/// defer walker.deinit();
/// while (try walker.next()) |member| {
///     const chassis = try core.bmc.get(Chassis, gpa, transport, member.odataId().?);
///     defer chassis.deinit();
/// }
/// ```
pub fn Walker(comptime Collection: type) type {
    return struct {
        const Self = @This();

        /// What `next` hands back: one link to a member of the collection.
        pub const Item = Member(Collection);

        gpa: std.mem.Allocator,
        transport: *BmcTransport,

        /// The page currently being read, or `null` before the first fetch.
        page: ?Owned(Collection) = null,
        /// Where the next page lives. `null` once the service stops offering
        /// one, which is how a walk ends.
        next_page: ?ODataId,
        /// How far into the current page's `Members` the walk has read.
        index: usize = 0,
        /// Set once the service declines to offer a further page, so an
        /// exhausted walker stays exhausted rather than re-fetching page one.
        done: bool = false,

        /// Begins a walk at `id`. Nothing is fetched until the first `next`.
        pub fn init(gpa: std.mem.Allocator, transport: *BmcTransport, id: ODataId) Self {
            return .{ .gpa = gpa, .transport = transport, .next_page = id };
        }

        /// Begins a walk over a collection already in hand.
        ///
        /// Takes ownership of `page`. This is the form to use after an
        /// `$expand`, where the first page arrived as part of a larger
        /// response and re-fetching it would undo the point of expanding.
        pub fn adopt(gpa: std.mem.Allocator, transport: *BmcTransport, page: Owned(Collection)) Self {
            return .{
                .gpa = gpa,
                .transport = transport,
                .page = page,
                .next_page = nextLink(page.value),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.page) |page| page.deinit();
            self.page = null;
        }

        /// The next member, or `null` when the collection is exhausted.
        ///
        /// The returned value borrows from the current page; see the type's
        /// lifetime note.
        pub fn next(self: *Self) !?Item {
            while (true) {
                if (self.page) |page| {
                    if (page.value.Members) |members| {
                        if (self.index < members.len) {
                            defer self.index += 1;
                            return members[self.index];
                        }
                    }
                }

                if (self.done) return null;
                try self.advance();
            }
        }

        /// How many members the collection has in total, as the service
        /// reported it on the page in hand — which is not how many this page
        /// holds, and is not always reported at all.
        pub fn total(self: Self) ?i64 {
            const page = self.page orelse return null;
            return @field(page.value, "Members@odata.count");
        }

        /// Fetches the next page and drops the one before it.
        fn advance(self: *Self) !void {
            const uri = self.next_page orelse {
                self.done = true;
                return;
            };

            const fetched = try bmc.get(Collection, self.gpa, self.transport, uri);
            errdefer fetched.deinit();

            // The link is read before the old page goes, because on the first
            // fetch `uri` still borrows from the caller and on every later one
            // it borrows from the page being replaced.
            const following = nextLink(fetched.value);

            if (self.page) |old| old.deinit();
            self.page = fetched;
            self.next_page = following;
            self.index = 0;
        }

        /// A collection's own next-page link, if it offered one.
        ///
        /// The field is named for the property it annotates, so this is
        /// `Members@odata.nextLink` — an OData annotation rather than a
        /// property, which is why no CSDL declares it and the emitter has to
        /// know to write it.
        fn nextLink(value: Collection) ?ODataId {
            return @field(value, "Members@odata.nextLink");
        }
    };
}

const testing = std.testing;

/// A collection shaped exactly as the emitter writes one.
const TestCollection = struct {
    @"@odata.id": ?ODataId = null,
    Members: ?[]const nav_property.NavProperty(TestMember) = null,
    @"Members@odata.count": ?i64 = null,
    @"Members@odata.nextLink": ?ODataId = null,
};

const TestMember = struct {
    @"@odata.id": ?ODataId = null,
    Name: ?[]const u8 = null,
};

/// A transport that answers each URI with a canned body, and records the order
/// it was asked — so a test can prove the walk followed the links rather than
/// guessing them.
const PagedTransport = struct {
    const Page = struct { uri: []const u8, body: []const u8 };

    transport: BmcTransport,
    pages: []const Page,
    requested: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, pages: []const Page) PagedTransport {
        return .{
            .transport = .{ .sendFn = send },
            .pages = pages,
            .gpa = gpa,
        };
    }

    fn deinit(self: *PagedTransport) void {
        self.requested.deinit(self.gpa);
    }

    fn send(transport: *BmcTransport, arena: std.mem.Allocator, request: bmc.RawRequest) !bmc.RawResponse {
        const self: *PagedTransport = @fieldParentPtr("transport", transport);
        try self.requested.append(self.gpa, try self.gpa.dupe(u8, request.uri));
        for (self.pages) |page| {
            if (std.mem.eql(u8, page.uri, request.uri)) {
                return .{ .status = 200, .body = try arena.dupe(u8, page.body), .headers = .empty };
            }
        }
        return error.NotFound;
    }
};

test "a walk crosses page boundaries and stops where the service does" {
    var transport: PagedTransport = .init(testing.allocator, &.{
        .{
            .uri = "/redfish/v1/Chassis",
            .body =
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1"},{"@odata.id":"/redfish/v1/Chassis/2"}],
            \\ "Members@odata.count":3,
            \\ "Members@odata.nextLink":"/redfish/v1/Chassis?$skip=2"}
            ,
        },
        .{
            .uri = "/redfish/v1/Chassis?$skip=2",
            .body =
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/3"}],
            \\ "Members@odata.count":3}
            ,
        },
    });
    defer transport.deinit();

    var walker: Walker(TestCollection) = .init(
        testing.allocator,
        &transport.transport,
        .{ .value = "/redfish/v1/Chassis" },
    );
    defer walker.deinit();

    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |item| testing.allocator.free(item);
        seen.deinit(testing.allocator);
    }

    while (try walker.next()) |member| {
        // Copied, because the page this borrows from is freed at the boundary.
        try seen.append(testing.allocator, try testing.allocator.dupe(u8, member.odataId().?.value));
    }

    try testing.expectEqual(@as(usize, 3), seen.items.len);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1", seen.items[0]);
    try testing.expectEqualStrings("/redfish/v1/Chassis/2", seen.items[1]);
    try testing.expectEqualStrings("/redfish/v1/Chassis/3", seen.items[2]);

    // Two pages fetched, in link order -- the second URI was never guessed.
    try testing.expectEqual(@as(usize, 2), transport.requested.items.len);
    try testing.expectEqualStrings("/redfish/v1/Chassis?$skip=2", transport.requested.items[1]);

    for (transport.requested.items) |uri| testing.allocator.free(uri);
}

test "a collection that fits in one response is fetched once" {
    var transport: PagedTransport = .init(testing.allocator, &.{.{
        .uri = "/redfish/v1/Chassis",
        .body =
        \\{"Members":[{"@odata.id":"/redfish/v1/Chassis/1"}],"Members@odata.count":1}
        ,
    }});
    defer transport.deinit();

    var walker: Walker(TestCollection) = .init(
        testing.allocator,
        &transport.transport,
        .{ .value = "/redfish/v1/Chassis" },
    );
    defer walker.deinit();

    try testing.expect(try walker.next() != null);
    try testing.expectEqual(@as(?i64, 1), walker.total());

    try testing.expect(try walker.next() == null);

    // Exhaustion is remembered: asking again does not re-fetch page one.
    try testing.expect(try walker.next() == null);
    try testing.expectEqual(@as(usize, 1), transport.requested.items.len);

    for (transport.requested.items) |uri| testing.allocator.free(uri);
}

test "an empty collection yields nothing" {
    var transport: PagedTransport = .init(testing.allocator, &.{.{
        .uri = "/redfish/v1/Chassis",
        .body = "{\"Members\":[],\"Members@odata.count\":0}",
    }});
    defer transport.deinit();

    var walker: Walker(TestCollection) = .init(
        testing.allocator,
        &transport.transport,
        .{ .value = "/redfish/v1/Chassis" },
    );
    defer walker.deinit();

    try testing.expect(try walker.next() == null);
    for (transport.requested.items) |uri| testing.allocator.free(uri);
}

test "a service may page without ever saying how many members there are" {
    // `@odata.count` is optional in DSP0266 where `@odata.nextLink` is not, so
    // a walk cannot be driven by counting members against a total.
    var transport: PagedTransport = .init(testing.allocator, &.{
        .{
            .uri = "/redfish/v1/Systems",
            .body =
            \\{"Members":[{"@odata.id":"/redfish/v1/Systems/1"}],
            \\ "Members@odata.nextLink":"/redfish/v1/Systems?$skip=1"}
            ,
        },
        .{
            .uri = "/redfish/v1/Systems?$skip=1",
            .body = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/2\"}]}",
        },
    });
    defer transport.deinit();

    var walker: Walker(TestCollection) = .init(
        testing.allocator,
        &transport.transport,
        .{ .value = "/redfish/v1/Systems" },
    );
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |_| count += 1;

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(?i64, null), walker.total());

    for (transport.requested.items) |uri| testing.allocator.free(uri);
}

test "the member type is recovered from the collection type" {
    try testing.expect(Member(TestCollection) == nav_property.NavProperty(TestMember));
}

test {
    testing.refAllDecls(@This());
}
