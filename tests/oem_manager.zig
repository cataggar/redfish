//! Five vendors extending one resource, and what each of them does with the
//! same three bytes of schema.
//!
//! Ports `nv-redfish`'s `test-manager-oem-ami.rs`,
//! `test-manager-oem-dell-attributes.rs`, `test-manager-oem-hpe.rs`,
//! `test-manager-oem-lenovo.rs` and `test-manager-oem-supermicro.rs`. Grouped
//! by the resource rather than by the vendor, because a vendor's field is
//! rarely interesting on its own and the comparison is: `Oem` is one open
//! property, and five vendors have put five different *kinds* of thing behind
//! it.
//!
//! HPE puts a property there and nothing else. Lenovo puts a property and a
//! navigation property to a resource of its own. Supermicro puts two
//! navigation properties and no properties at all. AMI puts a marker object
//! beside a bare string that is a URI without being a link. Dell puts an empty
//! marker and keeps everything it has to say at a URI that appears in no
//! payload anywhere. Two of the five are the shape a reader of DSP0266 would
//! expect.
//!
//! The path from `resource.Oem` to a vendor's generated struct is
//! `core.oem.parse`, which is new here and argued in `core/oem.zig` and in
//! `oem_service_root.zig`.
//!
//! Six reference tests are not ported. Five of them are one assertion:
//! `manager_without_hpe_oem_returns_none`,
//! `manager_without_lenovo_oem_returns_not_available`,
//! `manager_without_supermicro_oem_returns_none`,
//! `manager_without_ami_oem_returns_none` and
//! `manager_without_dell_oem_returns_not_available` differ only in the key
//! they miss, and the first four differ from the fifth only in whether the
//! service sent an empty `Oem` or none. `oem_service_root.zig` pins the
//! missing `Oem`; the second test below pins the other, and improves on all
//! five by asking for a vendor while a *different* vendor's object sits in the
//! bag, which is the case that distinguishes a lookup from a presence check.
//! `lenovo_oem_without_security_returns_not_available` is an absent optional
//! navigation property on a generated struct, which `manager.zig` already pins
//! for `NetworkProtocol` and which the Supermicro test below pins again for a
//! reason of its own. `malformed_hpe_oem_returns_parse_error` is
//! `service_root_ami_malformed_oem_returns_parse_error` in another file.
//!
//! `onlyManager` is a fourth copy of a walk `manager.zig`, `computer_system.zig`
//! and `chassis.zig` each keep their own of, deliberately: #54 decided against
//! a `tests/support.zig`, on the grounds that a shared helper in a test
//! directory reads like something the project offers callers.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const ami = @import("redfish_schema_oem_ami");
const dell = @import("redfish_schema_oem_dell");
const hpe = @import("redfish_schema_oem_hpe");
const lenovo = @import("redfish_schema_oem_lenovo");
const supermicro = @import("redfish_schema_oem_supermicro");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Manager = schema.manager.Manager;

const ConfigBmc = ami.ami_manager.ConfigBmc;
const DellAttributes = dell.dell_attributes.DellAttributes;
const HpeiLo = hpe.hpei_lo.HpeiLo;
const LenovoV0_1 = lenovo.lenovo_manager_v0_1_0.LenovoManagerProperties;
const LenovoV1_0 = lenovo.lenovo_manager_v1_0_0.LenovoManagerProperties;
const LenovoSecurityService = lenovo.lenovo_security_service.LenovoSecurityService;
const KcsState = lenovo.lenovo_manager.KcsState;
const FwRollbackState = lenovo.lenovo_security_service.FwRollbackState;
const SupermicroManager = supermicro.smc_manager_extensions.Manager;
const KcsInterface = supermicro.kcs_interface.KcsInterface;
const SysLockdown = supermicro.sys_lockdown.SysLockdown;

const managers_uri = "/redfish/v1/Managers";
const manager_uri = "/redfish/v1/Managers/1";

const root_with_managers =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Managers":{"@odata.id":"/redfish/v1/Managers"}}
;

