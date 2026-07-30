//! `session_login` — trade a username and password for a session token.
//!
//! ```
//! session_login --bmc https://bmc.example --username root --password calvin
//! ```
//!
//! Basic authentication works on every request and costs a password hash on
//! every request; a session costs one POST and then a header. What makes this
//! worth an example is where the session collection is found. DSP0266 puts it
//! at `ServiceRoot.Links.Sessions`, *not* at `SessionService.Sessions`, and
//! the reason is the order of operations: the service root is the one
//! resource readable without credentials, so a client that had to read
//! `SessionService` first would need the credentials that logging in exists
//! to obtain.
//!
//! Logging out is the other half. A service enforces a session limit, and a
//! program that logs in per run and abandons the session eventually cannot
//! log in at all.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const cli = @import("cli.zig");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const AccountService = schema.account_service.AccountService;

pub const usage =
    \\session_login — obtain and release a Redfish session.
    \\
    \\Usage:
    \\  session_login --bmc <url> --username <name> --password <secret>
    \\                [--keep]
    \\
    \\  --bmc <url>        Required, e.g. https://bmc.example.
    \\  --username <name>  Required.
    \\  --password <secret> Required.
    \\  --keep             Leave the session open instead of deleting it.
    \\  -h, --help         This message.
    \\
;

pub fn run(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    username: []const u8,
    password: []const u8,
    keep: bool,
) !void {
    // Anonymous so far: the root is the one resource that does not need
    // credentials, which is exactly why the session collection is named in it.
    var service = try Service.connect(gpa, transport);
    defer service.deinit();

    try out.print("{s} {s}\n", .{
        service.vendor() orelse "(no vendor)",
        service.product() orelse "(no product)",
    });

    try service.login(username, password);
    try out.writeAll("logged in; every later request carries X-Auth-Token\n");

    // Proof the token is in use: `AccountService` is not readable anonymously
    // on any service worth the name.
    if (service.has("AccountService")) {
        const accounts = try service.open("AccountService");
        defer accounts.deinit();
        try out.print("AccountService: {s}\n", .{
            accounts.get().Name orelse accounts.get().Id orelse "(unnamed)",
        });
    }

    if (keep) {
        try out.writeAll("session left open\n");
        return;
    }

    try service.logout();
    try out.writeAll("session deleted\n");
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

    const url = cli.flag(argv, "bmc") orelse "";
    const username = cli.flag(argv, "username") orelse "";
    const password = cli.flag(argv, "password") orelse "";
    if (url.len == 0 or username.len == 0 or password.len == 0) {
        try out.writeAll("session_login: --bmc, --username and --password are required\n\n" ++ usage);
        return 2;
    }

    var connection: cli.Connection = undefined;
    // Opened anonymously on purpose. Sending Basic credentials as well would
    // make it impossible to tell whether the token is what the service
    // accepted.
    try connection.open(init.gpa, io, url, .anonymous);
    defer connection.close();

    try run(init.gpa, connection.transport(), out, username, password, cli.present(argv, "keep"));
    return 0;
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "Vendor":"Contoso","Product":"Contoso BMC",
    \\ "AccountService":{"@odata.id":"/redfish/v1/AccountService"},
    \\ "SessionService":{"@odata.id":"/redfish/v1/SessionService"},
    \\ "Links":{"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}}
;

test "the example logs in, uses the token, and logs out" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.session("/redfish/v1/SessionService/Sessions",
            \\{"UserName":"root","Password":"calvin"}
        , "token-abc", "/redfish/v1/SessionService/Sessions/9",
            \\{"@odata.id":"/redfish/v1/SessionService/Sessions/9",
            \\ "@odata.type":"#Session.v1_7_0.Session",
            \\ "Id":"9","Name":"User Session","UserName":"root"}
        ),
        mock.Expect.get("/redfish/v1/AccountService",
            \\{"@odata.id":"/redfish/v1/AccountService",
            \\ "@odata.type":"#AccountService.v1_17_0.AccountService",
            \\ "Id":"AccountService","Name":"Account Service"}
        ),
        mock.Expect.delete("/redfish/v1/SessionService/Sessions/9"),
    });

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, "root", "calvin", false);

    try testing.expectEqualStrings(
        \\Contoso Contoso BMC
        \\logged in; every later request carries X-Auth-Token
        \\AccountService: Account Service
        \\session deleted
        \\
    , out.buffered());

    // Logging out disowns the token as well as deleting the session, so a
    // later request would go out unauthenticated rather than with a
    // credential the service has already invalidated.
    try testing.expectEqual(@as(?[]const u8, null), bmc.auth_token);
    try bmc.verify();
}

test "--keep leaves the session open and the token in use" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.session("/redfish/v1/SessionService/Sessions",
            \\{"UserName":"root","Password":"calvin"}
        , "token-abc", "/redfish/v1/SessionService/Sessions/9",
            \\{"@odata.id":"/redfish/v1/SessionService/Sessions/9",
            \\ "@odata.type":"#Session.v1_7_0.Session","Id":"9","Name":"User Session"}
        ),
        mock.Expect.get("/redfish/v1/AccountService",
            \\{"@odata.id":"/redfish/v1/AccountService",
            \\ "@odata.type":"#AccountService.v1_17_0.AccountService",
            \\ "Id":"AccountService","Name":"Account Service"}
        ),
    });

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, "root", "calvin", true);

    try testing.expectEqualStrings("token-abc", bmc.auth_token.?);
    try bmc.verify();
}

test "a service that advertises no session collection says so" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    // One of DMTF's 27 published roots links `SessionService` without
    // `Links.Sessions`. `login` cannot guess the collection's URI, and
    // guessing is what `loginAt` is for.
    try bmc.expect(mock.Expect.get("/redfish/v1",
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "Id":"RootService","Name":"Root Service",
        \\ "SessionService":{"@odata.id":"/redfish/v1/SessionService"}}
    ));

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try testing.expectError(
        error.SessionsNotAdvertised,
        run(testing.allocator, &bmc.transport, &out, "root", "calvin", false),
    );

    try bmc.verify();
}
