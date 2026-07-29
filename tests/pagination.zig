//! Walking a real generated collection over a mock service.
//!
//! `core/collection.zig` tests the walk against a hand-written collection
//! shaped like the emitter's output. This drives the same code through the
//! actual `redfish_schema_std` types and the actual mock transport, so the
//! three pieces are checked against each other rather than each against its
//! own idea of the others: the emitter really does write the two annotation
//! fields, the walker really does find them under those names, and a real
//! `NavProperty(Chassis)` really is what comes back.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const ChassisCollection = schema.chassis_collection.ChassisCollection;

test "a paged chassis collection is walked to its end" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1/Chassis",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Name":"Chassis Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],
            \\ "Members@odata.count":2,
            \\ "Members@odata.nextLink":"/redfish/v1/Chassis?$skip=1"}
        ),
        mock.Expect.get("/redfish/v1/Chassis?$skip=1",
            \\{"@odata.id":"/redfish/v1/Chassis",
            \\ "@odata.type":"#ChassisCollection.ChassisCollection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/2U"}],
            \\ "Members@odata.count":2}
        ),
    });

    var walker: core.Walker(ChassisCollection) = .init(
        testing.allocator,
        &bmc.transport,
        .{ .value = "/redfish/v1/Chassis" },
    );
    defer walker.deinit();

    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| testing.allocator.free(id);
        ids.deinit(testing.allocator);
    }

    while (try walker.next()) |member| {
        try ids.append(testing.allocator, try testing.allocator.dupe(u8, member.odataId().?.value));
    }

    try testing.expectEqual(@as(usize, 2), ids.items.len);
    try testing.expectEqualStrings("/redfish/v1/Chassis/1U", ids.items[0]);
    try testing.expectEqualStrings("/redfish/v1/Chassis/2U", ids.items[1]);

    // Both pages were asked for, and nothing else was.
    try bmc.verify();
}

test "the walker's member type is the resource the collection links to" {
    // If the emitter ever stopped writing `Members` as a collection of links,
    // this would catch it before a caller had to.
    try testing.expect(core.collection.Member(ChassisCollection) ==
        core.NavProperty(schema.chassis.Chassis));
}

test "a recorded collection reports a total but no next page" {
    // The real thing, from DMTF's mockups: a complete response, so DSP0266
    // requires no next link -- which is exactly why no recorded payload can
    // exercise the paging path above.
    const recorded =
        \\{"@odata.id":"/redfish/v1/Chassis",
        \\ "@odata.type":"#ChassisCollection.ChassisCollection",
        \\ "Members":[{"@odata.id":"/redfish/v1/Chassis/1U"}],
        \\ "Members@odata.count":1,
        \\ "Name":"Chassis Collection"}
    ;

    const parsed = try std.json.parseFromSlice(
        ChassisCollection,
        testing.allocator,
        recorded,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(?i64, 1), parsed.value.@"Members@odata.count");
    try testing.expect(parsed.value.@"Members@odata.nextLink" == null);
}
