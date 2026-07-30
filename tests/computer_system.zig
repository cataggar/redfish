//! What a system answers when it is asked to change, and what it looks like
//! when the service has nothing to say.
//!
//! Ports `nv-redfish`'s `test-computer-system.rs`. Where `chassis.zig` is
//! about reading a resource a service spelled badly, this one is mostly about
//! *writing*: the two shapes a `PATCH` can come back in, and an action whose
//! only parameter is optional.
//!
//! Three of the eight are per-platform workarounds again, and this time two of
//! them need nothing:
//!
//! - `nvidia_dpu_empty_system_uuid_*` is `UUID: ""` a second time, on
//!   `ComputerSystem` instead of `Chassis`. It was a two-test workaround
//!   there; here it is two tests that pass, because the rule lives in the
//!   parser rather than in a table of platforms.
//! - `dell_wrong_last_reset_time` is `"0000-00-00T00:00:00+00:00"`, which is
//!   the same phenomenon in a different type, and got the same answer:
//!   `DateTimeOffset.spellsAbsence`.
//! - `*_missing_root_systems_nav` is the one that is genuinely structural, and
//!   it is a question this stack answers by not having the problem. See the
//!   test.
//!
//! `reset_returns_action_not_available_when_computer_system_reset_is_absent`
//! is not ported: `base_operations.zig` and `chassis.zig` both pin
//! `error.ActionNotSupported`, and a third copy on a third resource would
//! assert the same line of generated code.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const ComputerSystem = schema.computer_system.ComputerSystem;
const ComputerSystemUpdate = schema.computer_system.ComputerSystemUpdate;

const systems_uri = "/redfish/v1/Systems";
const system_uri = "/redfish/v1/Systems/System-1";

const root_with_systems =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "Systems":{"@odata.id":"/redfish/v1/Systems"}}
;

/// A collection holding the one system as a bare link.
const system_collection =
    \\{"@odata.id":"/redfish/v1/Systems",
    \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
    \\ "Id":"Systems","Name":"Computer System Collection",
    \\ "Members":[{"@odata.id":"/redfish/v1/Systems/System-1"}]}
;

fn read(comptime T: type, bmc: *mock.MockBmc, uri: []const u8) !core.Owned(T) {
    return core.bmc.get(T, testing.allocator, &bmc.transport, .{ .value = uri });
}

/// Reads the one system the long way: root, collection, member. Every
/// tolerance test goes through this, because a payload that parses alone and
/// fails as a collection member has not been shown to work.
fn onlySystem(bmc: *mock.MockBmc, body: []const u8) !core.Resolved(ComputerSystem) {
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri, system_collection),
        mock.Expect.get(system_uri, body),
    });
    return followOnly(bmc);
}

/// The two hops below the root, for a collection that hands out bare links.
///
/// Only correct when the member is *fetched*: an expanded one borrows from the
/// page this releases, so a test with an inline member walks by hand and keeps
/// the walker alive. `Resolved.wasFetched` is what tells the two apart.
fn followOnly(bmc: *mock.MockBmc) !core.Resolved(ComputerSystem) {
    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    errdefer system.deinit();

    if (try walker.next() != null) return error.TooManyMembers;
    if (!system.wasFetched()) return error.BorrowedFromAReleasedPage;
    return system;
}

// -- Actions ---------------------------------------------------------------

