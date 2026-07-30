//! `explore` — read a BMC's inventory: what it is, and what is in it.
//!
//! ```
//! explore --bmc https://bmc.example --username root --password calvin
//! ```
//!
//! ## Why this is one example and not three
//!
//! `nv-redfish` ships this program three times — `readme-minimal`,
//! `explore-with-dummy-bmc`, `explore-with-reqwest-bmc` — because there a BMC
//! is a *type parameter*: a program is generic over the `Bmc` trait, and each
//! instantiation is its own crate. `BmcTransport` here is a function-pointer
//! struct resolved at runtime, so the same machine code drives a real service
//! and a mock. Which one it got is an argument, not a build.
//!
//! That is what lets `run` below be both the example an operator runs and the
//! code the test at the bottom of this file exercises. An example that CI
//! cannot run is an example that stops compiling and nobody notices.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const cli = @import("cli.zig");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Chassis = schema.chassis.Chassis;
const ComputerSystem = schema.computer_system.ComputerSystem;

pub const usage =
    \\explore — read a Redfish service's inventory.
    \\
    \\Usage:
    \\  explore --bmc <url> [--username <name> --password <secret>]
    \\
    \\  --bmc <url>        Required, e.g. https://bmc.example.
    \\  --username <name>  Sent as HTTP Basic together with --password.
    \\  --password <secret>
    \\  -h, --help         This message.
    \\
;

/// The whole example.
///
/// Takes the transport rather than a URL, and a writer rather than printing,
/// so that the test below runs exactly this and reads what it produced.
pub fn run(gpa: std.mem.Allocator, transport: *core.BmcTransport, out: *std.Io.Writer) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    try out.print("{s} {s} — Redfish {s}\n", .{
        service.vendor() orelse "(no vendor)",
        service.product() orelse "(no product)",
        service.redfishVersion() orelse "?",
    });

    // What the service says it supports is worth printing, because it decides
    // how the walk below behaves: with `$expand` a collection comes back with
    // its members inline and `follow` costs no request, and without it the
    // same loop makes one request per member.
    if (service.expandQuery()) |expand| {
        try out.print("$expand: {f}", .{expand.expression});
        if (expand.levels) |levels| try out.print(" $levels={d}", .{levels});
        try out.writeByte('\n');
    } else {
        try out.writeAll("$expand: not supported\n");
    }

    try list(Chassis, gpa, &service, transport, out, "Chassis", describeChassis);
    try list(ComputerSystem, gpa, &service, transport, out, "Systems", describeSystem);
}

/// Walks one of the root's collections and prints a line per member.
///
/// Generic over the member type and the line, because the two collections
/// below differ in nothing else: every Redfish collection is walked and
/// followed the same way, and that sameness is the point of `Walker` and
/// `follow` existing at all.
fn list(
    comptime T: type,
    gpa: std.mem.Allocator,
    service: *const Service,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    comptime field: []const u8,
    comptime describe: fn (*const T, *std.Io.Writer) std.Io.Writer.Error!void,
) !void {
    if (!service.has(field)) {
        try out.print("\n{s}: not offered by this service\n", .{field});
        return;
    }

    try out.print("\n{s}:\n", .{field});

    var walker = try service.walk(field);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |link| {
        // `follow` fetches only when the service did not already expand the
        // link. Adding `$expand` to the walk above is the entire change
        // needed to stop this making requests.
        const member = try core.follow(T, gpa, transport, link);
        defer member.deinit();

        count += 1;
        try out.writeAll("  ");
        try describe(member.get(), out);
        try out.writeByte('\n');
    }

    if (count == 0) try out.writeAll("  (none)\n");
}

fn describeChassis(chassis: *const Chassis, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{s}", .{chassis.Name orelse chassis.Id orelse "(unnamed)"});
    if (chassis.ChassisType) |kind| try out.print(" [{t}]", .{kind});
    if (chassis.Manufacturer) |made_by| try out.print(" {s}", .{made_by});
    if (chassis.Model) |model| try out.print(" {s}", .{model});
    if (chassis.PowerState) |power| try out.print(" power={t}", .{power});
    try describeHealth(chassis.Status, out);
}

