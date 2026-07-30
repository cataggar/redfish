//! Attributes a schema declines to name, and the three ways to read one.
//!
//! Ports `nv-redfish`'s `test-bios.rs`. `Bios.Attributes` is the largest open
//! shape in Redfish: DSP0266 declares it a container of dynamic properties
//! whose names and types are the platform's business, so a schema-driven
//! client cannot generate a field for any of them and has to hand the caller
//! whatever arrived.
//!
//! That makes this the test of `core/open_struct.zig` against a real
//! resource. `additional_properties` holds `std.json.Value`, which is the
//! honest answer -- the schema said nothing, so nothing is known -- and
//! `core.PrimitiveType` is the EDM reading a caller asks for when it wants
//! one, including an exact `Decimal` for a number that is not an integer.
//!
//! Writing is not here. `Bios.Attributes` is read-only on the resource and a
//! `PATCH` to it may be accepted and ignored, which is why `updatePending`
//! exists; `tests/writes.zig` pins that against `@Redfish.Settings` already.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const ComputerSystem = schema.computer_system.ComputerSystem;
const Bios = schema.bios.Bios;

const systems_uri = "/redfish/v1/Systems";
const system_uri = "/redfish/v1/Systems/System-1";
const bios_uri = "/redfish/v1/Systems/System-1/Bios";

const root_with_systems =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"}}
;

const system_collection =
    \\{"@odata.id":"/redfish/v1/Systems",
    \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
    \\ "Id":"Systems","Name":"Systems Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Systems/System-1"}]}
;

const system_with_bios =
    \\{"@odata.id":"/redfish/v1/Systems/System-1",
    \\ "@odata.type":"#ComputerSystem.v1_20_1.ComputerSystem",
    \\ "Id":"System-1","Name":"System-1",
    \\ "Bios":{"@odata.id":"/redfish/v1/Systems/System-1/Bios"}}
;

/// Reads the BIOS the way a program does: root, systems, system, BIOS.
///
/// Four hops for what could be one GET, and that is the point -- `Bios` is
/// reached through a nav property on a collection member, so a change to how
/// either of those parses shows up here.
fn biosOf(bmc: *mock.MockBmc, body: []const u8) !core.Resolved(Bios) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri, system_collection),
        mock.Expect.get(system_uri, system_with_bios),
        mock.Expect.get(bios_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    defer system.deinit();

    const bios_link = system.get().Bios orelse return error.NoBios;
    return core.follow(Bios, testing.allocator, &bmc.transport, bios_link);
}

/// The EDM reading of one attribute, or null if there is no such attribute.
///
/// `null` in the payload is a member the service sent and an attribute it
/// declined to give a value -- a write-only password, most often. It is not a
/// primitive, so this reports it as one rather than inventing a value.
fn attribute(bios: *const Bios, name: []const u8) !?core.PrimitiveType {
    const attrs = bios.Attributes orelse return null;
    const value = attrs.additional_properties.map.get(name) orelse return null;
    return try std.json.parseFromValueLeaky(
        core.PrimitiveType,
        testing.allocator,
        value,
        .{},
    );
}

test "an attribute of every type the platform might use" {
    // `bios_basic_retrieval_and_types`. Five attributes, five JSON shapes, and
    // the schema names none of them.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const bios = try biosOf(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings",
        \\ "Attributes":{"BootMode":"Uefi","WatchdogTimeout":5,
        \\               "Field Mode":false,"PowerCapping":125.5,
        \\               "SetupPassword":null}}
    );
    defer bios.deinit();

    const attrs = bios.get().Attributes.?.additional_properties.map;
    try testing.expectEqual(@as(usize, 5), attrs.count());

    try testing.expectEqualStrings("Uefi", (try attribute(bios.get(), "BootMode")).?.string);
    try testing.expectEqual(
        @as(i64, 5),
        (try attribute(bios.get(), "WatchdogTimeout")).?.integer,
    );
    try testing.expectEqual(false, (try attribute(bios.get(), "Field Mode")).?.boolean);

    // 125.5 is not representable in binary floating point, so `Decimal` holds
    // it as the digits the service wrote rather than the nearest double.
    const capping = (try attribute(bios.get(), "PowerCapping")).?.decimal;
    try testing.expectEqual(@as(i128, 1255), capping.mantissa);
    try testing.expectEqual(@as(u8, 1), capping.scale);

    try bmc.verify();
}

test "an attribute the service sent without a value" {
    // A password-like attribute is write-only, so the service lists the name
    // and sends `null`. Present and valueless are different facts from absent,
    // and the map keeps both: the key is there, and reading it as a primitive
    // refuses rather than guessing.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const bios = try biosOf(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings",
        \\ "Attributes":{"SetupPassword":null}}
    );
    defer bios.deinit();

    const attrs = bios.get().Attributes.?.additional_properties.map;
    try testing.expect(attrs.contains("SetupPassword"));
    try testing.expect(attrs.get("SetupPassword").? == .null);
    try testing.expect(!attrs.contains("NoSuchAttribute"));

    try testing.expectError(
        error.UnexpectedToken,
        attribute(bios.get(), "SetupPassword"),
    );
    try bmc.verify();
}

test "an attribute that is not a string has no string in it" {
    // `bios_attribute_string_value`. The union answers the question rather
    // than a fallible accessor: a caller that wanted text and got a number
    // matches the wrong arm, at the point of asking.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const bios = try biosOf(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings",
        \\ "Attributes":{"BootMode":"Uefi","WatchdogTimeout":5}}
    );
    defer bios.deinit();

    try testing.expect((try attribute(bios.get(), "BootMode")).? == .string);
    try testing.expect((try attribute(bios.get(), "WatchdogTimeout")).? != .string);
    try bmc.verify();
}

test "a BIOS with no attributes, and one with an empty set of them" {
    // `bios_missing_or_empty_attributes`. The two are different answers and
    // the types keep them apart: `Attributes` absent is a service that did not
    // say, `Attributes: {}` is one that said there are none.
    var missing: mock.MockBmc = .init(testing.allocator);
    defer missing.deinit();

    const without = try biosOf(&missing,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings"}
    );
    defer without.deinit();

    try testing.expect(without.get().Attributes == null);
    try testing.expect((try attribute(without.get(), "Anything")) == null);
    try missing.verify();

    var empty: mock.MockBmc = .init(testing.allocator);
    defer empty.deinit();

    const with = try biosOf(&empty,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings","Attributes":{}}
    );
    defer with.deinit();

    try testing.expectEqual(
        @as(usize, 0),
        with.get().Attributes.?.additional_properties.map.count(),
    );
    try testing.expect((try attribute(with.get(), "Anything")) == null);
    try empty.verify();
}

test "an attribute name the schema could never have generated" {
    // `Field Mode` has a space in it and `#Custom.Thing` starts with a `#`.
    // Neither is a Zig identifier, which is exactly why they cannot be fields
    // and have to live in a map keyed by the name the service used.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const bios = try biosOf(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1/Bios",
        \\ "@odata.type":"#Bios.v1_2_1.Bios",
        \\ "Id":"Bios","Name":"BIOS Settings",
        \\ "Attributes":{"Field Mode":true,"#Custom.Thing":"on","":"unnamed"}}
    );
    defer bios.deinit();

    try testing.expectEqual(true, (try attribute(bios.get(), "Field Mode")).?.boolean);
    try testing.expectEqualStrings("on", (try attribute(bios.get(), "#Custom.Thing")).?.string);
    try testing.expectEqualStrings("unnamed", (try attribute(bios.get(), "")).?.string);
    try bmc.verify();
}
