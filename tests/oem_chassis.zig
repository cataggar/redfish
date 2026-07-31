//! Two vendors, one power supply, and the same question answered in two
//! different places.
//!
//! Ports `nv-redfish`'s `test-chassis-oem-delta-power-supply.rs`,
//! `test-chassis-oem-liteon-power-supply.rs` and
//! `test-chassis-oem-nvidia-baseboard.rs`. Grouped by the anchor resource, as
//! `oem_manager.zig` was, because the comparison is the point: Delta and
//! LiteOn are both power-shelf vendors, both are describing a `PowerSupply`,
//! and both are answering "is this unit outputting power" — a question the
//! standard `PowerSupply` schema does not ask.
//!
//! **They answer it in different places, and that decides everything else.**
//! Delta writes `Oem/deltaenergysystems/Power`, which is the extension point
//! DSP0266 reserves; the resource is still a `PowerSupply`, the standard type
//! still reads it, and the vendor content is a bag lookup away. LiteOn
//! declares `PowerState` as a `Edm.Boolean` property on a type derived from
//! `PowerSupply.v1_6_0.PowerSupply` and writes it at the top level of the
//! resource. The `Oem` property is empty; there is nothing in the bag at all.
//!
//! Three consequences follow, and they are what this file pins.
//!
//! The access path is not shared. `core.oem.parse` reaches Delta's content
//! and cannot reach LiteOn's, because LiteOn's is not in an `Oem`. A LiteOn
//! power supply has to be read as `LiteonPowerSupply` from the start, which is
//! what `NavProperty.downcast` is for and what `--base-package` bought: the
//! vendor type derives from the standard one rather than copying it.
//!
//! The failure mode is not shared either. A caller who does not know about
//! Delta reads a `PowerSupply` and gets everything the schema describes.
//! A caller who does not know about LiteOn reads a `PowerSupply`, gets no
//! error, and silently loses the only property that was worth reading, because
//! `ignore_unknown_fields` drops a top-level member exactly as it drops an
//! annotation.
//!
//! And detection is not shared. Delta's extension names itself — the key *is*
//! the fingerprint, and finding it is the whole test. Nothing on a LiteOn
//! power supply says LiteOn: no key, no `@odata.type` a client could branch
//! on, only `Chassis.Manufacturer` reading `LITE-ON TECHNOLOGY CORP.`. So the
//! LiteOn path needs a vendor fingerprint against a string, and the Delta path
//! needs none.
//!
//! The generalization is not "power supplies need an abstraction". It is that
//! a vendor which uses `Oem` is discoverable and a vendor which does not is
//! not, and no library layer can close that gap.
//!
//! NVIDIA's baseboard extension is here for a third reason: it is the first
//! case where the vendor key is not enough. `Oem.Nvidia` covers every NVIDIA
//! schema, and `@odata.type` is what separates an `NvidiaCBCChassis` from a
//! plain `NvidiaChassis`. 6g₁ found Lenovo announcing a version it was not;
//! here the same annotation is load-bearing and correct. Both are true at
//! once, which is why reading it stays a decision of the caller who knows the
//! vendor rather than a rule in `core.oem`.
//!
//! Three reference tests are not ported.
//! `liteon_power_supply_links_multiple_psus` and
//! `liteon_power_supply_links_empty_collection` are `pagination.zig`'s subject
//! with a vendor type substituted; a collection of two and a collection of
//! none are not facts about LiteOn.
//! `oem_nvidia_baseboard_cbc_missing_oem_returns_not_available` is
//! `oem_service_root.zig`'s absent-`Oem` test on another resource.
//!
//! Two more are folded rather than dropped.
//! `delta_power_supply_oem_multiple_psus` is the first test, which reads two
//! supplies anyway so that `Power: false` has something to be distinguished
//! from, and `liteon_power_supply_links_missing_power_subsystem_returns_none`
//! is one of the three refusals the LiteOn gate makes — the gate has to answer
//! it, though an absent optional navigation property is otherwise
//! `chassis.zig`'s and `power_equipment.zig`'s subject.
//!
//! The walk from the service root down to a power supply is `chassis.zig`'s
//! first test and is not re-pinned; the helper below fetches the chassis and
//! goes on from there.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const delta = @import("redfish_schema_oem_delta");
const liteon = @import("redfish_schema_oem_liteon");
const nvidia = @import("redfish_schema_oem_nvidia_baseboard");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const PowerSubsystem = schema.power_subsystem.PowerSubsystem;
const PowerSupply = schema.power_supply.PowerSupply;
const PowerSupplyCollection = schema.power_supply_collection.PowerSupplyCollection;

