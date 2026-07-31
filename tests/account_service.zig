//! Accounts: the one resource whose payload is a credential, and the one
//! place a per-vendor create algorithm is a real algorithm.
//!
//! Ports `nv-redfish`'s `tests-account-service.rs`. Eleven tests, and they
//! divide into three arguments rather than eleven behaviours.
//!
//! **Redaction, and why there is none.** The reference opens with
//! `account_request_debug_redacts_passwords` and
//! `additional_properties_debug_is_fully_redacted`: a `ManagerAccountCreate`
//! must not show its password in `Debug` output while still serializing it,
//! and an OEM update's whole blob is hidden. Rust can promise that, because
//! `Debug` is the single hook every printing path goes through and a derive
//! is where the promise is kept.
//!
//! Zig has no such hook. `{f}` calls a type's `format` method; `{}` and
//! `{any}` reflect over the fields and ignore that the method exists. So a
//! generated `format` would be honoured by the one spelling a caller has to
//! choose deliberately and ignored by the two that are the defaults --
//! including `std.log.debug("{any}", .{request})`, which is the accident the
//! whole idea is meant to prevent. A protection that fails open on the common
//! path is worse than none: it invites the caller to stop being careful.
//!
//! This is not hypothetical. `core/response.zig` and `bmc_http/credentials.zig`
//! each redact a live credential exactly this way, and the last test here pins
//! how far that reaches. It is defensible for two hand-written types whose
//! doc-comment can say "never print credentials any other way" and whose
//! reviewers can hold that line. It is not defensible as a *generated*
//! guarantee: 35 write-only fields across 14 property names in the standard
//! schema alone, in every `*Create` and `*Update`, in ten packages.
//!
//! The keying would be wrong too. Permission is the principled signal and the
//! reference does not use it: `ManagerAccountCreate.user_name` is write-only
//! and is deliberately *not* redacted, because a username is not a secret.
//! What the reference actually uses is a hand-placed annotation, which for a
//! generator is a curated list of property names -- a heuristic, maintained
//! by hand, in the one part of this project that is meant to have no hand in
//! it. So the two tests are ported as assertions about what does happen, and
//! the answer is that a request body is a request body: a caller that logs one
//! has logged a password, and no type can stop it.
//!
//! **A property nobody sent.** `list_hpe_accounts`, `list_no_patch_accounts`
//! and `create_account_hpe_patched` are one absent `AccountTypes` read three
//! ways: an error for a generic vendor, `[Redfish]` invented for HPE, and the
//! same invention on the create path. Here absent is absent, once, and the
//! test says why the inference belongs to the caller.
//!
//! **Dell's slots.** `create_account_dell_slot_defined_*` and
//! `list_dell_accounts_hide_disabled` are a real algorithm and it stays in the
//! caller, for the reason `viking_with_garbage_in_computer_systems` stayed
//! there: the generated types give the right answer, and the part that cannot
//! generalise is a number.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const ManagerAccount = schema.manager_account.ManagerAccount;
const ManagerAccountCollection = schema.manager_account_collection.ManagerAccountCollection;
const ManagerAccountCreate = schema.manager_account.ManagerAccountCreate;
const ManagerAccountUpdate = schema.manager_account.ManagerAccountUpdate;

const account_service_uri = "/redfish/v1/AccountService";
const accounts_uri = "/redfish/v1/AccountService/Accounts";

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "AccountService":{"@odata.id":"/redfish/v1/AccountService"}}
;

const account_service_body =
    \\{"@odata.id":"/redfish/v1/AccountService",
    \\ "@odata.type":"#AccountService.v1_5_0.AccountService",
    \\ "Id":"AccountService","Name":"AccountService",
    \\ "Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"}}
;

