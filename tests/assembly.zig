//! A payload with no `@odata.type`, and what this stack does with the
//! annotation when it is there.
//!
//! Ports `nv-redfish`'s `test-assembly-wiwynn-missing-odata-type.rs`. Both of
//! its tests are named for the annotation, because the reference has a real
//! problem with it: its compiler marks `Resource` and `ResourceCollection`
//! `must_have_type`, so every generated resource carries a non-optional
//! `odata_type: String` and a Wiwynn payload that omits it fails to
//! deserialize. A whole class of bug that this stack does not have, because
//! the caller names the type it wants and the emitter writes `@odata.type` as
//! an optional annotation rather than as a required field. Both tests pass
//! with no workaround, and the first two below assert that.
//!
//! What the increment found is the other half, and it is not an absence. The
//! annotation is *not* inert here: `NavProperty` tells a link from an
//! expansion by asking whether the object carries anything the target type
//! declares, and every generated resource declares `@"@odata.type"` — so a
//! link a service decorated with its own type read as an expansion holding
//! nothing, and `follow` returned it without making the request. The same
//! silent wrong answer 6b fixed for AMI Viking's decorated links, arriving
//! through the one member name the fix could not see was an annotation.
//!
//! The rule now reads: a member whose name begins with `@` describes the
//! payload rather than the entity, and no annotation makes an object an
//! expansion. See `core/nav_property.zig` and the last two tests here.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const Assembly = schema.assembly.Assembly;
const AssemblyData = schema.assembly.AssemblyData;

const chassis_uri = "/redfish/v1/Chassis/Chassis_0";
const assembly_uri = chassis_uri ++ "/Assembly";

/// Wiwynn's own serial is a real one and this is not it. A fixture only needs
/// a string that survives the round trip, and the repository does not carry
/// service tags it did not invent.
const fake_serial = "SERIAL0000000000000000AA";

const root_with_chassis =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService","Vendor":"WIWYNN",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
;

const chassis_collection =
    \\{"@odata.id":"/redfish/v1/Chassis",
    \\ "@odata.type":"#ChassisCollection.ChassisCollection",
    \\ "Id":"Chassis","Name":"Chassis Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/Chassis_0"}]}
;

const chassis_body =
    \\{"@odata.id":"/redfish/v1/Chassis/Chassis_0",
    \\ "@odata.type":"#Chassis.v1_22_0.Chassis",
    \\ "Id":"Chassis_0","Name":"Chassis_0","ChassisType":"RackMount",
    \\ "Assembly":{"@odata.id":"/redfish/v1/Chassis/Chassis_0/Assembly"},
    \\ "Status":{"Health":"OK","State":"Enabled"}}
;

