//! Resolving Redfish URI references against a BMC endpoint.
//!
//! Redfish resources hand out URI references in many places: `Location`
//! headers, action targets, `HttpPushUri`, event stream URIs. Each one is
//! data the *service* controls, and each one is about to be sent a request
//! carrying the client's credentials.
//!
//! `Endpoint` resolves those references per RFC 3986 and then refuses any
//! result that is not same-origin with the configured BMC. Origin is compared
//! on scheme, host, and effective port — not on a string prefix, so a
//! lookalike such as `https://bmc.example.evil/` is rejected even though it
//! starts with the BMC's hostname.

const std = @import("std");

/// A BMC's base URL, and the origin every request must stay within.
///
/// The `std.Uri` borrows the text it was parsed from, so that string must
/// outlive the endpoint.
pub const Endpoint = struct {
    base: std.Uri,

    pub const ParseError = std.Uri.ParseError || error{
        /// Redfish runs over HTTP; anything else is a configuration mistake.
        UnsupportedScheme,
        /// A base URL has to name a host to be an origin.
        MissingHost,
    };

    /// Parse a BMC base URL, such as `https://bmc.example` or
    /// `https://10.0.0.1:8443`.
    pub fn parse(text: []const u8) ParseError!Endpoint {
        const base = try std.Uri.parse(text);
        if (defaultPort(base.scheme) == null) return ParseError.UnsupportedScheme;
        const host = base.host orelse return ParseError.MissingHost;
        if (componentSlice(host).len == 0) return ParseError.MissingHost;
        return .{ .base = base };
    }

    pub const ResolveError = error{
        /// The reference did not resolve to a URI at all.
        MalformedUriReference,
        /// The reference resolved to a different origin than the BMC.
        ///
        /// Following it would leak credentials to whatever host the service
        /// named, so the request is refused before any bytes go out.
        CrossOriginUriReference,
        OutOfMemory,
    };

    /// Resolve a service-provided URI reference and verify it stays on the
    /// BMC's origin.
    ///
    /// With base `https://bmc.example`:
    ///   * `/redfish/v1/Chassis` → `https://bmc.example/redfish/v1/Chassis`
    ///   * `//bmc.example/redfish/v1` → `https://bmc.example/redfish/v1`
    ///   * `redfish/v1/upload` resolves relative to the base path
    ///   * `https://bmc.example/x` is accepted
    ///   * `https://bmc.example.evil/x` is rejected
    ///   * `http://bmc.example/x` is rejected — a different scheme is a
    ///     different origin, and downgrades the transport
    ///
    /// The result borrows `arena`.
    pub fn resolve(
        self: Endpoint,
        arena: std.mem.Allocator,
        reference: []const u8,
    ) ResolveError!std.Uri {
        // `resolveInPlace` wants the reference at the front of a scratch
        // buffer and writes any merged path into what is left. A merged path
        // is the base path's directory, a separator, and the reference — so
        // the tail has to hold a whole second copy of the reference.
        const scratch = try arena.alloc(
            u8,
            2 * reference.len + basePathLength(self.base) + 2,
        );
        @memcpy(scratch[0..reference.len], reference);

        var remaining: []u8 = scratch;
        const resolved = std.Uri.resolveInPlace(self.base, reference.len, &remaining) catch |err| {
            // Distinguishing these matters: a scratch buffer we sized wrong
            // is our bug, not a bad reference from the service.
            return switch (err) {
                error.NoSpaceLeft => ResolveError.OutOfMemory,
                else => ResolveError.MalformedUriReference,
            };
        };

        if (!sameOrigin(self.base, resolved)) return ResolveError.CrossOriginUriReference;
        return resolved;
    }

    /// `resolve`, rendered back to text. For logging and for transports that
    /// want a string rather than a `std.Uri`.
    pub fn resolveText(
        self: Endpoint,
        arena: std.mem.Allocator,
        reference: []const u8,
    ) ResolveError![]u8 {
        const resolved = try self.resolve(arena, reference);
        return std.fmt.allocPrint(arena, "{f}", .{resolved});
    }

    /// The origin as text, for error messages and logs.
    pub fn originText(self: Endpoint, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}://{f}:{d}", .{
            self.base.scheme,
            std.fmt.alt(self.base.host.?, .formatHost),
            effectivePort(self.base).?,
        });
    }
};

/// The default port for a scheme, or null when the scheme is not one we
/// speak. Doubles as the scheme allow-list.
pub fn defaultPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    return null;
}

/// The port a request would actually connect to, filling in the scheme's
/// default. Null when the scheme is unknown.
pub fn effectivePort(uri: std.Uri) ?u16 {
    return uri.port orelse defaultPort(uri.scheme);
}

/// RFC 6454 origin equality: same scheme, same host, same effective port.
///
/// Host comparison is case-insensitive, since DNS names are; the rest of a
/// URI is not.
pub fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;

    const a_port = effectivePort(a) orelse return false;
    const b_port = effectivePort(b) orelse return false;
    if (a_port != b_port) return false;

    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    return std.ascii.eqlIgnoreCase(componentSlice(a_host), componentSlice(b_host));
}

/// The raw bytes of a URI component, whichever form it is carried in.
///
/// Comparing the encoded form is what we want for origins: a percent-encoded
/// host is not a legal host name, so treating an encoded host as different
/// from its decoding is the safe answer.
pub fn componentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

fn basePathLength(base: std.Uri) usize {
    return componentSlice(base.path).len;
}

const testing = std.testing;

fn resolveWith(base_text: []const u8, reference: []const u8, buf: []u8) ![]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const endpoint = try Endpoint.parse(base_text);
    return endpoint.resolveText(fba.allocator(), reference);
}

