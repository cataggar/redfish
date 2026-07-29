//! Server-sent events, the wire format behind `EventService`'s SSE endpoint.
//!
//! DSP0266 §13.2 has a Redfish service publish events as a `text/event-stream`,
//! which is the WHATWG HTML "server-sent events" format: a sequence of
//! `field: value` lines, with a blank line dispatching whatever has
//! accumulated. This is the parser for that format. It reads from a
//! `*std.Io.Reader` and knows nothing about HTTP, so `bmc_mock` can drive it
//! from a fixed buffer exactly as `bmc_http` drives it from a socket.
//!
//! ```zig
//! var events: EventReader = .init(gpa, stream.reader, .{});
//! defer events.deinit();
//!
//! while (try events.next()) |event| {
//!     std.log.info("{s}: {s}", .{ event.name, event.data });
//! }
//! ```

const std = @import("std");

const owned = @import("owned.zig");

const Allocator = std.mem.Allocator;
const Owned = owned.Owned;

/// One dispatched event.
///
/// Every field is borrowed from the `EventReader` and is only valid until the
/// next call to `next`.
pub const Event = struct {
    /// The `event` field. WHATWG defaults this to `message` when the stream
    /// does not set one; a Redfish service normally leaves it at the default.
    name: []const u8 = "message",
    /// The `data` fields, joined with newlines. A Redfish event body is the
    /// JSON of an `EventDestination` payload.
    data: []const u8 = &.{},
    /// The stream's last event id, which persists across events until the
    /// stream sets a new one. Null until the stream sets any.
    id: ?[]const u8 = null,
};

pub const Options = struct {
    /// Cap on a single event, counted across all the lines buffered for it.
    /// A service that never sends the blank line terminating an event must
    /// not be able to exhaust the client's memory.
    max_event_bytes: usize = 1 << 20,
};

pub const ReadError = error{
    /// A single event exceeded `max_event_bytes`.
    EventTooLarge,
    /// The underlying reader failed. Transports surface the cause
    /// separately.
    ReadFailed,
} || Allocator.Error;