/// A collection page around a literal `Members` array.
fn accountsPage(comptime member_list: []const u8) []const u8 {
    return
    \\{"@odata.id":"/redfish/v1/AccountService/Accounts",
    \\ "@odata.type":"#ManagerAccountCollection.ManagerAccountCollection",
    \\ "Name":"User Accounts","Members":
    ++ member_list ++ "}";
}

fn connect(bmc: *mock.MockBmc) !Service {
    try bmc.expect(mock.Expect.get("/redfish/v1", root_body));
    return Service.connect(testing.allocator, &bmc.transport);
}

/// Reads the accounts the way a program reaches them: root, account service,
/// then the collection with `$expand`.
///
/// The expansion is the point rather than an optimisation. `Enabled` is a
/// property of each account, and every question below -- which accounts to
/// show, which slot is free -- is answered by reading it for all of them. One
/// request, or one per account.
fn openAccounts(
    bmc: *mock.MockBmc,
    service: Service,
    body: []const u8,
) !core.Owned(ManagerAccountCollection) {
    try bmc.expectAll(&.{
        mock.Expect.get(account_service_uri, account_service_body),
        mock.Expect.expand(accounts_uri, body),
    });

    const account_service = try service.open("AccountService");
    defer account_service.deinit();

    const link = account_service.get().Accounts orelse return error.NoAccounts;
    return core.bmc.expand(
        ManagerAccountCollection,
        testing.allocator,
        &bmc.transport,
        link.odataId() orelse return error.NotAddressable,
        service.expandQuery().?,
    );
}

/// The accounts an expanded page holds, in the order the service listed them.
fn members(page: *const ManagerAccountCollection) []const core.NavProperty(ManagerAccount) {
    return page.Members orelse &.{};
}

// -- Reading ---------------------------------------------------------------

test "the accounts a service lists, and what each one says about itself" {
    // `list_accounts`.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","UserName":"Administrator",
        \\  "RoleId":"AdministratorRole","AccountTypes":[]}]
    ));
    defer page.deinit();

    const list = members(&page.value);
    try testing.expectEqual(@as(usize, 1), list.len);

    const account = list[0].value() orelse return error.NotExpanded;
    try testing.expectEqualStrings("Administrator", account.UserName.?);
    try testing.expectEqualStrings("AdministratorRole", account.RoleId.?);
    try testing.expectEqualStrings("User Account", account.Name.?);
    try testing.expectEqualStrings("1", account.Id.?);

    // An empty `AccountTypes` is the service saying this account can be used
    // for nothing, which is a statement. The next test is about its absence,
    // which is not.
    try testing.expectEqual(@as(usize, 0), account.AccountTypes.?.len);
    try bmc.verify();
}

test "an account that does not say what kind of account it is" {
    // `list_hpe_accounts`, `list_no_patch_accounts` and
    // `create_account_hpe_patched` are the same absent `AccountTypes` read
    // three ways: an error for a service the reference does not recognise,
    // `[Redfish]` invented for HPE, and the same invention again on the
    // create path. Two of the three need a vendor string to decide, and the
    // vendor string is `ServiceRoot.Vendor`, which several BMCs get wrong.
    //
    // Absent is absent here, and it costs nothing, because `AccountTypes` is
    // optional in the read shape whatever `Redfish.Required` says about it.
    // The inference the reference makes is sound -- an account reachable over
    // Redfish is at least a `Redfish` account -- and it belongs to the caller
    // precisely because the caller is the one that knows how it got here. A
    // client that reached this account over IPMI would be entitled to the
    // opposite conclusion.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","UserName":"Administrator",
        \\  "RoleId":"AdministratorRole"}]
    ));
    defer page.deinit();

    const account = members(&page.value)[0].value() orelse return error.NotExpanded;
    try testing.expectEqual(@as(?[]const ?schema.manager_account.AccountTypes, null), account.AccountTypes);

    // Everything the service did say arrived, which is what makes the
    // caller's inference cheap: it has the account in hand to make it about.
    try testing.expectEqualStrings("Administrator", account.UserName.?);
    try bmc.verify();
}

// -- Creating --------------------------------------------------------------

