//! A whole platform read end to end, and the one thing on it that is not
//! what it says it is.
//!
//! Ports `nv-redfish`'s `test-vera-rubin.rs`. That file is 163 lines and one
//! test, and its name is the specification:
//! `vera_rubin_composite_boot_order_is_normalized`. A VR NVL72 host BMC writes
//! `"Boot0019: Ubuntu"` into `Boot.BootOrder` where DSP0266 wants a bare
//! `BootOptionReference`, and the reference repairs it with a JSON patch run
//! before deserialization, gated on a `Platform::VeraRubin` fingerprint of
//! `Vendor == "NVIDIA"` and `Product == "VR NVL72"`.
//!
//! Nothing here is repaired, and the reason is the line `quirks.zig` draws in
//! its own doc-comment. This is a departure in the *data*: a property whose
//! value means something other than what its type says. `Deviation` names
//! departures in the *protocol*, because those are the ones the stack can
//! answer by itself -- stop sending the option, stop sending the header. There
//! is no general action to take on a wrong string, and the code that knows
//! what the string was for is the only code that can act. Eighth time, and the
//! fingerprint is exercised below to show it was available and declined.
//!
//! The increment's find is that the departure needs no fingerprint at all. The
//! composite entry is a `BootOptionReference` and its `DisplayName` joined
//! with `": "`, and both halves are properties of a `BootOption` in a
//! collection the same system links -- so the service that spelled the entry
//! wrongly also published the evidence for reading it. The reference's `": "`
//! split is a guess that costs nothing; matching against `BootOptions` is a
//! fact that costs a request. Both belong to the caller and both are here.
//!
//! The last test is what the increment is for. A real platform is read from
//! the root down with four of the tolerance rules the previous increments
//! produced firing at once, and none of them knows what a VR NVL72 is.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const ComputerSystem = schema.computer_system.ComputerSystem;
const BootOption = schema.boot_option.BootOption;
const BootOptionCollection = schema.boot_option_collection.BootOptionCollection;

const systems_uri = "/redfish/v1/Systems";
const system_uri = systems_uri ++ "/System_0";
const boot_options_uri = system_uri ++ "/BootOptions";

/// VR NVL72's root, as `test-vera-rubin.rs` records it. `NoLinks` is the only
/// `$expand` form it claims and it names no `Levels`, which is the whole of
/// what the stack has to decide from.
const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_15_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "Vendor":"NVIDIA","Product":"VR NVL72","RedfishVersion":"1.17.0",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"},
    \\ "Managers":{"@odata.id":"/redfish/v1/Managers"},
    \\ "Links":{"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}}
;

const system_collection =
    \\{"@odata.id":"/redfish/v1/Systems",
    \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
    \\ "Name":"Computer System Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Systems/System_0"}]}
;

/// The composite entries, as the reference records them. The MAC in the second
/// is part of the firmware's display name for a UEFI HTTP boot entry, and like
/// every other identifier in this file it is invented.
const composite_boot_order = [_][]const u8{
    "Boot0019: Ubuntu",
    "Boot0010: UEFI HTTPv4 (MAC:0011223344AA)",
};

const system_body =
    \\{"@odata.id":"/redfish/v1/Systems/System_0",
    \\ "@odata.type":"#ComputerSystem.v1_22_0.ComputerSystem",
    \\ "Id":"System_0","Name":"System_0",
    \\ "Status":{"Health":"OK","State":"Enabled"},
    \\ "Boot":{"BootOrder":["Boot0019: Ubuntu",
    \\                      "Boot0010: UEFI HTTPv4 (MAC:0011223344AA)"],
    \\         "BootOptions":{"@odata.id":"/redfish/v1/Systems/System_0/BootOptions"}}}
;

