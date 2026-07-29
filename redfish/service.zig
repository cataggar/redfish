//! The entry point: everything a client does starts at `/redfish/v1`.
//!
//! `Service` holds the three things every later call needs — the transport,
//! the allocator, and the service root — so they are threaded once instead of
//! at each call site. It also reads the root for what the service says it
//! supports, which is the only place that information exists.
//!
//! The accessors below are deliberately thin. A generated `ServiceRoot`
//! already names each subordinate service with a typed link, so a wrapper per
//! service would restate 300 modules to no end. What is worth wrapping is the
//! part that is easy to get wrong: a collection has to be walked rather than
//! read (`Members` may be one page of several), and a link has to be followed
//! rather than fetched (the service may already have expanded it).

const std = @import("std");
const core = @import("redfish_core");

const features = @import("features.zig");

const Features = features.Features;

/// Where a Redfish service root lives. Fixed by DSP0266; a service does not
/// get to choose it, which is what makes discovery possible at all.
pub const root_uri: core.ODataId = .{ .value = "/redfish/v1" };

/// A connected Redfish service.
///
/// Generic over the generated `ServiceRoot` so this module does not depend on
/// a particular schema package: the standard package and a vendor's own both
/// satisfy it, and neither is named here.
pub fn Service(comptime ServiceRoot: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        transport: *core.BmcTransport,

        /// The service root, held for the life of the connection. Every
        /// subordinate service is reached through a link in it, so it is
        /// fetched once rather than per call.
        root: core.Owned(ServiceRoot),

        /// What the service supports, after any correction. Read this rather
        /// than `root.value.ProtocolFeaturesSupported`, which is the claim
        /// before correction.
        supported: Features,

        /// Fetches the service root and reads what the service advertises.
        pub fn connect(gpa: std.mem.Allocator, transport: *core.BmcTransport) !Self {
            const root = try core.bmc.get(ServiceRoot, gpa, transport, root_uri);
            errdefer root.deinit();

            return .{
                .gpa = gpa,
                .transport = transport,
                .root = root,
                .supported = .advertised(root.value),
            };
        }

        pub fn deinit(self: Self) void {
            self.root.deinit();
        }

        /// Stops trusting this service's `$expand` advertisement.
        ///
        /// A caller that has found expansion to be broken — or that knows the
        /// platform from `vendor` and `product` — turns it off here, once, and
        /// every later `expandQuery` reflects it. The alternative is each call
        /// site remembering, which is the same as none of them remembering.
        pub fn distrustExpand(self: *Self) void {
            self.supported = self.supported.withoutExpand();
        }

        /// The `$expand` to send, or null when the service takes none.
        pub fn expandQuery(self: Self) ?core.ExpandQuery {
            return self.supported.bestExpand();
        }

        /// The DSP0266 protocol version the service implements, which is not
        /// the version of any schema it serves.
        pub fn redfishVersion(self: Self) ?[]const u8 {
            return self.root.value.RedfishVersion;
        }

        /// Who made the service. Absent more often than not: the property was
        /// added in ServiceRoot v1.5.0 and plenty of implementations predate
        /// it or simply omit it.
        pub fn vendor(self: Self) ?[]const u8 {
            return self.root.value.Vendor;
        }

        /// What the service runs on, as the service describes it.
        pub fn product(self: Self) ?[]const u8 {
            return self.root.value.Product;
        }

        /// Walks a collection the root links to, across as many pages as the
        /// service returns it in.
        ///
        /// ```zig
        /// var chassis = try service.walk("Chassis");
        /// defer chassis.deinit();
        /// while (try chassis.next()) |link| { ... }
        /// ```
        ///
        /// The field is named rather than typed because that is what the
        /// caller knows; the collection and member types are recovered from
        /// it. Naming a field the root does not have is a compile error, not a
        /// runtime one.
        pub fn walk(self: Self, comptime field: []const u8) !core.Walker(Linked(field)) {
            const link = @field(self.root.value, field) orelse return error.NotSupported;
            return .init(self.gpa, self.transport, link.odataId() orelse return error.NotAddressable);
        }

        /// Reads a subordinate service the root links to, fetching it only if
        /// the root did not already carry it expanded.
        ///
        /// ```zig
        /// const update = try service.open("UpdateService");
        /// defer update.deinit();
        /// ```
        pub fn open(self: Self, comptime field: []const u8) !core.Resolved(Linked(field)) {
            const link = @field(self.root.value, field) orelse return error.NotSupported;
            return core.follow(Linked(field), self.gpa, self.transport, link);
        }

        /// Whether the service links to a named subordinate service at all.
        ///
        /// Every one of them is optional in the schema, and a service that
        /// does not implement, say, `CompositionService` simply omits the
        /// link. This is the check to make before `open` or `walk` when the
        /// absence is expected rather than exceptional.
        pub fn has(self: Self, comptime field: []const u8) bool {
            return @field(self.root.value, field) != null;
        }

        /// The resource type behind a named link on the service root.
        pub fn Linked(comptime field: []const u8) type {
            return @typeInfo(@FieldType(ServiceRoot, field)).optional.child.Target;
        }
    };
}

const testing = std.testing;

