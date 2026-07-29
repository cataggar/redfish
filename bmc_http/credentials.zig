//! BMC credentials.
//!
//! Redfish offers two authentication schemes: HTTP Basic on every request,
//! and a session token in `X-Auth-Token`. A client normally starts with
//! Basic, creates a session, and switches to the token — so credentials are
//! mutable state on a live connection, not a constructor argument.
//!
//! Every `format` here redacts the secret. A credential value is exactly the
//! sort of thing that ends up in a debug print.

const std = @import("std");

const core = @import("redfish_core");

const Header = core.bmc.Header;

pub const Credentials = union(enum) {
    /// Unauthenticated. Legal for the service root and for `$metadata`,
    /// which Redfish requires to be readable without credentials.
    anonymous,
    /// HTTP Basic, sent on every request.
    basic: Basic,
    /// A Redfish session token, sent as `X-Auth-Token`.
    token: []const u8,

    pub const Basic = struct {
        username: []const u8,
        /// Absent is distinct from empty only in intent; both encode as an
        /// empty password field. Redfish services do reject empty passwords,
        /// so this mostly exists to model the accounts that have none.
        password: ?[]const u8 = null,
    };

    pub fn initBasic(username: []const u8, password: []const u8) Credentials {
        return .{ .basic = .{ .username = username, .password = password } };
    }

    pub fn initToken(value: []const u8) Credentials {
        return .{ .token = value };
    }

    /// Number of bytes `header` needs, so a caller can size a fixed buffer.
    pub fn headerSize(self: Credentials) usize {
        return switch (self) {
            .anonymous => 0,
            .basic => |basic| basic_prefix.len + std.base64.standard.Encoder.calcSize(
                basic.username.len + 1 + passwordOrEmpty(basic).len,
            ),
            .token => 0,
        };
    }

    /// The authentication header to attach to a request, or null when there
    /// is nothing to send.
    ///
    /// Basic needs an allocation for the base64; the token form borrows.
    pub fn header(self: Credentials, arena: std.mem.Allocator) !?Header {
        return switch (self) {
            .anonymous => null,
            .basic => .{ .name = "Authorization", .value = try self.basicValue(arena) },
            .token => |value| .{ .name = "X-Auth-Token", .value = value },
        };
    }

    /// `Basic <base64(user:pass)>`, per RFC 7617.
    ///
    /// The username may not contain a colon: RFC 7617 splits on the first
    /// one, so a colon in the username would silently move bytes into the
    /// password. Redfish account names do not permit colons.
    pub fn basicValue(self: Credentials, arena: std.mem.Allocator) ![]const u8 {
        const basic = switch (self) {
            .basic => |value| value,
            else => return CredentialsError.NotBasicCredentials,
        };
        if (std.mem.indexOfScalar(u8, basic.username, ':') != null) {
            return CredentialsError.InvalidUsername;
        }

        const password = passwordOrEmpty(basic);
        const raw = try arena.alloc(u8, basic.username.len + 1 + password.len);
        defer arena.free(raw);
        @memcpy(raw[0..basic.username.len], basic.username);
        raw[basic.username.len] = ':';
        @memcpy(raw[basic.username.len + 1 ..], password);

        const encoder = std.base64.standard.Encoder;
        const out = try arena.alloc(u8, basic_prefix.len + encoder.calcSize(raw.len));
        @memcpy(out[0..basic_prefix.len], basic_prefix);
        _ = encoder.encode(out[basic_prefix.len..], raw);
        return out;
    }

    /// Whether these credentials authenticate a request at all.
    pub fn isAnonymous(self: Credentials) bool {
        return self == .anonymous;
    }

    /// Redacts the secret. Never print credentials any other way.
    pub fn format(self: Credentials, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .anonymous => try w.writeAll("Credentials.anonymous"),
            .basic => |basic| try w.print(
                "Credentials.basic{{ .username = {s}, .password = [REDACTED] }}",
                .{basic.username},
            ),
            .token => try w.writeAll("Credentials.token{ [REDACTED] }"),
        }
    }
};