/// The two boot options the order refers to, holding separately the two
/// properties the entries were made by concatenating.
const boot_options_body =
    \\{"@odata.id":"/redfish/v1/Systems/System_0/BootOptions",
    \\ "@odata.type":"#BootOptionCollection.BootOptionCollection",
    \\ "Name":"Boot Option Collection",
    \\ "Members":[
    \\  {"@odata.id":"/redfish/v1/Systems/System_0/BootOptions/Boot0019",
    \\   "@odata.type":"#BootOption.v1_0_4.BootOption",
    \\   "Id":"Boot0019","Name":"Boot Option",
    \\   "BootOptionReference":"Boot0019","DisplayName":"Ubuntu",
    \\   "BootOptionEnabled":true},
    \\  {"@odata.id":"/redfish/v1/Systems/System_0/BootOptions/Boot0010",
    \\   "@odata.type":"#BootOption.v1_0_4.BootOption",
    \\   "Id":"Boot0010","Name":"Boot Option",
    \\   "BootOptionReference":"Boot0010",
    \\   "DisplayName":"UEFI HTTPv4 (MAC:0011223344AA)",
    \\   "BootOptionEnabled":true}]}
;

/// Reads a collection the root links, with the `$expand` the root advertised.
///
/// `Service.walk` deliberately does not expand -- a walker pages, and a page
/// is what a service decides. Naming the field and recovering the collection
/// type through `Service.Linked` is what a caller writes when it wants the
/// members in one request, and it is a compile error to name a link the root
/// does not have.
fn expandCollection(
    service: Service,
    transport: *core.BmcTransport,
    comptime field: []const u8,
) !core.Owned(Service.Linked(field)) {
    const link = @field(service.root.value, field) orelse return error.NotSupported;
    return core.bmc.expand(
        Service.Linked(field),
        testing.allocator,
        transport,
        link.odataId() orelse return error.NotAddressable,
        service.expandQuery() orelse return error.NoExpand,
    );
}

/// Root, then the systems collection expanded, then `System_0` — the path
/// `test-vera-rubin.rs` takes to reach it.
fn readSystem(bmc: *mock.MockBmc) !core.Owned(ComputerSystem) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.expand(systems_uri, system_collection),
        mock.Expect.get(system_uri, system_body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const collection = try expandCollection(service, &bmc.transport, "Systems");
    defer collection.deinit();

    const members = collection.value.Members orelse return error.NoMembers;
    if (members.len != 1) return error.WrongMemberCount;

    return core.bmc.get(
        ComputerSystem,
        testing.allocator,
        &bmc.transport,
        members[0].odataId() orelse return error.NotAddressable,
    );
}

/// The boot order as the system sent it.
fn bootOrder(system: *const ComputerSystem) ![]const ?[]const u8 {
    const boot = system.Boot orelse return error.NoBoot;
    return boot.BootOrder orelse error.NoBootOrder;
}

// -- What the firmware sends -----------------------------------------------

test "a composite boot order entry reaches the caller composite" {
    // `vera_rubin_composite_boot_order_is_normalized`, ported as the absence
    // of the normalization. The reference asserts `"Boot0019"`; this asserts
    // `"Boot0019: Ubuntu"`, because no layer between the socket and the caller
    // is entitled to decide that a string the service sent means something
    // else. `BootOrder` is an array of `Edm.String`, every value in it is a
    // legal one, and nothing in the payload is malformed -- this is a service
    // saying the wrong thing correctly, which is the one failure a parser
    // cannot see and therefore the one it must not pretend to fix.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try readSystem(&bmc);
    defer system.deinit();

    const order = try bootOrder(&system.value);
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expectEqualStrings(composite_boot_order[0], order[0].?);
    try testing.expectEqualStrings(composite_boot_order[1], order[1].?);

    try bmc.verify();
}

test "the fingerprint the reference gates on matches, and carries nothing" {
    // `Platform::VeraRubin` is `Vendor == "NVIDIA"` and `Product == "VR NVL72"`,
    // both on the root, so a rule can be aimed at this platform and the second
    // half of the test shows one landing. What is missing is not the
    // fingerprint but the deviation: every member `Deviation` has names
    // something the stack can do differently on its own, and there is nothing
    // to do differently about a `BootOrder` entry except read it differently.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1", root_body));

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expectEqualStrings("NVIDIA", service.vendor().?);
    try testing.expectEqualStrings("VR NVL72", service.product().?);
    try testing.expectEqualStrings("1.17.0", service.redfishVersion().?);

    // A rule with exactly this fingerprint matches, and one aimed a model
    // sideways does not. Nothing like either ships: `quirks.zig` has no table.
    service.applyQuirks(&.{
        .{
            .match = .{ .vendor = "NVIDIA", .product_contains = "GB200" },
            .deviations = &.{.etag_unreliable},
        },
        .{
            .match = .{ .vendor = "NVIDIA", .product_contains = "VR NVL72" },
            .deviations = &.{.expand_unreliable},
        },
    });

    try testing.expect(service.etagsUsable());
    try testing.expectEqual(@as(?core.ExpandQuery, null), service.expandQuery());

    try bmc.verify();
}