const DeltaPowerSupply = delta.delta_energy_systems_power_supply.PowerSupply;
const LiteonPowerSupply = liteon.liteon_power_supply.LiteonPowerSupply;
const LiteonPowerSupplyCollection =
    liteon.liteon_power_supply_collection.LiteonPowerSupplyCollection;
const NvidiaCbcChassis = nvidia.nvidia_chassis.NvidiaCbcChassis;

const chassis_collection_uri = "/redfish/v1/Chassis";

const root_with_chassis =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
;

/// The `Members` array of a collection listing `uris` as bare links.
fn memberLinks(comptime uris: []const []const u8) []const u8 {
    comptime var links: []const u8 = "";
    inline for (uris, 0..) |uri, i| {
        links = links ++ (if (i == 0) "" else ",") ++
            \\{"@odata.id":"
        ++ uri ++ "\"}";
    }
    return links;
}

/// A chassis collection listing `uris` as bare links.
fn chassisCollection(comptime uris: []const []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Chassis",
    \\ "@odata.type":"#ChassisCollection.ChassisCollection",
    \\ "Id":"Chassis","Name":"Chassis Collection",
    \\ "Members":[
    ++ comptime memberLinks(uris) ++ "]}";
}

/// Reads the one chassis in the collection: root, collection, member.
///
/// The member is fetched rather than expanded, so it owns its arena and the
/// collection page it was listed in is gone by the time a test looks at it.
fn onlyChassis(
    bmc: *mock.MockBmc,
    comptime uri: []const u8,
    body: []const u8,
) !core.Resolved(Chassis) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get(chassis_collection_uri, chassisCollection(&.{uri})),
        mock.Expect.get(uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
    errdefer chassis.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    if (!chassis.wasFetched()) return error.BorrowedFromAReleasedPage;
    return chassis;
}

/// The power supply collection under a chassis, two links down.
fn powerSupplies(
    bmc: *mock.MockBmc,
    chassis: *const Chassis,
) !core.Resolved(PowerSupplyCollection) {
    const subsystem = try core.follow(
        PowerSubsystem,
        testing.allocator,
        &bmc.transport,
        chassis.PowerSubsystem orelse return error.NoPowerSubsystem,
    );
    defer subsystem.deinit();

    return core.follow(
        PowerSupplyCollection,
        testing.allocator,
        &bmc.transport,
        subsystem.get().PowerSupplies orelse return error.NoPowerSupplies,
    );
}

// -- Delta: the answer is in the bag, and the bag names the vendor ---------

const delta_chassis_uri = "/redfish/v1/Chassis/1";
const delta_subsystem_uri = delta_chassis_uri ++ "/PowerSubsystem";
const delta_supplies_uri = delta_subsystem_uri ++ "/PowerSupplies";

/// Delta's key, which is neither the manufacturer string nor the namespace.
const delta_key = "deltaenergysystems";

const delta_chassis =
    \\{"@odata.id":"/redfish/v1/Chassis/1",
    \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
    \\ "Id":"1","Name":"chassis","ChassisType":"RackMount","Manufacturer":"DELTA",
    \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem"}}
;

const delta_subsystem =
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem",
    \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
    \\ "Id":"PowerSubsystem","Name":"Power Subsystem",
    \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies"}}
;

fn deltaSupplies(comptime uris: []const []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies",
    \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
    \\ "Id":"PowerSupplies","Name":"Power Supply Collection",
    \\ "Members":[
    ++ comptime memberLinks(uris) ++ "]}";
}

/// A Delta power supply. `oem` is the whole `"Oem"` member, or empty.
fn deltaSupply(comptime unit: []const u8, comptime oem: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/
    ++ unit ++
        \\","@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
        \\ "Id":"PowerSupplyUnit
    ++ " " ++ unit ++ "\",\"Name\":\"PowerSupplyUnit " ++ unit ++ "\"," ++
        \\ "Manufacturer":"Delta","Model":"ECD17020036",
        \\ "Status":{"Health":"OK","State":"Enabled"}
    ++ oem ++ "}";
}

test "Delta answers a question the power supply schema does not ask" {
    // `delta_power_supply_oem_reports_power_state` and
    // `delta_power_supply_oem_reports_power_off`, and
    // `delta_power_supply_oem_multiple_psus` with them: two supplies read from
    // one collection is what the third test is, and the second test needs a
    // neighbour anyway for `false` to be distinguishable from silence.
    //
    // A Delta shelf leaves the standard properties alone and reports whether a
    // unit is outputting power under its own key. Nothing about the resource
    // changes: it is a `PowerSupply.v1_5_0.PowerSupply`, `Manufacturer` and
    // `Model` read as they always did, and a client that has never heard of
    // Delta loses only what Delta added.
    //
    // `Power: false` and `FanSpeedTarget: 0` are both meaningful values, and a
    // reader that treated either as an absence would report a live shelf as
    // one that had stopped answering.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc, delta_chassis_uri, delta_chassis);
    defer chassis.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get(delta_subsystem_uri, delta_subsystem),
        mock.Expect.get(delta_supplies_uri, deltaSupplies(&.{
            delta_supplies_uri ++ "/3",
            delta_supplies_uri ++ "/4",
        })),
        mock.Expect.get(delta_supplies_uri ++ "/3", deltaSupply("3",
            \\,"Oem":{"deltaenergysystems":{
            \\   "@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/3#/Oem/deltaenergysystems",
            \\   "@odata.type":"#DeltaEnergySystemsPowerSupply.v1_0_0.PowerSupply",
            \\   "Power":true,"FanSpeedTarget":0}}
        )),
        mock.Expect.get(delta_supplies_uri ++ "/4", deltaSupply("4",
            \\,"Oem":{"deltaenergysystems":{
            \\   "@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/4#/Oem/deltaenergysystems",
            \\   "@odata.type":"#DeltaEnergySystemsPowerSupply.v1_0_0.PowerSupply",
            \\   "Power":false,"FanSpeedTarget":30}}
        )),
    });

    const supplies = try powerSupplies(&bmc, chassis.get());
    defer supplies.deinit();

    const members = supplies.get().Members.?;
    try testing.expectEqual(@as(usize, 2), members.len);

    const first = try core.follow(PowerSupply, testing.allocator, &bmc.transport, members[0]);
    defer first.deinit();
    const second = try core.follow(PowerSupply, testing.allocator, &bmc.transport, members[1]);
    defer second.deinit();

    try testing.expectEqualStrings("ECD17020036", first.get().Model.?);

    const running = (try core.oem.parse(
        DeltaPowerSupply,
        testing.allocator,
        first.get().Oem,
        delta_key,
    )).?;
    defer running.deinit();
    try testing.expectEqual(true, running.value.Power.?);
    try testing.expectEqual(@as(i64, 0), running.value.FanSpeedTarget.?);

    const stopped = (try core.oem.parse(
        DeltaPowerSupply,
        testing.allocator,
        second.get().Oem,
        delta_key,
    )).?;
    defer stopped.deinit();
    try testing.expectEqual(false, stopped.value.Power.?);
    try testing.expectEqual(@as(i64, 30), stopped.value.FanSpeedTarget.?);

    // Delta writes an `@odata.id` on its OEM object, and it is a JSON pointer
    // into the resource the object is already part of rather than somewhere to
    // GET. Neither it nor `@odata.type` is declared by the vendor schema, so
    // both are dropped, and no request was spent chasing the fragment.
    try testing.expect(!@hasField(DeltaPowerSupply, "@odata.id"));
    try testing.expectEqual(@as(usize, 7), bmc.requestCount());

    try bmc.verify();
}

test "a Delta supply with an empty bag, and a key that is not the name on the box" {
    // `delta_power_supply_without_oem_returns_none`, with the case that makes
    // the lookup worth having beside it.
    //
    // Delta keys its extension `deltaenergysystems`: not `Delta`, which is the
    // `Manufacturer` on the same resource, not `DELTA`, which is the
    // `Manufacturer` on the chassis above it, and not
    // `DeltaEnergySystemsPowerSupply`, which is the namespace the payload
    // announces. Three plausible guesses, none of them right, which is why
    // `core.oem` derives no key and folds no case. A lookup that matched any
    // of them would eventually decode one vendor's object into another
    // vendor's type and return a value rather than an error.
    //
    // The second supply carries no `Oem` at all, and that is a supply Delta
    // has nothing to say about — not a defect.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc, delta_chassis_uri, delta_chassis);
    defer chassis.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get(delta_subsystem_uri, delta_subsystem),
        mock.Expect.get(delta_supplies_uri, deltaSupplies(&.{
            delta_supplies_uri ++ "/3",
            delta_supplies_uri ++ "/4",
        })),
        mock.Expect.get(delta_supplies_uri ++ "/3", deltaSupply("3",
            \\,"Oem":{"deltaenergysystems":{"Power":true,"FanSpeedTarget":0}}
        )),
        mock.Expect.get(delta_supplies_uri ++ "/4", deltaSupply("4", "")),
    });

    const supplies = try powerSupplies(&bmc, chassis.get());
    defer supplies.deinit();

    const members = supplies.get().Members.?;
    const extended = try core.follow(PowerSupply, testing.allocator, &bmc.transport, members[0]);
    defer extended.deinit();
    const plain = try core.follow(PowerSupply, testing.allocator, &bmc.transport, members[1]);
    defer plain.deinit();

    for ([_][]const u8{ "Delta", "DELTA", "DeltaEnergySystems", "DeltaEnergySystemsPowerSupply" }) |guess| {
        try testing.expectEqual(
            @as(?std.json.Value, null),
            core.oem.value(extended.get().Oem, guess),
        );
    }
    try testing.expect(core.oem.value(extended.get().Oem, delta_key) != null);

    try testing.expectEqual(@as(?core.Owned(DeltaPowerSupply), null), try core.oem.parse(
        DeltaPowerSupply,
        testing.allocator,
        plain.get().Oem,
        delta_key,
    ));
    try testing.expect(plain.get().Oem == null);
    try testing.expectEqualStrings("Delta", plain.get().Manufacturer.?);

    try bmc.verify();
}

