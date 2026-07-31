//! A tree of collections, and the sensor readings that arrive without being
//! asked for.
//!
//! Ports `nv-redfish`'s `test-power-equipment.rs`, which is three tests, one
//! of which is a real navigation and two of which are `Ok(None)` for a link
//! the service did not send. Only the first is ported.
//! `missing_power_equipment_link_returns_none` is
//! `chassis.zig`'s "a root that does not link Chassis is not given one" with a
//! different field name, and `missing_power_shelves_link_returns_none` is
//! `manager.zig`'s "a manager with no network protocol link is not asked for
//! one". Both are `?T` on a generated struct; a third copy would assert `null
//! == null` against a fourth resource.
//!
//! The rest of the file is the part of power equipment that has no reference
//! test at all, because the reference stops at `PowerShelves` and never reads
//! an outlet or a circuit. That is where this schema keeps its distinctive
//! shape: **excerpts**. `Redfish.Excerpt` and `Redfish.ExcerptCopy` let a
//! service inline a projection of a `Sensor` into whatever quotes it, and a
//! power-equipment payload is mostly excerpts — a single outlet can carry ten
//! sensor readings that would otherwise be ten requests.
//!
//! `base_operations.zig` already pins that an excerpt is a narrower type than
//! the resource it copies, and `chassis.zig` that `DataSourceUri` is the only
//! way back to the original. What is new here, and is the finding of this
//! increment, is that the emitter got the *views* right: `Redfish.Excerpt`
//! takes a comma-separated list of view names, each property that quotes a
//! sensor names the view it wants, and the generator emits one type per view.
//! An `Outlet` therefore holds five different Zig types for the same
//! `Sensor`, and the widest of them is the one with no view name at all.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Outlet = schema.outlet.Outlet;
const PowerDistribution = schema.power_distribution.PowerDistribution;
const PowerDistributionCollection =
    schema.power_distribution_collection.PowerDistributionCollection;
const PowerDistributionMetrics =
    schema.power_distribution_metrics.PowerDistributionMetrics;
const PowerEquipment = schema.power_equipment.PowerEquipment;
const Sensor = schema.sensor.Sensor;
const SensorCollection = schema.sensor_collection.SensorCollection;

const power_equipment_uri = "/redfish/v1/PowerEquipment";
const power_shelves_uri = "/redfish/v1/PowerEquipment/PowerShelves";
const power_shelf_uri = "/redfish/v1/PowerEquipment/PowerShelves/1";
const rack_pdu_uri = "/redfish/v1/PowerEquipment/RackPDUs/1";
const outlet_uri = "/redfish/v1/PowerEquipment/RackPDUs/1/Outlets/A1";
const pdu_metrics_uri = "/redfish/v1/PowerEquipment/RackPDUs/1/Metrics";
const pdu_sensors_uri = "/redfish/v1/PowerEquipment/RackPDUs/1/Sensors";
const pdu_power_sensor_uri = "/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/PowerTotal";

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "PowerEquipment":{"@odata.id":"/redfish/v1/PowerEquipment"}}
;