fn describeSystem(system: *const ComputerSystem, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{s}", .{system.Name orelse system.Id orelse "(unnamed)"});
    if (system.PowerState) |power| try out.print(" power={t}", .{power});
    if (system.ProcessorSummary) |summary| {
        if (summary.Count) |count| try out.print(" cpus={d}", .{count});
    }
    if (system.MemorySummary) |summary| {
        if (summary.TotalSystemMemoryGiB) |gib| try out.print(" memory={f}GiB", .{gib});
    }
    if (system.BiosVersion) |version| try out.print(" bios={s}", .{version});
    try describeHealth(system.Status, out);
}

/// `Status` is `resource.Status` on every resource that has one, so the one
/// spelling serves both lines above.
fn describeHealth(
    status: ?schema.resource.Status,
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const value = status orelse return;
    if (value.Health) |health| try out.print(" health={t}", .{health});
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

    const url = cli.flag(argv, "bmc") orelse {
        try out.writeAll("explore: --bmc is required\n\n" ++ usage);
        return 2;
    };

    var connection: cli.Connection = undefined;
    try connection.open(init.gpa, io, url, cli.credentialsFrom(argv));
    defer connection.close();

    try run(init.gpa, connection.transport(), out);
    return 0;
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "RedfishVersion":"1.18.0","Vendor":"Contoso","Product":"Contoso BMC",
    \\ "ProtocolFeaturesSupported":{
    \\   "ExpandQuery":{"ExpandAll":true,"Levels":true,"MaxLevels":3}},
    \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"},
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"}}
;

test "the example prints a service's inventory" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],
            \\ "Members@odata.count":1}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1U",
            \\{"@odata.id":"/redfish/v1/Chassis/1U",
            \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\ "Id":"1U","Name":"Computer System Chassis","ChassisType":"RackMount",
            \\ "Manufacturer":"Contoso","Model":"3500RX","PowerState":"On",
            \\ "Status":{"State":"Enabled","Health":"OK"}}
        ),
        mock.Expect.get("/redfish/v1/Systems",
            \\{"@odata.id":"/redfish/v1/Systems",
            \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Systems/437XR1138R2"}],
            \\ "Members@odata.count":1}
        ),
        mock.Expect.get("/redfish/v1/Systems/437XR1138R2",
            \\{"@odata.id":"/redfish/v1/Systems/437XR1138R2",
            \\ "@odata.type":"#ComputerSystem.v1_24_0.ComputerSystem",
            \\ "Id":"437XR1138R2","Name":"WebFrontEnd483","PowerState":"On",
            \\ "BiosVersion":"P79 v1.45",
            \\ "ProcessorSummary":{"Count":2,"Model":"Multi-Core Intel(R) Xeon(R)"},
            \\ "MemorySummary":{"TotalSystemMemoryGiB":96},
            \\ "Status":{"State":"Enabled","Health":"OK"}}
        ),
    });

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out);

    try testing.expectEqualStrings(
        \\Contoso Contoso BMC — Redfish 1.18.0
        \\$expand: * $levels=1
        \\
        \\Chassis:
        \\  Computer System Chassis [RackMount] Contoso 3500RX power=On health=OK
        \\
        \\Systems:
        \\  WebFrontEnd483 power=On cpus=2 memory=96GiB bios=P79 v1.45 health=OK
        \\
    , out.buffered());

    try bmc.verify();
}

test "a service that offers no Systems collection is not an error" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    // Every subordinate service is optional in the schema, and a service that
    // does not implement one simply omits the link -- so `has` is the check,
    // not a failed GET.
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1",
            \\{"@odata.id":"/redfish/v1",
            \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
            \\ "Id":"RootService","Name":"Root Service","RedfishVersion":"1.6.0",
            \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
        ),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[],"Members@odata.count":0}
        ),
    });

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out);

    try testing.expectEqualStrings(
        \\(no vendor) (no product) — Redfish 1.6.0
        \\$expand: not supported
        \\
        \\Chassis:
        \\  (none)
        \\
        \\Systems: not offered by this service
        \\
    , out.buffered());

    try bmc.verify();
}
