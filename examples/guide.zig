//! `guide` — the code `doc/guide.md` shows, kept compiling.
//!
//! Every fenced Zig block in the guide is a function below, verbatim, and the
//! last test in this file fails if the two drift apart. `examples/readme.zig`
//! does the same for the README, for the same reason: a documented program
//! nobody compiles rots exactly as fast as an example nobody runs.
//!
//! A block the guide marks `// WRONG` is deliberately not here. It is code
//! that must not compile or must not be run, so the checker skips it — see
//! `wrong_marker` below.
//!
//! This file has no `main`. It is not a program; it is the guide's proof.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const delta = @import("redfish_schema_oem_delta");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const ChassisCollection = schema.chassis_collection.ChassisCollection;
const PowerSupply = schema.power_supply.PowerSupply;
const DeltaPowerSupply = delta.delta_energy_systems_power_supply.PowerSupply;

// -- Owned(T): what a fetch returns ----------------------------------------

/// `core.bmc.get` fetched it, so it owns it. The value is a field.
fn readOne(gpa: std.mem.Allocator, transport: *core.BmcTransport) !void {
    const chassis = try core.bmc.get(Chassis, gpa, transport, .init("/redfish/v1/Chassis/1"));
    defer chassis.deinit();

    std.debug.print("{s}\n", .{chassis.value.Name orelse "?"});
}

// -- Resolved(T): what a link returns --------------------------------------

/// `core.follow` may not have fetched anything, so the value is behind a
/// call. `deinit` is correct either way and is not optional.
fn readEach(gpa: std.mem.Allocator, transport: *core.BmcTransport) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, gpa, transport, link);
        defer chassis.deinit();

        std.debug.print("{s}\n", .{chassis.get().Name orelse "?"});
    }
}

/// Keeping one past the loop, safely.
///
/// `wasFetched` is the only thing that distinguishes a value that owns its
/// arena from one pointing into a page the walker is about to free.
fn firstFetched(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
) !?core.Resolved(Chassis) {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, gpa, transport, link);
        if (chassis.wasFetched()) return chassis;

        // Expanded inline: it borrows the walker's page and cannot leave.
        chassis.deinit();
    }
    return null;
}

// -- Tolerance -------------------------------------------------------------

/// What a service is allowed to send, and what this client makes of it.
fn tolerate(gpa: std.mem.Allocator, body: []const u8) !void {
    const chassis = try core.parseJson(Chassis, gpa, body, null);
    defer chassis.deinit();

    // A `ChassisType` no schema names is not an error. The string is lost;
    // the rest of the resource is not.
    std.debug.assert(chassis.value.ChassisType == .UnsupportedValue);

    // An empty `Guid` reads as absent, because an empty string is an absence
    // spelled out loud. A malformed one would still fail.
    std.debug.assert(chassis.value.UUID == null);

    // `Redfish.Required` is not enforced: `Id` is required and missing, and
    // the parse succeeded anyway.
    std.debug.assert(chassis.value.Id == null);
}

// -- OEM -------------------------------------------------------------------

/// The vendor's own type, out of the bag the standard type carried.
fn vendorExtension(gpa: std.mem.Allocator, supply: *const PowerSupply) !?bool {
    const found = try core.oem.parse(
        DeltaPowerSupply,
        gpa,
        supply.Oem,
        "deltaenergysystems",
    );
    const extension = found orelse return null;
    defer extension.deinit();

    return extension.value.Power;
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

const root_with_chassis =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
;

const one_chassis =
    \\{"@odata.id":"/redfish/v1/Chassis/1",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"1","Name":"Computer System Chassis"}
;

test "a fetched resource owns its arena" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{mock.Expect.get("/redfish/v1/Chassis/1", one_chassis)});

    try readOne(testing.allocator, &bmc.transport);
    try bmc.verify();
}

test "a followed link is read the same way whether or not it cost a request" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1"}]}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1", one_chassis),
    });

    try readEach(testing.allocator, &bmc.transport);
    try bmc.verify();
}

