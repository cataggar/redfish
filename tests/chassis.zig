//! What a chassis costs to reach, and what a chassis can arrive looking like.
//!
//! Ports `nv-redfish`'s `test-chassis.rs`. That file is fourteen tests and
//! eleven of them are named for a platform — `ami_viking_*`, `ami_gb300_*`,
//! `nvidia_dpu_*`, `nvswitch_*` — because each one is a *workaround*: serde is
//! strict, so a missing `Required` property, an unknown enum value, or an
//! extra member inside a link each fail the whole resource, and each platform
//! that does one of those needs code before its chassis can be read at all.
//!
//! Almost none of that is needed here, and not because this stack is more
//! forgiving by accident. Sweeping the recorded corpus (see `README.md`)
//! settled each of these as a decision about the generator: `Redfish.Required`
//! describes a conformant service rather than a real one, so it is not
//! enforced; an enum value the schema does not name becomes
//! `UnsupportedValue`; a member no schema declares is kept or ignored but
//! never fatal. So most of the ports below assert the *absence* of a
//! workaround. They are worth having anyway — that tolerance is load-bearing
//! for real hardware, and nothing else states which payloads depend on it.
//!
//! Four of the fourteen do need something:
//!
//! - a decorated link, which read as an expanded resource and now does not
//!   (`core/nav_property.zig`);
//! - the `$expand` quirk, which is a protocol deviation and so has a
//!   mechanism (`redfish/quirks.zig`);
//! - the navigation itself, which no other test walks this deep;
//! - `UUID: ""`, which reads as absent rather than failing the resource
//!   (`core/struct_json.zig`). A *malformed* UUID still fails, and the last
//!   two tests are that pair.
//!
//! The four `reset_*` cases are already covered by `base_operations.zig`, so
//! only the one that has to navigate four links to find its action is here.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const Control = schema.control.Control;
const EnvironmentMetrics = schema.environment_metrics.EnvironmentMetrics;
const PowerSubsystem = schema.power_subsystem.PowerSubsystem;
const PowerSupply = schema.power_supply.PowerSupply;
const PowerSupplyCollection = schema.power_supply_collection.PowerSupplyCollection;

const chassis_collection_uri = "/redfish/v1/Chassis";
const chassis_uri = "/redfish/v1/Chassis/1";

/// A chassis with everything the schema marks required and nothing else.
const valid_chassis =
    \\{"@odata.id":"/redfish/v1/Chassis/1",
    \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
    \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount"}
;

/// A collection holding one member as a bare link, which is what a service
/// that was not asked to expand returns.
const chassis_collection =
    \\{"@odata.id":"/redfish/v1/Chassis",
    \\ "@odata.type":"#ChassisCollection.ChassisCollection",
    \\ "Id":"Chassis","Name":"Chassis Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1"}]}
;

fn read(comptime T: type, bmc: *mock.MockBmc, uri: []const u8) !core.Owned(T) {
    return core.bmc.get(T, testing.allocator, &bmc.transport, .{ .value = uri });
}

/// Reads the one chassis in the collection, the long way: root, collection,
/// member. Every tolerance test below goes through this rather than fetching
/// the chassis directly, because a payload that parses in isolation and fails
/// as a collection member has not been proven to work.
fn onlyChassis(bmc: *mock.MockBmc, body: []const u8) !core.Resolved(Chassis) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get(chassis_collection_uri, chassis_collection),
        mock.Expect.get(chassis_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
    errdefer chassis.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    return chassis;
}

const root_with_chassis =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService","RedfishVersion":"1.9.0",
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
;

// -- Navigation ------------------------------------------------------------

