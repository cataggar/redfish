//! Sessions, from both ends: the collection a service lists them in, and the
//! one this client is holding.
//!
//! Ports `nv-redfish`'s `test-session-service.rs`. `redfish/service.zig`
//! already has `login`, `loginAt`, `logout` and `loggedIn` (#47), and
//! `tests/service.zig` pins the happy path of all four, so most of what is
//! here is the part that file asserts in a comment without showing:
//!
//! - `delete_created_session_uses_location` gives the created session a
//!   different `@odata.id` in the body from the URI in `Location`, which is
//!   the only fixture that can tell which one `logout` uses. `service.zig`
//!   uses the same URI for both and says in a comment that `Location` wins.
//! - `delete_session_preserves_async_task` is a service that queues the
//!   teardown. `logout` discards the response, so a `202` has to end the
//!   session here as surely as a `204` does, and nothing said so before.
//!
//! `create_session` is ported at the `core.bmc` layer rather than through
//! `Service`, because what it is about is where each part of the answer comes
//! from: the token and the URI are *headers*, and everything else is the body.
//! `Service.login` keeps all three and hands back none of them.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Session = schema.session.Session;
const SessionCollection = schema.session_collection.SessionCollection;
const SessionService = schema.session_service.SessionService;

const session_service_uri = "/redfish/v1/SessionService";
const sessions_uri = "/redfish/v1/SessionService/Sessions";