fn managerCollection(comptime member_uri: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Managers",
    \\ "@odata.type":"#ManagerCollection.ManagerCollection",
    \\ "Id":"Managers","Name":"Manager Collection",
    \\ "Members":[{"@odata.id":"
    ++ member_uri ++ "\"}]}";
}

/// A manager at `/redfish/v1/Managers/1` whose `Oem` property is `oem`.
fn managerWith(comptime oem: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Managers/1",
    \\ "@odata.type":"#Manager.v1_16_0.Manager",
    \\ "Id":"1","Name":"Manager","ManagerType":"BMC",
    \\ "Status":{"State":"Enabled"},
    \\ "Oem":
    ++ oem ++ "}";
}

/// Reads the one manager the way a program does: root, collection, member.
///
/// The member is fetched rather than expanded, so the returned value owns its
/// arena and the collection page it was listed in is already gone.
fn onlyManager(
    bmc: *mock.MockBmc,
    comptime member_uri: []const u8,
    body: []const u8,
) !core.Resolved(Manager) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_managers),
        mock.Expect.get(managers_uri, managerCollection(member_uri)),
        mock.Expect.get(member_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Managers");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const manager = try core.follow(Manager, testing.allocator, &bmc.transport, link);
    errdefer manager.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    if (!manager.wasFetched()) return error.BorrowedFromAReleasedPage;
    return manager;
}

// -- A property, and the property beside it that no vendor schema names ----

test "an HPE manager's virtual NIC, read past a type annotation no schema declares" {
    // `hpe_virtual_nic_enabled_supported`. `VirtualNICEnabled` is the whole
    // of `HpeiLO` as far as this package is concerned, and it is not the
    // interesting half of the payload. The interesting half is
    // `@odata.type`, which HPE writes on its OEM object as every vendor does
    // and which appears in no `HpeiLO` schema, because the annotation is a
    // Redfish protocol member rather than a property of the type.
    //
    // Every read this stack makes goes through `owned.parse_options`, which
    // ignores unknown fields; `std.json`'s default is to reject them. So a
    // caller writing the obvious `std.json.parseFromValue(HpeiLo, gpa, value,
    // .{})` gets an `error.UnknownField` here, on a payload the same type
    // decodes without complaint when it arrives at its own URI. That is the
    // reason `core.oem.parse` exists rather than the pair of lines it saves.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Hpe":{"@odata.type":"#HpeiLO.v2_11_0.HpeiLO","VirtualNICEnabled":true}}
    ));
    defer manager.deinit();

    const found = try core.oem.parse(HpeiLo, testing.allocator, manager.get().Oem, "Hpe");
    const ilo = found orelse return error.NoHpeExtension;
    defer ilo.deinit();

    try testing.expectEqual(true, ilo.value.VirtualNICEnabled.?);

    try testing.expectError(error.UnknownField, std.json.parseFromValue(
        HpeiLo,
        testing.allocator,
        core.oem.value(manager.get().Oem, "Hpe").?,
        .{},
    ));

    try bmc.verify();
}

test "an Oem property that names a vendor, and not the one being asked for" {
    // `manager_without_hpe_oem_returns_none` and its three siblings across
    // the AMI, Lenovo and Supermicro files, which all send `"Oem": {}`. The
    // bag here holds a vendor instead, because that is the case a presence
    // check would get wrong: a manager can carry two vendors' extensions at
    // once -- an ODM's and the silicon vendor's -- and "this resource has an
    // `Oem`" is not the question a caller is asking.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Lenovo":{"@odata.type":"#LenovoManager.v1_0_0.LenovoManagerProperties",
        \\           "KCSEnabled":"Enabled"}}
    ));
    defer manager.deinit();

    try testing.expect(manager.get().Oem != null);
    try testing.expectEqual(
        @as(?core.Owned(HpeiLo), null),
        try core.oem.parse(HpeiLo, testing.allocator, manager.get().Oem, "Hpe"),
    );

    try bmc.verify();
}

// -- A URI that is not a link ---------------------------------------------

const config_bmc_uri = manager_uri ++ "/Oem/ConfigBMC";

