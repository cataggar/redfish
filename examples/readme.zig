//! `readme` — the program in the top-level README's "Getting started".
//!
//! Kept as a file and not only as a fenced block, because a README program
//! nobody compiles rots exactly as fast as an example nobody runs. The last
//! test below asserts that `README.md` still contains this file's body
//! verbatim, so the two cannot drift apart without the suite saying so.
//!
//! Everything below this comment, down to the tests, is what the README
//! shows.

const std = @import("std");
const core = @import("redfish_core");
const http = @import("redfish_bmc_http");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const Service = redfish.Service(schema.service_root.ServiceRoot);

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var bmc: http.HttpBmc = try .init(init.gpa, &client, "https://bmc.example", .{
        .credentials = .initBasic("root", "calvin"),
    });
    defer bmc.deinit();

    try run(init.gpa, bmc.asTransport(), out);
    return 0;
}

fn run(gpa: std.mem.Allocator, transport: *core.BmcTransport, out: *std.Io.Writer) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    try out.print("{s} {s}\n", .{
        service.vendor() orelse "?",
        service.product() orelse "?",
    });

    var chassis = try service.walk("Chassis");
    defer chassis.deinit();

    while (try chassis.next()) |link| {
        const one = try core.follow(schema.chassis.Chassis, gpa, transport, link);
        defer one.deinit();
        try out.print("  {s}\n", .{one.get().Name orelse "?"});
    }
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

test "the README program lists a service's chassis across a page boundary" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    // In request order, which is the proof the walk is lazy: the second page
    // is fetched after the first runs out, by which time the loop has already
    // followed a member of page one.
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1",
            \\{"@odata.id":"/redfish/v1",
            \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
            \\ "Id":"RootService","Name":"Root Service",
            \\ "Vendor":"Contoso","Product":"Contoso BMC",
            \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
        ),
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],
            \\ "Members@odata.count":2,
            \\ "Members@odata.nextLink":"/redfish/v1/Chassis?$skip=1"}
        ),
        mock.Expect.get("/redfish/v1/Chassis/1U",
            \\{"@odata.id":"/redfish/v1/Chassis/1U",
            \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\ "Id":"1U","Name":"Computer System Chassis"}
        ),
        mock.Expect.get("/redfish/v1/Chassis?$skip=1",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/Drawer"}],
            \\ "Members@odata.count":2}
        ),
        mock.Expect.get("/redfish/v1/Chassis/Drawer",
            \\{"@odata.id":"/redfish/v1/Chassis/Drawer",
            \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
            \\ "Id":"Drawer","Name":"Drawer Chassis"}
        ),
    });

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out);

    try testing.expectEqualStrings(
        \\Contoso Contoso BMC
        \\  Computer System Chassis
        \\  Drawer Chassis
        \\
    , out.buffered());

    try bmc.verify();
}

/// Where the README's copy stops. The tests below it are not part of the
/// program the README shows.
const tests_marker = "// -- Tests";

test "the README still shows this program" {
    const source = @embedFile("readme.zig");
    const readme = @embedFile("README.md");

    // Past the `//!` header, which is about the file rather than part of it.
    const start = std.mem.indexOf(u8, source, "const std = @import(\"std\");").?;
    const end = std.mem.indexOf(u8, source, tests_marker).?;
    const program = std.mem.trimEnd(u8, source[start..end], " \n");

    if (std.mem.indexOf(u8, readme, program) == null) {
        std.debug.print(
            \\
            \\README.md no longer contains examples/readme.zig verbatim.
            \\Replace the fenced block under "Getting started" with:
            \\
            \\{s}
            \\
        , .{program});
        return error.ReadmeOutOfDate;
    }
}
