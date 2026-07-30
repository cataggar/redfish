//! `event_stream` — print a service's events as they arrive.
//!
//! ```
//! event_stream --bmc https://bmc.example --username root --password calvin
//! ```
//!
//! Redfish gives an `EventService` two ways to deliver: it POSTs to a
//! subscriber's URI, or it streams `text/event-stream` from
//! `ServerSentEventUri` to a client that asks. The second needs no listening
//! socket on this end, which is why it is the one worth showing.
//!
//! Each event's `data` is the JSON of an `Event` resource, so the stream is
//! read with the same generated types as everything else. `nextAs` parses it
//! into an arena the event outlives, because `next` alone hands back a slice
//! borrowed from the reader's buffer and valid only until the following call.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const cli = @import("cli.zig");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Event = schema.event.Event;
const EventRecord = schema.event.EventRecord;

pub const usage =
    \\event_stream — print Redfish events as the service sends them.
    \\
    \\Usage:
    \\  event_stream --bmc <url> [--username <name> --password <secret>]
    \\               [--count <n>]
    \\
    \\  --bmc <url>        Required, e.g. https://bmc.example.
    \\  --username <name>  Sent as HTTP Basic together with --password.
    \\  --password <secret>
    \\  --count <n>        Stop after n events. Default: stream until the
    \\                     service closes the connection.
    \\  -h, --help         This message.
    \\
;

pub fn run(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    limit: ?usize,
) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    if (!service.has("EventService")) {
        try out.writeAll("this service has no EventService\n");
        return;
    }

    const event_service = try service.open("EventService");
    defer event_service.deinit();

    const uri = event_service.get().ServerSentEventUri orelse {
        // An `EventService` that only pushes to subscribers is conformant;
        // it simply cannot serve this program.
        try out.writeAll("EventService advertises no ServerSentEventUri\n");
        return;
    };

    try out.print("streaming {s}\n", .{uri});

    var stream = try core.bmc.stream(transport, uri);
    defer stream.close();

    var reader: core.EventReader = .init(gpa, stream.reader, .{});
    defer reader.deinit();

    var seen: usize = 0;
    while (limit == null or seen < limit.?) : (seen += 1) {
        const payload = try reader.nextAs(Event, gpa) orelse break;
        defer payload.deinit();

        for (payload.value.Events orelse &.{}) |link| {
            // Inline in every event a service actually sends; `follow` is
            // still the right call, because it is what makes the one that
            // is not inline work too.
            const record = try core.follow(EventRecord, gpa, transport, link);
            defer record.deinit();
            try describe(record.get(), out);
        }
    }

    try out.print("{d} event(s)\n", .{seen});
}

fn describe(record: *const EventRecord, out: *std.Io.Writer) !void {
    try out.print("  {s}", .{record.MessageId orelse "(no MessageId)"});
    if (record.MessageSeverity) |severity| try out.print(" [{t}]", .{severity});
    if (record.EventTimestamp) |stamp| try out.print(" {f}", .{stamp});
    if (record.Message) |message| try out.print(" {s}", .{message});
    try out.writeByte('\n');
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

    const url = cli.flag(argv, "bmc") orelse {
        try out.writeAll("event_stream: --bmc is required\n\n" ++ usage);
        return 2;
    };

    const limit: ?usize = if (cli.flag(argv, "count")) |text|
        std.fmt.parseInt(usize, text, 10) catch {
            try out.print("event_stream: --count wants a number, got {s}\n", .{text});
            return 2;
        }
    else
        null;

    var connection: cli.Connection = undefined;
    try connection.open(init.gpa, io, url, cli.credentialsFrom(argv));
    defer connection.close();

    // Flushed per event rather than per buffer: a stream that prints nothing
    // for an hour and then eight lines at once is not a console.
    try run(init.gpa, connection.transport(), out, limit);
    return 0;
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "EventService":{"@odata.id":"/redfish/v1/EventService"}}
;

test "the example prints each event the service streams" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/EventService",
            \\{"@odata.id":"/redfish/v1/EventService",
            \\ "@odata.type":"#EventService.v1_11_0.EventService",
            \\ "Id":"EventService","Name":"Event Service",
            \\ "ServerSentEventUri":"/redfish/v1/EventService/SSE"}
        ),
        mock.Expect.stream("/redfish/v1/EventService/SSE",
            \\event: Event
            \\data: {"@odata.type":"#Event.v1_11_0.Event","Id":"1","Name":"Alert",
            \\data:  "Events":[{"MemberId":"1","MessageId":"Alert.1.0.LanDisconnect",
            \\data:  "MessageSeverity":"Warning","EventTimestamp":"2026-07-30T03:34:56Z",
            \\data:  "Message":"A LAN Disconnect on Port 1 was detected."}]}
            \\
            \\data: {"@odata.type":"#Event.v1_11_0.Event","Id":"2","Name":"Alert",
            \\data:  "Events":[{"MemberId":"1","MessageId":"Alert.1.0.LanConnect",
            \\data:  "MessageSeverity":"OK",
            \\data:  "Message":"A LAN Connect on Port 1 was detected."}]}
            \\
            \\
        ),
    });

    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, null);

    try testing.expectEqualStrings(
        \\streaming /redfish/v1/EventService/SSE
        \\  Alert.1.0.LanDisconnect [Warning] 2026-07-30T03:34:56Z A LAN Disconnect on Port 1 was detected.
        \\  Alert.1.0.LanConnect [OK] A LAN Connect on Port 1 was detected.
        \\2 event(s)
        \\
    , out.buffered());

    try testing.expect(bmc.request(2).is_stream);
    try bmc.verify();
}

test "--count stops the stream early" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/EventService",
            \\{"@odata.id":"/redfish/v1/EventService",
            \\ "@odata.type":"#EventService.v1_11_0.EventService",
            \\ "Id":"EventService","Name":"Event Service",
            \\ "ServerSentEventUri":"/redfish/v1/EventService/SSE"}
        ),
        mock.Expect.stream("/redfish/v1/EventService/SSE",
            \\data: {"Id":"1","Events":[{"MessageId":"Alert.1.0.One"}]}
            \\
            \\data: {"Id":"2","Events":[{"MessageId":"Alert.1.0.Two"}]}
            \\
            \\
        ),
    });

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, 1);

    try testing.expectEqualStrings(
        \\streaming /redfish/v1/EventService/SSE
        \\  Alert.1.0.One
        \\1 event(s)
        \\
    , out.buffered());

    try bmc.verify();
}

test "an EventService with no ServerSentEventUri is not a failure" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/EventService",
            \\{"@odata.id":"/redfish/v1/EventService",
            \\ "@odata.type":"#EventService.v1_11_0.EventService",
            \\ "Id":"EventService","Name":"Event Service"}
        ),
    });

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, &bmc.transport, &out, null);

    try testing.expectEqualStrings(
        "EventService advertises no ServerSentEventUri\n",
        out.buffered(),
    );

    try bmc.verify();
}
