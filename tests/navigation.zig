//! Reading through links in the real generated package.
//!
//! `core/resolve.zig` proves `follow` against a hand-written resource. This
//! proves the thing that actually matters about it: that adding `$expand` to
//! a request is the *only* change a caller has to make to stop paying for a
//! round trip. The same loop runs twice below, once against a service that
//! expands and once against one that does not, and the assertions about what
//! was read are identical — only the request count differs.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Chassis = schema.chassis.Chassis;
const Thermal = schema.thermal.Thermal;

/// The chassis as a service that does not expand returns it: `Thermal` is a
/// bare link.
const referenced =
    \\{"@odata.id":"/redfish/v1/Chassis/1U",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"1U","Name":"Computer System Chassis",
    \\ "Thermal":{"@odata.id":"/redfish/v1/Chassis/1U/Thermal"}}
;

/// The same chassis under `$expand`: `Thermal` arrives inline.
const expanded =
    \\{"@odata.id":"/redfish/v1/Chassis/1U",
    \\ "@odata.type":"#Chassis.v1_25_0.Chassis",
    \\ "Id":"1U","Name":"Computer System Chassis",
    \\ "Thermal":{"@odata.id":"/redfish/v1/Chassis/1U/Thermal",
    \\            "@odata.type":"#Thermal.v1_7_1.Thermal",
    \\            "Id":"Thermal","Name":"Thermal"}}
;

const thermal_body =
    \\{"@odata.id":"/redfish/v1/Chassis/1U/Thermal",
    \\ "@odata.type":"#Thermal.v1_7_1.Thermal",
    \\ "Id":"Thermal","Name":"Thermal"}
;

/// Reads a chassis and the thermal subsystem behind its link, without knowing
/// or caring which form the service used.
fn readThermalName(bmc: *mock.MockBmc, gpa: std.mem.Allocator, buf: []u8) ![]const u8 {
    const chassis = try core.bmc.get(Chassis, gpa, &bmc.transport, .{ .value = "/redfish/v1/Chassis/1U" });
    defer chassis.deinit();

    const thermal = try core.follow(Thermal, gpa, &bmc.transport, chassis.value.Thermal.?);
    defer thermal.deinit();

    const name = thermal.get().Name.?;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

test "expanding a request is the only change needed to skip a round trip" {
    var buf: [64]u8 = undefined;

    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();
        try bmc.expectAll(&.{
            mock.Expect.get("/redfish/v1/Chassis/1U", referenced),
            mock.Expect.get("/redfish/v1/Chassis/1U/Thermal", thermal_body),
        });

        try testing.expectEqualStrings("Thermal", try readThermalName(&bmc, testing.allocator, &buf));
        try testing.expectEqual(@as(usize, 2), bmc.requestCount());
        try bmc.verify();
    }

    {
        var bmc: mock.MockBmc = .init(testing.allocator);
        defer bmc.deinit();
        try bmc.expect(mock.Expect.get("/redfish/v1/Chassis/1U", expanded));

        // Same function, same result, one request instead of two.
        try testing.expectEqualStrings("Thermal", try readThermalName(&bmc, testing.allocator, &buf));
        try testing.expectEqual(@as(usize, 1), bmc.requestCount());
        try bmc.verify();
    }
}

test "an expanded link is not fetched even though it carries an id" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.get("/redfish/v1/Chassis/1U", expanded));

    const chassis = try core.bmc.get(Chassis, testing.allocator, &bmc.transport, .{ .value = "/redfish/v1/Chassis/1U" });
    defer chassis.deinit();

    const link = chassis.value.Thermal.?;
    try testing.expect(link.isExpanded());
    try testing.expectEqualStrings("/redfish/v1/Chassis/1U/Thermal", link.odataId().?.value);

    const thermal = try core.follow(Thermal, testing.allocator, &bmc.transport, link);
    defer thermal.deinit();

    try testing.expect(!thermal.wasFetched());
    try bmc.verify();
}
