//! The Redfish error payload.
//!
//! When a service rejects a request it answers with a body of a fixed shape,
//! defined by the `redfish-error` schema:
//!
//! ```json
//! {
//!   "error": {
//!     "code": "Base.1.0.GeneralError",
//!     "message": "A general error has occurred. See ExtendedInfo.",
//!     "@Message.ExtendedInfo": [
//!       {
//!         "MessageId": "Base.1.0.PropertyValueNotInList",
//!         "Message": "The value Red for IndicatorLED is not in the list.",
//!         "MessageArgs": ["Red", "IndicatorLED"],
//!         "MessageSeverity": "Warning",
//!         "Resolution": "Choose a value from the enumeration list."
//!       }
//!     ]
//!   }
//! }
//! ```
//!
//! This type is hand-written rather than generated. The shape has not
//! changed since Redfish 1.0, every transport needs it before any schema
//! package exists, and the generated packages would each carry their own
//! copy otherwise.
//!
//! Reference: DMTF DSP0266, "Error responses".

const std = @import("std");

/// How bad a message is. Redfish 1.6 renamed `Severity` to `MessageSeverity`
/// and narrowed the values; both spellings still appear on real BMCs.
pub const Severity = enum {
    OK,
    Warning,
    Critical,

    pub fn parse(text: []const u8) ?Severity {
        return std.meta.stringToEnum(Severity, text);
    }
};

/// One entry of `@Message.ExtendedInfo`.
///
/// Every field is optional. Services omit them freely, and a client that
/// requires any particular one will eventually meet a BMC that leaves it
/// out.
pub const Message = struct {
    /// Registry-qualified identifier, e.g. `Base.1.0.PropertyValueNotInList`.
    MessageId: ?[]const u8 = null,
    /// Human-readable text, with `MessageArgs` already substituted in.
    Message: ?[]const u8 = null,
    /// The values substituted into the registry's message template.
    MessageArgs: ?[]const []const u8 = null,
    /// Redfish 1.6 and later.
    MessageSeverity: ?[]const u8 = null,
    /// Deprecated in Redfish 1.6, still emitted by many services.
    Severity: ?[]const u8 = null,
    /// What the operator should do about it.
    Resolution: ?[]const u8 = null,
    /// JSON pointers to the properties this message is about.
    RelatedProperties: ?[]const []const u8 = null,

    /// The severity, preferring the current spelling and falling back to the
    /// deprecated one. Null when neither is present or neither parses.
    pub fn severity(self: Message) ?Severity {
        if (self.MessageSeverity) |text| {
            if (Severity.parse(text)) |value| return value;
        }
        if (self.Severity) |text| return Severity.parse(text);
        return null;
    }

    /// The last dot-separated segment of `MessageId` — the message name
    /// without its registry and version, e.g. `PropertyValueNotInList`.
    pub fn messageName(self: Message) ?[]const u8 {
        return lastSegment(self.MessageId orelse return null);
    }

    /// The registry a message came from, e.g. `Base` for
    /// `Base.1.0.PropertyValueNotInList`. Null when `MessageId` has no
    /// registry prefix.
    pub fn registry(self: Message) ?[]const u8 {
        const id = self.MessageId orelse return null;
        const dot = std.mem.indexOfScalar(u8, id, '.') orelse return null;
        return id[0..dot];
    }

    pub fn format(self: Message, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.MessageId) |id| try w.print("{s}", .{id});
        if (self.Message) |text| {
            if (self.MessageId != null) try w.writeAll(": ");
            try w.writeAll(text);
        }
    }
};

/// The `error` object inside a Redfish error body.
pub const ErrorBody = struct {
    /// Registry-qualified identifier for the overall failure.
    code: []const u8 = "",
    /// Human-readable summary.
    message: []const u8 = "",
    @"@Message.ExtendedInfo": ?[]const Message = null,

    /// The detailed messages, or an empty slice when the service sent none.
    pub fn extendedInfo(self: ErrorBody) []const Message {
        return self.@"@Message.ExtendedInfo" orelse &.{};
    }
};

/// A Redfish error response body.
pub const RedfishError = struct {
    @"error": ErrorBody = .{},

    /// The detailed messages, or an empty slice when the service sent none.
    pub fn extendedInfo(self: RedfishError) []const Message {
        return self.@"error".extendedInfo();
    }

    /// The last dot-separated segment of `error.code`, e.g. `GeneralError`
    /// for `Base.1.0.GeneralError`.
    pub fn codeName(self: RedfishError) []const u8 {
        return lastSegment(self.@"error".code);
    }

    /// The highest severity across the extended info, or null when nothing
    /// declared one.
    pub fn worstSeverity(self: RedfishError) ?Severity {
        var worst: ?Severity = null;
        for (self.extendedInfo()) |message| {
            const value = message.severity() orelse continue;
            if (worst == null or @intFromEnum(value) > @intFromEnum(worst.?)) worst = value;
        }
        return worst;
    }

    /// Parse an error body. Returns null when `bytes` is not one, so a
    /// caller can fall back to reporting the raw body.
    ///
    /// Leaky by design: everything lands in `arena`, which is the response
    /// arena the body itself came from.
    pub fn parseLeaky(arena: std.mem.Allocator, bytes: []const u8) ?RedfishError {
        return std.json.parseFromSliceLeaky(RedfishError, arena, bytes, .{
            .allocate = .alloc_if_needed,
            .ignore_unknown_fields = true,
        }) catch null;
    }

    pub fn format(self: RedfishError, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: {s}", .{ self.@"error".code, self.@"error".message });
        for (self.extendedInfo()) |message| {
            try w.print("\n  {f}", .{message});
            if (message.Resolution) |resolution| try w.print("\n    {s}", .{resolution});
        }
    }
};

