//! Ninety-six readings in one response, and the type information that is not
//! in any of them.
//!
//! Ports `nv-redfish`'s `test-telemetry-service.rs` — or rather, does not.
//! That file is three tests
//! (`set_enabled_preserves_task_and_empty_responses`,
//! `create_definitions_preserves_task_and_empty_responses`,
//! `update_and_delete_definitions_preserve_task_and_empty_responses`) and
//! their names say what they are: eight hand-written wrapper methods each
//! thread a `ModificationResponse` through `try_map_entity_async`, and each
//! one can drop the `Task` or `Empty` case on the way. There are eight
//! chances to get it wrong, so there are three tests.
//!
//! There is no wrapper here, so there is one function per verb and each is
//! already pinned: `account_service.zig`'s "the three answers a service can
//! give when asked to make an account" for `create`, `computer_system.zig`'s
//! "a boot order that becomes a task, and one that becomes nothing" for
//! `update`, and `account_service.zig`'s "deleting an account, and a service
//! that has only promised to" for `delete`. Porting them again against
//! `MetricDefinition` would assert `core.bmc.modificationResponse` a fourth,
//! fifth and sixth time. That is the fifth increment in a row where the
//! reference's per-resource layer turned out to be the thing under test
//! rather than the thing being used, which is worth recording for Decision B.
//!
//! What this file does instead is the increment's own subject: the **wide**
//! read. Every other integration test here reads one resource and a link or
//! two. A metric report is a single resource carrying a large array of small
//! repeated things, and it raises two questions nothing else does — what a
//! wide read costs, and what it leaves out. The answer to the second is the
//! interesting one: `MetricValue` is `Edm.String` however the metric is
//! typed, so a report tells a caller ninety-six numbers and not one of them
//! is a number.
//!
//! Paging is not here. A `MetricReportCollection` pages like any other
//! collection and `pagination.zig` owns that; a metric *report* is not a
//! collection and `MetricValues` is a plain array on the resource, so there
//! is no next link and nothing to walk.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const MetricDefinition = schema.metric_definition.MetricDefinition;
const MetricDefinitionCollection =
    schema.metric_definition_collection.MetricDefinitionCollection;
const MetricDataType = schema.metric_definition.MetricDataType;
const MetricReport = schema.metric_report.MetricReport;
const MetricReportDefinition = schema.metric_report_definition.MetricReportDefinition;
const TelemetryService = schema.telemetry_service.TelemetryService;

const telemetry_uri = "/redfish/v1/TelemetryService";
const definitions_uri = "/redfish/v1/TelemetryService/MetricDefinitions";
const report_uri = "/redfish/v1/TelemetryService/MetricReports/PlatformPowerUsage";
const report_definition_uri =
    "/redfish/v1/TelemetryService/MetricReportDefinitions/PlatformPowerUsage";

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "TelemetryService":{"@odata.id":"/redfish/v1/TelemetryService"}}
;

const telemetry_body =
    \\{"@odata.id":"/redfish/v1/TelemetryService",
    \\ "@odata.type":"#TelemetryService.v1_4_1.TelemetryService",
    \\ "Id":"TelemetryService","Name":"Telemetry Service","ServiceEnabled":true,
    \\ "MinCollectionInterval":"PT5S","MaxReports":8,
    \\ "SupportedCollectionFunctions":["Average","Maximum","Minimum"],
    \\ "MetricDefinitions":{"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions"},
    \\ "MetricReportDefinitions":{"@odata.id":"/redfish/v1/TelemetryService/MetricReportDefinitions"},
    \\ "MetricReports":{"@odata.id":"/redfish/v1/TelemetryService/MetricReports"}}
;

/// Three metrics, taken from thirty-two sensors each. A rack's worth of
/// telemetry is this shape and this size.
const metric_ids = [_][]const u8{ "TempCelsius", "PowerWatts", "FanPercent" };
const sensor_count = 32;
const value_count = sensor_count * metric_ids.len;

