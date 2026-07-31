//! A vendor extension that is a value, and a vendor extension that is a door.
//!
//! Ports `nv-redfish`'s `test-computer-system-oem-lenovo.rs` and
//! `test-computer-system-oem-nvidia-bluefield.rs`. The two are opposite ends
//! of what an `Oem` member can be. Lenovo's is content: a complex type in the
//! bag, decoded and read where it stands. NVIDIA's is a navigation property,
//! so the bag holds a URI and everything worth reading is a request away.
//!
//! Lenovo answers the question 6g₁ left open. `LenovoManager` declares
//! `KCSEnabled` as `Edm.Boolean` in `v0_1_0` and as an enumeration in
//! `v1_0_0`, both payloads announce `v1_0_0`, and the caller has to try two
//! structs because the annotation cannot pick one. Nothing like that happens
//! here. `FrontPanelUSB` and `USBManagementPortAssignment` are declared beside
//! each other in one version of one complex type, with the same type, so there
//! is one struct and both fields are on it. What Lenovo changed was the name,
//! not the shape, and the old name was kept rather than replaced — so a
//! service may send either, or both, and the schema is silent about which wins
//! when it sends both. That silence is the whole of the vendor logic and it
//! stays in the caller.
//!
//! NVIDIA's is where two of this stack's existing decisions pay for
//! themselves. `NavProperty` decides link-or-expansion by asking whether the
//! object carries anything the *target type* declares — the fix 6b made for
//! AMI Viking — and a Bluefield-3 that decorates its OEM link with a
//! navigation property of its own therefore reads as a link, which is what the
//! reference achieves by calling `to_reference()` on every one. And a fetched
//! payload with no `@odata.id` needs no patching here, because `Redfish.Required`
//! is not enforced and the property is optional on the generated type. Both of
//! the reference's Bluefield workarounds are absences.
//!
//! Two reference tests are not ported. `system_without_lenovo_oem_returns_not_available`
//! and `system_without_nvidia_oem_returns_none` are the absent-`Oem` test that
//! `oem_service_root.zig` pins and `oem_manager.zig` improves on by asking for
//! one vendor while another sits in the bag.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const lenovo = @import("redfish_schema_oem_lenovo");
const nvidia = @import("redfish_schema_oem_nvidia_bluefield");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const ComputerSystem = schema.computer_system.ComputerSystem;

const LenovoSystemProperties = lenovo.lenovo_computer_system.LenovoSystemProperties;
const UsbManagementPortAssignment =
    lenovo.lenovo_computer_system.UsbManagementPortAssignment;
const FpMode = lenovo.lenovo_computer_system.FpMode;
const PortSwitchingTo = lenovo.lenovo_computer_system.PortSwitchingTo;
const NvidiaComputerSystem = nvidia.nvidia_computer_system.NvidiaComputerSystem;
const Mode = nvidia.nvidia_computer_system.Mode;

const systems_uri = "/redfish/v1/Systems";
const system_uri = "/redfish/v1/Systems/Bluefield";
const nvidia_oem_uri = system_uri ++ "/Oem/Nvidia";

const root_with_systems =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"}}
;

const system_collection =
    \\{"@odata.id":"/redfish/v1/Systems",
    \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
    \\ "Id":"Systems","Name":"Computer System Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Systems/Bluefield"}]}
;

/// A system at `/redfish/v1/Systems/Bluefield` whose `Oem` property is `oem`.
fn systemWith(comptime oem: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/Systems/Bluefield",
    \\ "@odata.type":"#ComputerSystem.v1_19_0.ComputerSystem",
    \\ "Id":"Bluefield","Name":"Bluefield",
    \\ "Status":{"Health":"OK","State":"Enabled"},
    \\ "Oem":
    ++ oem ++ "}";
}

/// Reads the one system the way a program does: root, collection, member.
///
/// The member is fetched, so it owns its arena and the collection page is gone
/// before a test looks at it.
fn onlySystem(bmc: *mock.MockBmc, body: []const u8) !core.Resolved(ComputerSystem) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri, system_collection),
        mock.Expect.get(system_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    errdefer system.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    if (!system.wasFetched()) return error.BorrowedFromAReleasedPage;
    return system;
}

