//! Pushing firmware, and the two properties that say where to push it.
//!
//! Ports `nv-redfish`'s `test-update-service.rs`. The mechanism is already
//! here — `core/upload.zig` writes the multipart form and `examples/
//! firmware_push.zig` drives the whole operation against the mock — so what
//! these tests add is the part that runs through a *generated* `UpdateService`:
//! the push URIs as optional properties, the inventory below them, and the
//! write-back of the deprecated push options.
//!
//! Two of the eight reference tests are not ported.
//!
//! `ami_viking_missing_root_update_service_nav_workaround` is
//! `*_missing_root_systems_nav` for the third time. `computer_system.zig`
//! argues it and `manager.zig` cites that argument; a third copy would assert
//! the same two lines of `Service.open` again. The answer is unchanged: a root
//! that does not link its update service says so at the point of asking, and a
//! caller that knows better reads the URI directly.
//!
//! `uses_multipart_http_push_uri` is ported, but not its answer. The
//! reference's mock replies `200` with a task-shaped body, which is not what a
//! service that has accepted an image does; the test below pins the `202` with
//! a `Location` and a `Retry-After` that DSP0266 describes, and the entity
//! outcome is pinned on the deprecated raw push, where a body is what a
//! service actually returns.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const SoftwareInventoryCollection =
    schema.software_inventory_collection.SoftwareInventoryCollection;
const Task = schema.task.Task;
const UpdateService = schema.update_service.UpdateService;
const UpdateServiceUpdate = schema.update_service.UpdateServiceUpdate;

const update_service_uri = "/redfish/v1/UpdateService";
const inventory_uri = "/redfish/v1/UpdateService/FirmwareInventory";
const multipart_uri = "/redfish/v1/UpdateService/update-multipart";
const push_uri = "/redfish/v1/UpdateService/update";

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService"}}
;

/// An update service offering both push URIs and its firmware inventory.
const update_service_body =
    \\{"@odata.id":"/redfish/v1/UpdateService",
    \\ "@odata.type":"#UpdateService.v1_15_0.UpdateService",
    \\ "Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,
    \\ "HttpPushUri":"/redfish/v1/UpdateService/update",
    \\ "MultipartHttpPushUri":"/redfish/v1/UpdateService/update-multipart",
    \\ "FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"}}
;

/// Root, then the update service, which is how every test here starts.
fn openUpdateService(
    bmc: *mock.MockBmc,
    service: *Service,
    body: []const u8,
) !core.Resolved(UpdateService) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get(update_service_uri, body),
    });

    service.* = try Service.connect(testing.allocator, &bmc.transport);
    errdefer service.deinit();
    return service.open("UpdateService");
}

// -- The inventory ---------------------------------------------------------

test "a firmware inventory whose release dates are not dates" {
    // `list_dell_fw_inventores`. A Dell reports `"ReleaseDate": "00:00:00Z"`
    // for a component it has no date for, and `"0000-00-00T00:00:00Z"` for
    // the next one, which is the same nothing spelled two ways. The schema
    // invites the first of them: `SoftwareInventory.ReleaseDate` says the
    // time-of-day portion shall be `00:00:00Z` when the time is unknown, and
    // a service with no date at all writes that part and stops.
    //
    // `nv-redfish` patches both behind a platform fingerprint. Nothing here
    // knows about Dell: `DateTimeOffset.spellsAbsence` reads any timestamp
    // whose every digit is zero as absent, and it was written in #54 partly
    // to retire this case before the test that needed it was ported. That it
    // covers `"00:00:00Z"` — which is not even a timestamp shape — falls out
    // of the rule being about digits rather than about layout.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service, update_service_body);
    defer service.deinit();
    defer update_service.deinit();

    try bmc.expect(mock.Expect.expand(inventory_uri,
        \\{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory",
        \\ "@odata.type":"#SoftwareInventoryCollection.SoftwareInventoryCollection",
        \\ "Name":"Firmware Inventory Collection",
        \\ "Members":[
        \\  {"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory/Installed-0-1.0.0",
        \\   "@odata.type":"#SoftwareInventory.v1_4_0.SoftwareInventory",
        \\   "Id":"Installed-0-1.0.0","Name":"PCIe SSD in Slot 0 in Bay 1",
        \\   "ReleaseDate":"00:00:00Z","SoftwareId":"0",
        \\   "Status":{"Health":"OK","State":"Enabled"},
        \\   "Updateable":true,"Version":"1.0.0"},
        \\  {"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory/Installed-0-3.0.0",
        \\   "@odata.type":"#SoftwareInventory.v1_4_0.SoftwareInventory",
        \\   "Id":"Installed-0-3.0.0","Name":"PCIe SSD in Slot 0 in Bay 2",
        \\   "ReleaseDate":"0000-00-00T00:00:00Z","SoftwareId":"0",
        \\   "Status":{"Health":"OK","State":"Enabled"},
        \\   "Updateable":true,"Version":"3.0.0"}]}
    ));

    const link = update_service.get().FirmwareInventory orelse return error.NoInventory;
    const inventory = try core.bmc.expand(
        SoftwareInventoryCollection,
        testing.allocator,
        &bmc.transport,
        link.odataId() orelse return error.NotAddressable,
        service.expandQuery().?,
    );
    defer inventory.deinit();

    const members = inventory.value.Members.?;
    try testing.expectEqual(@as(usize, 2), members.len);

    for (members, [_][]const u8{ "1.0.0", "3.0.0" }) |member, version| {
        const software = member.value() orelse return error.NotExpanded;
        try testing.expect(software.ReleaseDate == null);

        // The whole component survived the date it did not have, which is the
        // only reason the rule exists.
        try testing.expectEqualStrings(version, software.Version.?);
        try testing.expectEqual(true, software.Updateable.?);
        try testing.expectEqual(schema.resource.Health.OK, software.Status.?.Health.?);
    }

    try bmc.verify();
}