test "AMI hangs its BMC configuration off a bare string beside the vendor object" {
    // `manager_oem_ami_config_bmc_supported`. Two departures from the shape
    // DSP0266 describes, in one small payload.
    //
    // The first is that `ConfigBMC` is a sibling of `Ami` rather than a member
    // of it, so the vendor's own object is a marker and the thing worth
    // reading is in the bag next to it. The second is that its value is a JSON
    // string and not `{"@odata.id": ...}`, so it is not a navigation property,
    // `NavProperty` will not parse it, and nothing generated from any schema
    // will ever point at `AmiManager.ConfigBMC`. A caller reads the string and
    // does the GET itself.
    //
    // This is a departure in the *data* and so belongs to the code that reads
    // the field, exactly as `redfish/quirks.zig` says: there is no general
    // action a client could take on its own, because knowing that this string
    // is a URI requires knowing it is AMI's.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Ami":{"@odata.type":"#AMIManager.v1_0_0.AMIManager"},
        \\ "ConfigBMC":"/redfish/v1/Managers/1/Oem/ConfigBMC"}
    ));
    defer manager.deinit();

    const marker = core.oem.value(manager.get().Oem, "Ami") orelse return error.NotAnAmiManager;
    try testing.expectEqual(@as(usize, 1), marker.object.count());

    const link = core.oem.value(manager.get().Oem, "ConfigBMC") orelse return error.NoConfigBmc;
    try testing.expectEqualStrings(config_bmc_uri, link.string);

    try bmc.expect(mock.Expect.get(config_bmc_uri,
        \\{"@odata.id":"/redfish/v1/Managers/1/Oem/ConfigBMC",
        \\ "LockoutHostControl":"Disable",
        \\ "LockoutBiosVariableWriteMode":"Disable",
        \\ "LockdownBiosSettingsChange":"Disable",
        \\ "LockdownBiosUpgradeDowngrade":"Disable"}
    ));

    const config = try core.bmc.get(
        ConfigBmc,
        testing.allocator,
        &bmc.transport,
        .init(link.string),
    );
    defer config.deinit();

    try testing.expectEqual(.Disable, config.value.LockoutHostControl.?);
    try testing.expectEqual(.Disable, config.value.LockoutBiosVariableWriteMode.?);
    try testing.expectEqual(.Disable, config.value.LockdownBiosSettingsChange.?);
    try testing.expectEqual(.Disable, config.value.LockdownBiosUpgradeDowngrade.?);

    try bmc.verify();
}

test "an AMI manager that says who made it and nothing about where its configuration is" {
    // `manager_ami_without_config_bmc_link_returns_none`. The vendor is
    // present and the second key is not, and the two are independent members
    // of one bag, so there is no struct whose optional field could carry the
    // absence. It is a lookup that finds nothing, and the caller stops.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Ami":{"@odata.type":"#AMIManager.v1_0_0.AMIManager"}}
    ));
    defer manager.deinit();

    try testing.expect(core.oem.value(manager.get().Oem, "Ami") != null);
    try testing.expectEqual(
        @as(?std.json.Value, null),
        core.oem.value(manager.get().Oem, "ConfigBMC"),
    );

    // Three requests: root, collection, manager. Nothing was spent on a URI
    // the service did not name.
    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

// -- One property, two schema versions, one @odata.type --------------------

/// Lenovo's KCS setting, from whichever of the two schema versions fits.
///
/// This is the reference's `#[serde(untagged)] enum LenovoManagerSchema`, in
/// the caller. `LenovoManager.v0_1_0` declares `KCSEnabled` as `Edm.Boolean`
/// and `v1_0_0` redeclares it as an enumeration, so the same property name
/// carries two JSON types and the generator wrote a struct for each. Trying
/// one and then the other is the whole of it; mapping `true` onto `Enabled`
/// is a reading of what Lenovo meant, which no schema states and which
/// therefore stays here.
fn kcsState(oem: anytype) !?KcsState {
    if (core.oem.parse(LenovoV1_0, testing.allocator, oem, "Lenovo") catch null) |named| {
        defer named.deinit();
        if (named.value.KCSEnabled) |state| return state;
    }
    const legacy = (try core.oem.parse(LenovoV0_1, testing.allocator, oem, "Lenovo")) orelse
        return null;
    defer legacy.deinit();
    const enabled = legacy.value.KCSEnabled orelse return null;
    return if (enabled) .Enabled else .Disabled;
}