// -- Lenovo: one setting under two names -----------------------------------

/// Which of Lenovo's two spellings of the USB port assignment to believe.
///
/// The reference's `front_panel_mode` and `port_switching_to`, in the caller
/// and as one function, since both of theirs run the same `or_else` chain and
/// the interesting part is the chain rather than the field.
///
/// `USBManagementPortAssignment` is preferred because it is the later name and
/// a firmware that writes it has been updated; a firmware that writes only
/// `FrontPanelUSB` has not. Nothing in `LenovoComputerSystem_v1.xml` says so —
/// both properties are optional, same type, same version — so this is a
/// reading of Lenovo's intent and belongs nowhere a caller cannot change it.
fn usbPortAssignment(properties: LenovoSystemProperties) ?UsbManagementPortAssignment {
    return properties.USBManagementPortAssignment orelse properties.FrontPanelUSB;
}

/// Reads `Oem.Lenovo` off a system and applies the preference above.
fn lenovoUsbPortAssignment(oem: anytype) !?UsbManagementPortAssignment {
    const found = (try core.oem.parse(
        LenovoSystemProperties,
        testing.allocator,
        oem,
        "Lenovo",
    )) orelse return null;
    defer found.deinit();

    // `UsbManagementPortAssignment` is two enums and nothing that points into
    // the arena, so returning it by value outlives the `Owned` it came from.
    // A vendor type holding a string would not, which is why `core.oem.parse`
    // hands back an arena rather than a value.
    return usbPortAssignment(found.value);
}

test "Lenovo gave one setting two names and went on writing both" {
    // `lenovo_computer_system_usb_management_fields`,
    // `lenovo_computer_system_front_panel_usb_variant` and
    // `lenovo_computer_system_prefers_usb_management_port_assignment`.
    //
    // Three firmware generations in three payloads: one that writes only the
    // later name, one that writes only the earlier, and one that writes both
    // and disagrees with itself. The third is the only one that needs a
    // decision, and the decision is a vendor's, so it is four words in the
    // caller and nothing at all in the library.
    //
    // Unlike `LenovoManager.KCSEnabled` in `oem_manager.zig`, no version is
    // involved. Both properties live in `LenovoComputerSystem.v1_0_0` with the
    // same type, so there is one struct rather than two and `@odata.type` was
    // never going to help. Two vendor traps that look alike from the payload
    // and are not the same trap.
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Lenovo":{"@odata.type":"#LenovoComputerSystem.v1_0_0.LenovoSystemProperties",
            \\           "USBManagementPortAssignment":{"FPMode":"Server","PortSwitchingTo":"Server"}}}
        ));
        defer system.deinit();

        const assignment = (try lenovoUsbPortAssignment(system.get().Oem)).?;
        try testing.expectEqual(FpMode.Server, assignment.FPMode.?);
        try testing.expectEqual(PortSwitchingTo.Server, assignment.PortSwitchingTo.?);

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Lenovo":{"@odata.type":"#LenovoComputerSystem.v1_0_0.LenovoSystemProperties",
            \\           "FrontPanelUSB":{"FPMode":"BMC","PortSwitchingTo":"BMC"}}}
        ));
        defer system.deinit();

        const assignment = (try lenovoUsbPortAssignment(system.get().Oem)).?;
        try testing.expectEqual(FpMode.BMC, assignment.FPMode.?);
        try testing.expectEqual(PortSwitchingTo.BMC, assignment.PortSwitchingTo.?);

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Lenovo":{"@odata.type":"#LenovoComputerSystem.v1_0_0.LenovoSystemProperties",
            \\           "FrontPanelUSB":{"FPMode":"BMC","PortSwitchingTo":"BMC"},
            \\           "USBManagementPortAssignment":{"FPMode":"Server","PortSwitchingTo":"Server"}}}
        ));
        defer system.deinit();

        const properties = (try core.oem.parse(
            LenovoSystemProperties,
            testing.allocator,
            system.get().Oem,
            "Lenovo",
        )).?;
        defer properties.deinit();

        // Both arrived, and both were kept: the generated struct has a field
        // for each, so the loser of the preference is still there to be read
        // by a caller who disagrees with it.
        try testing.expectEqual(FpMode.BMC, properties.value.FrontPanelUSB.?.FPMode.?);
        try testing.expectEqual(FpMode.Server, properties.value.USBManagementPortAssignment.?.FPMode.?);
        try testing.expectEqual(FpMode.Server, usbPortAssignment(properties.value).?.FPMode.?);

        try bmc.verify();
    }
}

