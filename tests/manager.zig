//! The manager, which is the one resource a BMC is certain to have, and the
//! four ways a service can be wrong about it.
//!
//! Ports `nv-redfish`'s `test-manager.rs`. Three of its seven tests are the
//! same per-platform workarounds this suite has met twice already, and all
//! three arrive at the same place they did before:
//!
//! - `ami_viking_missing_root_managers_nav_workaround` is
//!   `*_missing_root_systems_nav` under another name, and gets the same
//!   non-answer. See `computer_system.zig`.
//! - `anonymous_1_9_0_wrong_manager_status_state_workaround` is
//!   `Status.State: "Standby"`, which `Resource.State` does not name, and
//!   `OpenEnum` has covered since the corpus sweep.
//! - `viking_with_garbage_in_managers` is
//!   `viking_with_garbage_in_computer_systems` with six ids instead of three,
//!   and gets the same four-line filter in the test rather than anything in
//!   the library.
//!
//! What is new is the `NetworkProtocol` link, which is the first nav property
//! in this suite whose *absence* is the interesting case, and
//! `Manager.ResetToDefaults`, which is a second action on a resource that
//! already has one and takes a different enum.
//!
//! `reset_helpers_return_action_not_available_when_manager_actions_are_absent`
//! is not ported. `base_operations.zig`, `chassis.zig` and
//! `computer_system.zig` already pin `error.ActionNotSupported` on an
//! unadvertised action; a fourth copy would assert the same generated line for
//! the fourth time. The `Some`/`None` pair on `reset` is not repeated either,
//! for the same reason -- `computer_system.zig` pins that an optional action
//! parameter is omitted rather than sent as null.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Manager = schema.manager.Manager;
const ManagerCollection = schema.manager_collection.ManagerCollection;
const ManagerNetworkProtocol = schema.manager_network_protocol.ManagerNetworkProtocol;

const managers_uri = "/redfish/v1/Managers";
const manager_uri = "/redfish/v1/Managers/1";
const network_protocol_uri = "/redfish/v1/Managers/1/NetworkProtocol";

/// A root of the shape `anonymous_1_9_service_root` builds: a service that
/// says nothing about itself beyond its version, and links its managers.
const root_with_managers =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_9_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService","RedfishVersion":"1.9.0",
    \\ "Managers":{"@odata.id":"/redfish/v1/Managers"}}
;

const manager_collection =
    \\{"@odata.id":"/redfish/v1/Managers",
    \\ "@odata.type":"#ManagerCollection.ManagerCollection",
    \\ "Id":"Managers","Name":"Manager Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Managers/1"}]}
;

/// Reads the one manager the way a program does: root, collection, member.
///
/// Only correct for a *fetched* member; every payload below arrives on its
/// own request, so the collection page is gone by the time the manager is
/// read and the value has to own its arena.
fn onlyManager(bmc: *mock.MockBmc, body: []const u8) !core.Resolved(Manager) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_managers),
        mock.Expect.get(managers_uri, manager_collection),
        mock.Expect.get(manager_uri, body),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Managers");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const manager = try core.follow(Manager, testing.allocator, &bmc.transport, link);
    errdefer manager.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    if (!manager.wasFetched()) return error.BorrowedFromAReleasedPage;
    return manager;
}

// -- A link the service may not have --------------------------------------

test "a manager with no network protocol link is not asked for one" {
    // `network_protocol_returns_none_when_link_is_absent`. `NetworkProtocol`
    // is optional on `Manager` and plenty of managers have none -- a service
    // processor that speaks only Redfish has no IPMI, SSH or KVM settings to
    // report. The absence is a `null` field rather than a fetch that 404s,
    // which is the difference between a caller branching and a caller
    // handling an error it cannot distinguish from a real one.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc,
        \\{"@odata.id":"/redfish/v1/Managers/1",
        \\ "@odata.type":"#Manager.v1_16_0.Manager",
        \\ "Id":"1","Name":"Manager","ManagerType":"BMC",
        \\ "Status":{"State":"Enabled"}}
    );
    defer manager.deinit();

    try testing.expect(manager.get().NetworkProtocol == null);

    // Three requests: root, collection, manager. Nothing was spent finding
    // out that there is no fourth.
    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