test "Lenovo changed the type of one property and kept writing the later version's name" {
    // `lenovo_kcs_enabled_string_disabled_maps_state` and
    // `lenovo_kcs_enabled_boolean_true_maps_state`. Both payloads announce
    // themselves as `#LenovoManager.v1_0_0.LenovoManagerProperties` and only
    // one of them is: in the other, `KCSEnabled` is `true`, which is the
    // v0_1_0 shape. So the annotation cannot be used to choose the type, and
    // a client that trusted it would fail on half of Lenovo's fleet.
    //
    // Nothing here is a workaround. Two versions of a vendor schema really do
    // declare the property differently, the emitter wrote both, and picking
    // between them is a two-line try in the caller.
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const manager = try onlyManager(&bmc, manager_uri, managerWith(
            \\{"Lenovo":{"@odata.type":"#LenovoManager.v1_0_0.LenovoManagerProperties",
            \\           "KCSEnabled":"Disabled"}}
        ));
        defer manager.deinit();

        try testing.expectEqual(KcsState.Disabled, (try kcsState(manager.get().Oem)).?);

        // The string does not fit the earlier version, which is what makes
        // the order of the attempts irrelevant.
        try testing.expectError(error.UnexpectedToken, core.oem.parse(
            LenovoV0_1,
            testing.allocator,
            manager.get().Oem,
            "Lenovo",
        ));

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const manager = try onlyManager(&bmc, manager_uri, managerWith(
            \\{"Lenovo":{"@odata.type":"#LenovoManager.v1_0_0.LenovoManagerProperties",
            \\           "KCSEnabled":true}}
        ));
        defer manager.deinit();

        try testing.expectEqual(KcsState.Enabled, (try kcsState(manager.get().Oem)).?);

        try testing.expectError(error.UnexpectedToken, core.oem.parse(
            LenovoV1_0,
            testing.allocator,
            manager.get().Oem,
            "Lenovo",
        ));

        try bmc.verify();
    }
}

// -- A vendor resource behind a vendor navigation property -----------------

const security_uri = manager_uri ++ "/Oem/Lenovo/Security";

test "a vendor's own resource, fetched after the manager that named it is gone" {
    // `lenovo_security_fw_rollback_disabled`. `LenovoSecurityService` is a
    // whole resource with an `Id`, a `Name` and an `Oem` of its own, reached
    // through a navigation property inside the OEM object -- the ordinary
    // Redfish shape, one level further in than usual.
    //
    // The manager is released before the link is followed, which is the point.
    // A `std.json.Value` in an `Oem` bag belongs to the arena of the response
    // it arrived in, so a caller who decoded out of it and kept the result
    // would be holding freed strings the moment the resource went away.
    // `core.oem.parse` copies into an arena of its own for exactly this, and a
    // URI that survives its manager is the smallest thing that proves it.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Lenovo":{"@odata.type":"#LenovoManager.v1_0_0.LenovoManagerProperties",
        \\           "KCSEnabled":"Disabled",
        \\           "Security":{"@odata.id":"/redfish/v1/Managers/1/Oem/Lenovo/Security"}}}
    ));

    const found = try core.oem.parse(LenovoV1_0, testing.allocator, manager.get().Oem, "Lenovo");
    const properties = found orelse return error.NotALenovoManager;
    defer properties.deinit();

    manager.deinit();

    try bmc.expect(mock.Expect.get(security_uri,
        \\{"@odata.id":"/redfish/v1/Managers/1/Oem/Lenovo/Security",
        \\ "@odata.type":"#LenovoSecurityService.v1_0_0.LenovoSecurityService",
        \\ "Id":"Security","Name":"Security",
        \\ "Status":{"State":"Enabled"},
        \\ "Configurator":{"FWRollback":"Disabled"}}
    ));

    const security = try core.follow(
        LenovoSecurityService,
        testing.allocator,
        &bmc.transport,
        properties.value.Security.?,
    );
    defer security.deinit();

    try testing.expectEqualStrings("Security", security.get().Id.?);
    try testing.expectEqual(FwRollbackState.Disabled, security.get().Configurator.?.FWRollback.?);

    try bmc.verify();
}

// -- Two links, one of which the service did not send ----------------------