fn expectResolves(base_text: []const u8, reference: []const u8, expected: []const u8) !void {
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try resolveWith(base_text, reference, &buf));
}

fn expectRejects(base_text: []const u8, reference: []const u8, expected: anyerror) !void {
    var buf: [4096]u8 = undefined;
    try testing.expectError(expected, resolveWith(base_text, reference, &buf));
}

test "parses a BMC base URL" {
    const endpoint = try Endpoint.parse("https://bmc.example");
    try testing.expectEqualStrings("https", endpoint.base.scheme);
    try testing.expectEqual(@as(?u16, 443), effectivePort(endpoint.base));

    const with_port = try Endpoint.parse("https://10.0.0.1:8443");
    try testing.expectEqual(@as(?u16, 8443), effectivePort(with_port.base));

    const plaintext = try Endpoint.parse("http://bmc.example");
    try testing.expectEqual(@as(?u16, 80), effectivePort(plaintext.base));
}

test "rejects a base URL that is not usable as an origin" {
    try testing.expectError(
        Endpoint.ParseError.UnsupportedScheme,
        Endpoint.parse("ftp://bmc.example"),
    );
    try testing.expectError(
        Endpoint.ParseError.UnsupportedScheme,
        Endpoint.parse("file:///redfish/v1"),
    );
    try testing.expectError(
        Endpoint.ParseError.MissingHost,
        Endpoint.parse("https:///redfish/v1"),
    );
}

test "resolves an absolute path against the base" {
    try expectResolves(
        "https://bmc.example",
        "/redfish/v1/Chassis/1",
        "https://bmc.example/redfish/v1/Chassis/1",
    );
    try expectResolves(
        "https://10.0.0.1:8443",
        "/redfish/v1",
        "https://10.0.0.1:8443/redfish/v1",
    );
}

test "keeps the query on a resolved reference" {
    try expectResolves(
        "https://bmc.example",
        "/redfish/v1/Chassis?$top=10",
        "https://bmc.example/redfish/v1/Chassis?$top=10",
    );
}

test "resolves a protocol-relative reference onto the base scheme" {
    try expectResolves(
        "https://bmc.example",
        "//bmc.example/redfish/v1/EventService/SSE",
        "https://bmc.example/redfish/v1/EventService/SSE",
    );
}

test "resolves a relative reference against the base path" {
    try expectResolves(
        "https://bmc.example/redfish/v1/",
        "UpdateService/upload",
        "https://bmc.example/redfish/v1/UpdateService/upload",
    );
    // RFC 3986 merges against the base's *directory*, so a base path with no
    // trailing slash loses its last segment. Worth knowing before configuring
    // a base URL with a path.
    try expectResolves(
        "https://bmc.example/redfish/v1/Systems/1",
        "Actions/ComputerSystem.Reset",
        "https://bmc.example/redfish/v1/Systems/Actions/ComputerSystem.Reset",
    );
}

test "accepts an absolute reference that is already same-origin" {
    try expectResolves(
        "https://bmc.example",
        "https://bmc.example/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
        "https://bmc.example/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
    );
    // An explicit default port is the same origin as an implicit one.
    try expectResolves(
        "https://bmc.example",
        "https://bmc.example:443/redfish/v1",
        "https://bmc.example:443/redfish/v1",
    );
}

test "rejects a reference that resolves to another host" {
    // The prefix lookalike: string matching would accept this.
    try expectRejects(
        "https://bmc.example",
        "https://bmc.example.evil/redfish/v1/Actions/Reset",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
    try expectRejects(
        "https://bmc.example",
        "//attacker.example/redfish/v1",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
}

test "rejects a reference that downgrades the scheme" {
    try expectRejects(
        "https://bmc.example",
        "http://bmc.example/redfish/v1",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
}

test "rejects a reference on another port" {
    try expectRejects(
        "https://bmc.example",
        "https://bmc.example:8443/redfish/v1",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
    try expectRejects(
        "https://bmc.example:8443",
        "https://bmc.example/redfish/v1",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
}

test "rejects a reference with a scheme we do not speak" {
    try expectRejects(
        "https://bmc.example",
        "file:///etc/shadow",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
    try expectRejects(
        "https://bmc.example",
        "ftp://bmc.example/firmware",
        Endpoint.ResolveError.CrossOriginUriReference,
    );
}

test "host comparison is case-insensitive" {
    try expectResolves(
        "https://BMC.Example",
        "https://bmc.example/redfish/v1",
        "https://bmc.example/redfish/v1",
    );
}

test "resolve returns a std.Uri the transport can connect with" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const endpoint = try Endpoint.parse("https://bmc.example");
    const uri = try endpoint.resolve(fba.allocator(), "/redfish/v1/Chassis");

    try testing.expectEqualStrings("https", uri.scheme);
    try testing.expectEqualStrings("bmc.example", componentSlice(uri.host.?));
    try testing.expectEqualStrings("/redfish/v1/Chassis", componentSlice(uri.path));
}

test "sameOrigin follows RFC 6454" {
    const https = try std.Uri.parse("https://bmc.example/a");
    const https_other_path = try std.Uri.parse("https://bmc.example/b?q=1");
    const https_explicit_port = try std.Uri.parse("https://bmc.example:443/a");
    const http = try std.Uri.parse("http://bmc.example/a");
    const other_host = try std.Uri.parse("https://other.example/a");

    try testing.expect(sameOrigin(https, https_other_path));
    try testing.expect(sameOrigin(https, https_explicit_port));
    try testing.expect(!sameOrigin(https, http));
    try testing.expect(!sameOrigin(https, other_host));
}

test "originText renders the effective origin" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    const endpoint = try Endpoint.parse("https://bmc.example");
    try testing.expectEqualStrings(
        "https://bmc.example:443",
        try endpoint.originText(fba.allocator()),
    );
}