test "an update service with no name is still an update service" {
    // `ami_viking_missing_update_service_name_workaround`. `Name` is
    // `Redfish.Required` and this service omits it; the reference substitutes
    // the string "Unnamed update service" so that a required field can be
    // non-optional in Rust.
    //
    // There is nothing to substitute for. This generator does not enforce
    // `Redfish.Required` — decided once, during the corpus sweep, for every
    // required property in every schema — so the property is `?Name` like any
    // other and its absence is a `null` the caller can see. Inventing a name
    // would be worse than the absence: a caller cannot tell an invented name
    // from one the service chose.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service,
        \\{"@odata.id":"/redfish/v1/UpdateService",
        \\ "@odata.type":"#UpdateService.v1_9_0.UpdateService",
        \\ "Id":"UpdateService",
        \\ "FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"}}
    );
    defer service.deinit();
    defer update_service.deinit();

    try testing.expect(update_service.get().Name == null);
    try testing.expectEqualStrings("UpdateService", update_service.get().Id.?);
    try testing.expect(update_service.get().FirmwareInventory != null);
    try bmc.verify();
}

// -- Pushing ---------------------------------------------------------------

test "a push carries the parameters, the image, and a part the caller added" {
    // `uses_multipart_http_push_uri` and
    // `uses_generated_update_parameters_with_oem_parts`, which are one test
    // with and without an OEM part, so they are one test here.
    //
    // The parameters are an anonymous struct. DSP0266 defines the
    // `UpdateParameters` part inline and no CSDL entity describes it, so there
    // is no generated type to use and `multipartUpdate` asks for `anytype`
    // rather than inventing one. The `Oem` member is generated —
    // `resource.OemUpdate` is an open struct — which is the half of the
    // reference's `MultipartUpdateParameters` that a schema does describe.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service, update_service_body);
    defer service.deinit();
    defer update_service.deinit();

    try bmc.expect(mock.Expect.multipartPush(multipart_uri, .{
        .status = 202,
        .location = "/redfish/v1/TaskService/Tasks/42",
        .retry_after = 10,
    }));

    const nvidia = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"Mode":"Rms"}
    ,
        .{},
    );
    defer nvidia.deinit();

    var oem: core.AdditionalProperties = .{};
    defer oem.map.deinit(testing.allocator);
    try oem.map.put(testing.allocator, "Nvidia", nvidia.value);

    var image: std.Io.Reader = .fixed("firmware");
    var manifest: std.Io.Reader = .fixed("{\"Mode\":\"Rms\"}");
    var prng: std.Random.DefaultPrng = .init(1);

    const target = update_service.get().MultipartHttpPushUri orelse return error.NoPushUri;
    const pushed = try core.upload.multipartUpdate(
        Task,
        testing.allocator,
        &bmc.transport,
        .init(target),
        .{
            .ForceUpdate = true,
            .Targets = [_][]const u8{"/redfish/v1/Systems/1"},
            .Oem = schema.resource.OemUpdate{ .additional_properties = oem },
        },
        .{ .name = "firmware.bin", .reader = &image, .len = "firmware".len },
        &.{.{
            .name = "OemNvidia",
            .reader = &manifest,
            .content_type = "application/json",
            .len = "{\"Mode\":\"Rms\"}".len,
        }},
        prng.random(),
    );
    defer pushed.deinit();

    const push = bmc.request(2);
    try testing.expect(std.mem.startsWith(u8, push.content_type, "multipart/form-data; boundary="));
    try testing.expect(std.mem.indexOf(u8, push.body,
        \\{"ForceUpdate":true,"Targets":["/redfish/v1/Systems/1"],"Oem":{"Nvidia":{"Mode":"Rms"}}}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, push.body, "name=\"OemNvidia\"") != null);
    try testing.expect(std.mem.indexOf(u8, push.body, "{\"Mode\":\"Rms\"}") != null);

    // The whole point of the operation: the service took the image and will
    // apply it without the connection, and said how long to wait first.
    const task = pushed.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/42", task.location.value.value);
    try testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), task.retryAfterNanoseconds().?);

    try bmc.verify();
}