const kcs_interface_uri = manager_uri ++ "/Oem/Supermicro/KCSInterface";
const sys_lockdown_uri = manager_uri ++ "/Oem/Supermicro/SysLockdown";

test "two Supermicro resources, and a manager that offers only one of them" {
    // `supermicro_kcs_and_sys_lockdown_supported` and
    // `supermicro_manager_without_kcs_still_supports_sys_lockdown`, together.
    // Supermicro's OEM object has no properties at all: it is two navigation
    // properties, so the extension is entirely a pair of doors, and the second
    // test exists because a firmware that has closed one of them must not
    // close the other.
    //
    // This is where the difference between an absent key and an absent field
    // shows. AMI's missing `ConfigBMC` is a lookup that finds nothing, because
    // the bag has no schema; `KCSInterface` is a declared optional field on a
    // generated struct, and reads as `null` for free.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, manager_uri, managerWith(
        \\{"Supermicro":{"@odata.type":"#SmcManagerExtensions.v1_0_0.Manager",
        \\               "KCSInterface":{"@odata.id":"/redfish/v1/Managers/1/Oem/Supermicro/KCSInterface"},
        \\               "SysLockdown":{"@odata.id":"/redfish/v1/Managers/1/Oem/Supermicro/SysLockdown"}}}
    ));
    defer manager.deinit();

    const found = try core.oem.parse(
        SupermicroManager,
        testing.allocator,
        manager.get().Oem,
        "Supermicro",
    );
    const extensions = found orelse return error.NotASupermicroManager;
    defer extensions.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get(kcs_interface_uri,
            \\{"@odata.id":"/redfish/v1/Managers/1/Oem/Supermicro/KCSInterface",
            \\ "@odata.type":"#KCSInterface.v1_1_0.KCSInterface",
            \\ "Id":"KCSInterface","Name":"KCS Interface",
            \\ "Privilege":"Administrator",
            \\ "@odata.etag":"\"7f21b53f195494a7c2dad2008917b1d7\""}
        ),
        mock.Expect.get(sys_lockdown_uri,
            \\{"@odata.id":"/redfish/v1/Managers/1/Oem/Supermicro/SysLockdown",
            \\ "@odata.type":"#SysLockdown.v1_0_0.SysLockdown",
            \\ "Id":"SysLockdown","Name":"SysLockdown",
            \\ "SysLockdownEnabled":false,
            \\ "@odata.etag":"\"30b691549156f2528aac46ed839cf7f6\""}
        ),
    });

    const kcs = try core.follow(
        KcsInterface,
        testing.allocator,
        &bmc.transport,
        extensions.value.KCSInterface.?,
    );
    defer kcs.deinit();
    try testing.expectEqual(.Administrator, kcs.get().Privilege.?);

    const lockdown = try core.follow(
        SysLockdown,
        testing.allocator,
        &bmc.transport,
        extensions.value.SysLockdown.?,
    );
    defer lockdown.deinit();
    try testing.expectEqual(false, lockdown.get().SysLockdownEnabled.?);

    try bmc.verify();

    // The same extension with the KCS door missing. `SysLockdown` is
    // unaffected, and the KCS absence costs no request.
    var reduced: mock.MockBmc = .init(testing.allocator);
    defer reduced.deinit();

    const without_kcs = try onlyManager(&reduced, manager_uri, managerWith(
        \\{"Supermicro":{"@odata.type":"#SmcManagerExtensions.v1_0_0.Manager",
        \\               "SysLockdown":{"@odata.id":"/redfish/v1/Managers/1/Oem/Supermicro/SysLockdown"}}}
    ));
    defer without_kcs.deinit();

    const partial = (try core.oem.parse(
        SupermicroManager,
        testing.allocator,
        without_kcs.get().Oem,
        "Supermicro",
    )).?;
    defer partial.deinit();

    try testing.expect(partial.value.KCSInterface == null);
    try testing.expect(partial.value.SysLockdown != null);
    try testing.expectEqual(@as(usize, 3), reduced.requestCount());
    try reduced.verify();
}

// -- A resource nothing links to ------------------------------------------

const idrac_uri = "/redfish/v1/Managers/iDRAC.Embedded.1";
const dell_attributes_uri = idrac_uri ++ "/Oem/Dell/DellAttributes/iDRAC.Embedded.1";