test "a power supply is five links from the service root, and it resets" {
    // `Chassis.Reset` in `base_operations.zig` starts from a chassis already
    // in hand. This one starts where a program starts, because the thing that
    // breaks is never the POST -- it is one of the four hops before it, and
    // each hop is a different generated nav property.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get(chassis_collection_uri, chassis_collection),
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1",
            \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
            \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount",
            \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem"}}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem",
            \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem",
            \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
            \\ "Id":"PowerSubsystem","Name":"Power Subsystem",
            \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies"}}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies",
            \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies",
            \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
            \\ "Id":"PowerSupplies","Name":"Power Supply Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/1"}]}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/1",
            \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/1",
            \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
            \\ "Id":"1","Name":"Power Supply 1","Manufacturer":"Contoso","Model":"PSU-1",
            \\ "Status":{"Health":"OK","State":"Enabled"},
            \\ "Actions":{"#PowerSupply.Reset":{
            \\   "target":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/1/Actions/PowerSupply.Reset"}}}
        ),
        mock.Expect.action(
            "/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/1/Actions/PowerSupply.Reset",
            \\{"ResetType":"GracefulRestart"}
        ,
            "{}",
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();
    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, (try walker.next()).?);
    defer chassis.deinit();

    const subsystem = try core.follow(
        PowerSubsystem,
        testing.allocator,
        &bmc.transport,
        chassis.get().PowerSubsystem.?,
    );
    defer subsystem.deinit();

    const supplies = try core.follow(
        PowerSupplyCollection,
        testing.allocator,
        &bmc.transport,
        subsystem.get().PowerSupplies.?,
    );
    defer supplies.deinit();

    const supply = try core.follow(
        PowerSupply,
        testing.allocator,
        &bmc.transport,
        supplies.get().Members.?[0],
    );
    defer supply.deinit();

    try testing.expectEqualStrings("Power Supply 1", supply.get().Name.?);

    const response = try supply.get().Actions.?.reset(
        testing.allocator,
        &bmc.transport,
        .{ .ResetType = .GracefulRestart },
    );
    defer response.deinit();

    try bmc.verify();
}

test "a control is reached through the uri of the excerpt that quotes it" {
    // An excerpt is a copy, and `DataSourceUri` is the only way back to the
    // original -- it is a plain string rather than a nav property, so
    // `follow` does not apply and the id has to be made from it. This is the
    // one link shape in the schema that a caller has to assemble by hand,
    // which is exactly why it is worth a test.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const metrics_uri = "/redfish/v1/Chassis/1/EnvironmentMetrics";
    const control_uri = "/redfish/v1/Chassis/1/Controls/PowerLimit";

    try bmc.expectAll(&.{
        mock.Expect.get(metrics_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1/EnvironmentMetrics",
            \\ "@odata.type":"#EnvironmentMetrics.v1_1_0.EnvironmentMetrics",
            \\ "Id":"EnvironmentMetrics","Name":"Environment Metrics",
            \\ "PowerLimitWatts":{
            \\   "DataSourceUri":"/redfish/v1/Chassis/1/Controls/PowerLimit",
            \\   "SetPoint":600}}
        ),
        mock.Expect.get(control_uri, control_body("600")),
        mock.Expect.patch(control_uri,
            \\{"SetPoint":700}
        , control_body("700")),
    });

    const metrics = try read(EnvironmentMetrics, &bmc, metrics_uri);
    defer metrics.deinit();

    // The excerpt carries the set point and the way back, and nothing else:
    // the bounds live on the resource it was copied from.
    const excerpt = metrics.value.PowerLimitWatts.?;
    try testing.expectEqual(@as(f64, 600), excerpt.SetPoint.?.toFloat());
    try testing.expect(excerpt.AllowableMin == null);

    const control = try read(Control, &bmc, excerpt.DataSourceUri.?);
    defer control.deinit();

    try testing.expectEqual(@as(f64, 600), control.value.SetPoint.?.toFloat());
    try testing.expectEqual(@as(f64, 400), control.value.AllowableMin.?.toFloat());
    try testing.expectEqual(@as(f64, 900), control.value.AllowableMax.?.toFloat());

    const updated = try core.bmc.update(
        Control,
        testing.allocator,
        &bmc.transport,
        .{ .value = control_uri },
        null,
        schema.control.ControlUpdate{ .SetPoint = .init(.fromInt(700)) },
    );
    defer updated.deinit();

    const patched = try updated.value.expectEntity();
    try testing.expectEqual(@as(f64, 700), patched.SetPoint.?.toFloat());
    try bmc.verify();
}

fn control_body(comptime set_point: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Chassis/1/Controls/PowerLimit",
    \\ "@odata.type":"#Control.v1_7_0.Control",
    \\ "Id":"PowerLimit","Name":"Power Limit",
    \\ "ControlType":"Power","SetPointType":"Single","SetPointUnits":"W",
    \\ "AllowableMin":400,"AllowableMax":900,
    \\ "SetPoint":
    ++ set_point ++ "}";
}

// -- Payloads that need a workaround elsewhere and none here ---------------

test "a chassis missing the properties its schema requires is still read" {
    // `ami_viking_missing_chassis_type_workaround` and
    // `..._missing_chassis_name_workaround`. `ChassisType` and `Name` are
    // both `Redfish.Required`; 177 payloads in the recorded corpus omit a
    // property their own schema requires, so this is what services do.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis","Id":"1"}
    );
    defer chassis.deinit();

    try testing.expectEqualStrings("1", chassis.get().Id.?);
    try testing.expect(chassis.get().Name == null);
    try testing.expect(chassis.get().ChassisType == null);
    try bmc.verify();
}