const power_equipment_body =
    \\{"@odata.id":"/redfish/v1/PowerEquipment",
    \\ "@odata.type":"#PowerEquipment.v1_2_3.PowerEquipment",
    \\ "Id":"PowerEquipment","Name":"Power Equipment",
    \\ "Status":{"State":"Enabled","Health":"OK"},
    \\ "RackPDUs":{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs"},
    \\ "PowerShelves":{"@odata.id":"/redfish/v1/PowerEquipment/PowerShelves"}}
;

fn read(comptime T: type, bmc: *mock.MockBmc, uri: []const u8) !core.Owned(T) {
    return core.bmc.get(T, testing.allocator, &bmc.transport, .{ .value = uri });
}

// -- The navigation the reference does have --------------------------------

test "a power shelf is three links below the root and is not its own type" {
    // `power_equipment_lists_power_shelves`. The walk is ordinary; what is
    // worth pinning is what it arrives at. Every collection under
    // `PowerEquipment` is a `PowerDistributionCollection`, and a power shelf,
    // a rack PDU, a floor PDU and a transfer switch are all
    // `PowerDistribution` — one resource type discriminated at runtime by
    // `EquipmentType`. The reference names a `PowerShelf` type and gives it
    // its own module; here there is nothing to name, because the schema did
    // not distinguish them and inventing a distinction would mean a caller
    // that read `RackPDUs` could not pass a member to code that reads a
    // shelf, though the service says they are the same thing.
    comptime {
        // Named one at a time rather than swept with a loop, so that a rename
        // in the schema is a compile error here instead of a field the loop
        // quietly stops matching.
        for (.{
            "PowerShelves",     "RackPDUs",   "FloorPDUs",
            "TransferSwitches", "Switchgear", "ElectricalBuses",
        }) |name| {
            std.debug.assert(@FieldType(PowerEquipment, name) ==
                ?core.NavProperty(PowerDistributionCollection));
        }
    }

    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get(power_equipment_uri, power_equipment_body),
        mock.Expect.get(power_shelves_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/PowerShelves",
            \\ "@odata.type":"#PowerDistributionCollection.PowerDistributionCollection",
            \\ "Name":"Power Shelves",
            \\ "Members":[{"@odata.id":"/redfish/v1/PowerEquipment/PowerShelves/1"}],
            \\ "Members@odata.count":1}
        ),
        mock.Expect.get(power_shelf_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/PowerShelves/1",
            \\ "@odata.type":"#PowerDistribution.v1_6_0.PowerDistribution",
            \\ "Id":"1","Name":"Power Shelf 1","EquipmentType":"PowerShelf",
            \\ "Manufacturer":"NVIDIA","Model":"NV-PowerShelf-1",
            \\ "SerialNumber":"PS-12345","PartNumber":"900-12345-0000-000",
            \\ "Status":{"State":"Enabled","Health":"OK"}}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const equipment = try service.open("PowerEquipment");
    defer equipment.deinit();
    try testing.expectEqualStrings(
        power_equipment_uri,
        equipment.get().@"@odata.id".?.value,
    );

    const shelves = equipment.get().PowerShelves orelse return error.NoPowerShelves;
    var walker: core.Walker(PowerDistributionCollection) = .init(
        testing.allocator,
        &bmc.transport,
        shelves.odataId() orelse return error.NotAddressable,
    );
    defer walker.deinit();

    const member = (try walker.next()) orelse return error.NoMembers;
    const shelf = try core.follow(PowerDistribution, testing.allocator, &bmc.transport, member);
    defer shelf.deinit();

    try testing.expectEqual(
        schema.power_distribution.PowerEquipmentType.PowerShelf,
        shelf.get().EquipmentType.?,
    );
    try testing.expectEqualStrings("NVIDIA", shelf.get().Manufacturer.?);
    try testing.expectEqualStrings("NV-PowerShelf-1", shelf.get().Model.?);
    try testing.expectEqualStrings("PS-12345", shelf.get().SerialNumber.?);
    try testing.expectEqualStrings("900-12345-0000-000", shelf.get().PartNumber.?);

    try testing.expect(try walker.next() == null);
    try bmc.verify();
}

// -- Excerpts --------------------------------------------------------------

/// One outlet, quoting five sensors by five different excerpt views.
const outlet_body =
    \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Outlets/A1",
    \\ "@odata.type":"#Outlet.v1_4_5.Outlet",
    \\ "Id":"A1","Name":"Outlet A1","OutletType":"IEC_60320_C13",
    \\ "PhaseWiringType":"OnePhase3Wire","NominalVoltage":"AC200To240V",
    \\ "PowerState":"On","PowerEnabled":true,"RatedCurrentAmps":10,
    \\ "Voltage":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/VoltageA1",
    \\            "Reading":208.1,"CrestFactor":1.41,"THDPercent":2.5},
    \\ "CurrentAmps":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/CurrentA1",
    \\                "Reading":4.2,"CrestFactor":1.6},
    \\ "PowerWatts":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/PowerA1",
    \\               "Reading":873.4,"ApparentVA":900.2,"ReactiveVAR":110.5,
    \\               "PowerFactor":0.97,"PhaseAngleDegrees":12.5},
    \\ "EnergykWh":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/EnergyA1",
    \\              "Reading":19833.5,"ApparentkVAh":20100.5,"ReactivekVARh":880.25},
    \\ "FrequencyHz":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/FreqA1",
    \\                "Reading":50,"PhysicalContext":"PowerSupply",
    \\                "Thresholds":{"UpperCritical":{"Reading":63}}}}
;