/// A `text/event-stream` decoder over a `*std.Io.Reader`.
///
/// Borrows the reader; it must outlive the decoder.
pub const EventReader = struct {
    gpa: Allocator,
    reader: *std.Io.Reader,
    max_event_bytes: usize,

    /// Accumulated `data` field values, newline-separated.
    data: std.ArrayList(u8) = .empty,
    /// The current `event` field value. Empty means `message`.
    name: std.ArrayList(u8) = .empty,
    /// The stream's last event id. Unlike `data` and `name`, this survives a
    /// dispatch — WHATWG has it persist until the stream replaces it.
    last_event_id: std.ArrayList(u8) = .empty,
    /// Set once the stream has named an id, so an empty id can be told from
    /// no id at all.
    has_event_id: bool = false,
    /// The line being assembled.
    line: std.ArrayList(u8) = .empty,

    /// The `retry` field, in milliseconds. A stream-level setting rather than
    /// a per-event one: it tells a reconnecting client how long to wait.
    reconnect_ms: ?u64 = null,

    /// The buffers behind the last returned event are still live; clear them
    /// before assembling the next one rather than before returning, so the
    /// caller gets to read what it was handed.
    dispatched: bool = false,
    /// A leading byte-order mark is stripped once, before the first line.
    checked_bom: bool = false,
    /// The stream ended. `next` keeps reporting that rather than reading on.
    finished: bool = false,

    pub fn init(gpa: Allocator, reader: *std.Io.Reader, options: Options) EventReader {
        return .{
            .gpa = gpa,
            .reader = reader,
            .max_event_bytes = options.max_event_bytes,
        };
    }

    pub fn deinit(self: *EventReader) void {
        self.data.deinit(self.gpa);
        self.name.deinit(self.gpa);
        self.last_event_id.deinit(self.gpa);
        self.line.deinit(self.gpa);
        self.* = undefined;
    }

    /// The next event, or null once the stream ends.
    ///
    /// A partially accumulated event at end of stream is discarded, as WHATWG
    /// requires: without its terminating blank line there is no way to know it
    /// was complete.
    pub fn next(self: *EventReader) ReadError!?Event {
        if (self.dispatched) {
            self.data.clearRetainingCapacity();
            self.name.clearRetainingCapacity();
            self.dispatched = false;
        }
        if (self.finished) return null;

        while (true) {
            const line = try self.takeLine() orelse {
                self.finished = true;
                self.data.clearRetainingCapacity();
                self.name.clearRetainingCapacity();
                return null;
            };

            if (line.len == 0) {
                // A blank line dispatches. An event with no data is not an
                // event: WHATWG has it reset the buffers and produce nothing,
                // which is what keeps a stream of bare comments quiet.
                if (self.data.items.len == 0) {
                    self.name.clearRetainingCapacity();
                    continue;
                }
                // Every data line contributed a trailing newline; the last
                // one is a separator with nothing after it.
                if (self.data.items[self.data.items.len - 1] == '\n') {
                    _ = self.data.pop();
                }
                self.dispatched = true;
                return .{
                    .name = if (self.name.items.len == 0) "message" else self.name.items,
                    .data = self.data.items,
                    .id = if (self.has_event_id) self.last_event_id.items else null,
                };
            }

            // A line starting with a colon is a comment. Services use them as
            // heartbeats to keep an idle connection from being reaped.
            if (line[0] == ':') continue;

            try self.field(line);
        }
    }

    /// The next event with its `data` decoded as JSON.
    ///
    /// The returned value owns an arena and outlives the reader's buffers, so
    /// it is safe to keep past the next `next`.
    pub fn nextAs(
        self: *EventReader,
        comptime T: type,
        gpa: Allocator,
    ) !?Owned(T) {
        const event = try self.next() orelse return null;
        return try owned.parseJson(T, gpa, event.data, null);
    }

    /// Applies one `field: value` line.
    fn field(self: *EventReader, line: []const u8) ReadError!void {
        var name = line;
        var value: []const u8 = &.{};
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            name = line[0..colon];
            value = line[colon + 1 ..];
            // Exactly one space after the colon is separator, not content.
            if (value.len != 0 and value[0] == ' ') value = value[1..];
        }

        if (std.mem.eql(u8, name, "event")) {
            self.name.clearRetainingCapacity();
            try self.name.appendSlice(self.gpa, value);
        } else if (std.mem.eql(u8, name, "data")) {
            try self.data.appendSlice(self.gpa, value);
            try self.data.append(self.gpa, '\n');
        } else if (std.mem.eql(u8, name, "id")) {
            // WHATWG ignores an id containing NUL rather than truncating it.
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                self.last_event_id.clearRetainingCapacity();
                try self.last_event_id.appendSlice(self.gpa, value);
                self.has_event_id = true;
            }
        } else if (std.mem.eql(u8, name, "retry")) {
            // Only base-ten digits; anything else leaves the setting alone.
            self.reconnect_ms = std.fmt.parseInt(u64, value, 10) catch return;
        }
        // Any other field name is ignored, which is how the format stays
        // extensible.
    }

    /// One line, with the terminator consumed. Null at end of stream.
    ///
    /// Lines end with CR, LF, or CRLF — all three, because a service is free
    /// to pick any of them and a stream may mix them.
    fn takeLine(self: *EventReader) ReadError!?[]const u8 {
        try self.stripBom();
        self.line.clearRetainingCapacity();

        while (true) {
            const byte = self.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    // A final line with no terminator is not a line: the
                    // stream was cut mid-event.
                    return null;
                },
                error.ReadFailed => return ReadError.ReadFailed,
            };

            switch (byte) {
                '\n' => return self.line.items,
                '\r' => {
                    // Swallow the LF of a CRLF pair, but only if it is there.
                    if (self.reader.peekByte()) |peeked| {
                        if (peeked == '\n') self.reader.toss(1);
                    } else |err| switch (err) {
                        error.EndOfStream => {},
                        error.ReadFailed => return ReadError.ReadFailed,
                    }
                    return self.line.items;
                },
                else => {
                    // The budget covers the whole event, not just this line,
                    // so a service can neither send one enormous line nor
                    // dribble out millions of small ones.
                    if (self.data.items.len + self.line.items.len >= self.max_event_bytes) {
                        return ReadError.EventTooLarge;
                    }
                    try self.line.append(self.gpa, byte);
                },
            }
        }
    }

    fn stripBom(self: *EventReader) ReadError!void {
        if (self.checked_bom) return;
        self.checked_bom = true;

        const bom = "\xEF\xBB\xBF";
        const peeked = self.reader.peek(bom.len) catch |err| switch (err) {
            // Fewer than three bytes left, or a buffer too small to hold
            // them: either way there is no mark to strip.
            error.EndOfStream => return,
            error.ReadFailed => return ReadError.ReadFailed,
        };
        if (std.mem.eql(u8, peeked, bom)) self.reader.toss(bom.len);
    }
};

