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
const quirks = @import("quirks.zig");

const Features = features.Features;
const Quirks = quirks.Quirks;

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

        /// The known deviations of this service, once rules have been applied.
        /// Empty until `applyQuirks`, because there is no built-in table --
        /// see `quirks.zig` for why.
        deviations: Quirks = .{},

        /// The session held by `login`, kept so `logout` has a URI to DELETE
        /// and so the token outlives the response that carried it.
        session: ?core.Owned(core.SessionCreateResponse(Session)) = null,

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

        /// Frees the root and any held session response.
        ///
        /// It does *not* log out: that is a request, it can fail, and a
        /// `deinit` that makes network calls cannot report the failure. Call
        /// `logout` first -- a session left open occupies one of the service's
        /// limited slots until it times out.
        pub fn deinit(self: Self) void {
            if (self.session) |held| held.deinit();
            self.root.deinit();
        }

        /// Identifies the service against a caller's quirk rules and applies
        /// whatever they say is wrong with it.
        ///
        /// This is separate from `connect` because the rules are the caller's
        /// knowledge, not the library's. Every deviation it can act on is a
        /// capability withdrawal: the correction for a protocol feature that
        /// does not work is to stop using it.
        pub fn applyQuirks(self: *Self, rules: []const quirks.Rule) void {
            self.deviations = .identify(self.root.value, rules);

            if (self.deviations.has(.expand_unreliable)) self.supported = self.supported.withoutExpand();
            if (self.deviations.has(.filter_unreliable)) self.supported.filter = false;
            if (self.deviations.has(.top_skip_unreliable)) self.supported.top_skip = false;
        }

        /// Whether conditional requests can be trusted on this service.
        ///
        /// An ETag that does not change when the resource does makes a
        /// conditional `GET` answer from a stale copy, and `If-Match` guard
        /// nothing.
        pub fn etagsUsable(self: Self) bool {
            return !self.deviations.has(.etag_unreliable);
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

        /// Log in and authenticate every subsequent request with the
        /// resulting session token.
        ///
        /// The session collection is read from `Links.Sessions` on the service
        /// root, which is where DSP0266 puts it *because* the service root is
        /// the one resource reachable without credentials. Taking it from
        /// `SessionService.Sessions` instead would require reading
        /// `SessionService`, and reading that requires being logged in
        /// already. 23 of DMTF's 27 published service roots advertise the
        /// link; one links `SessionService` without it, and for that one there
        /// is `loginAt`.
        ///
        /// On success the transport stops sending whatever it authenticated
        /// with before. `logout` reverses both halves.
        pub fn login(self: *Self, username: []const u8, password: []const u8) !void {
            const links = self.root.value.Links orelse return error.SessionsNotAdvertised;
            const link = links.Sessions orelse return error.SessionsNotAdvertised;
            const id = link.odataId() orelse return error.SessionsNotAdvertised;
            return self.loginAt(id, username, password);
        }

        /// Log in at a session collection the caller names.
        ///
        /// For a service that does not advertise `Links.Sessions`, and for a
        /// caller that already knows the URI and would rather not spend a
        /// request rediscovering it.
        pub fn loginAt(
            self: *Self,
            sessions: core.ODataId,
            username: []const u8,
            password: []const u8,
        ) !void {
            const created = try core.bmc.createSession(Session, self.gpa, self.transport, sessions, .{
                .UserName = username,
                .Password = password,
            });
            errdefer created.deinit();

            try self.transport.authenticate(created.value.auth_token);
            errdefer self.transport.authenticate(null) catch {};

            // Held so `logout` has a URI to DELETE, and so the token outlives
            // the response it arrived in.
            self.session = created;
        }

        /// DELETE the session and stop authenticating with its token.
        ///
        /// A session a client abandons without deleting stays open until the
        /// service times it out, and a service enforces a session limit -- a
        /// program that logs in per run and never logs out eventually cannot
        /// log in at all.
        pub fn logout(self: *Self) !void {
            const open_session = self.session orelse return;
            self.session = null;
            defer open_session.deinit();

            // The token is dropped even if the DELETE fails: the caller asked
            // to stop using it, and a failed logout is not a reason to keep
            // authenticating with a credential it has disowned.
            defer self.transport.authenticate(null) catch {};
            const removed = try core.bmc.delete(Session, self.gpa, self.transport, open_session.value.location);
            removed.deinit();
        }

        /// Whether a session is currently held.
        pub fn loggedIn(self: Self) bool {
            return self.session != null;
        }

        /// The session resource type, recovered from the collection the root
        /// links to, so it cannot drift from the schema in use.
        pub const Session = core.collection.Member(SessionCollection);

        const RootLinks = @typeInfo(@FieldType(ServiceRoot, "Links")).optional.child;
        const SessionCollection = @typeInfo(@FieldType(RootLinks, "Sessions")).optional.child.Target;

        /// PATCH a resource this service handed out, reusing its own id and
        /// ETag.
        ///
        /// Prefer this to `core.bmc.update`: the id and the ETag come from the
        /// same value, so they cannot be mismatched, and the write is
        /// conditional whenever the service supplied a tag. When quirks have
        /// withdrawn `etag_unreliable`, the tag is dropped rather than sent
        /// against a service that does not maintain it -- a stale tag there
        /// means every write fails `412` for no reason.
        ///
        /// For `Bios`, this is the wrong call; see `updatePending`.
        pub fn update(
            self: Self,
            comptime T: type,
            target: anytype,
            body: anytype,
        ) !core.Owned(core.ModificationResponse(T)) {
            const id = core.entity.id(target) orelse return error.NotAddressable;
            const tag = if (self.etagsUsable()) core.entity.etag(target) else null;
            return core.bmc.update(T, self.gpa, self.transport, id, tag, body);
        }

        /// PATCH the settings resource a value defers its writes to.
        ///
        /// `Bios.Attributes` cannot be written any other way: the `Bios`
        /// resource reports them read-only, and a PATCH addressed to it may be
        /// accepted and ignored. `update` on such a resource therefore fails in
        /// the shape of a success.
        pub fn updatePending(
            self: Self,
            comptime T: type,
            target: anytype,
            body: anytype,
        ) !core.Owned(core.ModificationResponse(T)) {
            return core.bmc.updatePending(T, self.gpa, self.transport, target, body);
        }

        /// POST a new member to a collection.
        pub fn create(
            self: Self,
            comptime T: type,
            collection: core.ODataId,
            body: anytype,
        ) !core.Owned(core.ModificationResponse(T)) {
            return core.bmc.create(T, self.gpa, self.transport, collection, body);
        }

        /// DELETE a resource this service handed out.
        pub fn remove(
            self: Self,
            comptime T: type,
            target: anytype,
        ) !core.Owned(core.ModificationResponse(T)) {
            const id = core.entity.id(target) orelse return error.NotAddressable;
            return core.bmc.delete(T, self.gpa, self.transport, id);
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

    /// The session collection lives under `Links` on a real service root,
    /// because that is the one place an unauthenticated client can read it.
    const LinksBlock = struct {
        Sessions: ?core.NavProperty(SessionCollection) = null,
    };

    const SessionCollection = struct {
        @"@odata.id": ?core.ODataId = null,
        Members: ?[]const core.NavProperty(Session) = null,
    };

    const Session = struct {
        @"@odata.id": ?core.ODataId = null,
        Id: ?[]const u8 = null,
        UserName: ?[]const u8 = null,
    };

    @"@odata.id": ?core.ODataId = null,
    Links: ?LinksBlock = null,
    RedfishVersion: ?[]const u8 = null,
    Vendor: ?[]const u8 = null,
    Product: ?[]const u8 = null,
    Oem: ?struct { additional_properties: core.AdditionalProperties = .{} } = null,
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

test "a quirk withdraws the capability it says does not work" {
    var transport: StubTransport = .{ .routes = &.{.{ .uri = "/redfish/v1", .body = root_body }} };

    var service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();

    // Advertised, and believed until told otherwise.
    try testing.expect(service.expandQuery() != null);
    try testing.expect(service.supported.filter);
    try testing.expect(service.etagsUsable());

    service.applyQuirks(&.{.{
        .match = .{ .vendor = "Contoso", .product_contains = "BMC" },
        .deviations = &.{ .expand_unreliable, .etag_unreliable },
    }});

    try testing.expect(service.expandQuery() == null);
    try testing.expect(!service.etagsUsable());
    // `$expand` being broken says nothing about `$filter`, and no rule did.
    try testing.expect(service.supported.filter);
}

test "a service no rule names is left exactly as it advertised" {
    var transport: StubTransport = .{ .routes = &.{.{ .uri = "/redfish/v1", .body = root_body }} };

    var service = try TestService.connect(testing.allocator, &transport.transport);
    defer service.deinit();
    const before = service.supported;

    service.applyQuirks(&.{.{
        .match = .{ .vendor = "Fabrikam" },
        .deviations = &.{.expand_unreliable},
    }});

    try testing.expect(!service.deviations.any());
    try testing.expectEqual(before.expand.subordinates, service.supported.expand.subordinates);
    try testing.expect(service.expandQuery() != null);
}

test {
    testing.refAllDecls(@This());
}