/// The report as the service sends it. `zeroed` replaces the report's own
/// timestamp and one value's timestamp with the all-zero form some services
/// write when they have no time to report.
fn wideReport(comptime zeroed: bool) []const u8 {
    comptime {
        @setEvalBranchQuota(500_000);
        const report_time = if (zeroed) "0000-00-00T00:00:00+00:00" else "2024-06-01T12:00:00Z";
        var body: []const u8 = std.fmt.comptimePrint(
            \\{{"@odata.id":"{s}",
            \\ "@odata.type":"#MetricReport.v1_5_2.MetricReport",
            \\ "Id":"PlatformPowerUsage","Name":"Platform Power Usage",
            \\ "Timestamp":"{s}",
            \\ "MetricReportDefinition":{{"@odata.id":"{s}"}},
            \\ "MetricValues":[
        , .{ report_uri, report_time, report_definition_uri });

        var index: usize = 0;
        for (0..sensor_count) |sensor| {
            for (metric_ids, 0..) |metric_id, kind| {
                const stamp = if (zeroed and index == 40)
                    "0000-00-00T00:00:00+00:00"
                else
                    "2024-06-01T12:00:00Z";
                if (index != 0) body = body ++ ",";
                const link = if (index == 0)
                    "\"MetricDefinition\":{\"@odata.id\":\"" ++
                        definitions_uri ++ "/TempCelsius\"},"
                else
                    "";
                body = body ++ std.fmt.comptimePrint(
                    \\{{{s}"MetricId":"{s}","MetricValue":"{d}.5","Timestamp":"{s}",
                    \\ "MetricProperty":"/redfish/v1/Chassis/1/Sensors/{s}{d}/Reading"}}
                , .{ link, metric_id, kind * 100 + sensor, stamp, metric_id, sensor });
                index += 1;
            }
        }

        return body ++ "]}";
    }
}

const wide_report = wideReport(false);
const wide_report_zeroed = wideReport(true);

/// The definitions of the three metrics the report above carries. Expanded,
/// because a caller reading the collection wants the definitions and not
/// three more URIs.
const definitions_body =
    \\{"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions",
    \\ "@odata.type":"#MetricDefinitionCollection.MetricDefinitionCollection",
    \\ "Name":"Metric Definition Collection","Members@odata.count":3,
    \\ "Members":[
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/TempCelsius",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"TempCelsius","Name":"Temperature","MetricType":"Numeric",
    \\   "MetricDataType":"Decimal","Units":"Cel","IsLinear":true,
    \\   "SensingInterval":"PT5S","Implementation":"PhysicalSensor",
    \\   "MetricProperties":["/redfish/v1/Chassis/1/Sensors/TempCelsius{S}/Reading"],
    \\   "Wildcards":[{"Name":"S","Values":["0","1","2"]}]},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/PowerWatts",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"PowerWatts","Name":"Power","MetricType":"Numeric",
    \\   "MetricDataType":"Decimal","Units":"W","IsLinear":true,
    \\   "SensingInterval":"PT1S","Implementation":"PhysicalSensor"},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/FanPercent",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"FanPercent","Name":"Fan Speed","MetricType":"Gauge",
    \\   "MetricDataType":"Decimal","Units":"%","IsLinear":true,
    \\   "SensingInterval":"PT10S","Implementation":"Synthesized"}]}
;

fn read(comptime T: type, bmc: *mock.MockBmc, uri: []const u8) !core.Owned(T) {
    return core.bmc.get(T, testing.allocator, &bmc.transport, .{ .value = uri });
}

// -- The wide read ---------------------------------------------------------