test "a reset with a type, and a reset that lets the service choose" {
    // `ResetType` is the only parameter and it is optional, which DSP0266
    // means literally: a service may accept the action with no body at all and
    // do whatever its implementation calls a reset. Both requests have to be
    // sent, and they are not the same request -- `Payload` has to omit the
    // absent field rather than write `null`, or the service sees a caller
    // asking for a reset type it did not name.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const target = system_uri ++ "/Actions/ComputerSystem.Reset";
    const system = try onlySystem(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1",
        \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
        \\ "Id":"System-1","Name":"System-1",
        \\ "Actions":{"#ComputerSystem.Reset":{
        \\   "target":"/redfish/v1/Systems/System-1/Actions/ComputerSystem.Reset"}}}
    );
    defer system.deinit();

    const actions = system.get().Actions.?;

    try bmc.expect(mock.Expect.action(target,
        \\{"ResetType":"GracefulRestart"}
    , ""));
    const restart = try actions.reset(testing.allocator, &bmc.transport, .{
        .ResetType = .GracefulRestart,
    });
    defer restart.deinit();
    try testing.expect(restart.value == .empty);

    try bmc.expect(mock.Expect.action(target, "{}", ""));
    const default = try actions.reset(testing.allocator, &bmc.transport, .{});
    defer default.deinit();
    try testing.expect(default.value == .empty);

    try bmc.verify();
}

// -- Writes ----------------------------------------------------------------

test "a boot order that becomes a task, and one that becomes nothing" {
    // The same `PATCH` twice, answered the two ways DSP0266 allows a service
    // to answer it: `202` with a `Location`, and `204` with no body. A caller
    // that assumed a body gets an unhandled variant rather than a wrong value,
    // which is the entire reason `ModificationResponse` is a union and not an
    // optional.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri, system_collection),
        mock.Expect.get(system_uri,
            \\{"@odata.id":"/redfish/v1/Systems/System-1",
            \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
            \\ "Id":"System-1","Name":"System-1",
            \\ "Boot":{"BootOrder":["Boot0001"]}}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    defer system.deinit();

    try testing.expectEqualStrings("Boot0001", system.get().Boot.?.BootOrder.?[0].?);

    const task_uri = "/redfish/v1/TaskService/Tasks/52";
    try bmc.expect(mock.Expect.patchAccepted(system_uri,
        \\{"Boot":{"BootOrder":["Boot0002"]}}
    , task_uri));

    const accepted = try service.update(ComputerSystem, system.get(), ComputerSystemUpdate{
        .Boot = .{ .BootOrder = &.{"Boot0002"} },
    });
    defer accepted.deinit();

    const task = accepted.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqualStrings(task_uri, task.location.value.value);

    try bmc.expect(mock.Expect.patchNoContent(system_uri,
        \\{"Boot":{"BootOrder":["Boot0003"]}}
    ));

    const done = try service.update(ComputerSystem, system.get(), ComputerSystemUpdate{
        .Boot = .{ .BootOrder = &.{"Boot0003"} },
    });
    defer done.deinit();
    try testing.expect(done.value == .empty);

    // Neither answer carries a resource, and asking for one says which.
    try testing.expectError(error.OperationIsAsynchronous, accepted.value.expectEntity());
    try testing.expectError(error.NoResponseBody, done.value.expectEntity());

    try bmc.verify();
}

// -- What a service says when it has nothing to say ------------------------

test "a system whose last reset time is all zeros is read without one" {
    // `dell_wrong_last_reset_time_workaround`. A Dell that has never reset the
    // system writes `LastResetTime` anyway, with every field zeroed, and
    // strictly parsed that costs the caller the whole system over a timestamp
    // it was not asking for.
    //
    // Same trade as `UUID: ""`, same answer, and now it is one rule rather
    // than two: `DateTimeOffset.spellsAbsence`. Nothing about Dell is written
    // down anywhere for this to work.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try onlySystem(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1",
        \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
        \\ "Id":"System-1","Name":"System-1",
        \\ "LastResetTime":"0000-00-00T00:00:00+00:00",
        \\ "Status":{"Health":"OK","State":"Enabled"}}
    );
    defer system.deinit();

    try testing.expect(system.get().LastResetTime == null);

    // The rest of the system arrived, which is the whole point.
    try testing.expectEqualStrings("System-1", system.get().Id.?);
    try testing.expectEqual(schema.resource.Health.OK, system.get().Status.?.Health.?);
    try bmc.verify();
}