test "the three answers a service can give when asked to make an account" {
    // `create_account_standard_preserves_all_response_variants`. `201` with
    // the member, `202` with a task, `204` with nothing, all to the same
    // request -- and the third is why `create` returns a union rather than
    // the resource. A caller that assumed a body gets an unhandled variant
    // instead of a wrong value.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage("[]"));
    defer page.deinit();

    try bmc.expect(mock.Expect.created(
        accounts_uri,
        \\{"Password":"password","UserName":"user","RoleId":"Operator"}
    ,
        "/redfish/v1/AccountService/Accounts/1",
        \\{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\ "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\ "Id":"1","Name":"User Account","UserName":"user",
        \\ "RoleId":"Operator","AccountTypes":[]}
        ,
    ));

    const made = try service.create(ManagerAccount, .init(accounts_uri), ManagerAccountCreate{
        .Password = "password",
        .UserName = "user",
        .RoleId = "Operator",
    });
    defer made.deinit();

    const account = try made.value.expectEntity();
    try testing.expectEqualStrings("1", account.Id.?);
    try testing.expectEqualStrings("user", account.UserName.?);
    try testing.expectEqualStrings("Operator", account.RoleId.?);

    try bmc.expect(mock.Expect.postAccepted(
        accounts_uri,
        \\{"Password":"password","UserName":"task-user","RoleId":"Operator"}
    ,
        "/redfish/v1/TaskService/Tasks/42",
        7,
    ));

    const queued = try service.create(ManagerAccount, .init(accounts_uri), ManagerAccountCreate{
        .Password = "password",
        .UserName = "task-user",
        .RoleId = "Operator",
    });
    defer queued.deinit();

    const task = queued.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/42", task.location.value.value);
    try testing.expectEqual(@as(?u64, 7 * std.time.ns_per_s), task.retryAfterNanoseconds());

    try bmc.expect(mock.Expect.postNoContent(accounts_uri,
        \\{"Password":"password","UserName":"empty-user","RoleId":"Operator"}
    ));

    const silent = try service.create(ManagerAccount, .init(accounts_uri), ManagerAccountCreate{
        .Password = "password",
        .UserName = "empty-user",
        .RoleId = "Operator",
    });
    defer silent.deinit();
    try testing.expect(silent.value == .empty);

    try bmc.verify();
}

// -- Writing ---------------------------------------------------------------

test "a password reaches the service and the seventeen properties beside it do not" {
    // `update_account_preserves_task_and_empty_responses`. The pair of
    // response shapes is already pinned in `computer_system.zig`; what is new
    // is the request. `ManagerAccountUpdate` has eighteen properties and a
    // caller setting one must send one -- a PATCH that carried the defaults
    // would ask the service to clear seventeen things, including the account's
    // own role.
    try testing.expectEqual(
        @as(usize, 18),
        @typeInfo(ManagerAccountUpdate).@"struct".fields.len,
    );

    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","Enabled":true,
        \\  "UserName":"user","AccountTypes":[]}]
    ));
    defer page.deinit();

    const account = members(&page.value)[0].value() orelse return error.NotExpanded;

    try bmc.expect(mock.Expect.patchNoContent("/redfish/v1/AccountService/Accounts/1",
        \\{"Password":"new-password"}
    ));

    const written = try service.update(ManagerAccount, account, ManagerAccountUpdate{
        .Password = .init("new-password"),
    });
    defer written.deinit();
    try testing.expect(written.value == .empty);

    try bmc.expect(mock.Expect.patchAccepted(
        "/redfish/v1/AccountService/Accounts/1",
        \\{"Password":"newer-password"}
    ,
        "/redfish/v1/TaskService/Tasks/44",
        9,
    ));

    const queued = try service.update(ManagerAccount, account, ManagerAccountUpdate{
        .Password = .init("newer-password"),
    });
    defer queued.deinit();

    const task = queued.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqual(@as(?u64, 9 * std.time.ns_per_s), task.retryAfterNanoseconds());
    try bmc.verify();
}

