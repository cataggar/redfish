//! Redfish actions — the invocable operations under a resource's `Actions`
//! object.
//!
//! A service advertises an action as an object naming its endpoint:
//!
//! ```json
//! {
//!   "Actions": {
//!     "#ComputerSystem.Reset": {
//!       "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
//!       "ResetType@Redfish.AllowableValues": ["On", "GracefulRestart"]
//!     }
//!   }
//! }
//! ```
//!
//! `Action(Parameters, Result)` models the inner object. Only `target` is
//! decoded; the annotations beside it describe constraints that a higher layer
//! may read from the raw payload.
//!
//! Reference: DMTF DSP0266, "Actions".

const std = @import("std");
const odata = @import("odata.zig");

const ODataId = odata.ODataId;

/// The URI reference in an action's `target`.
///
/// Kept distinct from `ODataId`: an action target is an invocation endpoint,
/// not a resource identity, and the transport applies its outbound request
/// policy to it before use.
pub const ActionTarget = struct {
    value: []const u8,

    pub fn init(value: []const u8) ActionTarget {
        return .{ .value = value };
    }

    pub fn eql(self: ActionTarget, other: ActionTarget) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    pub fn format(self: ActionTarget, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return w.writeAll(self.value);
    }

    pub fn jsonStringify(self: ActionTarget, jw: anytype) !void {
        return jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ActionTarget {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ActionTarget {
        return .{
            .value = try std.json.innerParseFromValue([]const u8, allocator, source, options),
        };
    }
};

/// What can go wrong before a request is even sent.
pub const ActionError = error{
    /// The resource did not advertise the action, so there is no target to
    /// POST to. A service omits an action it does not implement, and a
    /// generated wrapper cannot invent a URI for it.
    ActionNotSupported,
};

/// An action taking `Parameters` and returning `Result`.
///
/// `nv-redfish` carries the two types as `PhantomData`; here they are `pub
/// const` declarations, which costs no storage and lets generated call sites
/// name them (`@TypeOf(action).Parameters`).
pub fn Action(comptime P: type, comptime R: type) type {
    return struct {
        target: ActionTarget,

        const Self = @This();

        /// Body type POSTed to `target`.
        pub const Parameters = P;
        /// Type the service returns.
        pub const Result = R;

        pub fn init(target: ActionTarget) Self {
            return .{ .target = target };
        }

        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.target.format(w);
        }

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("target");
            try jw.write(self.target);
            try jw.endObject();
        }

        /// Decodes `target` and skips everything else.
        ///
        /// The sibling properties are `@Redfish.AllowableValues` and
        /// `@Redfish.ActionInfo` annotations whose names vary per action, so
        /// they cannot be declared as struct fields; ignoring them here is
        /// what makes the type usable across every generated action.
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            var tolerant = options;
            tolerant.ignore_unknown_fields = true;

            const Body = struct { target: ActionTarget };
            const body = try std.json.innerParse(Body, allocator, source, tolerant);
            return .{ .target = body.target };
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Self {
            var tolerant = options;
            tolerant.ignore_unknown_fields = true;

            const Body = struct { target: ActionTarget };
            const body = try std.json.innerParseFromValue(Body, allocator, source, tolerant);
            return .{ .target = body.target };
        }
    };
}

const testing = std.testing;
const owned = @import("owned.zig");

const ResetParameters = struct { ResetType: []const u8 };
const ResetResult = struct { @"@odata.id": ODataId };

const Reset = Action(ResetParameters, ResetResult);

test "decodes target and ignores the annotations beside it" {
    const parsed = try owned.parseJson(Reset, testing.allocator,
        \\{
        \\  "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        \\  "@Redfish.ActionInfo": "/redfish/v1/Systems/1/ResetActionInfo",
        \\  "ResetType@Redfish.AllowableValues": ["On", "GracefulRestart"]
        \\}
    , null);
    defer parsed.deinit();

    try testing.expect(parsed.value.target.eql(
        .init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"),
    ));
}

test "ignores annotations even when the caller asks for strict options" {
    // The annotation names vary per action, so they can never be declared as
    // fields; strictness here would make the type unusable.
    const parsed = try owned.parseJson(Reset, testing.allocator,
        \\{
        \\  "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        \\  "ResetType@Redfish.AllowableValues": ["On"]
        \\}
    , .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.target.eql(
        .init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"),
    ));
}

test "requires target" {
    try testing.expectError(error.MissingField, owned.parseJson(
        Reset,
        testing.allocator,
        "{ \"@Redfish.ActionInfo\": \"/redfish/v1/Info\" }",
        null,
    ));
}

test "decodes inside an Actions object" {
    const Actions = struct {
        @"#ComputerSystem.Reset": Reset,
    };

    const parsed = try owned.parseJson(Actions, testing.allocator,
        \\{
        \\  "#ComputerSystem.Reset": {
        \\    "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        \\    "ResetType@Redfish.AllowableValues": ["On"]
        \\  }
        \\}
    , null);
    defer parsed.deinit();

    try testing.expect(parsed.value.@"#ComputerSystem.Reset".target.eql(
        .init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"),
    ));
}

test "the parameter and result types are reachable from the value" {
    const action = Reset.init(.init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"));
    try testing.expectEqual(ResetParameters, @TypeOf(action).Parameters);
    try testing.expectEqual(ResetResult, @TypeOf(action).Result);
}

test "the type carries no storage for its parameters" {
    // `Parameters` and `Result` are declarations, not fields.
    try testing.expectEqual(@sizeOf(ActionTarget), @sizeOf(Reset));
}

test "serializes back to an object with just target" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(
        Reset.init(.init("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")),
        .{},
        &w,
    );
    try testing.expectEqualStrings(
        "{\"target\":\"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset\"}",
        w.buffered(),
    );
}

test "ActionTarget round-trips as a bare JSON string" {
    const Wrapper = struct { target: ActionTarget };

    var buf: [96]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(Wrapper{ .target = .init("/redfish/v1/Actions/X") }, .{}, &w);
    try testing.expectEqualStrings("{\"target\":\"/redfish/v1/Actions/X\"}", w.buffered());

    const parsed = try owned.parseJson(Wrapper, testing.allocator, w.buffered(), null);
    defer parsed.deinit();
    try testing.expect(parsed.value.target.eql(.init("/redfish/v1/Actions/X")));
}

test "ActionTarget formats as its raw value" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "/redfish/v1/Actions/X",
        try std.fmt.bufPrint(&buf, "{f}", .{ActionTarget.init("/redfish/v1/Actions/X")}),
    );
}