// -- LiteOn: the answer is on the resource, and nothing names the vendor ---

const liteon_manufacturer = "LITE-ON TECHNOLOGY CORP.";

const shelf_uri = "/redfish/v1/Chassis/powershelf";
const shelf_subsystem_uri = shelf_uri ++ "/PowerSubsystem";
const shelf_supplies_uri = shelf_subsystem_uri ++ "/PowerSupplies";
const shelf_supply_uri = shelf_supplies_uri ++ "/0";

const liteon_shelf =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf",
    \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
    \\ "Id":"powershelf","Name":"powershelf","ChassisType":"Shelf",
    \\ "Manufacturer":"LITE-ON TECHNOLOGY CORP.",
    \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem"}}
;

const liteon_subsystem =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem",
    \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
    \\ "Id":"PowerSubsystem","Name":"Power Subsystem",
    \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies"}}
;

const liteon_supplies =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies",
    \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
    \\ "Id":"PowerSupplies","Name":"Power Supply Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies/0"}]}
;

const liteon_supply =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies/0",
    \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
    \\ "Id":"0","Name":"Power Supply 0",
    \\ "Manufacturer":"LITE-ON TECHNOLOGY CORP.","Model":"SP-2552-1R",
    \\ "PowerState":true,
    \\ "Status":{"Health":"OK","State":"Enabled"}}