test "deleting an account, and a service that has only promised to" {
    // `delete_account_preserves_task_and_empty_responses`. Removing an
    // account can mean tearing down that account's open sessions, so a
    // service that answers `202` here is not being awkward.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","Enabled":true,"UserName":"first"},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/2",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"2","Name":"User Account","Enabled":true,"UserName":"second"}]
    ));
    defer page.deinit();

    const list = members(&page.value);
    const queued_account = list[0].value() orelse return error.NotExpanded;
    const silent_account = list[1].value() orelse return error.NotExpanded;

    try bmc.expect(mock.Expect.deleteAccepted(
        "/redfish/v1/AccountService/Accounts/1",
        "/redfish/v1/TaskService/Tasks/45",
        10,
    ));

    const queued = try service.remove(ManagerAccount, queued_account);
    defer queued.deinit();

    const task = queued.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/45", task.location.value.value);
    try testing.expectEqual(@as(?u64, 10 * std.time.ns_per_s), task.retryAfterNanoseconds());

    try bmc.expect(mock.Expect.delete("/redfish/v1/AccountService/Accounts/2"));

    const silent = try service.remove(ManagerAccount, silent_account);
    defer silent.deinit();
    try testing.expect(silent.value == .empty);

    try bmc.verify();
}

// -- A fixed set of slots --------------------------------------------------

/// The lowest-numbered account at or above `min_slot` that nobody is using.
///
/// This is what a caller writes when it knows it is talking to an iDRAC.
/// Dell ships a fixed set of account slots rather than a collection a client
/// can grow, so creating an account is claiming a disabled one, and the slots
/// below a threshold are reserved for the service's own use. `min_slot` is
/// that threshold and it is a number no schema carries: it is 3 on the
/// platform `nv-redfish` records and there is nothing in the payload that
/// says so.
///
/// Nothing here is Dell-specific except that number, which is why it is an
/// argument, and nothing about it belongs in the library, which would have to
/// keep a table of platforms to supply it. The generated types answer every
/// other part: `Enabled` is on each account, `$expand` puts all of them in one
/// response, and the PATCH is `service.update`.
fn freeSlot(
    accounts: []const core.NavProperty(ManagerAccount),
    min_slot: u32,
) ?*const ManagerAccount {
    for (accounts) |member| {
        const account = member.value() orelse continue;
        const id = account.Id orelse continue;
        const slot = std.fmt.parseInt(u32, id, 10) catch continue;
        if (slot < min_slot) continue;
        // Absent reads as in use: a slot that will not say is not one to take.
        if (account.Enabled orelse true) continue;
        return account;
    }
    return null;
}

test "a Dell account listing is the slots somebody is using" {
    // `list_dell_accounts_hide_disabled`. The reference makes this a vendor
    // behaviour of its account collection. It is one line in the caller, and
    // it reads the same field the create path reads -- which is the
    // observation worth keeping: "hide the disabled accounts" and "claim a
    // disabled account" are one fact about a fixed set of slots, asked twice.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","Enabled":true,"UserName":"root"},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/3",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"3","Name":"User Account","Enabled":false,"UserName":""},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/4",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"4","Name":"User Account","Enabled":true,"UserName":"other"}]
    ));
    defer page.deinit();

    var in_use: std.ArrayList([]const u8) = .empty;
    defer in_use.deinit(testing.allocator);
    for (members(&page.value)) |member| {
        const account = member.value() orelse continue;
        if (!(account.Enabled orelse true)) continue;
        try in_use.append(testing.allocator, account.Id.?);
    }

    try testing.expectEqual(@as(usize, 2), in_use.items.len);
    try testing.expectEqualStrings("1", in_use.items[0]);
    try testing.expectEqualStrings("4", in_use.items[1]);

    // The unused slot is still there to be read, which is the difference
    // between filtering a listing and losing the account. It is what the next
    // test claims.
    try testing.expectEqual(@as(usize, 3), members(&page.value).len);
    try bmc.verify();
}