/// Message codes whose last segment means "this worked".
///
/// DSP0266 7.11, Table 10: an operation with no response body may answer
/// with an error-shaped body that reports success. Treating one of those as
/// a failure would turn a completed action into a spurious error.
const success_codes = [_][]const u8{ "Success", "Created", "NoOperation" };

/// Whether an error-shaped body actually reports success.
///
/// Two shapes qualify:
///   * a top-level `@Message.ExtendedInfo` array with no enclosing `error`
///     object — a service reporting informational messages about a request
///     that worked;
///   * a normal error body whose `code` ends in `Success`, `Created`, or
///     `NoOperation`.
///
/// Anything else, including a body that is not an error at all, is false.
pub fn isSuccessBody(arena: std.mem.Allocator, bytes: []const u8) bool {
    const Envelope = struct {
        @"@Message.ExtendedInfo": []const Message,
    };
    if (std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    })) |_| {
        return true;
    } else |_| {}

    const parsed = RedfishError.parseLeaky(arena, bytes) orelse return false;
    const name = parsed.codeName();
    for (success_codes) |code| {
        if (std.mem.eql(u8, name, code)) return true;
    }
    return false;
}

fn lastSegment(value: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, value, '.') orelse return value;
    return value[dot + 1 ..];
}

const testing = std.testing;

/// Parse into a scratch arena and hand the value to `check`.
fn withParsed(
    bytes: []const u8,
    context: anytype,
    comptime check: fn (@TypeOf(context), RedfishError) anyerror!void,
) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = RedfishError.parseLeaky(arena.allocator(), bytes) orelse
        return error.NotAnErrorBody;
    try check(context, parsed);
}

const full_body =
    \\{
    \\  "error": {
    \\    "code": "Base.1.0.GeneralError",
    \\    "message": "A general error has occurred. See ExtendedInfo.",
    \\    "@Message.ExtendedInfo": [
    \\      {
    \\        "@odata.type": "#Message.v1_0_0.Message",
    \\        "MessageId": "Base.1.0.PropertyValueNotInList",
    \\        "Message": "The value Red for IndicatorLED is not in the list.",
    \\        "MessageArgs": ["Red", "IndicatorLED"],
    \\        "MessageSeverity": "Warning",
    \\        "Resolution": "Choose a value from the enumeration list.",
    \\        "RelatedProperties": ["#/IndicatorLED"]
    \\      }
    \\    ]
    \\  }
    \\}
;

test "parses a full error body" {
    try withParsed(full_body, {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqualStrings("Base.1.0.GeneralError", parsed.@"error".code);
            try testing.expectEqualStrings("GeneralError", parsed.codeName());
            try testing.expectEqual(@as(usize, 1), parsed.extendedInfo().len);

            const message = parsed.extendedInfo()[0];
            try testing.expectEqualStrings("Base.1.0.PropertyValueNotInList", message.MessageId.?);
            try testing.expectEqualStrings("PropertyValueNotInList", message.messageName().?);
            try testing.expectEqualStrings("Base", message.registry().?);
            try testing.expectEqual(Severity.Warning, message.severity().?);
            try testing.expectEqual(@as(usize, 2), message.MessageArgs.?.len);
            try testing.expectEqualStrings("Red", message.MessageArgs.?[0]);
            try testing.expectEqualStrings("#/IndicatorLED", message.RelatedProperties.?[0]);
        }
    }.check);
}

test "parses a body with no extended info" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.AccessDenied","message":"Denied."}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqualStrings("AccessDenied", parsed.codeName());
            try testing.expectEqual(@as(usize, 0), parsed.extendedInfo().len);
            try testing.expectEqual(@as(?Severity, null), parsed.worstSeverity());
        }
    }.check);
}

test "ignores schema properties it does not model" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.X","message":"m","@Message.ExtendedInfo":[],
        \\ "@odata.type":"#RedfishError.v1_0_0.RedfishError","Oem":{"Vendor":{"A":1}}}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqualStrings("Base.1.0.X", parsed.@"error".code);
        }
    }.check);
}

test "falls back to the deprecated Severity spelling" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.X","message":"m","@Message.ExtendedInfo":[
        \\ {"MessageId":"Base.1.0.Y","Severity":"Critical"}]}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            const message = parsed.extendedInfo()[0];
            try testing.expectEqual(Severity.Critical, message.severity().?);
            try testing.expectEqual(@as(?[]const u8, null), message.MessageSeverity);
        }
    }.check);
}