test "the deprecated raw push is still the only one many services implement" {
    // `uses_http_push_uri_without_update_parameters`. `HttpPushUri` takes the
    // image as the entire body, so there is nowhere to put parameters and
    // nothing to encode: the request is the bytes, matched here exactly,
    // which the multipart form can never be.
    //
    // This is also where the entity outcome belongs. A raw push answered with
    // a body is answered with the service's own reply — the reference decodes
    // `{"Result": "accepted"}`, which is not a Redfish resource and is not
    // required to be one, so the type is the caller's to name.
    const UploadResponse = struct { Result: []const u8 };

    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service, update_service_body);
    defer service.deinit();
    defer update_service.deinit();

    try bmc.expect(.{ .request = .{
        .match = .{
            .method = .post,
            .uri = .{ .exact = push_uri },
            .body = .{ .bytes = "firmware" },
            .content_type = "application/octet-stream",
        },
        .reply = .{ .response = .{ .body = "{\"Result\":\"accepted\"}" } },
    } });

    var image: std.Io.Reader = .fixed("firmware");
    const target = update_service.get().HttpPushUri orelse return error.NoPushUri;
    const pushed = try core.upload.httpPushUriUpdate(
        UploadResponse,
        testing.allocator,
        &bmc.transport,
        .init(target),
        &image,
        "firmware".len,
    );
    defer pushed.deinit();

    try testing.expectEqualStrings("accepted", (try pushed.value.expectEntity()).Result);
    try bmc.verify();
}

test "a service with nowhere to push has no error to report" {
    // `requires_multipart_http_push_uri` and `requires_http_push_uri`. The
    // reference has an error case for each — `UpdateServiceMultipartHttpPush
    // UriNotAvailable` and its sibling — raised from inside the upload call
    // when the service named no URI.
    //
    // Both properties are optional in the schema and both are `null` here, so
    // a caller that cannot push finds out by looking rather than by failing,
    // before it has opened the image or built a form. There is no error to
    // define, and one defined anyway would be an error the caller can only
    // reach by not looking first.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service,
        \\{"@odata.id":"/redfish/v1/UpdateService",
        \\ "@odata.type":"#UpdateService.v1_15_0.UpdateService",
        \\ "Id":"UpdateService","Name":"Update Service","ServiceEnabled":true}
    );
    defer service.deinit();
    defer update_service.deinit();

    try testing.expect(update_service.get().MultipartHttpPushUri == null);
    try testing.expect(update_service.get().HttpPushUri == null);

    // Two requests, and neither of them was an upload begun on the chance
    // that a URI nobody advertised might work.
    try testing.expectEqual(@as(usize, 2), bmc.requestCount());
    try bmc.verify();
}

// -- Writing ---------------------------------------------------------------

test "the push options a caller writes back before a raw push" {
    // `patches_http_push_uri_options_and_targets`. Everything the deprecated
    // push cannot carry in its body is instead PATCHed onto the update
    // service first, which is why these four properties exist at all and why
    // two of them are named `...Busy`: a client sets the targets, does the
    // push, and clears them.
    //
    // `HttpPushUriTargetsBusy` is `Nullable(bool)` rather than `?bool`
    // because clearing it means writing JSON `null`, and a caller that meant
    // "leave it alone" writes nothing. The payload below is the evidence:
    // `ServiceEnabled` was not set and does not appear.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    var service: Service = undefined;
    const update_service = try openUpdateService(&bmc, &service, update_service_body);
    defer service.deinit();
    defer update_service.deinit();

    try bmc.expect(mock.Expect.patch(update_service_uri,
        \\{"HttpPushUriTargets":["/redfish/v1/Systems/1"],
        \\ "HttpPushUriTargetsBusy":true,
        \\ "HttpPushUriOptions":{"ForceUpdate":true},
        \\ "HttpPushUriOptionsBusy":true}
    , update_service_body));

    const written = try service.update(UpdateService, update_service.get(), UpdateServiceUpdate{
        .HttpPushUriTargets = &.{"/redfish/v1/Systems/1"},
        .HttpPushUriTargetsBusy = .init(true),
        .HttpPushUriOptions = .{ .ForceUpdate = true },
        .HttpPushUriOptionsBusy = .init(true),
    });
    defer written.deinit();

    const updated = try written.value.expectEntity();
    try testing.expectEqualStrings(push_uri, updated.HttpPushUri.?);
    try bmc.verify();
}