;

/// Where a LiteOn shelf keeps its power supplies, or null if this is not one.
///
/// The reference's `chassis_fetch_links`, in the caller. Every refusal it can
/// make is here: a chassis some other vendor built, a chassis that named no
/// manufacturer, and a chassis with no `PowerSubsystem` to look under. The
/// manufacturer string is the only fingerprint there is, so this is per-vendor
/// policy by necessity and not by preference, and it stays with the code that
/// knows it is talking to LiteOn.
fn liteonPowerSupplies(chassis: *const Chassis) ?core.NavProperty(PowerSubsystem) {
    const manufacturer = chassis.Manufacturer orelse return null;
    if (!std.mem.eql(u8, manufacturer, liteon_manufacturer)) return null;
    return chassis.PowerSubsystem;
}

test "LiteOn put its answer on the resource, where a standard read loses it" {
    // `liteon_power_supply_links_happy_path`, and the reason the file exists.
    //
    // `LiteonPowerSupply_v1.xml` derives from `PowerSupply.v1_6_0.PowerSupply`
    // and adds `PowerState` as an `Edm.Boolean` at the top level of the
    // resource. That is not an OEM extension in the sense DSP0266 means: the
    // `Oem` property is untouched and empty, and the vendor's content is
    // indistinguishable, in the payload, from a standard property this
    // client's schema version has not caught up with.
    //
    // So the standard type reads the resource *successfully* and drops the
    // only thing worth reading. That is the same `ignore_unknown_fields` that
    // makes a newer service safe to talk to, doing the wrong thing for the
    // right reason, and there is no rule a client could apply to tell the two
    // apart. Both reads are below, against the same bytes.
    //
    // `NavProperty.downcast` is how the link is re-typed. The collection's URI
    // is the same either way — Redfish subtypes share it — so this is the
    // reference's `NavProperty::<LiteonPowerSupplyCollection>::new_reference`
    // and costs no extra request.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const chassis = try onlyChassis(&bmc, shelf_uri, liteon_shelf);
    defer chassis.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get(shelf_subsystem_uri, liteon_subsystem),
        mock.Expect.get(shelf_supplies_uri, liteon_supplies),
        mock.Expect.get(shelf_supply_uri, liteon_supply),
        mock.Expect.get(shelf_supply_uri, liteon_supply),
    });

    const subsystem = try core.follow(
        PowerSubsystem,
        testing.allocator,
        &bmc.transport,
        liteonPowerSupplies(chassis.get()) orelse return error.NotALiteonShelf,
    );
    defer subsystem.deinit();

    const supplies = try core.follow(
        LiteonPowerSupplyCollection,
        testing.allocator,
        &bmc.transport,
        subsystem.get().PowerSupplies.?.downcast(LiteonPowerSupplyCollection).?,
    );
    defer supplies.deinit();

    const members = supplies.get().Members.?;
    try testing.expectEqual(@as(usize, 1), members.len);
    try testing.expectEqualStrings(shelf_supply_uri, members[0].odataId().?.value);

    const supply = try core.follow(
        LiteonPowerSupply,
        testing.allocator,
        &bmc.transport,
        members[0],
    );
    defer supply.deinit();

    try testing.expectEqual(true, supply.get().PowerState.?);
    try testing.expectEqualStrings("SP-2552-1R", supply.get().Model.?);

    // The bag DSP0266 reserved for this is empty. There is no key to find, so
    // `core.oem` has nothing to reach and no amount of plumbing would help.
    try testing.expect(supply.get().Oem == null);

    // The same bytes through the standard type: no error, and the answer gone.
    const standard = try core.bmc.get(
        PowerSupply,
        testing.allocator,
        &bmc.transport,
        .init(shelf_supply_uri),
    );
    defer standard.deinit();

    try testing.expectEqualStrings("SP-2552-1R", standard.value.Model.?);
    try testing.expect(!@hasField(PowerSupply, "PowerState"));

    try bmc.verify();
}

