//! The vendor's half of a service root, and the path a caller takes to reach
//! it.
//!
//! Ports `nv-redfish`'s `test-service-root-oem-ami.rs` and
//! `test-service-root-oem-hpe.rs`. Together with `oem_manager.zig` this is the
//! first code anywhere in the repository to read one of the ten OEM schema
//! packages #50 generated, so the subject is less any one vendor's property
//! than the step in front of all of them: how a caller gets from
//! `resource.Oem` -- an open struct holding whatever the service sent -- to a
//! struct a vendor's CSDL describes.
//!
//! That step is `core.oem.parse`, which is new in this increment, and the
//! argument for it being in the library rather than at each call site is in
//! its own doc-comment. The short form is that the obvious call,
//! `std.json.parseFromValue(T, gpa, value, .{})`, rejects the `@odata.type`
//! every vendor writes beside its properties, because `std.json`'s default is
//! strict and every other read in this stack goes through
//! `owned.parse_options`, which is not. A caller who wrote it by hand would
//! find that a vendor type decodes at its own URI and fails inside an `Oem`.
//!
//! `service_root_hpe_manager_type_other_variant` is not ported as its own
//! test. The reference parses `"iLO 6"` into `ManagerType::Ilo(6)` and
//! everything else into `ManagerType::Other`, so it needs a second test to
//! reach the second arm; here `HpeiLOServiceExt.Manager[].ManagerType` is the
//! `Edm.String` the CSDL declares and both payloads are the same shape. The
//! generation is recovered in the test, which is where a rule that no schema
//! states belongs.
//!
//! `service_root_hpe_malformed_oem_returns_parse_error` is not ported either.
//! It is `service_root_ami_malformed_oem_returns_parse_error` with an object
//! where an array belongs instead of an integer where a string belongs, and
//! one of the two is enough to pin that a value of the wrong type is an error
//! rather than an absence.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const ami = @import("redfish_schema_oem_ami");
const hpe = @import("redfish_schema_oem_hpe");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const AmiServiceRoot = ami.ami_service_root.AmiServiceRoot;
const HpeiLoServiceExt = hpe.hpei_lo_service_ext.HpeiLoServiceExt;

/// A root with `oem` spliced in where a service writes its `Oem` property.
/// The reference builds the same payload by merging two JSON objects.
fn rootWith(comptime oem: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_17_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "RedfishVersion":"1.21.1",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Links":{"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
    ++ oem ++ "}";
}

fn connect(bmc: *mock.MockBmc, body: []const u8) !Service {
    try bmc.expect(mock.Expect.get("/redfish/v1", body));
    return Service.connect(testing.allocator, &bmc.transport);
}

test "an AMI service root carries a technology-pack version no standard schema has" {
    // `service_root_ami_rtp_version_parsed`. `RtpVersion` is the version of
    // the Redfish stack AMI ships to its licensees, which is not
    // `RedfishVersion` -- that is the specification the service implements --
    // and is not `SoftwareId` either, since one technology pack is built into
    // many products. There is nowhere in the standard schema for it, which is
    // what `Oem` is for.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc, rootWith(
        \\,"Oem":{"Ami":{"@odata.type":"#AMIServiceRoot.v1_0_0.AMIServiceRoot",
        \\               "RtpVersion":"13.09.1"}}
    ));
    defer service.deinit();

    const found = try core.oem.parse(
        AmiServiceRoot,
        testing.allocator,
        service.root.value.Oem,
        "Ami",
    );
    const extension = found orelse return error.NoAmiExtension;
    defer extension.deinit();

    try testing.expectEqualStrings("13.09.1", extension.value.RtpVersion.?);

    // The key is `Ami` and the namespace it decodes into is `AMIServiceRoot`.
    // Nothing derives one from the other, which is why the vendor is an
    // argument rather than something `core.oem` works out.
    try testing.expectEqual(@as(?std.json.Value, null), core.oem.value(service.root.value.Oem, "AMI"));

    try bmc.verify();
}