// -- Reading it in the caller ----------------------------------------------

/// The `BootOptionReference` part of a boot order entry, for firmware that
/// writes the display name into the same string.
///
/// Ports `vera_rubin_boot_order_entry_reference`, and stays exactly as narrow.
/// The separator is `": "` and not `':'`, because a bare colon is inside
/// `MAC:0011223344AA`, inside every UEFI device path and inside every URI --
/// a rule that cut at the first colon would turn a legal reference into a
/// prefix of one. An entry with no separator is returned whole, which is what
/// a conformant service sends and what this does to one.
fn bootOptionReference(entry: []const u8) []const u8 {
    const cut = std.mem.indexOf(u8, entry, ": ") orelse return entry;
    return entry[0..cut];
}

test "a boot order entry splits at the separator and nowhere else" {
    try testing.expectEqualStrings("Boot0019", bootOptionReference("Boot0019: Ubuntu"));
    try testing.expectEqualStrings(
        "Boot0010",
        bootOptionReference("Boot0010: UEFI HTTPv4 (MAC:0011223344AA)"),
    );

    // A conformant entry, untouched.
    try testing.expectEqualStrings("Boot0010", bootOptionReference("Boot0010"));

    // A colon that is not a separator, and a reference that is itself a URI:
    // both survive, which is the whole reason the space is in the pattern.
    try testing.expectEqualStrings("Boot0010:Ubuntu", bootOptionReference("Boot0010:Ubuntu"));
    try testing.expectEqualStrings(
        "http://boot.example/img",
        bootOptionReference("http://boot.example/img"),
    );
}

test "the composite entry is a boot option reference and its display name" {
    // Not a port: the reference asserts that its patch produced `"Boot0019"`
    // and stops. What makes the patch *right* is a fact about the service
    // rather than about the platform, and it is one request away --
    // `Boot.BootOptions` lists a `BootOption` per entry carrying
    // `BootOptionReference` and `DisplayName` as separate properties, and the
    // firmware's string is those two joined by `": "`.
    //
    // So a caller has two ways to read a composite entry and they are not the
    // same kind of thing. Cutting at `": "` is a guess that is free and could
    // in principle cut a reference that contains the separator. Matching
    // against `BootOptions` is evidence, costs a request, and names no vendor
    // anywhere -- against a conformant service the first match succeeds and
    // the split is never reached.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try readSystem(&bmc);
    defer system.deinit();

    const boot = system.value.Boot.?;
    try bmc.expect(mock.Expect.expand(boot_options_uri, boot_options_body));

    const options = try core.bmc.expand(
        BootOptionCollection,
        testing.allocator,
        &bmc.transport,
        boot.BootOptions.?.odataId() orelse return error.NotAddressable,
        core.ExpandQuery.no_levels,
    );
    defer options.deinit();

    const order = try bootOrder(&system.value);
    for (order, 0..) |maybe_entry, index| {
        const entry = maybe_entry orelse return error.AbsentEntry;

        // As sent, the entry names no boot option at all.
        try testing.expect(findOption(&options.value, entry) == null);

        // Cut at the separator it names exactly one, and that option's own two
        // properties rebuild the string the firmware sent -- which is what
        // makes this a concatenation rather than a different identifier.
        const option = findOption(&options.value, bootOptionReference(entry)) orelse
            return error.NoSuchBootOption;

        const rejoined = try std.mem.concat(testing.allocator, u8, &.{
            option.BootOptionReference.?,
            ": ",
            option.DisplayName.?,
        });
        defer testing.allocator.free(rejoined);
        try testing.expectEqualStrings(composite_boot_order[index], rejoined);
        try testing.expect(option.BootOptionEnabled.?);
    }

    try bmc.verify();
}

/// The boot option whose `BootOptionReference` is `reference`, or null.
fn findOption(collection: *const BootOptionCollection, reference: []const u8) ?*const BootOption {
    for (collection.Members orelse &.{}) |member| {
        const option = member.value() orelse continue;
        const declared = option.BootOptionReference orelse continue;
        if (std.mem.eql(u8, declared, reference)) return option;
    }
    return null;
}