test "nothing on a LiteOn power supply says LiteOn" {
    // `liteon_power_supply_links_wrong_manufacturer_returns_none`,
    // `liteon_power_supply_links_missing_manufacturer_returns_none` and
    // `liteon_power_supply_links_missing_power_subsystem_returns_none`, over
    // one heterogeneous collection, which is what a fleet is.
    //
    // Delta's supplies are found by asking for a key. LiteOn's cannot be:
    // the vendor left no key, no `@odata.type` of its own, and no property
    // name a standard schema would not eventually claim. What is left is
    // `Chassis.Manufacturer` matched against a string with a hyphen, a space
    // and a trailing period in it, which is a fingerprint and reads like one.
    //
    // The refusal is free. Three chassis are read and none of them costs a
    // `PowerSubsystem` request, because the gate runs before the walk rather
    // than after it — which is the reason it is a predicate on a chassis
    // already in hand and not a method that fetches.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const other_uri = "/redfish/v1/Chassis/acme";
    const anonymous_uri = "/redfish/v1/Chassis/anonymous";
    const headless_uri = "/redfish/v1/Chassis/headless";

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get(chassis_collection_uri, chassisCollection(&.{
            other_uri,
            anonymous_uri,
            headless_uri,
        })),
        mock.Expect.get(other_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/acme",
            \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
            \\ "Id":"acme","Name":"acme","ChassisType":"Shelf",
            \\ "Manufacturer":"ACME Corp.",
            \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem"}}
        ),
        mock.Expect.get(anonymous_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/anonymous",
            \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
            \\ "Id":"anonymous","Name":"anonymous","ChassisType":"Shelf",
            \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/anonymous/PowerSubsystem"}}
        ),
        mock.Expect.get(headless_uri,
            \\{"@odata.id":"/redfish/v1/Chassis/headless",
            \\ "@odata.type":"#Chassis.v1_23_0.Chassis",
            \\ "Id":"headless","Name":"headless","ChassisType":"Shelf",
            \\ "Manufacturer":"LITE-ON TECHNOLOGY CORP."}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    var seen: usize = 0;
    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
        defer chassis.deinit();
        try testing.expectEqual(
            @as(?core.NavProperty(PowerSubsystem), null),
            liteonPowerSupplies(chassis.get()),
        );
        seen += 1;
    }

    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqual(@as(usize, 5), bmc.requestCount());
    try bmc.verify();
}