test "MessageSeverity wins over the deprecated Severity" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.X","message":"m","@Message.ExtendedInfo":[
        \\ {"MessageSeverity":"OK","Severity":"Critical"}]}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqual(Severity.OK, parsed.extendedInfo()[0].severity().?);
        }
    }.check);
}

test "an unrecognized severity is null rather than an error" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.X","message":"m","@Message.ExtendedInfo":[
        \\ {"MessageSeverity":"Catastrophic"}]}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqual(@as(?Severity, null), parsed.extendedInfo()[0].severity());
        }
    }.check);
}

test "worstSeverity picks the highest across messages" {
    try withParsed(
        \\{"error":{"code":"Base.1.0.X","message":"m","@Message.ExtendedInfo":[
        \\ {"MessageSeverity":"OK"},{"MessageSeverity":"Critical"},{"MessageSeverity":"Warning"}]}}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqual(Severity.Critical, parsed.worstSeverity().?);
        }
    }.check);
}

test "a message id without a registry prefix has no registry" {
    const message: Message = .{ .MessageId = "Success" };
    try testing.expectEqualStrings("Success", message.messageName().?);
    try testing.expectEqual(@as(?[]const u8, null), message.registry());
}

test "parseLeaky returns null for a body that is not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `error` must be an object; a string is the wrong shape.
    try testing.expectEqual(
        @as(?RedfishError, null),
        RedfishError.parseLeaky(arena.allocator(), "{\"error\":\"nope\"}"),
    );
    try testing.expectEqual(
        @as(?RedfishError, null),
        RedfishError.parseLeaky(arena.allocator(), "not json at all"),
    );
}

test "a resource body parses as an error with empty fields" {
    // `ignore_unknown_fields` means an ordinary resource decodes into an
    // error with a blank code. That is why `isSuccessBody` checks the code
    // rather than merely whether parsing succeeded.
    try withParsed(
        \\{"@odata.id":"/redfish/v1/Chassis/1","Name":"Tray"}
    , {}, struct {
        fn check(_: void, parsed: RedfishError) !void {
            try testing.expectEqualStrings("", parsed.@"error".code);
            try testing.expectEqual(@as(usize, 0), parsed.extendedInfo().len);
        }
    }.check);
}

fn expectSuccessBody(bytes: []const u8, expected: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(expected, isSuccessBody(arena.allocator(), bytes));
}

test "an error-shaped body reporting success is recognized" {
    // DSP0266 7.11, Table 10.
    try expectSuccessBody(
        \\{"error":{"code":"Base.1.0.Success","message":"Successfully Completed Request."}}
    , true);
    try expectSuccessBody(
        \\{"error":{"code":"Base.1.13.0.Created","message":"The resource was created."}}
    , true);
    try expectSuccessBody(
        \\{"error":{"code":"Base.1.0.NoOperation","message":"Nothing to do."}}
    , true);
}

test "a top-level ExtendedInfo array reports success" {
    try expectSuccessBody(
        \\{"@Message.ExtendedInfo":[{"MessageId":"Base.1.0.Success"}]}
    , true);
    try expectSuccessBody("{\"@Message.ExtendedInfo\":[]}", true);
}

test "a genuine failure is not mistaken for success" {
    try expectSuccessBody(full_body, false);
    try expectSuccessBody(
        \\{"error":{"code":"Base.1.0.AccessDenied","message":"Denied."}}
    , false);
    // `Successful` is not `Success`; the whole last segment must match.
    try expectSuccessBody(
        \\{"error":{"code":"Base.1.0.Successful","message":"m"}}
    , false);
}

test "an ordinary resource body is not a success body" {
    try expectSuccessBody(
        \\{"@odata.id":"/redfish/v1/Chassis/1","Name":"Tray"}
    , false);
    try expectSuccessBody("not json at all", false);
    try expectSuccessBody("", false);
}

test "formats an error for a log line" {
    var buf: [512]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = RedfishError.parseLeaky(arena.allocator(), full_body).?;
    try testing.expectEqualStrings(
        "Base.1.0.GeneralError: A general error has occurred. See ExtendedInfo.\n" ++
            "  Base.1.0.PropertyValueNotInList: The value Red for IndicatorLED is not in the list.\n" ++
            "    Choose a value from the enumeration list.",
        try std.fmt.bufPrint(&buf, "{f}", .{parsed}),
    );
}

test "formats a message with only one of id and text" {
    var buf: [128]u8 = undefined;

    try testing.expectEqualStrings(
        "Base.1.0.Y",
        try std.fmt.bufPrint(&buf, "{f}", .{Message{ .MessageId = "Base.1.0.Y" }}),
    );
    try testing.expectEqualStrings(
        "something went wrong",
        try std.fmt.bufPrint(&buf, "{f}", .{Message{ .Message = "something went wrong" }}),
    );
    try testing.expectEqualStrings("", try std.fmt.bufPrint(&buf, "{f}", .{Message{}}));
}