const testing = std.testing;

/// Collects every event a stream produces, for comparison as a whole.
fn collect(gpa: Allocator, bytes: []const u8, options: Options) ![]Event {
    var reader: std.Io.Reader = .fixed(bytes);
    var events: EventReader = .init(gpa, &reader, options);
    defer events.deinit();

    var list: std.ArrayList(Event) = .empty;
    errdefer freeEvents(gpa, list.items);
    errdefer list.deinit(gpa);

    while (try events.next()) |event| {
        try list.append(gpa, .{
            .name = try gpa.dupe(u8, event.name),
            .data = try gpa.dupe(u8, event.data),
            .id = if (event.id) |id| try gpa.dupe(u8, id) else null,
        });
    }
    return list.toOwnedSlice(gpa);
}

fn freeEvents(gpa: Allocator, events: []const Event) void {
    for (events) |event| {
        gpa.free(event.name);
        gpa.free(event.data);
        if (event.id) |id| gpa.free(id);
    }
}

fn expectEvents(bytes: []const u8, expected: []const Event) !void {
    const events = try collect(testing.allocator, bytes, .{});
    defer testing.allocator.free(events);
    defer freeEvents(testing.allocator, events);

    try testing.expectEqual(expected.len, events.len);
    for (expected, events) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.data, got.data);
        if (want.id) |id| {
            try testing.expectEqualStrings(id, got.id orelse return error.MissingId);
        } else {
            try testing.expectEqual(@as(?[]const u8, null), got.id);
        }
    }
}

test "a single event is dispatched on the blank line" {
    try expectEvents("data: hello\n\n", &.{.{ .data = "hello" }});
}

test "an event with no terminator is discarded" {
    try expectEvents("data: hello\n", &.{});
    try expectEvents("data: hello", &.{});
}

test "consecutive events are separate" {
    try expectEvents(
        "data: one\n\ndata: two\n\n",
        &.{ .{ .data = "one" }, .{ .data = "two" } },
    );
}

test "data lines are joined with newlines" {
    try expectEvents("data: one\ndata: two\ndata: three\n\n", &.{.{ .data = "one\ntwo\nthree" }});
}

test "an empty data line contributes a newline" {
    try expectEvents("data: one\ndata\ndata: two\n\n", &.{.{ .data = "one\n\ntwo" }});
    try expectEvents("data\n\n", &.{.{ .data = "" }});
}

test "exactly one space after the colon is stripped" {
    try expectEvents("data:  padded\n\n", &.{.{ .data = " padded" }});
    try expectEvents("data:tight\n\n", &.{.{ .data = "tight" }});
}

test "a field with no colon has an empty value" {
    // `data` alone is the same as `data:`.
    try expectEvents("event\ndata: x\n\n", &.{.{ .name = "message", .data = "x" }});
}

test "the event name defaults to message and resets between events" {
    try expectEvents(
        "event: Alert\ndata: one\n\ndata: two\n\n",
        &.{ .{ .name = "Alert", .data = "one" }, .{ .name = "message", .data = "two" } },
    );
}

test "the last event id persists across events" {
    try expectEvents(
        "id: 1\ndata: one\n\ndata: two\n\nid: 3\ndata: three\n\n",
        &.{
            .{ .data = "one", .id = "1" },
            .{ .data = "two", .id = "1" },
            .{ .data = "three", .id = "3" },
        },
    );
}

test "an id containing NUL is ignored" {
    try expectEvents(
        "id: 1\ndata: one\n\nid: b\x00d\ndata: two\n\n",
        &.{ .{ .data = "one", .id = "1" }, .{ .data = "two", .id = "1" } },
    );
}

test "comments are skipped and do not dispatch" {
    try expectEvents(": heartbeat\n\ndata: real\n\n", &.{.{ .data = "real" }});
    try expectEvents(":\n:\n:\n", &.{});
}