test "a real last reset time is still read" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try onlySystem(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1",
        \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
        \\ "Id":"System-1","Name":"System-1",
        \\ "LastResetTime":"2024-03-07T14:44:30Z"}
    );
    defer system.deinit();

    const reset_at = system.get().LastResetTime.?;
    try testing.expectEqual(@as(u16, 2024), reset_at.year);
    try testing.expectEqual(@as(u8, 30), reset_at.second);
    try bmc.verify();
}

test "an empty system UUID inside an expanded collection" {
    // `nvidia_dpu_empty_system_uuid_in_expanded_members_workaround`. The
    // member is inline, so the tolerance has to survive being reached through
    // the collection's own parse rather than a fetch of its own.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri,
            \\{"@odata.id":"/redfish/v1/Systems",
            \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
            \\ "Id":"Systems","Name":"Computer System Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Systems/System-1",
            \\             "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
            \\             "Id":"System-1","Name":"System-1","UUID":""}]}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    defer system.deinit();

    // Borrowed from the page the walker is still holding, which is the whole
    // saving `$expand` buys and the reason the walker outlives this value.
    try testing.expect(!system.wasFetched());

    try testing.expect(system.get().UUID == null);
    try testing.expectEqualStrings("System-1", system.get().Id.?);

    // Two requests, not three: the member was already there.
    try testing.expectEqual(@as(usize, 2), bmc.requestCount());
    try bmc.verify();
}

test "an empty system UUID in a member fetched by link" {
    // `nvidia_dpu_empty_system_uuid_on_member_fetch_workaround`. The other
    // half: the collection gave a link and the member arrived on its own.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const system = try onlySystem(&bmc,
        \\{"@odata.id":"/redfish/v1/Systems/System-1",
        \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
        \\ "Id":"System-1","Name":"System-1","UUID":""}
    );
    defer system.deinit();

    try testing.expect(system.wasFetched());
    try testing.expect(system.get().UUID == null);
    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

// -- Links a service did not send ------------------------------------------

test "a root that does not link its systems still has systems" {
    // `ami_viking_missing_root_systems_nav_workaround` and
    // `anonymous_1_9_0_missing_root_systems_nav_workaround` are the same
    // deviation on two platforms: the root omits `Systems`, and `nv-redfish`
    // repairs it by synthesising `{root}/Systems` when the fingerprint matches.
    //
    // There is nothing to repair here, because there is nothing that breaks.
    // `walk` is a convenience over a link the root advertises, and when the
    // root does not advertise one it says so -- `error.NotSupported`, at the
    // point of asking, not as a wrong answer later. The collection is at a
    // well-known URI that DSP0266 fixes, so a caller who knows the root is
    // lying reads it directly, with no fingerprint and no table.
    //
    // The distinction that makes this safe is the one `quirks.zig` draws: a
    // missing link is a departure in the *data*, and the code that knows what
    // the link was for is the only code that can act on it.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1",
            \\{"@odata.id":"/redfish/v1",
            \\ "@odata.type":"#ServiceRoot.v1_9_0.ServiceRoot",
            \\ "Id":"RootService","Name":"RootService","RedfishVersion":"1.9.0"}
        ),
        mock.Expect.get(systems_uri, system_collection),
        mock.Expect.get(system_uri,
            \\{"@odata.id":"/redfish/v1/Systems/System-1",
            \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
            \\ "Id":"System-1","Name":"System-1"}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try testing.expect(!service.has("Systems"));
    try testing.expectError(error.NotSupported, service.walk("Systems"));

    var walker: core.Walker(schema.computer_system_collection.ComputerSystemCollection) =
        .init(testing.allocator, &bmc.transport, .{ .value = systems_uri });
    defer walker.deinit();

    const link = (try walker.next()) orelse return error.NoMembers;
    const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
    defer system.deinit();

    try testing.expectEqualStrings("System-1", system.get().Id.?);
    try bmc.verify();
}