test "a member the schema does not declare does not cost the link it sits in" {
    // `ami_viking_invalid_contained_by_fields_workaround`: an `InvalidField`
    // alongside `@odata.id` inside a nav property. This is the one payload in
    // the file that did need a change here -- `NavProperty` told a link from
    // an expanded resource by counting members, so a decorated link read as
    // an expansion carrying nothing, and `follow` would then hand back an
    // empty chassis without fetching it. It now asks whether the object
    // carries anything `Chassis` would recognize.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount",
        \\ "Links":{"ContainedBy":{"@odata.id":"/redfish/v1/Chassis/0",
        \\                         "InvalidField":"invalid"}}}
    );
    defer chassis.deinit();

    const containing = chassis.get().Links.?.ContainedBy.?;
    try testing.expectEqualStrings("/redfish/v1/Chassis/0", containing.odataId().?.value);
    // A link that is only a link, however much else the service put in it.
    try testing.expect(!containing.isExpanded());
    try bmc.verify();
}

test "an enum value the schema does not name does not cost the resource" {
    // `anonymous_1_9_0_wrong_chassis_status_state_workaround`:
    // `Status.State` = `"Standby"`, which is not a `Resource.State` -- the
    // schema has `StandbyOffline` and `StandbySpare` and no bare `Standby`.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"Shelf",
        \\ "Status":{"Health":"OK","HealthRollup":"OK","State":"Standby"}}
    );
    defer chassis.deinit();

    const status = chassis.get().Status.?;
    try testing.expectEqual(schema.resource.State.UnsupportedValue, status.State.?);
    // The properties either side of the bad one survived it, which is the
    // whole point: a client that wanted `Health` should not lose it because
    // the service misspelled something else.
    try testing.expectEqual(schema.resource.Health.OK, status.Health.?);
    try testing.expectEqual(schema.chassis.ChassisType.Shelf, chassis.get().ChassisType.?);
    try bmc.verify();
}

test "the same holds for an enum two complex types down" {
    // `nvswitch_wrong_location_part_location_type_workaround`:
    // `Location.PartLocation.LocationType` = `"Unknown"`. Same tolerance,
    // reached through `Chassis` -> `Resource.Location` -> `PartLocation`,
    // because the value is decoded by whichever struct declares the field and
    // nothing about that is specific to a resource.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"Module",
        \\ "Location":{"PartLocation":{"LocationType":"Unknown",
        \\                             "ServiceLabel":"CPLD_0"}}}
    );
    defer chassis.deinit();

    const part = chassis.get().Location.?.PartLocation.?;
    try testing.expectEqual(schema.resource.LocationType.UnsupportedValue, part.LocationType.?);
    try testing.expectEqualStrings("CPLD_0", part.ServiceLabel.?);
    try bmc.verify();
}

test "a root that does not link Chassis is not given one" {
    // `ami_viking_missing_root_chassis_nav_workaround` invents
    // `/redfish/v1/Chassis` when the root omits the link. This does not, and
    // the difference is deliberate: `@odata.id` is the only statement a
    // service makes about where a resource lives, and a client that guesses
    // has to guess again for every collection. `has` is the check to make,
    // and it is cheap.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1",
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
        \\ "Id":"RootService","Name":"RootService"}
    ));

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expect(!service.has("Chassis"));
    try testing.expectError(error.NotSupported, service.walk("Chassis"));
    // Refused without a request, so a caller that recovers by naming the URI
    // itself has spent nothing.
    try testing.expectEqual(@as(usize, 1), bmc.requestCount());
    try bmc.verify();
}

// -- The one deviation that is a protocol deviation ------------------------

/// An AMI root, optionally carrying the OEM property that identifies the
/// firmware build whose `$expand` drops required properties from the members
/// it embeds.
fn amiRoot(comptime rtp_version: ?[]const u8) []const u8 {
    const head =
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
        \\ "Id":"RootService","Name":"RootService",
        \\ "RedfishVersion":"1.21.1","Vendor":"AMI","Product":"AMI BMC",
        \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true,"ExpandAll":true}},
        \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}
    ;
    return head ++ (if (rtp_version) |v|
        ",\"Oem\":{\"Ami\":{\"RtpVersion\":\"" ++ v ++ "\"}}}"
    else
        "}");
}

/// What a caller observed about that build, in the form `applyQuirks` takes.
const gb300: []const redfish.quirks.Rule = &.{.{
    .match = .{ .vendor = "AMI", .oem = .{
        .vendor = "Ami",
        .property = "RtpVersion",
        .equals = "13.09.1",
    } },
    .deviations = &.{.expand_unreliable},
}};