/// A root shaped like the one `test-session-service.rs` builds: it links the
/// session service, advertises that it can expand, and repeats the session
/// collection under `Links`, which is where an unauthenticated client is
/// meant to find it.
const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"RootService",
    \\ "ProtocolFeaturesSupported":{"ExpandQuery":{"NoLinks":true}},
    \\ "SessionService":{"@odata.id":"/redfish/v1/SessionService"},
    \\ "Links":{"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}}
;

const session_service_body =
    \\{"@odata.id":"/redfish/v1/SessionService",
    \\ "@odata.type":"#SessionService.v1_1_5.SessionService",
    \\ "Id":"SessionService","Name":"Session Service",
    \\ "ServiceEnabled":true,"SessionTimeout":600,
    \\ "Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
;

test "the sessions a service is holding open, read through the session service" {
    // `list_sessions`. Reading the collection needs credentials, which is why
    // it hangs off `SessionService` and not only off `Links` -- a client that
    // is already logged in asks who else is.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get(session_service_uri, session_service_body),
        mock.Expect.expand(sessions_uri,
            \\{"@odata.id":"/redfish/v1/SessionService/Sessions",
            \\ "@odata.type":"#SessionCollection.SessionCollection",
            \\ "Name":"User Sessions",
            \\ "Members":[{"@odata.id":"/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
            \\             "@odata.type":"#Session.v1_5_0.Session",
            \\             "Id":"1234567890ABCDEF","Name":"User Session",
            \\             "UserName":"Administrator","SessionType":"ManagerConsole"}]}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const session_service = try service.open("SessionService");
    defer session_service.deinit();
    try testing.expectEqual(true, session_service.get().ServiceEnabled.?);
    try testing.expectEqual(@as(i64, 600), session_service.get().SessionTimeout.?);

    const link = session_service.get().Sessions orelse return error.NoSessions;
    const sessions = try core.bmc.expand(
        SessionCollection,
        testing.allocator,
        &bmc.transport,
        link.odataId() orelse return error.NotAddressable,
        service.expandQuery().?,
    );
    defer sessions.deinit();

    const members = sessions.value.Members.?;
    try testing.expectEqual(@as(usize, 1), members.len);

    // Expanded, so the member is the session and no further request buys
    // anything. Three requests for the whole walk.
    const session = members[0].value() orelse return error.NotExpanded;
    try testing.expectEqualStrings("Administrator", session.UserName.?);
    try testing.expectEqual(schema.session.SessionTypes.ManagerConsole, session.SessionType.?);
    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

test "a login is answered in three places at once" {
    // `create_session`. The response to a session create is the one place in
    // Redfish where the headers carry more than the body does: `X-Auth-Token`
    // is the credential and `Location` is the URI to DELETE, and neither is a
    // property of `Session`. The body is the session as a resource, which is
    // worth having but is not what logging in was for.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expect(mock.Expect.session(
        sessions_uri,
        \\{"UserName":"Administrator","Password":"password"}
    ,
        "session-token-123",
        "/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
        \\{"@odata.id":"/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
        \\ "@odata.type":"#Session.v1_5_0.Session",
        \\ "ClientOriginIPAddress":"127.0.0.1",
        \\ "CreatedTime":"2026-03-18T00:47:59-05:00",
        \\ "Description":"User Session","Id":"1234567890ABCDEF",
        \\ "Name":"User Session","UserName":"Administrator",
        \\ "SessionType":"ManagerConsole"}
        ,
    ));

    const created = try core.bmc.createSession(
        Session,
        testing.allocator,
        &bmc.transport,
        .init(sessions_uri),
        schema.session.SessionCreate{
            .UserName = "Administrator",
            .Password = "password",
        },
    );
    defer created.deinit();

    try testing.expectEqualStrings("session-token-123", created.value.auth_token);
    try testing.expectEqualStrings(
        "/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
        created.value.location.value,
    );

    const session = created.value.entity;
    try testing.expectEqualStrings("Administrator", session.UserName.?);
    try testing.expectEqualStrings("127.0.0.1", session.ClientOriginIPAddress.?);
    try testing.expectEqual(schema.session.SessionTypes.ManagerConsole, session.SessionType.?);

    // The offset is kept rather than normalised: a BMC five hours behind UTC
    // said so, and rewriting that to `Z` would lose the only evidence of
    // where the service thinks it is.
    const created_at = session.CreatedTime.?;
    try testing.expectEqual(@as(u16, 2026), created_at.year);
    try testing.expectEqual(@as(i16, -300), created_at.offset_minutes);

    try bmc.verify();
}

test "the session to delete is the one Location named, not the one the body claims" {
    // `delete_created_session_uses_location`. A service may answer a session
    // create with a body whose `@odata.id` is not the URI it put in
    // `Location`, and DSP0266 says `Location` is where the new resource is.
    // The two differ here only so that the test can tell which one `logout`
    // used; `tests/service.zig` makes the same claim in a comment against a
    // fixture where both are the same string, which proves nothing.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.session(
            sessions_uri,
            \\{"UserName":"Administrator","Password":"password"}
        ,
            "session-token-123",
            "/redfish/v1/SessionService/Sessions/location-id",
            \\{"@odata.id":"/redfish/v1/SessionService/Sessions/body-id",
            \\ "@odata.type":"#Session.v1_5_0.Session",
            \\ "Id":"body-id","Name":"User Session","UserName":"Administrator"}
            ,
        ),
        mock.Expect.delete("/redfish/v1/SessionService/Sessions/location-id"),
    });

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try service.login("Administrator", "password");
    try testing.expectEqualStrings("session-token-123", bmc.auth_token.?);

    try service.logout();

    try testing.expect(!service.loggedIn());
    try testing.expect(bmc.auth_token == null);
    try bmc.verify();
}

test "a service that has only queued the teardown has still ended the session here" {
    // `delete_session_preserves_async_task`. A `202` says the service took
    // the request and will get to it, and `logout` throws the response away,
    // so from this client's side the difference between `202` and `204` is
    // nothing: the token is disowned either way.
    //
    // That is the right answer rather than a shortcut. A caller cannot use a
    // token it has asked to have revoked, whatever the service is still doing
    // about it, and a `logout` that reported the task would be inviting the
    // caller to keep authenticating with a credential it has given up.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.session(
            sessions_uri,
            \\{"UserName":"Administrator","Password":"password"}
        ,
            "session-token-123",
            "/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
            \\{"@odata.id":"/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
            \\ "@odata.type":"#Session.v1_5_0.Session","Id":"1234567890ABCDEF"}
            ,
        ),
        mock.Expect.deleteAccepted(
            "/redfish/v1/SessionService/Sessions/1234567890ABCDEF",
            "/redfish/v1/TaskService/Tasks/51",
            6,
        ),
    });

    var service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    try service.login("Administrator", "password");
    try service.logout();

    try testing.expect(!service.loggedIn());
    try testing.expect(bmc.auth_token == null);
    try bmc.verify();
}
