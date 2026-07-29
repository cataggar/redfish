//! The high-level client against the real generated schema and a mock BMC.
//!
//! This is the Phase 5 exit criterion in test form: the whole stack — mock
//! transport, `redfish_core`, the generated `redfish_schema_std`, and the
//! `redfish` module on top — driven the way a program would drive it.
//!
//! `redfish/service.zig` tests `Service` against a stand-in root shaped like
//! the emitter's output. This runs it against the emitter's actual output,
//! which is the only way to find out whether the two agree.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "RedfishVersion":"1.18.0","Vendor":"Contoso","Product":"Contoso BMC",
    \\ "UUID":"92384634-2938-2342-8820-489239905423",
    \\ "ProtocolFeaturesSupported":{
    \\   "ExpandQuery":{"NoLinks":true,"ExpandAll":true,"Levels":true,"MaxLevels":2},
    \\   "FilterQuery":true,"SelectQuery":true},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"},
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"},
    \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService"},
    \\ "SessionService":{"@odata.id":"/redfish/v1/SessionService"}}
;

test "a program reads the service root and learns what it can ask for" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1", root_body));

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expectEqualStrings("1.18.0", service.redfishVersion().?);
    try testing.expectEqualStrings("Contoso", service.vendor().?);
    try testing.expectEqualStrings("Contoso BMC", service.product().?);

    // `.` beats `*`, and `$levels` is sent because this service claimed it.
    const expand = service.expandQuery().?;
    try testing.expectEqual(core.ExpandQuery.Expression.current, expand.expression);
    try testing.expectEqual(@as(?u32, 1), expand.levels);
    try testing.expectEqual(@as(?u32, 2), service.supported.levels(9));

    try testing.expect(service.has("Chassis"));
    try testing.expect(!service.has("CompositionService"));

    try bmc.verify();
}

test "the README example: list every chassis the service has" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    // In request order -- which is worth reading closely, because it is the
    // proof that the walk is lazy. The second page is not fetched when the
    // collection is opened; it is fetched after the first page runs out, by
    // which time the caller has already read a member from page one.
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],
            \\ "Members@odata.count":2,
            \\ "Members@odata.nextLink":"/redfish/v1/Chassis?$skip=1"}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1U",
            \\{"@odata.id":"/redfish/v1/Chassis/1U",
            \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\ "Id":"1U","Name":"Computer System Chassis","ChassisType":"RackMount",
            \\ "Manufacturer":"Contoso","SerialNumber":"2M220100SL"}
        ),
        mock.Expect.get("/redfish/v1/Chassis?$skip=1",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/Drawer"}],
            \\ "Members@odata.count":2}
        ),
        mock.Expect.get("/redfish/v1/Chassis/Drawer",
            \\{"@odata.id":"/redfish/v1/Chassis/Drawer",
            \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\ "Id":"Drawer","Name":"Drawer Chassis","ChassisType":"Drawer",
            \\ "Manufacturer":"Contoso","SerialNumber":"2M220100SM"}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| testing.allocator.free(name);
        names.deinit(testing.allocator);
    }

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
        defer chassis.deinit();
        try names.append(testing.allocator, try testing.allocator.dupe(u8, chassis.get().Name.?));
    }

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("Computer System Chassis", names.items[0]);
    try testing.expectEqualStrings("Drawer Chassis", names.items[1]);

    // The walk crossed a page boundary without the loop above knowing.
    try bmc.verify();
}

test "opening a subordinate service the root already expanded costs no request" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1",
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "Id":"RootService","Name":"Root Service",
        \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService",
        \\                  "@odata.type":"#UpdateService.v1_15_0.UpdateService",
        \\                  "Id":"UpdateService","Name":"Update Service",
        \\                  "ServiceEnabled":true,
        \\                  "HttpPushUri":"/FWUpdate"}}
    ));

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const update = try service.open("UpdateService");
    defer update.deinit();

    try testing.expect(!update.wasFetched());
    try testing.expect(update.get().ServiceEnabled.?);
    try testing.expectEqualStrings("/FWUpdate", update.get().HttpPushUri.?);

    try testing.expectEqual(@as(usize, 1), bmc.requestCount());
    try bmc.verify();
}

test "the types behind the root's links are the generated ones" {
    try testing.expect(Service.Linked("Chassis") ==
        schema.chassis_collection.ChassisCollection);
    try testing.expect(Service.Linked("UpdateService") ==
        schema.update_service.UpdateService);
    try testing.expect(Service.Linked("Systems") ==
        schema.computer_system_collection.ComputerSystemCollection);
}

test "a service whose expand advertisement is not trusted sends none" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1", root_body));

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();
    try testing.expect(service.expandQuery() != null);

    // What a caller does on recognizing a platform whose `$expand` returns
    // a response that parses and is wrong.
    service.distrustExpand();

    try testing.expect(service.expandQuery() == null);
    try testing.expect(service.supported.filter);
    try bmc.verify();
}

test "a quirk is matched against the real service root, oem included" {
    // The `Oem` path is the one worth checking against the generated type
    // rather than a stand-in: it reads through the open struct that keeps
    // members no schema names, which is where a vendor identifies its own
    // firmware build when nothing else does.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1",
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "Id":"RootService","Name":"Root Service",
        \\ "RedfishVersion":"1.9.0","Vendor":"AMI","Product":"AMI BMC",
        \\ "Oem":{"Ami":{"RtpVersion":"1.2.3"}},
        \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true},"FilterQuery":true}}
    ));

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();
    try testing.expect(service.expandQuery() != null);

    service.applyQuirks(&.{
        // Every AMI service: no rule about expand.
        .{ .match = .{ .vendor = "AMI" }, .deviations = &.{.filter_unreliable} },
        // Only the build identified by the OEM property.
        .{
            .match = .{ .vendor = "AMI", .oem = .{
                .vendor = "Ami",
                .property = "RtpVersion",
                .equals = "1.2.3",
            } },
            .deviations = &.{.expand_unreliable},
        },
        // A build this is not.
        .{
            .match = .{ .oem = .{ .vendor = "Ami", .property = "RtpVersion", .equals = "9.9.9" } },
            .deviations = &.{.etag_unreliable},
        },
    });

    try testing.expect(service.expandQuery() == null);
    try testing.expect(!service.supported.filter);
    try testing.expect(service.etagsUsable());
    try bmc.verify();
}