test "five properties quote one sensor and get five different types" {
    // No reference test: `nv-redfish` never reads an outlet. This is the
    // shape of a power-equipment payload and it is the one place in the
    // schema where the same underlying entity deliberately arrives as
    // different types depending on which property carried it.
    //
    // `Redfish.Excerpt` on a `Sensor` property takes a comma-separated list
    // of view names; `Redfish.ExcerptCopy` on the property that quotes it
    // names the view it wants. The emitter resolves that into one struct per
    // view, so `Outlet.Voltage` and `Outlet.PowerWatts` are not the same type
    // and cannot be confused for one another, and neither is a `Sensor`.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(outlet_uri, outlet_body));

    const outlet = try read(Outlet, &bmc, outlet_uri);
    defer outlet.deinit();

    const voltage = outlet.value.Voltage.?;
    const current = outlet.value.CurrentAmps.?;
    const power = outlet.value.PowerWatts.?;
    const energy = outlet.value.EnergykWh.?;
    const frequency = outlet.value.FrequencyHz.?;

    try testing.expectEqual(@as(f64, 208.1), voltage.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 4.2), current.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 873.4), power.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 19833.5), energy.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 50), frequency.Reading.?.toFloat());

    // Four named views and the unnamed one, all distinct. `Voltage` and
    // `CurrentAmps` happen to project the same four properties and are still
    // separate types, because the annotation named separate views and a
    // later schema version can widen one without widening the other.
    const Voltage = @TypeOf(voltage);
    const Current = @TypeOf(current);
    const Power = @TypeOf(power);
    const Energy = @TypeOf(energy);
    const Default = @TypeOf(frequency);
    comptime {
        std.debug.assert(Voltage != Current);
        std.debug.assert(Voltage != Power);
        std.debug.assert(Power != Energy);
        std.debug.assert(Default != Power);
        std.debug.assert(Default != Sensor);
    }

    // Each view carries exactly what its name is for. Power factor is a
    // property of a power measurement and appears nowhere else; the harmonic
    // distortion of a voltage waveform appears on the two views that measure
    // waveforms.
    try testing.expectEqual(@as(f64, 0.97), power.PowerFactor.?.toFloat());
    try testing.expectEqual(@as(f64, 2.5), voltage.THDPercent.?.toFloat());
    try testing.expectEqual(@as(f64, 880.25), energy.ReactivekVARh.?.toFloat());
    comptime {
        std.debug.assert(!@hasField(Voltage, "ApparentVA"));
        std.debug.assert(@hasField(Power, "ApparentVA"));
        std.debug.assert(!@hasField(Power, "ReactivekVARh"));
        std.debug.assert(@hasField(Energy, "ReactivekVARh"));
    }

    // The view with no name is the widest, which is why the properties that
    // have no particular kind of reading to report use it: `FrequencyHz`
    // gets the thresholds and the physical context that the named views drop.
    try testing.expectEqual(
        @as(f64, 63),
        frequency.Thresholds.?.UpperCritical.?.Reading.?.toFloat(),
    );
    try testing.expectEqual(
        schema.physical_context.PhysicalContext.PowerSupply,
        frequency.PhysicalContext.?,
    );
    comptime {
        std.debug.assert(!@hasField(Voltage, "Thresholds"));
        std.debug.assert(!@hasField(Voltage, "PhysicalContext"));
    }

    // And the excerpt is not a subset of the resource. `DataSourceUri` is
    // annotated `Redfish.ExcerptCopyOnly`, so it exists in every copy and in
    // no `Sensor` — the property that says where a copy came from would be
    // meaningless on the original. A caller cannot therefore write one
    // function over "a sensor or a copy of one" by reading `DataSourceUri`.
    comptime {
        std.debug.assert(@hasField(Voltage, "DataSourceUri"));
        std.debug.assert(@hasField(Default, "DataSourceUri"));
        std.debug.assert(!@hasField(Sensor, "DataSourceUri"));
    }

    try bmc.verify();
}