test "ninety-six readings arrive in one resource that does not page" {
    // The report is reached the ordinary way -- root, telemetry service,
    // report -- and then the whole of a rack's telemetry is in hand. Three
    // requests, not ninety-nine, and no walk: `MetricValues` is an array
    // property of a resource rather than a collection, so DSP0266 gives the
    // service no way to send half of it and the client no next link to
    // follow. A service with too much to say issues a different report.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get(telemetry_uri, telemetry_body),
        mock.Expect.get(report_uri, wide_report),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const telemetry = try service.open("TelemetryService");
    defer telemetry.deinit();
    try testing.expectEqual(@as(i64, 8), telemetry.get().MaxReports.?);
    try testing.expectEqual(@as(f64, 5), telemetry.get().MinCollectionInterval.?.toFloatSeconds());

    const report = try read(MetricReport, &bmc, report_uri);
    defer report.deinit();

    const values = report.value.MetricValues.?;
    try testing.expectEqual(@as(usize, value_count), values.len);
    try testing.expectEqualStrings("TempCelsius", values[0].MetricId.?);
    try testing.expectEqualStrings("0.5", values[0].MetricValue.?);
    try testing.expectEqualStrings("FanPercent", values[value_count - 1].MetricId.?);
    try testing.expectEqualStrings("231.5", values[value_count - 1].MetricValue.?);
    try testing.expectEqualStrings(
        "/redfish/v1/Chassis/1/Sensors/FanPercent31/Reading",
        values[value_count - 1].MetricProperty.?,
    );

    // Every one of them parsed, and every one carries its own timestamp --
    // the report's `Timestamp` is when the report was made and not when any
    // particular metric was read.
    for (values) |value| {
        try testing.expect(value.MetricId != null);
        try testing.expect(value.MetricValue != null);
        try testing.expectEqual(@as(u8, 6), value.Timestamp.?.month);
    }
    try testing.expectEqual(@as(u16, 2024), report.value.Timestamp.?.year);

    // Nothing about a report resembles a collection, which is what makes it
    // one response rather than several.
    comptime {
        std.debug.assert(!@hasField(MetricReport, "Members"));
        std.debug.assert(!@hasField(MetricReport, "Members@odata.nextLink"));
    }

    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

test "one timestamp that is not a timestamp costs none of the other values" {
    // The reference has no telemetry-side workaround for this, but it patches
    // the same phenomenon twice elsewhere — `ComputerSystem.LastResetTime`
    // and `SoftwareInventory.ReleaseDate` — each behind a platform
    // fingerprint. #54 replaced both with one rule that knows nothing about
    // any platform: a timestamp whose every digit is zero is a timestamp the
    // service does not have, and reads as absent.
    //
    // A wide read is where that rule earns the most. In an array of ninety-six
    // values a strict parser fails the resource on the first bad element, so
    // one sensor whose clock never started costs the whole rack's telemetry.
    // Here it costs its own `Timestamp` and nothing else: the value beside it
    // is still readable, and so are the ninety-five others.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(report_uri, wide_report_zeroed));

    const report = try read(MetricReport, &bmc, report_uri);
    defer report.deinit();

    try testing.expect(report.value.Timestamp == null);

    const values = report.value.MetricValues.?;
    try testing.expectEqual(@as(usize, value_count), values.len);
    try testing.expect(values[40].Timestamp == null);
    try testing.expectEqualStrings("PowerWatts", values[40].MetricId.?);
    try testing.expectEqualStrings("113.5", values[40].MetricValue.?);

    var timestamped: usize = 0;
    for (values) |value| {
        if (value.Timestamp != null) timestamped += 1;
        try testing.expect(value.MetricValue != null);
    }
    try testing.expectEqual(@as(usize, value_count - 1), timestamped);

    try bmc.verify();
}

// -- What a report does not carry ------------------------------------------

/// A short report whose four metrics are four different types, plus one the
/// service had no value for.
const typed_report =
    \\{"@odata.id":"/redfish/v1/TelemetryService/MetricReports/Mixed",
    \\ "@odata.type":"#MetricReport.v1_5_2.MetricReport",
    \\ "Id":"Mixed","Name":"Mixed Metric Report",
    \\ "Timestamp":"2024-06-01T12:00:00Z",
    \\ "MetricValues":[
    \\  {"MetricId":"InletTemp","MetricValue":"23.5"},
    \\  {"MetricId":"PowerCapped","MetricValue":"true"},
    \\  {"MetricId":"Reboots","MetricValue":"42"},
    \\  {"MetricId":"PowerState","MetricValue":"On"},
    \\  {"MetricId":"FanSpeed","MetricValue":null}]}
;

const typed_definitions =
    \\{"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions",
    \\ "@odata.type":"#MetricDefinitionCollection.MetricDefinitionCollection",
    \\ "Name":"Metric Definition Collection","Members@odata.count":5,
    \\ "Members":[
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/InletTemp",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"InletTemp","Name":"Inlet Temperature",
    \\   "MetricDataType":"Decimal","MetricType":"Numeric","Units":"Cel"},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/PowerCapped",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"PowerCapped","Name":"Power Capped",
    \\   "MetricDataType":"Boolean","MetricType":"Discrete",
    \\   "DiscreteValues":["true","false"]},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/Reboots",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"Reboots","Name":"Reboot Count",
    \\   "MetricDataType":"Integer","MetricType":"Counter"},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/PowerState",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"PowerState","Name":"Power State",
    \\   "MetricDataType":"Enumeration","MetricType":"Discrete",
    \\   "DiscreteValues":["On","Off","PoweringOn","PoweringOff"]},
    \\  {"@odata.id":"/redfish/v1/TelemetryService/MetricDefinitions/FanSpeed",
    \\   "@odata.type":"#MetricDefinition.v1_3_5.MetricDefinition",
    \\   "Id":"FanSpeed","Name":"Fan Speed",
    \\   "MetricDataType":"Decimal","MetricType":"Gauge","Units":"%"}]}
