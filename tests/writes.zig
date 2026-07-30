//! Writing through the real generated schema and a mock BMC.
//!
//! The case worth pinning is `Bios`, because the obvious call is the wrong
//! one. `Bios.Attributes` is read-only on the `Bios` resource; the writable
//! copy is at the URI in `@Redfish.Settings.SettingsObject`, and DSP0266 lets a
//! service accept a PATCH to the resource itself and do nothing with it. So a
//! client that writes the resource gets a 200 back and no change made.
//!
//! These tests assert the two calls address two different URIs, which is the
//! whole content of the distinction.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Bios = schema.bios.Bios;
const bios_uri = "/redfish/v1/Systems/437XR1138R2/Bios";
const settings_uri = "/redfish/v1/Systems/437XR1138R2/Bios/Settings";

/// The shape of DMTF's own `Bios` mockup, trimmed to what these tests read.
const bios_body =
    \\{"@odata.id":"/redfish/v1/Systems/437XR1138R2/Bios",
    \\ "@odata.type":"#Bios.v1_3_0.Bios",
    \\ "@odata.etag":"W/\"1234\"",
    \\ "Id":"BIOS","Name":"BIOS Configuration Current Settings",
    \\ "AttributeRegistry":"BiosAttributeRegistryP89.v1_0_0",
    \\ "Attributes":{"BootMode":"Uefi","ProcTurboMode":"Enabled"},
    \\ "@Redfish.Settings":{
    \\   "@odata.type":"#Settings.v1_5_0.Settings",
    \\   "SettingsObject":{"@odata.id":"/redfish/v1/Systems/437XR1138R2/Bios/Settings"},
    \\   "Time":"2016-03-07T14:44.30-05:00"}}
;

fn parseBios(gpa: std.mem.Allocator) !std.json.Parsed(Bios) {
    return std.json.parseFromSlice(Bios, gpa, bios_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "a resource names the settings object rather than itself" {
    const parsed = try parseBios(testing.allocator);
    defer parsed.deinit();

    const target = core.entity.pendingSettings(parsed.value).?;
    try testing.expectEqualStrings(settings_uri, target.value);

    // The point of the annotation is that these differ.
    try testing.expectEqualStrings(bios_uri, core.entity.id(parsed.value).?.value);
    try testing.expect(!std.mem.eql(u8, target.value, core.entity.id(parsed.value).?.value));
}

test "a resource that takes writes directly reports no pending settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        schema.chassis.Chassis,
        arena.allocator(),
        \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U","Name":"Computer System Chassis"}
    ,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    try testing.expectEqual(@as(?core.ODataId, null), core.entity.pendingSettings(parsed));
}

test "writing pending settings addresses the settings object" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.patchNoContent(
        settings_uri,
        \\{"Attributes":{"ProcTurboMode":"Disabled"}}
        ,
    ));

    const parsed = try parseBios(testing.allocator);
    defer parsed.deinit();

    const written = try core.bmc.updatePending(
        Bios,
        testing.allocator,
        &bmc.transport,
        parsed.value,
        .{ .Attributes = .{ .ProcTurboMode = "Disabled" } },
    );
    defer written.deinit();

    try bmc.verify();

    // No `If-Match`. `Settings.ETag` is the tag of the resource *after* the
    // settings are applied, so sending it would compare against the wrong
    // resource; the `Bios` ETag belongs to the `Bios`, not to this URI.
    try testing.expect(bmc.requests.items[0].if_match == null);
}

test "the ordinary write addresses the resource, conditionally" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.patchNoContent(
        bios_uri,
        \\{"Attributes":{"ProcTurboMode":"Disabled"}}
        ,
    ));

    const parsed = try parseBios(testing.allocator);
    defer parsed.deinit();

    const written = try core.bmc.updateEntity(
        Bios,
        testing.allocator,
        &bmc.transport,
        parsed.value,
        .{ .Attributes = .{ .ProcTurboMode = "Disabled" } },
    );
    defer written.deinit();

    try bmc.verify();

    // The resource's own ETag applies here, and this is the write a service is
    // free to ignore for `Bios`.
    try testing.expectEqualStrings("W/\"1234\"", bmc.requests.items[0].if_match.?);
}

test "a resource with no settings annotation refuses the deferred write" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const chassis = try std.json.parseFromSliceLeaky(
        schema.chassis.Chassis,
        arena.allocator(),
        \\{"@odata.id":"/redfish/v1/Chassis/1U","Id":"1U","Name":"Chassis"}
    ,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    try testing.expectError(core.bmc.Error.NoPendingSettings, core.bmc.updatePending(
        schema.chassis.Chassis,
        testing.allocator,
        &bmc.transport,
        chassis,
        .{ .AssetTag = "x" },
    ));

    // Nothing was sent: there was no URI to send it to.
    try testing.expectEqual(@as(usize, 0), bmc.requests.items.len);
}