test "unknown fields are ignored" {
    try expectEvents("severity: Critical\ndata: x\n\n", &.{.{ .data = "x" }});
}

test "every line terminator is accepted" {
    try expectEvents("data: lf\n\n", &.{.{ .data = "lf" }});
    try expectEvents("data: cr\r\r", &.{.{ .data = "cr" }});
    try expectEvents("data: crlf\r\n\r\n", &.{.{ .data = "crlf" }});
    try expectEvents(
        "data: mixed\r\ndata: more\rdata: last\n\n",
        &.{.{ .data = "mixed\nmore\nlast" }},
    );
}

test "a leading byte-order mark is stripped" {
    try expectEvents("\xEF\xBB\xBFdata: x\n\n", &.{.{ .data = "x" }});
    // Only the first one: a second mark is part of the field name and makes
    // it unrecognized.
    try expectEvents("\xEF\xBB\xBF\xEF\xBB\xBFdata: x\n\n", &.{});
}

test "a short stream is not mistaken for a byte-order mark" {
    try expectEvents("\n", &.{});
}

test "retry sets the reconnection time" {
    var reader: std.Io.Reader = .fixed("retry: 2500\ndata: x\n\n");
    var events: EventReader = .init(testing.allocator, &reader, .{});
    defer events.deinit();

    try testing.expectEqual(@as(?u64, null), events.reconnect_ms);
    _ = try events.next();
    try testing.expectEqual(@as(?u64, 2500), events.reconnect_ms);
}

test "a non-numeric retry leaves the reconnection time alone" {
    var reader: std.Io.Reader = .fixed("retry: 1000\n\nretry: soon\ndata: x\n\n");
    var events: EventReader = .init(testing.allocator, &reader, .{});
    defer events.deinit();

    _ = try events.next();
    try testing.expectEqual(@as(?u64, 1000), events.reconnect_ms);
}

test "an oversized event is refused" {
    var reader: std.Io.Reader = .fixed("data: " ++ "x" ** 512 ++ "\n\n");
    var events: EventReader = .init(testing.allocator, &reader, .{ .max_event_bytes = 64 });
    defer events.deinit();

    try testing.expectError(ReadError.EventTooLarge, events.next());
}

test "the budget spans an event's lines, not just one of them" {
    const line = "data: " ++ "x" ** 32 ++ "\n";
    var reader: std.Io.Reader = .fixed(line ** 8 ++ "\n");
    var events: EventReader = .init(testing.allocator, &reader, .{ .max_event_bytes = 100 });
    defer events.deinit();

    try testing.expectError(ReadError.EventTooLarge, events.next());
}

test "the stream stays finished once it ends" {
    var reader: std.Io.Reader = .fixed("data: x\n\n");
    var events: EventReader = .init(testing.allocator, &reader, .{});
    defer events.deinit();

    try testing.expectEqualStrings("x", (try events.next()).?.data);
    try testing.expectEqual(@as(?Event, null), try events.next());
    try testing.expectEqual(@as(?Event, null), try events.next());
}

test "a Redfish event payload decodes from an event's data" {
    var reader: std.Io.Reader = .fixed(
        \\id: 1
        \\data: {"@odata.type":"#Event.v1_7_0.Event","Id":"1","Events":[
        \\data: {"EventType":"Alert","MessageId":"Base.1.0.Success"}]}
        \\
        \\
    );
    var events: EventReader = .init(testing.allocator, &reader, .{});
    defer events.deinit();

    const EventRecord = struct {
        EventType: []const u8,
        MessageId: []const u8,
    };
    const Payload = struct {
        @"@odata.type": []const u8,
        Id: []const u8,
        Events: []const EventRecord,
    };

    var payload = (try events.nextAs(Payload, testing.allocator)).?;
    defer payload.deinit();

    try testing.expectEqualStrings("1", payload.value.Id);
    try testing.expectEqual(@as(usize, 1), payload.value.Events.len);
    try testing.expectEqualStrings("Alert", payload.value.Events[0].EventType);
    try testing.expectEqualStrings("Base.1.0.Success", payload.value.Events[0].MessageId);

    try testing.expectEqual(@as(?Owned(Payload), null), try events.nextAs(Payload, testing.allocator));
}