test "a Lenovo extension that answers half the question, and one that answers none" {
    // `lenovo_computer_system_partial_variant_fields` and
    // `lenovo_computer_system_both_variants_absent`.
    //
    // The first is a firmware that knows which way the front panel is switched
    // and not what it is switching to; the second is a firmware that carries
    // Lenovo's schema and none of the feature. Neither is an error and the two
    // are different answers, so the absence has to survive as far as the
    // caller rather than being flattened into a default at the parse.
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Lenovo":{"@odata.type":"#LenovoComputerSystem.v1_0_0.LenovoSystemProperties",
            \\           "FrontPanelUSB":{"FPMode":"Shared"}}}
        ));
        defer system.deinit();

        const assignment = (try lenovoUsbPortAssignment(system.get().Oem)).?;
        try testing.expectEqual(FpMode.Shared, assignment.FPMode.?);
        try testing.expectEqual(@as(?PortSwitchingTo, null), assignment.PortSwitchingTo);

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Lenovo":{"@odata.type":"#LenovoComputerSystem.v1_0_0.LenovoSystemProperties"}}
        ));
        defer system.deinit();

        // The vendor is present and says nothing, which is not the same as the
        // vendor being absent -- and only the second of those is a null from
        // `core.oem.parse`.
        try testing.expect(core.oem.value(system.get().Oem, "Lenovo") != null);
        try testing.expectEqual(
            @as(?UsbManagementPortAssignment, null),
            try lenovoUsbPortAssignment(system.get().Oem),
        );

        try bmc.verify();
    }
}

// -- NVIDIA: the bag holds a URI -------------------------------------------

/// Where NVIDIA keeps a Bluefield system's extension, as a link.
///
/// `Oem.Nvidia` is a navigation property rather than content, so what comes
/// out of the bag is a `NavProperty` and not a resource. `core.oem.parse`
/// decodes it like anything else -- the arena matters more here than usual,
/// because the URI is a string in the *system's* response and the caller is
/// about to make a request with it.
fn nvidiaLink(oem: anytype) !?core.Owned(core.NavProperty(NvidiaComputerSystem)) {
    return core.oem.parse(
        core.NavProperty(NvidiaComputerSystem),
        testing.allocator,
        oem,
        "Nvidia",
    );
}

test "a Bluefield extension is a URI, and what is at it need not say where it is" {
    // `oem_nvidia_bluefield_missing_odata_id_in_oem_target_payload` and
    // `oem_nvidia_bluefield_with_odata_id_still_supported`.
    //
    // BF-24.07-14 answers the GET on its own OEM resource without an
    // `@odata.id`, which the reference repairs by splicing one in before
    // deserializing. Here there is nothing to repair: `@odata.id` is
    // `Redfish.Required` and this stack does not enforce `Redfish.Required`,
    // because the annotation describes a conformant service rather than a real
    // one. The property reads as null and the resource reads.
    //
    // That tolerance is not free and it is worth being honest about the cost.
    // A resource that does not say where it lives cannot be re-fetched from
    // itself, so a caller that wants to PATCH it has to remember the URI it
    // asked for. The link is the one that knew, and it is still in hand.
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Nvidia":{"@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia"}}
        ));
        defer system.deinit();

        const link = (try nvidiaLink(system.get().Oem)) orelse return error.NotABluefield;
        defer link.deinit();

        try bmc.expect(mock.Expect.get(nvidia_oem_uri,
            \\{"@odata.type":"#NvidiaComputerSystem.v1_0_0.NvidiaComputerSystem",
            \\ "BaseMAC":"1070fd010203","Mode":"NicMode"}
        ));

        const oem = try core.follow(
            NvidiaComputerSystem,
            testing.allocator,
            &bmc.transport,
            link.value,
        );
        defer oem.deinit();

        try testing.expectEqualStrings("1070fd010203", oem.get().BaseMAC.?);
        try testing.expectEqual(Mode.NicMode, oem.get().Mode.?);
        try testing.expectEqual(@as(?core.ODataId, null), oem.get().@"@odata.id");
        try testing.expectEqualStrings(nvidia_oem_uri, link.value.odataId().?.value);

        try bmc.verify();
    }
    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();

        const system = try onlySystem(&bmc, systemWith(
            \\{"Nvidia":{"@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia"}}
        ));
        defer system.deinit();

        const link = (try nvidiaLink(system.get().Oem)) orelse return error.NotABluefield;
        defer link.deinit();

        try bmc.expect(mock.Expect.get(nvidia_oem_uri,
            \\{"@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia",
            \\ "@odata.type":"#NvidiaComputerSystem.v1_0_0.NvidiaComputerSystem",
            \\ "BaseMAC":"aabbccddeeff","Mode":"DpuMode"}
        ));

        const oem = try core.follow(
            NvidiaComputerSystem,
            testing.allocator,
            &bmc.transport,
            link.value,
        );
        defer oem.deinit();

        try testing.expectEqualStrings("aabbccddeeff", oem.get().BaseMAC.?);
        try testing.expectEqual(Mode.DpuMode, oem.get().Mode.?);
        try testing.expectEqualStrings(nvidia_oem_uri, oem.get().@"@odata.id".?.value);

        try bmc.verify();
    }
}