test "claiming an account slot is a PATCH, and running out of them costs no request" {
    // `create_account_dell_slot_defined_first_available` and
    // `create_account_dell_slot_defined_no_slot_available`. A create on this
    // platform is not a POST: the collection cannot grow, so the request that
    // makes an account is a PATCH to a slot that is currently disabled.
    //
    // `create_account_slot_defined_preserves_async_task` is not ported
    // separately -- it is this PATCH answered `202`, and the previous test
    // already pins that a PATCH to an account can be a task.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const service = try connect(&bmc);
    defer service.deinit();

    const page = try openAccounts(&bmc, service, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","Enabled":true,"UserName":"root"},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/2",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"2","Name":"User Account","Enabled":false,"UserName":""},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/3",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"3","Name":"User Account","Enabled":false,"UserName":""},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/4",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"4","Name":"User Account","Enabled":false,"UserName":""}]
    ));
    defer page.deinit();

    // Slot 2 is free and is not chosen: the reserved range is below 3.
    const slot = freeSlot(members(&page.value), 3) orelse return error.NoFreeSlot;
    try testing.expectEqualStrings("3", slot.Id.?);

    try bmc.expect(mock.Expect.patch(
        "/redfish/v1/AccountService/Accounts/3",
        \\{"Password":"password","UserName":"user","RoleId":"Operator","Enabled":true}
    ,
        \\{"@odata.id":"/redfish/v1/AccountService/Accounts/3",
        \\ "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\ "Id":"3","Name":"User Account","Enabled":true,
        \\ "UserName":"user","RoleId":"Operator","AccountTypes":[]}
        ,
    ));

    const claimed = try service.update(ManagerAccount, slot, ManagerAccountUpdate{
        .Password = .init("password"),
        .UserName = "user",
        .RoleId = "Operator",
        .Enabled = true,
    });
    defer claimed.deinit();

    const account = try claimed.value.expectEntity();
    try testing.expectEqualStrings("3", account.Id.?);
    try testing.expectEqualStrings("user", account.UserName.?);
    try testing.expectEqualStrings("Operator", account.RoleId.?);
    try testing.expectEqual(true, account.Enabled.?);
    try bmc.verify();

    // The other half: every slot at or above the threshold is taken. The
    // caller finds that out from the page it already has, so the failure
    // costs nothing and is not a status code to interpret.
    var full: mock.MockBmc = .init(testing.allocator);
    defer full.deinit();

    const other = try connect(&full);
    defer other.deinit();

    const taken = try openAccounts(&full, other, accountsPage(
        \\[{"@odata.id":"/redfish/v1/AccountService/Accounts/1",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"1","Name":"User Account","Enabled":false,"UserName":""},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/3",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"3","Name":"User Account","Enabled":true,"UserName":"root"},
        \\ {"@odata.id":"/redfish/v1/AccountService/Accounts/4",
        \\  "@odata.type":"#ManagerAccount.v1_3_0.ManagerAccount",
        \\  "Id":"4","Name":"User Account","Enabled":true,"UserName":"other"}]
    ));
    defer taken.deinit();

    try testing.expect(freeSlot(members(&taken.value), 3) == null);
    try testing.expectEqual(@as(usize, 3), full.requestCount());
    try full.verify();
}

// -- The password itself ---------------------------------------------------

/// How `{any}` renders a string: the bytes, in decimal.
fn asBytes(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{ ");
    for (text, 0..) |byte, index| {
        if (index > 0) try out.appendSlice(gpa, ", ");
        var digits: [4]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&digits, "{d}", .{byte}));
    }
    try out.appendSlice(gpa, " }");
    return out.toOwnedSlice(gpa);
}