test "Dell's attributes are at a URI no payload contains, behind a marker that is empty" {
    // `manager_dell_attributes_lean_payload`. Dell's is the odd one of the
    // five and it is odd in the reach rather than in the content: the
    // manager's `Oem` carries `"Dell": {}` and nothing else, so the extension
    // announces that the hardware is Dell's and says nothing about where its
    // several hundred settings are. The URI is a convention --
    // `<manager>/Oem/Dell/DellAttributes/<id>` -- built by the caller out of
    // two fields of the manager, and a client that has not been told the rule
    // cannot discover it.
    //
    // What comes back is `DellAttributes.Attributes`, an open complex type
    // with no declared members: names like `CurrentNIC.1.MTU` are
    // instance-numbered and vendor-defined, and the values are integers,
    // strings, booleans and explicit nulls in one object. It is annotated
    // `Redfish.DynamicPropertyPatterns` with `Edm.PrimitiveType`, which is
    // exactly what `Bios.Attributes` carries, so it is the same generated
    // shape and `bios.zig` owns how one reads -- including the difference
    // between a member sent as `null` and a member not sent, and the
    // `core.PrimitiveType` reading of a value. This checks the four shapes
    // once and spends its argument on the reach.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc, idrac_uri,
        \\{"@odata.id":"/redfish/v1/Managers/iDRAC.Embedded.1",
        \\ "@odata.type":"#Manager.v1_18_0.Manager",
        \\ "Id":"iDRAC.Embedded.1","Name":"iDRAC.Embedded.1",
        \\ "Status":{"Health":"OK","State":"Enabled"},
        \\ "Oem":{"Dell":{}}}
    );
    defer manager.deinit();

    const marker = core.oem.value(manager.get().Oem, "Dell") orelse return error.NotADellManager;
    try testing.expectEqual(@as(usize, 0), marker.object.count());

    const uri = try std.fmt.allocPrint(testing.allocator, "{f}/Oem/Dell/DellAttributes/{s}", .{
        manager.get().@"@odata.id".?,
        manager.get().Id.?,
    });
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings(dell_attributes_uri, uri);

    try bmc.expect(mock.Expect.get(dell_attributes_uri,
        \\{"@odata.id":"/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/iDRAC.Embedded.1",
        \\ "@odata.type":"#DellAttributes.v1_0_0.DellAttributes",
        \\ "Id":"iDRAC.Embedded.1","Name":"OEMAttributeRegistry",
        \\ "Description":"This schema provides the oem attributes",
        \\ "AttributeRegistry":"ManagerAttributeRegistry.v1_0_0",
        \\ "Attributes":{"CurrentNIC.1.MTU":1500,
        \\               "CurrentNIC.1.ProxyEnabled":true,
        \\               "CurrentNIC.1.Hostname":"idrac-embedded",
        \\               "CurrentNIC.1.OptionalNull":null}}
    ));

    const attributes = try core.bmc.get(
        DellAttributes,
        testing.allocator,
        &bmc.transport,
        .init(uri),
    );
    defer attributes.deinit();

    const bag = attributes.value.Attributes.?.additional_properties.map;
    try testing.expectEqual(@as(i64, 1500), bag.get("CurrentNIC.1.MTU").?.integer);
    try testing.expectEqualStrings("idrac-embedded", bag.get("CurrentNIC.1.Hostname").?.string);
    try testing.expectEqual(true, bag.get("CurrentNIC.1.ProxyEnabled").?.bool);
    try testing.expectEqual(std.json.Value.null, bag.get("CurrentNIC.1.OptionalNull").?);
    try testing.expectEqual(@as(?std.json.Value, null), bag.get("CurrentNIC.1.Unknown"));

    // `AttributeRegistry` is on every iDRAC's payload and on no `DellAttributes`
    // this package generated, because `schema/oem/dell` was written from
    // observed payloads and did not declare it. A read from a BMC ignores
    // unknown fields, so the property is dropped rather than fatal -- which is
    // the right trade and is still a loss, and is the price of a vendor schema
    // nobody publishes.
    try testing.expect(!@hasField(DellAttributes, "AttributeRegistry"));

    try bmc.verify();
}