/// The Wiwynn assembly, with the member's `@odata.type` under the caller's
/// control. Everything else is the payload the reference records: a member
/// addressed by a JSON-pointer fragment into the resource that carries it,
/// which is what a `ReferenceableMember` is and why it can never be fetched
/// on its own.
fn assemblyBody(comptime typed: bool) []const u8 {
    const member_type = if (typed)
        \\"@odata.type":"#Assembly.v1_5_1.AssemblyData",
    else
        "";

    return
    \\{"@odata.id":"/redfish/v1/Chassis/Chassis_0/Assembly",
    \\ "@odata.type":"#Assembly.v1_3_0.Assembly",
    \\ "Id":"Assembly","Name":"Assembly data for Chassis_0",
    \\ "Assemblies":[{
    \\   "@odata.id":"/redfish/v1/Chassis/Chassis_0/Assembly#/Assemblies/0",
    ++ member_type ++
        \\   "Location":{"PartLocation":{"LocationType":"Embedded"}},
        \\   "MemberId":"0","Model":"GB200 NVL","Name":"PDB Chassis FRU Assembly0",
        \\   "PartNumber":"B81.11801.0008","SerialNumber":"
    ++ fake_serial ++
        \\","Vendor":"NVIDIA"}]}
    ;
}

/// Root, collection, chassis, then the assembly with `$expand` — which is how
/// the reference reads it too, and for the same reason: `Assemblies` holds
/// members that are not separately addressable, so there is no second request
/// that could recover them.
fn onlyAssembly(bmc: *mock.MockBmc, body: []const u8) !core.Owned(Assembly) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis", chassis_collection),
        mock.Expect.get(chassis_uri, chassis_body),
        mock.Expect.expand(assembly_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
    defer chassis.deinit();

    const assembly = chassis.get().Assembly orelse return error.NoAssembly;
    return core.bmc.expand(
        Assembly,
        testing.allocator,
        &bmc.transport,
        assembly.odataId() orelse return error.NotAddressable,
        service.expandQuery().?,
    );
}

/// The one assembly record, however it was spelled.
fn onlyMember(assembly: *const Assembly) !*const AssemblyData {
    const members = assembly.Assemblies orelse return error.NoAssemblies;
    if (members.len != 1) return error.WrongMemberCount;
    return members[0].value() orelse error.NotExpanded;
}

// -- The two ports ---------------------------------------------------------

test "an assembly record with no type annotation is read like any other" {
    // `wiwynn_assembly_without_member_odata_type_is_supported`. In the
    // reference this is the workaround test; here it is the test that there is
    // nothing to work around. `AssemblyData` derives from
    // `Resource.ReferenceableMember` rather than from `Resource`, so the
    // emitter writes no `@odata.type` field on it at all -- the annotation is
    // not merely optional, it is absent from the type, and a payload cannot
    // omit a field the reader never looks for.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const assembly = try onlyAssembly(&bmc, assemblyBody(false));
    defer assembly.deinit();

    const member = try onlyMember(&assembly.value);
    try testing.expectEqualStrings("GB200 NVL", member.Model.?);
    try testing.expectEqualStrings("B81.11801.0008", member.PartNumber.?);
    try testing.expectEqualStrings(fake_serial, member.SerialNumber.?);
    try testing.expectEqualStrings("NVIDIA", member.Vendor.?);
    try testing.expectEqual(
        schema.resource.LocationType.Embedded,
        member.Location.?.PartLocation.?.LocationType.?,
    );

    // The reference reads a producer here and gets `None`, because Wiwynn
    // sends `Vendor` and `Producer` is the property that names a manufacturer.
    // Pinned because it is the difference between "the workaround failed" and
    // "the payload says nothing", and only one of those is worth chasing.
    try testing.expect(member.Producer == null);

    try testing.expect(!@hasField(AssemblyData, "@odata.type"));
    try bmc.verify();
}

test "the same record with a type annotation reads the same" {
    // `wiwynn_assembly_with_member_odata_type_still_supported`. The reference
    // needs this test because its workaround is a shape decision made from the
    // annotation, so the annotated payload takes a different path through it.
    // There is one path here: `@odata.type` is a member `AssemblyData` does
    // not declare, and an undeclared member is dropped, which the corpus sweep
    // settled long before any vendor came up.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const assembly = try onlyAssembly(&bmc, assemblyBody(true));
    defer assembly.deinit();

    const member = try onlyMember(&assembly.value);
    try testing.expectEqualStrings("GB200 NVL", member.Model.?);
    try testing.expectEqualStrings("B81.11801.0008", member.PartNumber.?);
    try testing.expectEqualStrings(fake_serial, member.SerialNumber.?);

    try bmc.verify();
}

// -- Where the annotation is not inert -------------------------------------

test "a link a service decorated with its own type is still a link" {
    // Not a port: the reference cannot have this test, because its
    // `NavProperty` decides on member *count* and a decorated link has never
    // looked like anything but an expansion to it.
    //
    // Here the decision is structural -- does this object carry anything the
    // target type declares -- and that is the right question for a property.
    // `@odata.type` is not one. The emitter writes it on every resource read
    // shape as an annotation, no CSDL declares it, and a service that puts it
    // beside an `@odata.id` is labelling a link rather than expanding it. Read
    // as an expansion, the caller gets a `Chassis` with a null `Id`, a null
    // `Name` and no request made -- absent everywhere, with nothing to
    // distinguish it from a service that answered and had nothing to say.
    //
    // So an annotation never makes an object an expansion. The cost of being
    // wrong the other way is one request that returns exactly what was
    // already in hand; the cost of being wrong this way is the resource.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Id":"Chassis","Name":"Chassis Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/Chassis_0",
            \\             "@odata.type":"#Chassis.v1_22_0.Chassis",
            \\             "@odata.etag":"W/\"1\""}]}
        ),
        mock.Expect.get(chassis_uri, chassis_body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    try testing.expect(!link.isExpanded());

    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
    defer chassis.deinit();

    try testing.expect(chassis.wasFetched());
    try testing.expectEqualStrings("Chassis_0", chassis.get().Id.?);
    try testing.expectEqual(schema.chassis.ChassisType.RackMount, chassis.get().ChassisType.?);

    try bmc.verify();
}

test "one declared property is enough to make an expansion" {
    // The other side of the same line, so neither can move without this file
    // noticing. `Id` is a property `Chassis` declares, so the object carries
    // entity data and the service meant it as an expansion -- annotations
    // alongside change nothing, and no request is made.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Id":"Chassis","Name":"Chassis Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/Chassis_0",
            \\             "@odata.type":"#Chassis.v1_22_0.Chassis",
            \\             "Id":"Chassis_0"}]}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    try testing.expect(link.isExpanded());

    const chassis = try core.follow(Chassis, testing.allocator, &bmc.transport, link);
    defer chassis.deinit();

    try testing.expect(!chassis.wasFetched());
    try testing.expectEqualStrings("Chassis_0", chassis.get().Id.?);
    try testing.expectEqual(@as(usize, 2), bmc.requestCount());

    try bmc.verify();
}