/// Requests a collection the way a caller does: with whatever `$expand` the
/// service is still trusted for, and without one otherwise. Returns the
/// request as the BMC saw it.
fn requestCollection(service: *const Service, bmc: *mock.MockBmc) !mock.Recorded {
    var buf: [128]u8 = undefined;
    const uri = if (service.expandQuery()) |expand| blk: {
        const query = try expand.toQueryString(testing.allocator);
        defer testing.allocator.free(query);
        break :blk try std.fmt.bufPrint(&buf, "{s}?{s}", .{ chassis_collection_uri, query });
    } else chassis_collection_uri;

    const collection = try read(schema.chassis_collection.ChassisCollection, bmc, uri);
    defer collection.deinit();

    return bmc.request(bmc.requestCount() - 1);
}

test "a service whose expand drops required properties is asked without it" {
    // `ami_gb300_disables_expand_for_chassis_collection`. This is the one
    // deviation in the file that the stack can act on by itself, because it
    // is about the request rather than the response: the correction for a
    // query option that does not work is to stop sending it.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", amiRoot("13.09.1")),
        // Exact, not `expand`: a query string here would not match.
        mock.Expect.get(chassis_collection_uri, chassis_collection),
    });

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expect(service.expandQuery() != null);
    service.applyQuirks(gb300);
    try testing.expect(service.expandQuery() == null);

    // Nothing was asked of the service that it does not do correctly.
    const sent = try requestCollection(&service, &bmc);
    try testing.expectEqualStrings(chassis_collection_uri, sent.path());
    try testing.expectEqual(@as(?[]const u8, null), sent.queryString());
    try bmc.verify();
}

test "an ami service that is not that build keeps its expand" {
    // `ami_without_gb300_rtp_version_uses_expand`. The rule above is written
    // against one firmware build, so a service that is merely the same vendor
    // is not penalised -- which is the reason `Match` can name an OEM
    // property at all.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", amiRoot(null)),
        mock.Expect.expand(chassis_collection_uri, chassis_collection),
    });

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    service.applyQuirks(gb300);
    try testing.expect(service.expandQuery() != null);

    // `.` rather than `*`, and no `$levels`, because this root advertised
    // `NoLinks` and `ExpandAll` and said nothing about levels.
    const sent = try requestCollection(&service, &bmc);
    try testing.expectEqualStrings(chassis_collection_uri, sent.path());
    try testing.expectEqualStrings("$expand=.", sent.queryString().?);
    try bmc.verify();
}

// -- The empty string --------------------------------------------------------

test "a chassis whose UUID is an empty string is read without one" {
    // `nvidia_dpu_empty_chassis_uuid_*`: a DPU in NIC mode answers
    // `"UUID": ""`. `Resource.Uuid` is `Edm.Guid`, and an empty string is not
    // one, so a strict parse fails -- and it fails for the *resource*, not
    // the property, losing a chassis a caller could otherwise have used
    // entirely.
    //
    // That is the wrong trade, and the same trade this stack already refused
    // twice above: an unsupported enum value and an omitted required property
    // both degrade to something readable rather than failing the payload. An
    // empty string where a formatted scalar was required gets the same
    // answer, because an empty string is an absence spelled out loud.
    //
    // A malformed one does not, which is the next test.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(chassis_uri,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount","UUID":""}
    ));

    const chassis = try read(Chassis, &bmc, chassis_uri);
    defer chassis.deinit();

    // Absent, and the rest of the resource arrived.
    try testing.expect(chassis.value.UUID == null);
    try testing.expectEqualStrings("1", chassis.value.Id.?);
    try testing.expectEqual(schema.chassis.ChassisType.RackMount, chassis.value.ChassisType.?);
    try bmc.verify();

    // A well-formed one still reads as itself, so the rule is about the empty
    // string and not about the field.
    var ok: mock.MockBmc = .init(testing.allocator);
    defer ok.deinit();
    try ok.expect(mock.Expect.get(chassis_uri,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount",
        \\ "UUID":"00000000-0000-0000-0000-000000000000"}
    ));

    const nil = try read(Chassis, &ok, chassis_uri);
    defer nil.deinit();
    try testing.expect(nil.value.UUID.?.isNil());
    try ok.verify();
}

test "a chassis whose UUID is wrong is still wrong" {
    // The line is between an absence and an error. `"not-a-uuid"` is a value
    // the service meant, and it is not one -- reading it as absent would
    // report a silence the service never kept.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(chassis_uri,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
        \\ "Id":"1","Name":"Chassis","ChassisType":"RackMount","UUID":"not-a-uuid"}
    ));

    try testing.expectError(error.InvalidCharacter, read(Chassis, &bmc, chassis_uri));
}
