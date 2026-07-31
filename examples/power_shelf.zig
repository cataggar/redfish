//! `power_shelf` — is this power supply outputting power, and how do you ask?
//!
//! ```
//! power_shelf --bmc https://bmc.example --username root --password calvin
//! power_shelf --bmc https://bmc.example --standard-only
//! ```
//!
//! The standard `PowerSupply` schema does not ask that question. Two vendors
//! answer it anyway, in two different places, and a program that wants the
//! answer has to know both — which is what this example is for. It is the one
//! example that names a vendor, and the only vendor-specific code in it is the
//! two constants below and the two short functions marked `-- Delta --` and
//! `-- LiteOn --`. That is the shape the whole suite argues for: read the type
//! you want, tolerate what you get, and keep the vendor knowledge in your own
//! code.
//!
//! **Delta** writes `Oem/deltaenergysystems/Power`, which is the extension
//! point DSP0266 reserves. The resource is still a `PowerSupply`, the standard
//! type still reads it, and a client that has never heard of Delta loses only
//! what Delta added. `core.oem.parse` is the whole access path, the key is the
//! fingerprint, and finding it costs nothing.
//!
//! **LiteOn** declares `PowerState` as a property on a type derived from
//! `PowerSupply`, and writes it at the top level of the resource. `Oem` is
//! empty; there is no key to find. So the standard type reads the same bytes
//! **successfully** and drops the only property worth reading — because
//! `ignore_unknown_fields` cannot tell a vendor's property from a standard one
//! this package was generated too early to know. Nothing errors. The answer is
//! simply gone.
//!
//! That is why `--standard-only` exists. It runs the same walk with the two
//! vendor branches removed, against the same service, and the LiteOn shelf
//! reports `unknown` where the vendor-aware run reports `on`. Run it both ways
//! before you trust a field: a property your type does not declare is dropped
//! in silence, and this is what that silence looks like.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");
const delta = @import("redfish_schema_oem_delta");
const liteon = @import("redfish_schema_oem_liteon");

const cli = @import("cli.zig");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const PowerSubsystem = schema.power_subsystem.PowerSubsystem;
const PowerSupply = schema.power_supply.PowerSupply;
const PowerSupplyCollection = schema.power_supply_collection.PowerSupplyCollection;

/// Delta's key. Not `Delta`, which is the `Manufacturer` on the same resource,
/// and not `DeltaEnergySystemsPowerSupply`, which is the namespace the payload
/// announces. DSP0266 leaves the name to the vendor, so it is read off the
/// wire and never derived.
const delta_key = "deltaenergysystems";
const DeltaPowerSupply = delta.delta_energy_systems_power_supply.PowerSupply;

/// LiteOn signs nothing. No key, no `@odata.type` of its own, no property name
/// a standard schema would not eventually claim — this string on the chassis
/// is the only fingerprint there is.
const liteon_manufacturer = "LITE-ON TECHNOLOGY CORP.";
const LiteonPowerSupply = liteon.liteon_power_supply.LiteonPowerSupply;
const LiteonPowerSupplyCollection =
    liteon.liteon_power_supply_collection.LiteonPowerSupplyCollection;

pub const usage =
    \\power_shelf — report whether each power supply is outputting power.
    \\
    \\Usage:
    \\  power_shelf --bmc <url> [--username <name>] [--password <secret>]
    \\              [--standard-only]
    \\
    \\  --bmc <url>        Required, e.g. https://bmc.example.
    \\  --standard-only    Read only standard types, with no vendor knowledge.
    \\                     Shows what a LiteOn shelf loses in silence.
    \\  -h, --help         This message.
    \\
;

/// Whether a supply is outputting power, and `unknown` when nothing said.
///
/// `unknown` is a third answer and not a default. A supply that is off and a
/// supply nobody asked are different facts, and a reader that collapsed them
/// would report a live shelf as one that had stopped.
const Outputting = enum { on, off, unknown };

/// How much the caller is willing to know about specific vendors.
pub const Knowledge = enum { vendors, standard_only };

pub fn run(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    knowledge: Knowledge,
) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, gpa, transport, link);
        defer chassis.deinit();

        try out.print("{s} ({s})\n", .{
            chassis.get().Id orelse "?",
            chassis.get().Manufacturer orelse "no manufacturer",
        });

        try report(gpa, transport, out, chassis.get(), knowledge);
    }
}