test "a manager's network protocol is read through the link it advertised" {
    // `network_protocol_fetches_linked_resource`. `IPMI.Port` is `1623`
    // rather than the 623 the schema documents as the default, because the
    // point of reading the resource is that the default is not a fact.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc,
        \\{"@odata.id":"/redfish/v1/Managers/1",
        \\ "@odata.type":"#Manager.v1_16_0.Manager",
        \\ "Id":"1","Name":"Manager","ManagerType":"BMC",
        \\ "Status":{"State":"Enabled"},
        \\ "NetworkProtocol":{"@odata.id":"/redfish/v1/Managers/1/NetworkProtocol"}}
    );
    defer manager.deinit();

    try bmc.expect(mock.Expect.get(network_protocol_uri,
        \\{"@odata.id":"/redfish/v1/Managers/1/NetworkProtocol",
        \\ "@odata.type":"#ManagerNetworkProtocol.v1_5_0.ManagerNetworkProtocol",
        \\ "Id":"NetworkProtocol","Name":"Manager Network Protocol",
        \\ "IPMI":{"ProtocolEnabled":true,"Port":1623}}
    ));

    const link = manager.get().NetworkProtocol.?;
    try testing.expect(!link.isExpanded());

    const protocol = try core.follow(
        ManagerNetworkProtocol,
        testing.allocator,
        &bmc.transport,
        link,
    );
    defer protocol.deinit();

    const ipmi = protocol.get().IPMI.?;
    try testing.expectEqual(true, ipmi.ProtocolEnabled.?);
    try testing.expectEqual(@as(i64, 1623), ipmi.Port.?);
    try bmc.verify();
}

// -- Two actions on one resource ------------------------------------------

test "a manager reset and a factory reset are different actions with different types" {
    // `reset_invokes_manager_reset_action` and
    // `reset_to_defaults_invokes_manager_reset_to_defaults_action`, together,
    // because what they show as a pair is what neither shows alone: the two
    // actions go to the targets the *service* named, and their parameters are
    // called the same thing and are not the same type.
    //
    // `Manager.Reset` takes a `Resource.ResetType` and restarts the BMC.
    // `Manager.ResetToDefaults` takes a `Manager.ResetToDefaultsType` and
    // discards its configuration. Both spell the parameter `ResetType`, and
    // nothing but the type stops a caller sending `ForceRestart` to the one
    // that wipes the settings.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const reset_target = manager_uri ++ "/Actions/Manager.Reset";
    const defaults_target = "/redfish/v1/Managers/1/DefaultsAction";

    const manager = try onlyManager(&bmc,
        \\{"@odata.id":"/redfish/v1/Managers/1",
        \\ "@odata.type":"#Manager.v1_16_0.Manager",
        \\ "Id":"1","Name":"Manager","ManagerType":"BMC",
        \\ "Actions":{
        \\   "#Manager.Reset":{
        \\     "target":"/redfish/v1/Managers/1/Actions/Manager.Reset"},
        \\   "#Manager.ResetToDefaults":{
        \\     "target":"/redfish/v1/Managers/1/DefaultsAction"}}}
    );
    defer manager.deinit();

    const actions = manager.get().Actions.?;

    try bmc.expect(mock.Expect.action(reset_target,
        \\{"ResetType":"ForceRestart"}
    , ""));
    const restarted = try actions.reset(testing.allocator, &bmc.transport, .{
        .ResetType = .ForceRestart,
    });
    defer restarted.deinit();
    try testing.expect(restarted.value == .empty);

    try bmc.expect(mock.Expect.action(defaults_target,
        \\{"ResetType":"ResetAll"}
    , ""));
    const wiped = try actions.resetToDefaults(testing.allocator, &bmc.transport, .{
        .ResetType = .ResetAll,
    });
    defer wiped.deinit();
    try testing.expect(wiped.value == .empty);

    // `ResetToDefaults` was not at `.../Actions/Manager.ResetToDefaults`, and
    // the request went where the service said rather than where the name
    // suggests.
    try testing.expectEqualStrings(defaults_target, bmc.request(4).uri);

    // The two parameter types are unrelated, so the compiler is what stops
    // `ForceRestart` reaching the action that erases the configuration.
    try testing.expect(schema.manager.ManagerResetAction != schema.manager.ManagerResetToDefaultsAction);
    try testing.expect(!@hasField(schema.manager.ResetToDefaultsType, "ForceRestart"));

    try bmc.verify();
}