test "a service root with no Oem property at all belongs to no vendor" {
    // `service_root_without_ami_oem_returns_none` and
    // `service_root_without_hpe_oem_returns_none`, which are the same
    // assertion with two keys. `Oem` is optional on every Redfish resource
    // and a service that has no extensions omits it, so the lookup has to
    // answer for a bag that does not exist rather than one that is empty.
    // `oem_manager.zig` pins the other shape, where `Oem` is present and
    // names a vendor this caller does not know.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc, rootWith(""));
    defer service.deinit();

    try testing.expect(service.root.value.Oem == null);
    try testing.expectEqual(
        @as(?core.Owned(AmiServiceRoot), null),
        try core.oem.parse(AmiServiceRoot, testing.allocator, service.root.value.Oem, "Ami"),
    );

    try bmc.verify();
}

test "a vendor property of the wrong type is a defect, not an absence" {
    // `service_root_ami_malformed_oem_returns_parse_error`. `RtpVersion` is
    // `Edm.String` and this service sends a number. The reference asserts the
    // error text contains "invalid type"; what matters is that it is an error
    // at all, because the alternative -- folding a failed decode into the
    // `null` that means "not this vendor's hardware" -- would have a caller
    // read a default off a service that is telling it something is wrong.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc, rootWith(
        \\,"Oem":{"Ami":{"@odata.type":"#AMIServiceRoot.v1_0_0.AMIServiceRoot",
        \\               "RtpVersion":13091}}
    ));
    defer service.deinit();

    try testing.expectError(error.UnexpectedToken, core.oem.parse(
        AmiServiceRoot,
        testing.allocator,
        service.root.value.Oem,
        "Ami",
    ));

    // The key is there and the raw value is readable, which is the difference
    // between this and the test above.
    try testing.expect(core.oem.value(service.root.value.Oem, "Ami") != null);

    try bmc.verify();
}

/// The iLO generation in a `ManagerType`, or null for anything else.
///
/// `service_root_hpe_ilo_manager_type_parsed` and
/// `service_root_hpe_manager_type_other_variant` are the two arms of this
/// function in the reference, where it is a type. It stays in the caller for
/// the reason five increments have kept per-platform reading in the caller:
/// the string is `Edm.String` in HPE's own CSDL, so a schema-shaped answer
/// would be inventing a rule the vendor did not write down, and the rule is
/// four lines wherever it is put.
fn iloGeneration(manager_type: []const u8) ?u16 {
    const prefix = "iLO ";
    if (!std.mem.startsWith(u8, manager_type, prefix)) return null;
    return std.fmt.parseInt(u16, manager_type[prefix.len..], 10) catch null;
}

test "an HPE service root names its manager, and what that name means is the caller's" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc, rootWith(
        \\,"Oem":{"Hpe":{"@odata.type":"#HpeiLOServiceExt.v2_5_0.HpeiLOServiceExt",
        \\               "Manager":[{"ManagerType":"iLO 6",
        \\                           "ManagerFirmwareVersion":"1.62"},
        \\                          {"ManagerType":"Custom"}]}}
    ));
    defer service.deinit();

    const found = try core.oem.parse(
        HpeiLoServiceExt,
        testing.allocator,
        service.root.value.Oem,
        "Hpe",
    );
    const extension = found orelse return error.NoHpeExtension;
    defer extension.deinit();

    // `Manager` is a collection in HPE's schema even on a machine with one
    // manager, which is the shape the reference's malformed-payload test
    // exists to defend.
    const managers = extension.value.Manager.?;
    try testing.expectEqual(@as(usize, 2), managers.len);
    try testing.expectEqualStrings("iLO 6", managers[0].ManagerType.?);
    try testing.expectEqualStrings("1.62", managers[0].ManagerFirmwareVersion.?);

    try testing.expectEqual(@as(?u16, 6), iloGeneration(managers[0].ManagerType.?));
    try testing.expectEqual(@as(?u16, null), iloGeneration(managers[1].ManagerType.?));
    try testing.expectEqual(@as(?[]const u8, null), managers[1].ManagerFirmwareVersion);

    try bmc.verify();
}