/// Every power supply under one chassis.
///
/// The subsystem is held for the whole of this function and released last.
/// `core.follow` returns a `Resolved` that owns its arena only when it had to
/// fetch; a service that expanded `PowerSupplies` inline hands back a value
/// borrowing the subsystem's page, and releasing the subsystem first would
/// free the collection out from under the loop. `wasFetched()` is what tells
/// the two apart when a caller needs to know; outliving the parent is what
/// makes not needing to know safe.
fn report(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    chassis: *const Chassis,
    knowledge: Knowledge,
) !void {
    const subsystem = try core.follow(
        PowerSubsystem,
        gpa,
        transport,
        chassis.PowerSubsystem orelse return,
    );
    defer subsystem.deinit();

    const supplies = subsystem.get().PowerSupplies orelse return;

    // -- LiteOn -------------------------------------------------------------
    // The fingerprint is checked against a chassis already in hand, so a shelf
    // some other vendor built costs no further request.
    if (knowledge == .vendors and isLiteon(chassis)) {
        return reportLiteon(gpa, transport, out, supplies);
    }

    const page = try core.follow(PowerSupplyCollection, gpa, transport, supplies);
    defer page.deinit();

    for (page.get().Members orelse &.{}) |member| {
        const supply = try core.follow(PowerSupply, gpa, transport, member);
        defer supply.deinit();

        // -- Delta ----------------------------------------------------------
        // Three answers, not two: no `Oem` at all, no `deltaenergysystems` in
        // it, or a value that does not decode. Only the last is an error, and
        // `core.oem.parse` keeps them apart so a malformed extension is not
        // read as absent hardware.
        var outputting: Outputting = .unknown;
        if (knowledge == .vendors) {
            const found = try core.oem.parse(
                DeltaPowerSupply,
                gpa,
                supply.get().Oem,
                delta_key,
            );
            if (found) |extension| {
                defer extension.deinit();
                if (extension.value.Power) |power| outputting = if (power) .on else .off;
            }
        }

        try describe(out, supply.get().Id, supply.get().Model, outputting);
    }
}

/// Whether this chassis is a LiteOn power shelf.
fn isLiteon(chassis: *const Chassis) bool {
    const manufacturer = chassis.Manufacturer orelse return false;
    return std.mem.eql(u8, manufacturer, liteon_manufacturer);
}

/// The same supplies, read as LiteOn's derived type.
///
/// `downcast` re-labels the link and fetches nothing: a Redfish subtype shares
/// its base's URI, so reading a `LiteonPowerSupplyCollection` where the schema
/// declared a `PowerSupplyCollection` costs no extra request. It answers null
/// only for a link the service already expanded inline, which has no URI to
/// re-label — ask for the collection unexpanded and it is a reference again.
fn reportLiteon(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    supplies: core.NavProperty(PowerSupplyCollection),
) !void {
    const typed = supplies.downcast(LiteonPowerSupplyCollection) orelse return;

    const page = try core.follow(LiteonPowerSupplyCollection, gpa, transport, typed);
    defer page.deinit();

    for (page.get().Members orelse &.{}) |member| {
        const supply = try core.follow(LiteonPowerSupply, gpa, transport, member);
        defer supply.deinit();

        const outputting: Outputting = if (supply.get().PowerState) |on|
            if (on) .on else .off
        else
            .unknown;

        try describe(out, supply.get().Id, supply.get().Model, outputting);
    }
}

fn describe(
    out: *std.Io.Writer,
    id: ?[]const u8,
    model: ?[]const u8,
    outputting: Outputting,
) !void {
    try out.print("  {s} {s}: {t}\n", .{ id orelse "?", model orelse "?", outputting });
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const argv = try cli.arguments(arena, init);
    if (cli.present(argv, "help") or cli.present(argv, "h")) {
        try out.writeAll(usage);
        return 0;
    }

    const base_url = cli.flag(argv, "bmc") orelse {
        try out.writeAll("power_shelf: --bmc is required\n\n" ++ usage);
        return 2;
    };

    var connection: cli.Connection = undefined;
    try connection.open(init.gpa, io, base_url, cli.credentialsFrom(argv));
    defer connection.close();

    try run(
        init.gpa,
        connection.transport(),
        out,
        if (cli.present(argv, "standard-only")) .standard_only else .vendors,
    );
    return 0;
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

const chassis_collection =
    \\{"@odata.id":"/redfish/v1/Chassis",
    \\ "@odata.type":"#ChassisCollection.ChassisCollection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1"},
    \\            {"@odata.id":"/redfish/v1/Chassis/powershelf"},
    \\            {"@odata.id":"/redfish/v1/Chassis/acme"}]}
;

const delta_chassis =
    \\{"@odata.id":"/redfish/v1/Chassis/1",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"1","Name":"chassis","Manufacturer":"DELTA",
    \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem"}}
;

const delta_subsystem =
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem",
    \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
    \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies"}}
;

const delta_supplies =
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies",
    \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/3"},
    \\            {"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/4"}]}
;

const delta_supply_3 =
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/3",
    \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
    \\ "Id":"3","Manufacturer":"Delta","Model":"ECD17020036",
    \\ "Oem":{"deltaenergysystems":{
    \\   "@odata.type":"#DeltaEnergySystemsPowerSupply.v1_0_0.PowerSupply",
    \\   "Power":true,"FanSpeedTarget":0}}}
;

const delta_supply_4 =
    \\{"@odata.id":"/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/4",
    \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
    \\ "Id":"4","Manufacturer":"Delta","Model":"ECD17020036",
    \\ "Oem":{"deltaenergysystems":{
    \\   "@odata.type":"#DeltaEnergySystemsPowerSupply.v1_0_0.PowerSupply",
    \\   "Power":false,"FanSpeedTarget":30}}}