pub const CredentialsError = error{
    /// `basicValue` was called on credentials that are not Basic.
    NotBasicCredentials,
    /// The username contains a colon, which RFC 7617 cannot encode
    /// unambiguously.
    InvalidUsername,
};

fn passwordOrEmpty(basic: Credentials.Basic) []const u8 {
    return basic.password orelse &.{};
}

const basic_prefix = "Basic ";

const testing = std.testing;

test "basic credentials encode as RFC 7617" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    // The RFC 7617 example.
    const credentials: Credentials = .initBasic("Aladdin", "open sesame");
    try testing.expectEqualStrings(
        "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
        try credentials.basicValue(fba.allocator()),
    );
}

test "an absent password encodes as an empty one" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const credentials: Credentials = .{ .basic = .{ .username = "admin" } };
    // base64("admin:")
    try testing.expectEqualStrings(
        "Basic YWRtaW46",
        try credentials.basicValue(fba.allocator()),
    );
}

test "a colon in the username is rejected rather than silently split" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const credentials: Credentials = .initBasic("host:admin", "pw");
    try testing.expectError(
        CredentialsError.InvalidUsername,
        credentials.basicValue(fba.allocator()),
    );
}

test "a colon in the password is fine" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const credentials: Credentials = .initBasic("admin", "a:b");
    // base64("admin:a:b")
    try testing.expectEqualStrings(
        "Basic YWRtaW46YTpi",
        try credentials.basicValue(fba.allocator()),
    );
}

test "basicValue rejects non-basic credentials" {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    try testing.expectError(
        CredentialsError.NotBasicCredentials,
        Credentials.initToken("t").basicValue(fba.allocator()),
    );
    const anonymous: Credentials = .anonymous;
    try testing.expectError(
        CredentialsError.NotBasicCredentials,
        anonymous.basicValue(fba.allocator()),
    );
}

test "each scheme produces its own header" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const arena = fba.allocator();

    const basic = (try Credentials.initBasic("admin", "pw").header(arena)).?;
    try testing.expectEqualStrings("Authorization", basic.name);
    try testing.expectEqualStrings("Basic YWRtaW46cHc=", basic.value);

    const token = (try Credentials.initToken("6f4b3c2a").header(arena)).?;
    try testing.expectEqualStrings("X-Auth-Token", token.name);
    try testing.expectEqualStrings("6f4b3c2a", token.value);

    const anonymous: Credentials = .anonymous;
    try testing.expectEqual(@as(?Header, null), try anonymous.header(arena));
}

test "headerSize covers what header allocates" {
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const credentials: Credentials = .initBasic("Aladdin", "open sesame");
    const value = try credentials.basicValue(fba.allocator());
    try testing.expectEqual(credentials.headerSize(), value.len);
}

test "isAnonymous distinguishes the unauthenticated case" {
    const anonymous: Credentials = .anonymous;
    try testing.expect(anonymous.isAnonymous());
    try testing.expect(!Credentials.initBasic("admin", "pw").isAnonymous());
    try testing.expect(!Credentials.initToken("t").isAnonymous());
}

test "formatting never reveals the secret" {
    var buf: [128]u8 = undefined;

    const basic = try std.fmt.bufPrint(&buf, "{f}", .{Credentials.initBasic("admin", "hunter2")});
    try testing.expect(std.mem.indexOf(u8, basic, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, basic, "admin") != null);
    try testing.expect(std.mem.indexOf(u8, basic, "[REDACTED]") != null);

    const token = try std.fmt.bufPrint(&buf, "{f}", .{Credentials.initToken("6f4b3c2a")});
    try testing.expect(std.mem.indexOf(u8, token, "6f4b3c2a") == null);
    try testing.expect(std.mem.indexOf(u8, token, "[REDACTED]") != null);

    const anonymous: Credentials = .anonymous;
    try testing.expectEqualStrings(
        "Credentials.anonymous",
        try std.fmt.bufPrint(&buf, "{f}", .{anonymous}),
    );
}