;

/// What a caller has to write, because nothing in the stack writes it for
/// them: the string from the report, read according to the type from the
/// definition.
fn readAs(data_type: MetricDataType, text: []const u8) !core.PrimitiveType {
    return switch (data_type) {
        .Decimal => .{ .decimal = try core.Decimal.parse(text) },
        .Integer => .{ .integer = try std.fmt.parseInt(i64, text, 10) },
        .Boolean => .{ .boolean = if (std.mem.eql(u8, text, "true"))
            true
        else if (std.mem.eql(u8, text, "false"))
            false
        else
            return error.NotABoolean },
        .String, .Enumeration, .DateTime, .UnsupportedValue => .{ .string = text },
    };
}

test "a metric value is a string whatever the metric's type is" {
    // `MetricReport.MetricValues[].MetricValue` is `Edm.String`, and the
    // schema is explicit that it stays one: a number is converted to its
    // string form, an array to a JSON string, and a boolean to the literal
    // `true` or `false`. The generator has no room to be clever here and is
    // not, so a report of ninety-six numbers is ninety-six strings and the
    // caller does the arithmetic of turning them back.
    //
    // The corpus proves this is a decision the schema made rather than a
    // limit of the generator. `AttributeRegistry`'s `CurrentValue` is
    // `Edm.PrimitiveType` and comes back as `core.PrimitiveType`, carrying
    // whichever JSON type the service sent — the same emitter, the same run,
    // a different annotation. `bios.zig` pins the neighbouring case, where an
    // attribute value keeps its JSON type through `std.json.Value`.
    //
    // No helper for this went into `redfish/`, and `readAs` above is the
    // whole of what one would be. The type it needs is not in the report: it
    // is in a `MetricDefinition` that a caller may or may not have fetched,
    // may have fetched from a different service, and may not be able to fetch
    // at all, because a metric report arriving over SSE carries no service to
    // ask. A library function taking both would only be spelling the switch
    // that a caller writes once and then never touches; a library function
    // taking one would have to guess. That is the fifth time this stack has
    // declined to make per-caller policy into API.
    comptime {
        const MetricValue = schema.metric_report.MetricValue;
        std.debug.assert(@FieldType(MetricValue, "MetricValue") == ?[]const u8);
        // The declared type of the metric is not here at all, and there is no
        // second field carrying it. It lives one resource away.
        std.debug.assert(!@hasField(MetricValue, "MetricDataType"));
    }

    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1/TelemetryService/MetricReports/Mixed", typed_report),
        mock.Expect.expand(definitions_uri, typed_definitions),
    });

    const report = try read(MetricReport, &bmc, "/redfish/v1/TelemetryService/MetricReports/Mixed");
    defer report.deinit();

    const definitions = try core.bmc.expand(
        MetricDefinitionCollection,
        testing.allocator,
        &bmc.transport,
        .{ .value = definitions_uri },
        .{ .levels = 1 },
    );
    defer definitions.deinit();

    const values = report.value.MetricValues.?;
    try testing.expectEqual(@as(usize, 5), values.len);

    // Every value is a string in the payload, and four of them are not
    // strings in any other sense.
    try testing.expectEqualStrings("23.5", values[0].MetricValue.?);
    try testing.expectEqualStrings("true", values[1].MetricValue.?);
    try testing.expectEqualStrings("42", values[2].MetricValue.?);
    try testing.expectEqualStrings("On", values[3].MetricValue.?);

    // An explicit JSON null is the metric having no value, which the schema
    // says in as many words. It reads the same as a value the service left
    // out; `base_operations.zig` settles that they are indistinguishable.
    try testing.expect(values[4].MetricValue == null);

    const expected = [_]core.PrimitiveType{
        .{ .decimal = try core.Decimal.parse("23.5") },
        .{ .boolean = true },
        .{ .integer = 42 },
        .{ .string = "On" },
    };

    for (values[0..4], expected) |value, want| {
        const definition = findDefinition(definitions.value, value.MetricId.?) orelse
            return error.NoSuchDefinition;
        const got = try readAs(definition.MetricDataType.?, value.MetricValue.?);
        try testing.expectEqual(
            @as(std.meta.Tag(core.PrimitiveType), want),
            @as(std.meta.Tag(core.PrimitiveType), got),
        );
        switch (want) {
            .decimal => |d| try testing.expect(d.eql(got.decimal)),
            .boolean => |b| try testing.expectEqual(b, got.boolean),
            .integer => |i| try testing.expectEqual(i, got.integer),
            .string => |s| try testing.expectEqualStrings(s, got.string),
        }
    }

    // The string is not enough on its own, and this is the proof: "42" reads
    // as an integer under one definition and would read as four bytes under
    // another, and the report says nothing about which.
    const as_string = try readAs(.String, values[2].MetricValue.?);
    try testing.expectEqualStrings("42", as_string.string);

    try bmc.verify();
}