;

const liteon_shelf =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"powershelf","Name":"powershelf","ChassisType":"Shelf",
    \\ "Manufacturer":"LITE-ON TECHNOLOGY CORP.",
    \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem"}}
;

const liteon_subsystem =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem",
    \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
    \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies"}}
;

const liteon_supplies =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies",
    \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies/0"}]}
;

/// LiteOn's `PowerState` sits at the top level, beside `Model`, and the `Oem`
/// bag DSP0266 reserved for exactly this is not present at all.
const liteon_supply =
    \\{"@odata.id":"/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies/0",
    \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
    \\ "Id":"0","Manufacturer":"LITE-ON TECHNOLOGY CORP.","Model":"SP-2552-1R",
    \\ "PowerState":true}
;

/// A chassis from a vendor this program has never heard of, with a supply that
/// answers the question nowhere. `unknown` here is the correct answer.
const acme_chassis =
    \\{"@odata.id":"/redfish/v1/Chassis/acme",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"acme","Name":"acme","Manufacturer":"ACME Corp.",
    \\ "PowerSubsystem":{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem"}}
;

const acme_subsystem =
    \\{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem",
    \\ "@odata.type":"#PowerSubsystem.v1_1_0.PowerSubsystem",
    \\ "PowerSupplies":{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies"}}
;

const acme_supplies =
    \\{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies",
    \\ "@odata.type":"#PowerSupplyCollection.PowerSupplyCollection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies/1"}]}
;

const acme_supply =
    \\{"@odata.id":"/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies/1",
    \\ "@odata.type":"#PowerSupply.v1_5_0.PowerSupply",
    \\ "Id":"1","Manufacturer":"ACME Corp.","Model":"AC-1"}
;

/// The whole fleet, in the order the program reads it.
fn expectFleet(bmc: *mock.MockBmc) !void {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_chassis),
        mock.Expect.get("/redfish/v1/Chassis", chassis_collection),

        mock.Expect.get("/redfish/v1/Chassis/1", delta_chassis),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem", delta_subsystem),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies", delta_supplies),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/3", delta_supply_3),
        mock.Expect.get("/redfish/v1/Chassis/1/PowerSubsystem/PowerSupplies/4", delta_supply_4),

        mock.Expect.get("/redfish/v1/Chassis/powershelf", liteon_shelf),
        mock.Expect.get("/redfish/v1/Chassis/powershelf/PowerSubsystem", liteon_subsystem),
        mock.Expect.get(
            "/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies",
            liteon_supplies,
        ),
        mock.Expect.get(
            "/redfish/v1/Chassis/powershelf/PowerSubsystem/PowerSupplies/0",
            liteon_supply,
        ),

        mock.Expect.get("/redfish/v1/Chassis/acme", acme_chassis),
        mock.Expect.get("/redfish/v1/Chassis/acme/PowerSubsystem", acme_subsystem),
        mock.Expect.get("/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies", acme_supplies),
        mock.Expect.get("/redfish/v1/Chassis/acme/PowerSubsystem/PowerSupplies/1", acme_supply),
    });
}

test "two vendors answer the same question in two different places" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try expectFleet(&bmc);

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, .vendors);

    try testing.expectEqualStrings(
        \\1 (DELTA)
        \\  3 ECD17020036: on
        \\  4 ECD17020036: off
        \\powershelf (LITE-ON TECHNOLOGY CORP.)
        \\  0 SP-2552-1R: on
        \\acme (ACME Corp.)
        \\  1 AC-1: unknown
        \\
    , out.buffered());

    try bmc.verify();
}

test "without the vendor knowledge, LiteOn's answer is lost and nothing says so" {
    // The same service, the same bytes, the same number of requests — and one
    // fewer answer. Delta survives because Delta used `Oem`, which the
    // standard type carries whole; LiteOn does not, because its property is
    // one `ignore_unknown_fields` drops without a word.
    //
    // This is the cost of the tolerance model stated as a program. It is not
    // a defect in the parse and there is no rule that would fix it: a property
    // a vendor added and a property a newer standard schema added arrive
    // identically, and dropping the second is the behaviour that lets this
    // client talk to a service newer than itself.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try expectFleet(&bmc);

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, .standard_only);

    try testing.expectEqualStrings(
        \\1 (DELTA)
        \\  3 ECD17020036: unknown
        \\  4 ECD17020036: unknown
        \\powershelf (LITE-ON TECHNOLOGY CORP.)
        \\  0 SP-2552-1R: unknown
        \\acme (ACME Corp.)
        \\  1 AC-1: unknown
        \\
    , out.buffered());

    // No error was returned and no property was rejected. The LiteOn supply
    // parsed clean into `PowerSupply`, which has no field to put `PowerState`
    // in and never will.
    try testing.expect(!@hasField(PowerSupply, "PowerState"));

    try bmc.verify();
}