test "an expanded member cannot leave the walk and a fetched one can" {
    // The same program against two services. The first expands its members,
    // so every `Resolved` borrows the walker's page and none may be kept;
    // the second does not, so the first one may. Nothing in the call site
    // changes, which is the point of `Resolved` — and `wasFetched` is the
    // only thing that can tell them apart.
    var expanding: mock.MockBmc = .init(testing.allocator);
    defer expanding.deinit();
    try expanding.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1",
            \\             "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\             "Id":"1","Name":"Computer System Chassis"}]}
        ),
    });

    try testing.expectEqual(
        @as(?core.Resolved(Chassis), null),
        try firstFetched(testing.allocator, &expanding.transport),
    );
    try expanding.verify();

    var referencing: mock.MockBmc = .init(testing.allocator);
    defer referencing.deinit();
    try referencing.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1"}]}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1", one_chassis),
    });

    const kept = (try firstFetched(testing.allocator, &referencing.transport)).?;
    defer kept.deinit();

    // The walker is gone and this is still readable, because it was fetched.
    try testing.expectEqualStrings("Computer System Chassis", kept.get().Name.?);
    try referencing.verify();
}

test "three departures from the schema, none of them fatal" {
    try tolerate(testing.allocator,
        \\{"@odata.id":"/redfish/v1/Chassis/1",
        \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
        \\ "Name":"Computer System Chassis",
        \\ "ChassisType":"OrbitalHabitat",
        \\ "UUID":"",
        \\ "ContosoPowerBudget":1200}
    );
}

test "a malformed value is still a failure" {
    // The tolerance is for absence spelled oddly, not for a value that is
    // wrong. Nothing here reads `not-a-uuid` as "the service said nothing".
    try testing.expectError(error.InvalidCharacter, core.parseJson(Chassis, testing.allocator,
        \\{"@odata.id":"/redfish/v1/Chassis/1","UUID":"not-a-uuid"}
    , null));
}

test "the vendor's answer comes out of the standard type's bag" {
    const supply = try core.parseJson(PowerSupply, testing.allocator,
        \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/3",
        \\ "Id":"3","Model":"ECD17020036",
        \\ "Oem":{"deltaenergysystems":{
        \\   "@odata.type":"#DeltaEnergySystemsPowerSupply.v1_0_0.PowerSupply",
        \\   "Power":true}}}
    , null);
    defer supply.deinit();

    try testing.expectEqual(@as(?bool, true), try vendorExtension(testing.allocator, &supply.value));

    // A supply from any other vendor is null rather than an error: "not that
    // vendor's hardware" is an answer, and a different one from "this is and
    // the payload is wrong".
    const other = try core.parseJson(PowerSupply, testing.allocator,
        \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/4","Id":"4"}
    , null);
    defer other.deinit();

    try testing.expectEqual(
        @as(?bool, null),
        try vendorExtension(testing.allocator, &other.value),
    );
}

// -- The guide shows this file ----------------------------------------------

/// A fenced block carrying this is code that must not compile or must not be
/// run, so it is not in this file and is not checked.
const wrong_marker = "// WRONG";

/// Where this file stops being the guide's.
const tests_marker = "// -- Tests";

test "doc/guide.md shows code that compiles" {
    const source = @embedFile("guide.zig");
    const guide = @embedFile("guide.md");
    const shown = source[0..std.mem.indexOf(u8, source, tests_marker).?];

    var checked: usize = 0;
    var rest: []const u8 = guide;
    while (std.mem.indexOf(u8, rest, "```zig\n")) |open| {
        const body = rest[open + "```zig\n".len ..];
        const close = std.mem.indexOf(u8, body, "```") orelse return error.UnterminatedBlock;
        const block = body[0..close];
        rest = body[close..];

        if (std.mem.indexOf(u8, block, wrong_marker) != null) continue;
        checked += 1;

        if (std.mem.indexOf(u8, shown, std.mem.trimEnd(u8, block, "\n")) == null) {
            std.debug.print(
                \\
                \\doc/guide.md shows a Zig block that examples/guide.zig does not contain:
                \\
                \\{s}
                \\
                \\Add it to examples/guide.zig, or mark the block `{s}` if it is
                \\code that must not compile.
                \\
            , .{ block, wrong_marker });
            return error.GuideOutOfDate;
        }
    }

    // A guide whose blocks were all renamed out of existence would otherwise
    // pass by checking nothing.
    try testing.expect(checked >= 5);
}
