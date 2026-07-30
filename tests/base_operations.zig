//! The protocol surface, exercised through the real generated schema.
//!
//! `core/` proves each primitive on a hand-written struct: `Nullable` tells
//! absent from null, `Payload` omits what nobody set, `OpenEnum` keeps a
//! member it does not know. What none of that proves is that the *generator*
//! reaches for those primitives in the right places, which is the only reason
//! a caller ever benefits from them.
//!
//! So every type here comes from `redfish_schema_std`, chosen because the
//! standard schema happens to declare the shape in question: a rigid array
//! on `ExternalAccountProvider`, an excerpt on `BatteryMetrics`, a bound
//! action on `Chassis`, a creatable member behind `EventDestination`.
//!
//! These are ports of `nv-redfish`'s `tests-base-operations.rs`, which runs
//! the same cases against a synthetic corpus written to contain one of each.
//! Two of its cases are `trybuild` assertions that a program does *not*
//! compile -- that a read struct has no write-only field, and that action
//! parameters have no `Debug`. Zig's test runner cannot express either, and
//! both are already pinned where the decision is made: `emit.zig`'s "a
//! write-only property is not in the shape that reads it", and the absence of
//! any derive to suppress.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const AccountService = schema.account_service.AccountService;
const BatteryMetrics = schema.battery_metrics.BatteryMetrics;
const Chassis = schema.chassis.Chassis;
const EventDestination = schema.event_destination.EventDestination;
const Sensor = schema.sensor.Sensor;

const account_service_uri = "/redfish/v1/AccountService";
const chassis_uri = "/redfish/v1/Chassis/1U";
const subscriptions_uri = "/redfish/v1/EventService/Subscriptions";

/// Reads `T` from the mock at `uri`, which every test below starts by doing.
fn read(comptime T: type, bmc: *mock.MockBmc, uri: []const u8) !core.Owned(T) {
    return core.bmc.get(T, testing.allocator, &bmc.transport, .{ .value = uri });
}

// -- Reading ---------------------------------------------------------------

test "a property the service sent as null reads the same as one it left out" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U","AssetTag":null}
        ),
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U"}
        ),
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U","AssetTag":"free-form"}
        ),
    });

    // A read shape does not distinguish the two, and deliberately: DSP0266
    // gives them the same meaning on the way out -- the service has no value
    // for the property -- and a caller that had to handle `??[]const u8`
    // everywhere would pay for a difference it can never act on.
    const explicit = try read(Chassis, &bmc, chassis_uri);
    defer explicit.deinit();
    try testing.expectEqual(@as(?[]const u8, null), explicit.value.AssetTag);

    const absent = try read(Chassis, &bmc, chassis_uri);
    defer absent.deinit();
    try testing.expectEqual(@as(?[]const u8, null), absent.value.AssetTag);

    const present = try read(Chassis, &bmc, chassis_uri);
    defer present.deinit();
    try testing.expectEqualStrings("free-form", present.value.AssetTag.?);

    try bmc.verify();
}

test "a rigid array keeps the holes the service left in it" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(account_service_uri,
        \\{"@odata.id":"/redfish/v1/AccountService","Id":"AccountService",
        \\ "LDAP":{"ServiceAddresses":["ldaps://a.example",null,"ldaps://c.example"]}}
    ));

    const service = try read(AccountService, &bmc, account_service_uri);
    defer service.deinit();

    // `ServiceAddresses` is a rigid array: position is meaningful, so a
    // service that has nothing for slot 1 sends a null rather than a shorter
    // array. Dropping it would silently renumber the addresses after it.
    const addresses = service.value.LDAP.?.ServiceAddresses.?;
    try testing.expectEqual(@as(usize, 3), addresses.len);
    try testing.expectEqualStrings("ldaps://a.example", addresses[0].?);
    try testing.expectEqual(@as(?[]const u8, null), addresses[1]);
    try testing.expectEqualStrings("ldaps://c.example", addresses[2].?);

    try bmc.verify();
}