/// A three-phase outlet, which reports every line separately.
const poly_phase_outlet_body =
    \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Outlets/A1",
    \\ "@odata.type":"#Outlet.v1_4_5.Outlet",
    \\ "Id":"A1","Name":"Outlet A1","PhaseWiringType":"ThreePhase5Wire",
    \\ "PowerState":"On",
    \\ "PolyPhaseVoltage":{
    \\   "Line1ToLine2":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L1L2","Reading":401.1},
    \\   "Line2ToLine3":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L2L3","Reading":399.4},
    \\   "Line3ToLine1":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L3L1","Reading":400.7},
    \\   "Line1ToNeutral":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L1N","Reading":231.2},
    \\   "Line2ToNeutral":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L2N","Reading":230.6},
    \\   "Line3ToNeutral":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L3N","Reading":231.9}},
    \\ "PolyPhaseCurrentAmps":{
    \\   "Line1":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/I1","Reading":12.5},
    \\   "Line2":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/I2","Reading":11.8},
    \\   "Line3":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/I3","Reading":12.1},
    \\   "Neutral":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/IN","Reading":0.4}}}
;

const l1_neutral_sensor_body =
    \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L1N",
    \\ "@odata.type":"#Sensor.v1_10_0.Sensor",
    \\ "Id":"L1N","Name":"Line 1 to Neutral Voltage",
    \\ "ReadingType":"Voltage","ReadingUnits":"V","Reading":231.2,
    \\ "ElectricalContext":"Line1ToNeutral",
    \\ "Status":{"State":"Enabled","Health":"OK"},
    \\ "Thresholds":{"UpperCritical":{"Reading":264},"LowerCritical":{"Reading":180}}}
;

test "ten readings arrive with the outlet and the eleventh costs a request" {
    // No reference test. This is what an excerpt is worth: a three-phase
    // outlet's ten sensors are ten `Sensor` resources at ten URIs, and the
    // service sends the reading of every one of them inside the outlet. A
    // client that wants a dashboard is done after one request.
    //
    // What it does not get is everything. The excerpt has the number and the
    // way back and nothing that says what the number means — units, health,
    // and the thresholds that decide whether 231.2 is a problem all live on
    // the sensor. So the eleventh piece of information costs the request the
    // first ten did not, and this test is the ratio: one request for ten
    // readings, two for one reading understood.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(outlet_uri, poly_phase_outlet_body),
        mock.Expect.get(
            "/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/L1N",
            l1_neutral_sensor_body,
        ),
    });

    const outlet = try read(Outlet, &bmc, outlet_uri);
    defer outlet.deinit();

    const volts = outlet.value.PolyPhaseVoltage.?;
    const amps = outlet.value.PolyPhaseCurrentAmps.?;

    try testing.expectEqual(@as(f64, 401.1), volts.Line1ToLine2.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 399.4), volts.Line2ToLine3.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 400.7), volts.Line3ToLine1.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 231.2), volts.Line1ToNeutral.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 230.6), volts.Line2ToNeutral.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 231.9), volts.Line3ToNeutral.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 12.5), amps.Line1.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 11.8), amps.Line2.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 12.1), amps.Line3.?.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 0.4), amps.Neutral.?.Reading.?.toFloat());
    try testing.expectEqual(@as(usize, 1), bmc.requestCount());

    // `DataSourceUri` is a string rather than a navigation property, so
    // `follow` does not apply and the id is assembled from it. That is the
    // same assembly `chassis.zig` makes for a `Control`; what is different
    // here is that the outlet quoted ten of them and the caller chose one.
    const sensor = try read(Sensor, &bmc, volts.Line1ToNeutral.?.DataSourceUri.?);
    defer sensor.deinit();

    try testing.expectEqualStrings("V", sensor.value.ReadingUnits.?);
    try testing.expectEqual(schema.resource.Health.OK, sensor.value.Status.?.Health.?);
    try testing.expectEqual(
        @as(f64, 264),
        sensor.value.Thresholds.?.UpperCritical.?.Reading.?.toFloat(),
    );
    // Same reading, told twice: the copy is a copy.
    try testing.expectEqual(
        volts.Line1ToNeutral.?.Reading.?.toFloat(),
        sensor.value.Reading.?.toFloat(),
    );

    try testing.expectEqual(@as(usize, 2), bmc.requestCount());
    try bmc.verify();
}