// -- NVIDIA: one key, several schemas, and the annotation that chooses -----

const cbc_uri = "/redfish/v1/Chassis/CBC_0";

/// Whether `Oem.Nvidia` is the cable-cartridge-backplane extension.
///
/// The reference's check, in the caller. `Nvidia` is one key over every
/// schema NVIDIA publishes, so the key is a vendor and not a type, and the
/// type is in `@odata.type`. It has to be read off the raw value before the
/// decode, because `NvidiaCbcChassis` does not declare `@odata.type` and would
/// therefore accept any object whose members happen to fit.
///
/// Only the leading namespace segment is compared, so a service on a later
/// `NvidiaChassis` version still matches — the version is the part of an
/// annotation a client has no business insisting on.
fn isCbcChassis(oem: anytype) bool {
    const found = core.oem.value(oem, "Nvidia") orelse return false;
    const announced = core.ODataType.parseFrom(found) orelse return false;
    if (!std.mem.eql(u8, announced.type_name, "NvidiaCBCChassis")) return false;
    var segments = announced.namespaceSegments();
    return std.mem.eql(u8, segments.first(), "NvidiaChassis");
}

fn cbcChassis(comptime type_name: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Chassis/CBC_0",
    \\ "@odata.type":"#Chassis.v1_22_0.Chassis",
    \\ "Id":"CBC_0","Name":"CBC_0","ChassisType":"Component",
    \\ "Status":{"Health":"OK","State":"Enabled"},
    \\ "Oem":{"Nvidia":{"@odata.type":"#NvidiaChassis.v1_4_0.
    ++ type_name ++
        \\","ChassisPhysicalSlotNumber":24,"ComputeTrayIndex":14,
        \\ "RevisionId":2,"TopologyId":128}}}
    ;
}

test "NVIDIA's vendor key is a vendor, and the type is in the annotation" {
    // `oem_nvidia_baseboard_cbc_real_payload` and
    // `oem_nvidia_baseboard_cbc_wrong_odata_type_returns_not_available`.
    //
    // Every vendor so far has been found by its key. NVIDIA writes `Nvidia`
    // for a chassis extension, a computer-system extension and everything
    // else, so finding the key answers only "this is NVIDIA hardware" and the
    // caller still has to ask what kind. `@odata.type` is the only thing in
    // the payload that says.
    //
    // The second half is what makes the check necessary rather than tidy. The
    // two payloads differ in one word of one annotation and are otherwise
    // identical, so `core.oem.parse` decodes both into a `NvidiaCbcChassis`
    // with four correct-looking integers. A caller that skipped the
    // discriminator would read a compute tray's slot number off a chassis that
    // is not a compute tray.
    //
    // 6g₁ found Lenovo announcing `#LenovoManager.v1_0_0` on a payload that
    // was the v0_1_0 shape, and concluded that `@odata.type` cannot pick a
    // struct. Both findings hold: the annotation is authoritative about which
    // *type* a vendor means and unreliable about which *version* of it. Which
    // half to lean on is knowledge about a vendor, so it lives here.
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const chassis = try onlyChassis(&bmc, cbc_uri, cbcChassis("NvidiaCBCChassis"));
        defer chassis.deinit();

        try testing.expect(isCbcChassis(chassis.get().Oem));

        const cbc = (try core.oem.parse(
            NvidiaCbcChassis,
            testing.allocator,
            chassis.get().Oem,
            "Nvidia",
        )).?;
        defer cbc.deinit();

        try testing.expectEqual(@as(i64, 24), cbc.value.ChassisPhysicalSlotNumber.?);
        try testing.expectEqual(@as(i64, 14), cbc.value.ComputeTrayIndex.?);
        try testing.expectEqual(@as(i64, 2), cbc.value.RevisionId.?);
        try testing.expectEqual(@as(i64, 128), cbc.value.TopologyId.?);

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const chassis = try onlyChassis(&bmc, cbc_uri, cbcChassis("NvidiaChassis"));
        defer chassis.deinit();

        try testing.expect(!isCbcChassis(chassis.get().Oem));

        // The type itself cannot tell, which is the point of the gate.
        const decoded = (try core.oem.parse(
            NvidiaCbcChassis,
            testing.allocator,
            chassis.get().Oem,
            "Nvidia",
        )).?;
        defer decoded.deinit();
        try testing.expectEqual(@as(i64, 24), decoded.value.ChassisPhysicalSlotNumber.?);

        try bmc.verify();
    }
}