test "an empty collection property is empty, which is not the same as absent" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(account_service_uri,
            \\{"@odata.id":"/redfish/v1/AccountService","LDAP":{"ServiceAddresses":[]}}
        ),
        mock.Expect.get(account_service_uri,
            \\{"@odata.id":"/redfish/v1/AccountService","LDAP":{}}
        ),
    });

    const empty = try read(AccountService, &bmc, account_service_uri);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.value.LDAP.?.ServiceAddresses.?.len);

    // "the service configured no addresses" and "the service does not report
    // addresses" are different answers, and a client deciding whether to
    // write the property needs to be able to tell them apart.
    const missing = try read(AccountService, &bmc, account_service_uri);
    defer missing.deinit();
    try testing.expectEqual(@as(?[]const ?[]const u8, null), missing.value.LDAP.?.ServiceAddresses);

    try bmc.verify();
}

test "a value the schema does not name is kept rather than rejected" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(chassis_uri,
        \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U",
        \\ "ChassisType":"OrbitalHabitat","PowerState":"On"}
    ));

    const chassis = try read(Chassis, &bmc, chassis_uri);
    defer chassis.deinit();

    // A service is free to be newer than the client. `OrbitalHabitat` is not
    // a member the generated enum names, and the alternative to keeping the
    // resource is failing it over a property the caller may never read.
    try testing.expectEqual(schema.chassis.ChassisType.UnsupportedValue, chassis.value.ChassisType.?);
    try testing.expectEqual(schema.resource.PowerState.On, chassis.value.PowerState.?);

    try bmc.verify();
}

test "an excerpt carries the projection, and the resource it copies carries the rest" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1/Chassis/1U/Battery/0/Metrics",
        \\{"@odata.id":"/redfish/v1/Chassis/1U/Battery/0/Metrics","Id":"Metrics",
        \\ "InputVoltage":{"DataSourceUri":"/redfish/v1/Chassis/1U/Sensors/VoltIn",
        \\                 "Reading":12.1,"CrestFactor":1.4}}
    ));

    const metrics = try read(BatteryMetrics, &bmc, "/redfish/v1/Chassis/1U/Battery/0/Metrics");
    defer metrics.deinit();

    const voltage = metrics.value.InputVoltage.?;
    try testing.expectEqualStrings("/redfish/v1/Chassis/1U/Sensors/VoltIn", voltage.DataSourceUri.?);
    try testing.expectEqual(@as(f64, 12.1), voltage.Reading.?.toFloat());

    // The excerpt is a different type from the sensor, holding only the
    // projection the annotation names. `Status` is on the sensor and not in
    // the copy, so a caller that wants it has to follow `DataSourceUri`.
    try testing.expect(!@hasField(@TypeOf(voltage), "Status"));
    try testing.expect(@hasField(Sensor, "Status"));

    try bmc.verify();
}

// -- Writing ---------------------------------------------------------------

test "an update sends the properties the caller set and no others" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.patchNoContent(chassis_uri,
        \\{"AssetTag":"rack-4-slot-2"}
    ));

    const written = try core.bmc.update(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .{ .value = chassis_uri },
        null,
        schema.chassis.ChassisUpdate{ .AssetTag = .{ .value = "rack-4-slot-2" } },
    );
    defer written.deinit();

    // Everything else on `ChassisUpdate` defaulted, and a PATCH that carried
    // those defaults would be a request to clear them.
    try bmc.verify();
}

test "a write tells apart leaving a property alone and clearing it" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.patchNoContent(chassis_uri,
        \\{"AssetTag":null}
    ));

    const written = try core.bmc.update(
        Chassis,
        testing.allocator,
        &bmc.transport,
        .{ .value = chassis_uri },
        null,
        schema.chassis.ChassisUpdate{ .AssetTag = .none },
    );
    defer written.deinit();

    // This is the distinction the read shape does not need and the write
    // shape cannot do without: `.absent` omits the property, `.none` asks the
    // service to forget the value it has.
    try bmc.verify();
}

test "a rigid array is written back with its holes intact" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.patchNoContent(account_service_uri,
        \\{"LDAP":{"ServiceAddresses":["ldaps://a.example",null]}}
    ));

    const written = try core.bmc.update(
        AccountService,
        testing.allocator,
        &bmc.transport,
        .{ .value = account_service_uri },
        null,
        schema.account_service.AccountServiceUpdate{
            .LDAP = .{ .ServiceAddresses = &.{ "ldaps://a.example", null } },
        },
    );
    defer written.deinit();

    // A hole in the request means "leave this slot alone", so collapsing the
    // array on the way out would rewrite the entry after it.
    try bmc.verify();
}