// -- The service as a whole ------------------------------------------------

test "a service that advertises only NoLinks is asked for a dot and no levels" {
    // The request that actually went out, read back off the mock. `NoLinks` is
    // `$expand=.`, and `Levels` is absent from the advertisement, so no
    // `$levels` is sent -- DSP0266 lets a service reject the whole request for
    // carrying a parameter it never claimed, and `ExpandQuery`'s own default
    // is one level, so this is a correction rather than a passthrough.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try readSystem(&bmc);
    defer system.deinit();

    try testing.expectEqualStrings("$expand=.", bmc.request(1).queryString().?);

    // The other two carry no query at all: the root is read before anything is
    // known, and a member fetched by its own link has nothing to expand.
    try testing.expectEqual(@as(?[]const u8, null), bmc.request(0).queryString());
    try testing.expectEqual(@as(?[]const u8, null), bmc.request(2).queryString());

    try bmc.verify();
}

test "the platform reads whole with nothing known about it" {
    // The acceptance test for the phase rather than a test of one service:
    // one platform, read from the root down through three collections, with
    // four tolerance rules firing at once and not one of them holding a vendor
    // name. Each rule is pinned where it was decided; what is new here is that
    // they compose -- a resource can be wrong in four ways at the same time
    // and still arrive with everything it did say intact, and a service can be
    // wrong in one resource without costing the caller the others.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.expand("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Name":"Chassis Collection",
            \\ "Members":[
            \\  {"@odata.id":"/redfish/v1/Chassis/Chassis_0",
            \\   "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\   "Id":"Chassis_0","ChassisType":"RackMount","UUID":"",
            \\   "Status":{"Health":"OK","State":"Quiesced_"},
            \\   "NvidiaTrayIndex":3}]}
        ),
        mock.Expect.expand(systems_uri,
            \\{"@odata.id":"/redfish/v1/Systems",
            \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
            \\ "Name":"Computer System Collection",
            \\ "Members":[
            \\  {"@odata.id":"/redfish/v1/Systems/System_0",
            \\   "@odata.type":"#ComputerSystem.v1_22_0.ComputerSystem",
            \\   "Id":"System_0","Name":"System_0",
            \\   "LastResetTime":"0000-00-00T00:00:00+00:00",
            \\   "Boot":{"BootOrder":["Boot0019: Ubuntu"]}}]}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const chassis = try expandCollection(service, &bmc.transport, "Chassis");
    defer chassis.deinit();

    const only = (chassis.value.Members orelse return error.NoMembers)[0].value() orelse
        return error.NotExpanded;

    // `Name` is `Redfish.Required` and absent, which is not enforced.
    try testing.expect(only.Name == null);
    // `"Quiesced_"` is a value no enum names, so it is `UnsupportedValue`.
    try testing.expectEqual(schema.resource.State.UnsupportedValue, only.Status.?.State.?);
    // `"UUID": ""` is an absence spelled out loud.
    try testing.expect(only.UUID == null);
    // `NvidiaTrayIndex` is a member no schema declares, and is dropped.
    try testing.expect(!@hasField(schema.chassis.Chassis, "NvidiaTrayIndex"));

    // And the chassis arrived, which is the only assertion that matters.
    try testing.expectEqualStrings("Chassis_0", only.Id.?);
    try testing.expectEqual(schema.chassis.ChassisType.RackMount, only.ChassisType.?);
    try testing.expectEqual(schema.resource.Health.OK, only.Status.?.Health.?);

    const systems = try expandCollection(service, &bmc.transport, "Systems");
    defer systems.deinit();

    const system = (systems.value.Members orelse return error.NoMembers)[0].value() orelse
        return error.NotExpanded;

    // A timestamp of all zeros is not a timestamp, and costs only itself.
    try testing.expect(system.LastResetTime == null);
    try testing.expectEqualStrings("System_0", system.Id.?);

    // The one departure no rule touches, arriving intact for the caller to
    // deal with. That it is still composite here is the whole argument of
    // this file.
    try testing.expectEqualStrings(
        composite_boot_order[0],
        system.Boot.?.BootOrder.?[0].?,
    );

    try bmc.verify();
}