/// Stands in for a generated `ServiceRoot`, with the same field shapes.
const TestRoot = struct {
    const Collection = struct {
        @"@odata.id": ?core.ODataId = null,
        Members: ?[]const core.NavProperty(Member) = null,
        @"Members@odata.count": ?i64 = null,
        @"Members@odata.nextLink": ?core.ODataId = null,
    };

    const Member = struct {
        @"@odata.id": ?core.ODataId = null,
    };

    const Subordinate = struct {
        @"@odata.id": ?core.ODataId = null,
        ServiceEnabled: ?bool = null,
    };

    @"@odata.id": ?core.ODataId = null,
    RedfishVersion: ?[]const u8 = null,
    Vendor: ?[]const u8 = null,
    Product: ?[]const u8 = null,
    ProtocolFeaturesSupported: ?struct {
        ExpandQuery: ?struct {
            Links: ?bool = null,
            NoLinks: ?bool = null,
            ExpandAll: ?bool = null,
            Levels: ?bool = null,
            MaxLevels: ?i64 = null,
        } = null,
        FilterQuery: ?bool = null,
        SelectQuery: ?bool = null,
        ExcerptQuery: ?bool = null,
        OnlyMemberQuery: ?bool = null,
        TopSkipQuery: ?bool = null,
    } = null,
    Chassis: ?core.NavProperty(Collection) = null,
    UpdateService: ?core.NavProperty(Subordinate) = null,
    CompositionService: ?core.NavProperty(Subordinate) = null,
};

const TestService = Service(TestRoot);

/// Answers a fixed table of URIs and counts what was asked.
const StubTransport = struct {
    const Route = struct { uri: []const u8, body: []const u8 };

    transport: core.BmcTransport = .{ .sendFn = send },
    routes: []const Route,
    calls: usize = 0,

    fn send(t: *core.BmcTransport, arena: std.mem.Allocator, request: core.RawRequest) !core.RawResponse {
        const self: *StubTransport = @fieldParentPtr("transport", t);
        self.calls += 1;
        for (self.routes) |route| {
            if (std.mem.eql(u8, route.uri, request.uri)) {
                return .{ .status = 200, .body = try arena.dupe(u8, route.body), .headers = .empty };
            }
        }
        return error.NotFound;
    }
};

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "RedfishVersion":"1.18.0","Vendor":"Contoso","Product":"Contoso BMC",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true,"Levels":true,"MaxLevels":2},
    \\                              "FilterQuery":true},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"},
    \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService"}}
;

test "connecting reads the root and what the service advertises" {
    var transport: StubTransport = .{ .routes = &.{.{ .uri = "/redfish/v1", .body = root_body }} };

    const service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();

    try testing.expectEqualStrings("1.18.0", service.redfishVersion().?);
    try testing.expectEqualStrings("Contoso", service.vendor().?);
    try testing.expectEqualStrings("Contoso BMC", service.product().?);

    try testing.expect(service.supported.filter);
    try testing.expectEqual(core.ExpandQuery.Expression.current, service.expandQuery().?.expression);
    try testing.expectEqual(@as(?u32, 1), service.expandQuery().?.levels);

    // One request: the root is fetched once and kept.
    try testing.expectEqual(@as(usize, 1), transport.calls);
}

test "a subordinate service the root does not link to is absent, not an error to ask about" {
    var transport: StubTransport = .{ .routes = &.{.{ .uri = "/redfish/v1", .body = root_body }} };

    const service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();

    try testing.expect(service.has("UpdateService"));
    try testing.expect(!service.has("CompositionService"));

    try testing.expectError(error.NotSupported, service.open("CompositionService"));
}

test "a linked service is opened, and a collection is walked" {
    var transport: StubTransport = .{ .routes = &.{
        .{ .uri = "/redfish/v1", .body = root_body },
        .{ .uri = "/redfish/v1/UpdateService", .body = "{\"ServiceEnabled\":true}" },
        .{
            .uri = "/redfish/v1/Chassis",
            .body =
            \\{"Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],"Members@odata.count":1}
            ,
        },
    } };

    const service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();

    const update = try service.open("UpdateService");
    defer update.deinit();
    try testing.expect(update.get().ServiceEnabled.?);

    var chassis = try service.walk("Chassis");
    defer chassis.deinit();

    var count: usize = 0;
    while (try chassis.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "the type behind a link is recovered from the field name" {
    try testing.expect(TestService.Linked("UpdateService") == TestRoot.Subordinate);
    try testing.expect(TestService.Linked("Chassis") == TestRoot.Collection);
}

test "distrusting expand survives to every later query" {
    var transport: StubTransport = .{ .routes = &.{.{ .uri = "/redfish/v1", .body = root_body }} };

    var service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();
    try testing.expect(service.expandQuery() != null);

    service.distrustExpand();

    try testing.expect(service.expandQuery() == null);
    try testing.expect(!service.supported.expand.any());
    // The advertisement itself is untouched -- what changed is the decision.
    try testing.expect(service.root.value.ProtocolFeaturesSupported.?.ExpandQuery.?.NoLinks.?);
    // And it says nothing about the other capabilities.
    try testing.expect(service.supported.filter);
}

test {
    testing.refAllDecls(@This());
}