test "a resource is written at its own id, with its own etag" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1U","@odata.etag":"W/\"42\"","Id":"1U"}
        ),
        mock.Expect.patchNoContent(chassis_uri,
            \\{"AssetTag":"rack-4-slot-2"}
        ),
    });

    const chassis = try read(Chassis, &bmc, chassis_uri);
    defer chassis.deinit();

    const written = try core.bmc.updateEntity(
        Chassis,
        testing.allocator,
        &bmc.transport,
        chassis.value,
        schema.chassis.ChassisUpdate{ .AssetTag = .{ .value = "rack-4-slot-2" } },
    );
    defer written.deinit();

    // The id and the ETag came from the value that was read, so they cannot
    // be mismatched with each other the way two arguments could be.
    try testing.expectEqualStrings("W/\"42\"", bmc.request(1).if_match.?);
    try bmc.verify();
}

// -- Creating --------------------------------------------------------------

test "creating a collection member posts to the collection and returns the member" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.created(
        subscriptions_uri,
        \\{"Destination":"https://listener.example/events","Protocol":"Redfish"}
    ,
        "/redfish/v1/EventService/Subscriptions/1",
        \\{"@odata.id":"/redfish/v1/EventService/Subscriptions/1","Id":"1",
        \\ "Destination":"https://listener.example/events","Protocol":"Redfish"}
        ,
    ));

    const created = try core.bmc.create(
        EventDestination,
        testing.allocator,
        &bmc.transport,
        .{ .value = subscriptions_uri },
        schema.event_destination.EventDestinationCreate{
            .Destination = "https://listener.example/events",
            .Protocol = .Redfish,
        },
    );
    defer created.deinit();

    // `Destination` and `Protocol` have no default because the schema marks
    // them required on create: the create shape will not compile without
    // them, which is the whole reason it is a separate type.
    const member = try created.value.expectEntity();
    try testing.expectEqualStrings("/redfish/v1/EventService/Subscriptions/1", member.@"@odata.id".?.value);
    try bmc.verify();
}

// -- Invoking --------------------------------------------------------------

test "invoking an action posts its parameters to the target the service advertised" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(chassis_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U",
            \\ "Actions":{"#Chassis.Reset":{
            \\   "target":"/redfish/v1/Chassis/1U/Actions/Chassis.Reset"}}}
        ),
        mock.Expect.action(
            "/redfish/v1/Chassis/1U/Actions/Chassis.Reset",
            \\{"ResetType":"GracefulRestart"}
        ,
            "{}",
        ),
    });

    const chassis = try read(Chassis, &bmc, chassis_uri);
    defer chassis.deinit();

    const response = try chassis.value.Actions.?.reset(
        testing.allocator,
        &bmc.transport,
        .{ .ResetType = .GracefulRestart },
    );
    defer response.deinit();

    // The target is the service's, not a URI the client built. A service is
    // free to put its actions anywhere, and several do.
    try testing.expectEqualStrings(
        "/redfish/v1/Chassis/1U/Actions/Chassis.Reset",
        bmc.request(1).uri,
    );
    try bmc.verify();
}

test "an action the service did not advertise is refused before anything is sent" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(chassis_uri,
        \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U","Actions":{}}
    ));

    const chassis = try read(Chassis, &bmc, chassis_uri);
    defer chassis.deinit();

    // Not every service implements every action the schema declares, and the
    // only honest answer is the one that costs no request.
    try testing.expectError(error.ActionNotSupported, chassis.value.Actions.?.reset(
        testing.allocator,
        &bmc.transport,
        .{},
    ));
    try testing.expectEqual(@as(usize, 1), bmc.requestCount());
    try bmc.verify();
}

test "an action request omits the parameters the caller did not set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Reset = schema.chassis.ChassisResetAction;

    const omitted = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        Reset{},
        .{ .emit_null_optional_fields = false },
    );
    try testing.expectEqualStrings("{}", omitted);

    const set = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        Reset{ .ResetType = .ForceOff },
        .{ .emit_null_optional_fields = false },
    );
    try testing.expectEqualStrings("{\"ResetType\":\"ForceOff\"}", set);
}