test "the sensor an excerpt copied is a member of a collection the pdu lists" {
    // No reference test. An excerpt's `DataSourceUri` is documented as the
    // source of the copy, and for power equipment that source is normally a
    // member of the `Sensors` collection hanging off the same resource. So
    // the same reading is reachable two ways, and this pins that they agree:
    // the metrics resource quotes a sensor, the PDU lists it, and the number
    // in the copy is the number on the original.
    //
    // Nothing in the schema enforces the correspondence — `DataSourceUri` is
    // a string and could name anything — so a caller that needs the full
    // sensor gets it by reading the URI, not by searching the collection.
    // The search below is the test's, to prove the two agree; it is not how
    // a caller would do it.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(rack_pdu_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1",
            \\ "@odata.type":"#PowerDistribution.v1_6_0.PowerDistribution",
            \\ "Id":"1","Name":"Rack PDU 1","EquipmentType":"RackPDU",
            \\ "PowerCapacityVA":9000,
            \\ "Metrics":{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Metrics"},
            \\ "Sensors":{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors"},
            \\ "Outlets":{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Outlets"}}
        ),
        mock.Expect.get(pdu_metrics_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Metrics",
            \\ "@odata.type":"#PowerDistributionMetrics.v1_3_2.PowerDistributionMetrics",
            \\ "Id":"Metrics","Name":"Rack PDU Metrics",
            \\ "PowerWatts":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/PowerTotal",
            \\               "Reading":4821.5,"ApparentVA":4970.25,"PowerFactor":0.97},
            \\ "EnergykWh":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/EnergyTotal",
            \\              "Reading":118422.75},
            \\ "TemperatureCelsius":{"DataSourceUri":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/Inlet",
            \\                       "Reading":24.5,"PhysicalContext":"Intake"}}
        ),
        mock.Expect.get(pdu_sensors_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors",
            \\ "@odata.type":"#SensorCollection.SensorCollection",
            \\ "Name":"Sensor Collection",
            \\ "Members":[
            \\  {"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/EnergyTotal"},
            \\  {"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/Inlet"},
            \\  {"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/PowerTotal"}],
            \\ "Members@odata.count":3}
        ),
        mock.Expect.get(pdu_power_sensor_uri,
            \\{"@odata.id":"/redfish/v1/PowerEquipment/RackPDUs/1/Sensors/PowerTotal",
            \\ "@odata.type":"#Sensor.v1_10_0.Sensor",
            \\ "Id":"PowerTotal","Name":"Total Power","ReadingType":"Power",
            \\ "ReadingUnits":"W","Reading":4821.5,"ApparentVA":4970.25,
            \\ "PowerFactor":0.97,"ElectricalContext":"Total",
            \\ "Status":{"State":"Enabled","Health":"OK"}}
        ),
    });

    const pdu = try read(PowerDistribution, &bmc, rack_pdu_uri);
    defer pdu.deinit();
    try testing.expectEqual(
        schema.power_distribution.PowerEquipmentType.RackPDU,
        pdu.value.EquipmentType.?,
    );

    const metrics_link = pdu.value.Metrics orelse return error.NoMetrics;
    const metrics = try core.follow(
        PowerDistributionMetrics,
        testing.allocator,
        &bmc.transport,
        metrics_link,
    );
    defer metrics.deinit();

    const total_power = metrics.get().PowerWatts.?;
    try testing.expectEqual(@as(f64, 4821.5), total_power.Reading.?.toFloat());
    try testing.expectEqual(@as(f64, 24.5), metrics.get().TemperatureCelsius.?.Reading.?.toFloat());

    const sensors_link = pdu.value.Sensors orelse return error.NoSensors;
    var walker: core.Walker(SensorCollection) = .init(
        testing.allocator,
        &bmc.transport,
        sensors_link.odataId() orelse return error.NotAddressable,
    );
    defer walker.deinit();

    var listed = false;
    while (try walker.next()) |member| {
        const id = member.odataId() orelse continue;
        if (std.mem.eql(u8, id.value, total_power.DataSourceUri.?)) listed = true;
    }
    try testing.expect(listed);

    const sensor = try read(Sensor, &bmc, total_power.DataSourceUri.?);
    defer sensor.deinit();

    try testing.expectEqual(total_power.Reading.?.toFloat(), sensor.value.Reading.?.toFloat());
    try testing.expectEqual(total_power.ApparentVA.?.toFloat(), sensor.value.ApparentVA.?.toFloat());
    // The units are on the original and nowhere in the copy, which is the
    // reason to have fetched it.
    try testing.expectEqualStrings("W", sensor.value.ReadingUnits.?);
    comptime std.debug.assert(!@hasField(@TypeOf(metrics.get().PowerWatts.?), "ReadingUnits"));

    try bmc.verify();
}