/// The definition with this `Id`, out of a collection the service expanded.
///
/// Returns a pointer into the collection's own arena, so it is valid exactly
/// as long as the `Owned` that holds it.
fn findDefinition(
    collection: MetricDefinitionCollection,
    id: []const u8,
) ?*const MetricDefinition {
    for (collection.Members orelse return null) |member| {
        const definition = member.value() orelse continue;
        const member_id = definition.Id orelse continue;
        if (std.mem.eql(u8, member_id, id)) return definition;
    }
    return null;
}

test "the definitions ninety-six values point at are read once, not ninety-six times" {
    // The cost of a wide read is not the reading, it is what a caller does
    // next. Ninety-six values name three metrics between them, and the type,
    // the units and the sensing interval a caller needs to make sense of any
    // of them are on the metric rather than on the value — so the choice is
    // one request for the definitions collection, or one per value.
    //
    // The schema agrees, and says so by deprecating the other path.
    // `MetricValue.MetricDefinition` is a link to the definition of that one
    // value, deprecated in v1.5.0 in favour of `MetricId`, which is the same
    // information as a key into a collection already in hand. It is still
    // generated, because the emitter emits what the CSDL declares, and the
    // first value below carries one. Following it is what the deprecation is
    // warning about: it arrives as a reference and not as an expansion, so
    // ninety-six of them would be ninety-six round trips for three answers.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get(report_uri, wide_report),
        mock.Expect.expand(definitions_uri, definitions_body),
    });

    const report = try read(MetricReport, &bmc, report_uri);
    defer report.deinit();

    const definitions = try core.bmc.expand(
        MetricDefinitionCollection,
        testing.allocator,
        &bmc.transport,
        .{ .value = definitions_uri },
        .{ .levels = 1 },
    );
    defer definitions.deinit();

    try testing.expectEqual(@as(i64, 3), definitions.value.@"Members@odata.count".?);

    var units_seen: [metric_ids.len][]const u8 = undefined;
    for (metric_ids, 0..) |id, i| {
        const definition = findDefinition(definitions.value, id) orelse
            return error.NoSuchDefinition;
        try testing.expectEqual(MetricDataType.Decimal, definition.MetricDataType.?);
        units_seen[i] = definition.Units.?;
    }
    try testing.expectEqualStrings("Cel", units_seen[0]);
    try testing.expectEqualStrings("W", units_seen[1]);
    try testing.expectEqualStrings("%", units_seen[2]);

    // Every value in the report resolved against the three definitions, and
    // the resolution cost nothing beyond the two requests already made. The
    // deprecated per-value link is a reference on the one value that carries
    // it and absent on the other ninety-five, so nothing about reading the
    // report went near it.
    const values = report.value.MetricValues.?;
    const deprecated = values[0].MetricDefinition.?;
    try testing.expect(!deprecated.isExpanded());
    try testing.expectEqualStrings(
        definitions_uri ++ "/TempCelsius",
        deprecated.odataId().?.value,
    );
    for (values, 0..) |value, i| {
        try testing.expect(findDefinition(definitions.value, value.MetricId.?) != null);
        if (i != 0) try testing.expect(value.MetricDefinition == null);
    }
    try testing.expectEqual(@as(usize, 2), bmc.requestCount());

    // The sensing interval is the other thing only the definition knows, and
    // it is what tells a caller how often the report is worth re-reading.
    const temperature = findDefinition(definitions.value, "TempCelsius").?;
    try testing.expectEqual(@as(f64, 5), temperature.SensingInterval.?.toFloatSeconds());
    try testing.expectEqual(
        schema.metric_definition.ImplementationType.Synthesized,
        findDefinition(definitions.value, "FanPercent").?.Implementation.?,
    );

    try bmc.verify();
}

// -- What the report was asked for -----------------------------------------