// -- What a service says badly --------------------------------------------

test "a manager in a state the schema does not name is still a manager" {
    // `anonymous_1_9_0_wrong_manager_status_state_workaround`. A Liteon
    // powershelf reports `Status.State: "Standby"`. `Resource.State` has
    // `StandbyOffline` and `StandbySpare` and no bare `Standby`, so serde
    // fails the resource and the reference needs a per-platform patch to read
    // the manager at all.
    //
    // Here it is `UnsupportedValue`, decided once for every enum the emitter
    // writes. Worth pinning on `Manager` even though `chassis.zig` pins the
    // identical value on `Chassis`: the two resources reach `Resource.Status`
    // through different modules, and the property that makes this work is
    // that the enum decides, not the resource that declares it.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const manager = try onlyManager(&bmc,
        \\{"@odata.id":"/redfish/v1/Managers/1",
        \\ "@odata.type":"#Manager.v1_16_0.Manager",
        \\ "Id":"1","Name":"Manager","ManagerType":"BMC",
        \\ "Status":{"Health":"OK","State":"Standby"}}
    );
    defer manager.deinit();

    const status = manager.get().Status.?;
    try testing.expectEqual(schema.resource.State.UnsupportedValue, status.State.?);
    try testing.expectEqual(schema.resource.Health.OK, status.Health.?);
    try testing.expectEqual(schema.manager.ManagerType.BMC, manager.get().ManagerType.?);
    try bmc.verify();
}

test "a root that does not link its managers still has managers" {
    // `ami_viking_missing_root_managers_nav_workaround`. Identical in shape to
    // `*_missing_root_systems_nav`, which `computer_system.zig` answers, and
    // it gets the same answer: nothing is repaired, because nothing breaks.
    //
    // `walk` is a convenience over a link the root advertises, and a root that
    // advertises none says so at the point of asking rather than as a wrong
    // answer later. `/redfish/v1/Managers` is a URI DSP0266 fixes, so a caller
    // who knows the root is lying reads the collection directly and spends no
    // request discovering that.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1",
            \\{"@odata.id":"/redfish/v1",
            \\ "@odata.type":"#ServiceRoot.v1_9_0.ServiceRoot",
            \\ "Id":"RootService","Name":"RootService","RedfishVersion":"1.9.0",
            \\ "Vendor":"AMI"}
        ),
        mock.Expect.get(managers_uri, manager_collection),
        mock.Expect.get(manager_uri,
            \\{"@odata.id":"/redfish/v1/Managers/1",
            \\ "@odata.type":"#Manager.v1_16_0.Manager",
            \\ "Id":"1","Name":"Manager","ManagerType":"BMC"}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expect(!service.has("Managers"));
    try testing.expectError(error.NotSupported, service.walk("Managers"));

    var walker: core.Walker(ManagerCollection) =
        .init(testing.allocator, &bmc.transport, .{ .value = managers_uri });
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const manager = try core.follow(Manager, testing.allocator, &bmc.transport, link);
    defer manager.deinit();

    try testing.expectEqualStrings("1", manager.get().Id.?);
    try bmc.verify();
}