test "an OEM link a service decorated is a link, and is fetched" {
    // `oem_nvidia_bluefield_inline_oem_object_shape_supported`. Bluefield-3
    // sends `Oem.Nvidia` with an `@odata.id`, an `@odata.type` and a
    // navigation property of its own, and none of the properties the link
    // points at. Counting members would read that as an expanded resource
    // holding nothing, and `follow` would hand it back without a request --
    // a `BaseMAC` of null on a device that has one.
    //
    // `NavProperty.isReferenceShape` asks instead whether the object carries
    // anything `NvidiaComputerSystem` declares. `SystemConfigProfile` is not
    // in NVIDIA's own schema for this type and `@odata.type` is in nobody's,
    // so the answer is a link and the fetch happens. The reference reaches the
    // same place by calling `to_reference()` unconditionally; 6b's fix, made
    // for AMI Viking's decorated links, covers this without knowing NVIDIA
    // exists.
    //
    // The limit is real and worth stating. The test is against *this*
    // package's schema, so a later NVIDIA CSDL that declared
    // `SystemConfigProfile` on `NvidiaComputerSystem` would turn the same
    // payload into a partial expansion. A caller who would rather not depend
    // on that has `toReference`, which is the reference's rule spelled out,
    // and the second half asserts it says the same thing here.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try onlySystem(&bmc, systemWith(
        \\{"Nvidia":{"@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia",
        \\           "@odata.type":"#NvidiaComputerSystem.v1_3_0.NvidiaComputerSystem",
        \\           "SystemConfigProfile":{
        \\             "@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia/SystemConfigProfile",
        \\             "@odata.type":"#SystemConfigProfile.v1_0_0.SystemConfigProfile"}}}
    ));
    defer system.deinit();

    const link = (try nvidiaLink(system.get().Oem)) orelse return error.NotABluefield;
    defer link.deinit();

    try testing.expect(!link.value.isExpanded());
    try testing.expect(!@hasField(NvidiaComputerSystem, "SystemConfigProfile"));

    try bmc.expect(mock.Expect.get(nvidia_oem_uri,
        \\{"@odata.id":"/redfish/v1/Systems/Bluefield/Oem/Nvidia",
        \\ "@odata.type":"#NvidiaComputerSystem.v1_3_0.NvidiaComputerSystem",
        \\ "BaseMAC":"001122334455","Mode":"NicMode"}
    ));

    const oem = try core.follow(
        NvidiaComputerSystem,
        testing.allocator,
        &bmc.transport,
        link.value,
    );
    defer oem.deinit();

    try testing.expect(oem.wasFetched());
    try testing.expectEqualStrings("001122334455", oem.get().BaseMAC.?);
    try testing.expectEqual(Mode.NicMode, oem.get().Mode.?);

    try testing.expectEqualStrings(nvidia_oem_uri, link.value.toReference().?.odataId().?.value);

    try bmc.verify();
}