test "a report definition is arrays inside arrays, and wildcards nobody expands" {
    // The other half of a wide read is the request that produced it, and a
    // `MetricReportDefinition` is the deepest plain-data shape in the corpus
    // that no navigation is involved in: an array of `Metric`, each holding
    // an array of nullable strings, beside an array of `Wildcard`, each
    // holding another. Nothing else in this suite reads an array of a complex
    // type that itself contains an array.
    //
    // The wildcards are the point. `MetricProperties` holds a template with
    // `{name}` in it and `Wildcards` holds the values that fill it, so the
    // definition of ninety-six readings is three lines rather than ninety-six.
    // Expanding them is arithmetic on strings with no Redfish in it, and it
    // stays in the caller for the same reason parsing a metric value does —
    // the schema hands over both halves and does not ask for the answer back.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get(report_definition_uri,
        \\{"@odata.id":"/redfish/v1/TelemetryService/MetricReportDefinitions/PlatformPowerUsage",
        \\ "@odata.type":"#MetricReportDefinition.v1_4_7.MetricReportDefinition",
        \\ "Id":"PlatformPowerUsage","Name":"Platform Power Usage",
        \\ "MetricReportDefinitionType":"Periodic","MetricReportDefinitionEnabled":true,
        \\ "ReportActions":["LogToMetricReportsCollection","RedfishEvent"],
        \\ "ReportUpdates":"Overwrite","AppendLimit":1000,
        \\ "Schedule":{"RecurrenceInterval":"PT30S"},
        \\ "Wildcards":[
        \\  {"Name":"CId","Values":["1","2"]},
        \\  {"Name":"SId","Values":["Inlet","Outlet",null]}],
        \\ "Metrics":[
        \\  {"MetricId":"TempCelsius",
        \\   "MetricProperties":["/redfish/v1/Chassis/{CId}/Sensors/{SId}/Reading"],
        \\   "CollectionFunction":"Average","CollectionDuration":"PT30S",
        \\   "CollectionTimeScope":"Interval"},
        \\  {"MetricId":"PowerWatts",
        \\   "MetricProperties":["/redfish/v1/Chassis/{CId}/Sensors/Power/Reading",
        \\                       "/redfish/v1/Chassis/{CId}/Sensors/PowerPeak/Reading"],
        \\   "CollectionFunction":"Maximum","CollectionTimeScope":"Point"}],
        \\ "MetricReport":{"@odata.id":"/redfish/v1/TelemetryService/MetricReports/PlatformPowerUsage"}}
    ));

    const definition = try read(MetricReportDefinition, &bmc, report_definition_uri);
    defer definition.deinit();

    try testing.expectEqual(
        schema.metric_report_definition.MetricReportDefinitionType.Periodic,
        definition.value.MetricReportDefinitionType.?,
    );
    try testing.expectEqual(
        @as(f64, 30),
        definition.value.Schedule.?.RecurrenceInterval.?.toFloatSeconds(),
    );

    const actions = definition.value.ReportActions.?;
    try testing.expectEqual(@as(usize, 2), actions.len);
    try testing.expectEqual(
        schema.metric_report_definition.ReportActionsEnum.LogToMetricReportsCollection,
        actions[0],
    );

    const metrics = definition.value.Metrics.?;
    try testing.expectEqual(@as(usize, 2), metrics.len);
    try testing.expectEqual(@as(usize, 1), metrics[0].MetricProperties.?.len);
    try testing.expectEqual(@as(usize, 2), metrics[1].MetricProperties.?.len);
    try testing.expectEqual(@as(f64, 30), metrics[0].CollectionDuration.?.toFloatSeconds());
    try testing.expectEqual(
        schema.metric_report_definition.CalculationAlgorithmEnum.Maximum,
        metrics[1].CollectionFunction.?,
    );

    // `Values` is an array of *nullable* strings, so a hole in it is a member
    // the service sent as null rather than a member it omitted. That
    // distinction is the whole reason the element type is `?[]const u8`, and
    // it survives two levels of nesting.
    const wildcards = definition.value.Wildcards.?;
    try testing.expectEqual(@as(usize, 2), wildcards.len);
    try testing.expectEqualStrings("CId", wildcards[0].Name.?);
    try testing.expectEqual(@as(usize, 3), wildcards[1].Values.?.len);
    try testing.expectEqualStrings("Inlet", wildcards[1].Values.?[0].?);
    try testing.expect(wildcards[1].Values.?[2] == null);

    // The template is handed over as written. Nothing substituted `{CId}`,
    // and a caller that wants the eight URIs this expands to writes the loop.
    try testing.expect(std.mem.indexOf(
        u8,
        metrics[0].MetricProperties.?[0].?,
        "{CId}",
    ) != null);

    try bmc.verify();
}