test "a managers collection that lists things that are not managers" {
    // `viking_with_garbage_in_managers`. Viking's `Managers` lists six ids,
    // three of which are a node manager underneath a manager, an *action
    // target*, and an `ActionInfo` -- none of which is a `Manager`, and all of
    // which parse as one, because every property on the type is optional.
    //
    // Same shape as `viking_with_garbage_in_computer_systems`, same answer:
    // the reference filters on a per-platform allowlist of the three ids that
    // platform uses, which cannot generalise, but the observation underneath
    // it does -- a garbage id is not a resource directly under the collection
    // that listed it.
    //
    // `isDirectMember` is duplicated from `computer_system.zig` rather than
    // shared. It is four lines, and it is the *subject* of both tests rather
    // than a utility they happen to need: a `tests/support.zig` holding it
    // would leave each test asserting something it does not show, and would
    // look like a thing the project offers, which is precisely what the
    // decision in #54 was that it should not be.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_managers),
        mock.Expect.get(managers_uri,
            \\{"@odata.id":"/redfish/v1/Managers",
            \\ "@odata.type":"#ManagerCollection.ManagerCollection",
            \\ "Id":"Managers","Name":"Manager Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Managers/BMC"},
            \\            {"@odata.id":"/redfish/v1/Managers/BMC/NodeManager"},
            \\            {"@odata.id":"/redfish/v1/Managers/HGX_BMC_0/Actions/Manager.Reset"},
            \\            {"@odata.id":"/redfish/v1/Managers/HGX_BMC_0"},
            \\            {"@odata.id":"/redfish/v1/Managers/HGX_BMC_0/ResetActionInfo"},
            \\            {"@odata.id":"/redfish/v1/Managers/HGX_FabricManager_0"}]}
        ),
        mock.Expect.get("/redfish/v1/Managers/BMC",
            \\{"@odata.id":"/redfish/v1/Managers/BMC",
            \\ "@odata.type":"#Manager.v1_16_0.Manager","Id":"BMC","Name":"BMC"}
        ),
        mock.Expect.get("/redfish/v1/Managers/HGX_BMC_0",
            \\{"@odata.id":"/redfish/v1/Managers/HGX_BMC_0",
            \\ "@odata.type":"#Manager.v1_16_0.Manager",
            \\ "Id":"HGX_BMC_0","Name":"HGX_BMC_0"}
        ),
        mock.Expect.get("/redfish/v1/Managers/HGX_FabricManager_0",
            \\{"@odata.id":"/redfish/v1/Managers/HGX_FabricManager_0",
            \\ "@odata.type":"#Manager.v1_16_0.Manager",
            \\ "Id":"HGX_FabricManager_0","Name":"HGX_FabricManager_0"}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Managers");
    defer walker.deinit();

    var kept: usize = 0;
    var skipped: usize = 0;
    while (try walker.next()) |link| {
        const id = link.odataId() orelse return error.NotAddressable;
        if (!isDirectMember(managers_uri, id.value)) {
            skipped += 1;
            continue;
        }
        const manager = try core.follow(Manager, testing.allocator, &bmc.transport, link);
        defer manager.deinit();
        try testing.expect(manager.get().Id != null);
        kept += 1;
    }

    try testing.expectEqual(@as(usize, 3), kept);
    try testing.expectEqual(@as(usize, 3), skipped);

    // Five requests, not eight. The three that were never managers were never
    // fetched, and the id said so before the fetch.
    try testing.expectEqual(@as(usize, 5), bmc.requestCount());
    try bmc.verify();
}

/// Whether `id` names a resource directly under `collection`.
///
/// The same four lines as `computer_system.zig`, and deliberately still in a
/// test: a library that shipped it would have to answer for every collection
/// in Redfish, and some legitimately list members from elsewhere --
/// `Storage.Drives` points into `Chassis`.
fn isDirectMember(collection: []const u8, id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, collection)) return false;
    const rest = id[collection.len..];
    if (rest.len < 2 or rest[0] != '/') return false;
    return std.mem.indexOfScalar(u8, rest[1..], '/') == null;
}

test "an action target under a manager is not a manager" {
    // The three ids Viking adds, against the rule that rejects them. An
    // action target and an `ActionInfo` are two segments down, and a node
    // manager is a resource that exists but is not a member of this
    // collection.
    try testing.expect(isDirectMember(managers_uri, "/redfish/v1/Managers/BMC"));
    try testing.expect(!isDirectMember(managers_uri, "/redfish/v1/Managers/BMC/NodeManager"));
    try testing.expect(!isDirectMember(
        managers_uri,
        "/redfish/v1/Managers/HGX_BMC_0/Actions/Manager.Reset",
    ));
    try testing.expect(!isDirectMember(
        managers_uri,
        "/redfish/v1/Managers/HGX_BMC_0/ResetActionInfo",
    ));
}