test "a create request serializes the password it was given" {
    // The half of `account_request_debug_redacts_passwords` that is a
    // requirement rather than a hope: whatever is done about printing, the
    // password has to reach the service, and it is the only place a new
    // account's password can come from.
    const secret = "debug-secret-sentinel";

    const create = ManagerAccountCreate{
        .Password = secret,
        .UserName = "debug-user",
        .RoleId = "Operator",
    };

    const encoded = try std.json.Stringify.valueAlloc(
        testing.allocator,
        create,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(
        \\{"Password":"debug-secret-sentinel","UserName":"debug-user","RoleId":"Operator"}
    , encoded);

    // And an update sends it only when the caller set it, which is the
    // difference between changing a password and clearing one.
    const set = try std.json.Stringify.valueAlloc(
        testing.allocator,
        ManagerAccountUpdate{ .Password = .init(secret), .UserName = "debug-user" },
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(set);
    try testing.expectEqualStrings(
        \\{"Password":"debug-secret-sentinel","UserName":"debug-user"}
    , set);

    const unset = try std.json.Stringify.valueAlloc(
        testing.allocator,
        ManagerAccountUpdate{ .UserName = "debug-user" },
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(unset);
    try testing.expectEqualStrings(
        \\{"UserName":"debug-user"}
    , unset);
}

test "nothing in a generated request hides a password from a log" {
    // `account_request_debug_redacts_passwords` and
    // `additional_properties_debug_is_fully_redacted`, ported as what they
    // actually assert here. See the module comment for the argument; this is
    // the evidence for it.
    const secret = "debug-secret-sentinel";
    const gpa = testing.allocator;

    const bytes = try asBytes(gpa, secret);
    defer gpa.free(bytes);

    const printed = try std.fmt.allocPrint(gpa, "{any}", .{ManagerAccountCreate{
        .Password = secret,
        .UserName = "debug-user",
        .RoleId = "Operator",
    }});
    defer gpa.free(printed);

    // Not the string, because `{any}` renders `[]const u8` as its bytes --
    // which is the password with one decoding step in front of it, and is
    // exactly as recoverable from a log file.
    try testing.expect(std.mem.indexOf(u8, printed, bytes) != null);

    // An OEM blob is a `std.json.ArrayHashMap`, and what `{any}` makes of one
    // is the map's internals. The secret does not appear -- not because
    // anything hid it, but because a hash map has no printable form and the
    // values are behind a pointer. It is luck, and it is not a property to
    // rely on: the same value written as JSON is the same secret again.
    var oem: core.AdditionalProperties = .{};
    defer oem.map.deinit(gpa);
    try oem.map.put(gpa, "Secret", .{ .string = secret });

    const update = schema.resource.OemUpdate{ .additional_properties = oem };
    const serialized = try std.json.Stringify.valueAlloc(
        gpa,
        update,
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(serialized);
    try testing.expectEqualStrings(
        \\{"Secret":"debug-secret-sentinel"}
    , serialized);
}

test "the two places this stack does redact reach one of the three ways to print" {
    // `core/response.zig` and `bmc_http/credentials.zig` each give a live
    // credential a `format` that writes `[REDACTED]`, and each has a test
    // that it does. Neither says how far it goes, and this is the answer:
    // `{f}` calls `format`, `{}` and `{any}` do not know it exists.
    //
    // That is the whole reason the generator does not do the same for every
    // write shape. Two hand-written types can carry a doc-comment saying
    // never to print them any other way. Thirty-five generated fields cannot.
    const gpa = testing.allocator;
    const response: core.SessionCreateResponse(u8) = .{
        .entity = 0,
        .auth_token = "session-token-123",
        .location = .init("/redfish/v1/SessionService/Sessions/1"),
    };

    const redacted = try std.fmt.allocPrint(gpa, "{f}", .{response});
    defer gpa.free(redacted);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, redacted, "session-token-123") == null);

    const bytes = try asBytes(gpa, "session-token-123");
    defer gpa.free(bytes);

    const reflected = try std.fmt.allocPrint(gpa, "{any}", .{response});
    defer gpa.free(reflected);
    try testing.expect(std.mem.indexOf(u8, reflected, "[REDACTED]") == null);
    try testing.expect(std.mem.indexOf(u8, reflected, bytes) != null);
}