test "a collection member that is not in the collection" {
    // `viking_with_garbage_in_computer_systems`. Viking's `Systems` lists
    // `.../System-1/LogServices/FDR`, which is a log service, and fetching it
    // as a `ComputerSystem` yields a resource made entirely of absences --
    // every field optional, so nothing fails, and the caller gets a system
    // that is not one.
    //
    // `nv-redfish` answers with a per-platform allowlist of the two ids it
    // expects to see. That is not portable and cannot be: the next platform
    // has different names. What *is* portable is the observation that made the
    // allowlist work -- the garbage id is not a member of the collection it
    // was listed in, and a caller can see that without knowing any vendor,
    // because both ids are right there.
    //
    // So no filter is built in. The test pins that the evidence is available
    // and costs nothing: the link carries its id before it is followed, so a
    // caller decides *before* spending the request.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_with_systems),
        mock.Expect.get(systems_uri,
            \\{"@odata.id":"/redfish/v1/Systems",
            \\ "@odata.type":"#ComputerSystemCollection.ComputerSystemCollection",
            \\ "Id":"Systems","Name":"Systems Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/Systems/DGX"},
            \\            {"@odata.id":"/redfish/v1/Systems/HGX_Baseboard_0/LogServices/FDR"},
            \\            {"@odata.id":"/redfish/v1/Systems/HGX_Baseboard_0"}]}
        ),
        mock.Expect.get("/redfish/v1/Systems/DGX",
            \\{"@odata.id":"/redfish/v1/Systems/DGX",
            \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
            \\ "Id":"DGX","Name":"DGX"}
        ),
        mock.Expect.get("/redfish/v1/Systems/HGX_Baseboard_0",
            \\{"@odata.id":"/redfish/v1/Systems/HGX_Baseboard_0",
            \\ "@odata.type":"#ComputerSystem.v1_20_0.ComputerSystem",
            \\ "Id":"HGX_Baseboard_0","Name":"HGX_Baseboard_0"}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    var walker = try service.walk("Systems");
    defer walker.deinit();

    var kept: usize = 0;
    var skipped: usize = 0;
    while (try walker.next()) |link| {
        const id = link.odataId() orelse return error.NotAddressable;
        if (!isDirectMember(systems_uri, id.value)) {
            skipped += 1;
            continue;
        }
        const system = try core.follow(ComputerSystem, testing.allocator, &bmc.transport, link);
        defer system.deinit();
        try testing.expect(system.get().Id != null);
        kept += 1;
    }

    try testing.expectEqual(@as(usize, 2), kept);
    try testing.expectEqual(@as(usize, 1), skipped);

    // Four requests, not five. The one that was never a system was never
    // fetched, because the id said so before the fetch.
    try testing.expectEqual(@as(usize, 4), bmc.requestCount());
    try bmc.verify();
}

/// Whether `id` names a resource directly under `collection`.
///
/// Not exported anywhere: this is what a *caller* writes, and it is four lines
/// because the evidence is in the ids. A library that shipped it would have to
/// decide for every collection in Redfish, and some of them legitimately list
/// members from elsewhere -- `Storage.Drives` points into `Chassis`.
fn isDirectMember(collection: []const u8, id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, collection)) return false;
    const rest = id[collection.len..];
    if (rest.len < 2 or rest[0] != '/') return false;
    return std.mem.indexOfScalar(u8, rest[1..], '/') == null;
}

test "a direct member is one segment down and no more" {
    try testing.expect(isDirectMember("/redfish/v1/Systems", "/redfish/v1/Systems/DGX"));
    try testing.expect(!isDirectMember(
        "/redfish/v1/Systems",
        "/redfish/v1/Systems/DGX/LogServices/FDR",
    ));

    // The collection itself is not a member of itself, and neither is a
    // sibling whose name merely starts the same way.
    try testing.expect(!isDirectMember("/redfish/v1/Systems", "/redfish/v1/Systems"));
    try testing.expect(!isDirectMember("/redfish/v1/Systems", "/redfish/v1/SystemsOther/1"));
    try testing.expect(!isDirectMember("/redfish/v1/Systems", "/redfish/v1/Chassis/1"));
}
