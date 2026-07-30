//! What the examples share: reading a flag, and opening a connection.
//!
//! Deliberately not an argument-parsing framework. Every example here takes
//! four or five flags, and the point of an example is that a reader can see
//! the whole of it — a parser generic over a struct would be the most
//! interesting thing in the file, which is the wrong thing to be interesting.
//!
//! `Connection` is the part worth sharing: an `std.http.Client` and an
//! `HttpBmc` over it, in one value, because `HttpBmc` borrows the client and
//! so the two have to be stored together or the borrow outlives the lender.

const std = @import("std");
const core = @import("redfish_core");
const http = @import("redfish_bmc_http");

/// The value of `--name`, or null when it was not given.
///
/// `--name=value` and `--name value` are both read, because an operator who
/// has used one CLI expects both.
pub fn flag(argv: []const []const u8, name: []const u8) ?[]const u8 {
    for (argv, 0..) |arg, index| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const body = arg[2..];
        if (std.mem.indexOfScalar(u8, body, '=')) |split| {
            if (std.mem.eql(u8, body[0..split], name)) return body[split + 1 ..];
            continue;
        }
        if (!std.mem.eql(u8, body, name)) continue;
        if (index + 1 < argv.len) return argv[index + 1];
        return "";
    }
    return null;
}

/// Whether `--name` was given at all, for flags that carry no value.
pub fn present(argv: []const []const u8, name: []const u8) bool {
    for (argv) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const body = arg[2..];
        const end = std.mem.indexOfScalar(u8, body, '=') orelse body.len;
        if (std.mem.eql(u8, body[0..end], name)) return true;
    }
    return false;
}

/// The command line without the program name, allocated in `arena`.
pub fn arguments(
    arena: std.mem.Allocator,
    init: std.process.Init,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.next();
    while (it.next()) |arg| try argv.append(arena, try arena.dupe(u8, arg));
    return argv.items;
}

/// An open connection to a BMC.
///
/// Initialized in place: `HttpBmc` holds a `*std.http.Client`, so a
/// `Connection` returned by value would leave that pointer addressing the
/// frame it was built in.
pub const Connection = struct {
    client: std.http.Client,
    bmc: http.HttpBmc,

    pub fn open(
        self: *Connection,
        gpa: std.mem.Allocator,
        io: std.Io,
        base_url: []const u8,
        credentials: http.Credentials,
    ) !void {
        self.client = .{ .allocator = gpa, .io = io };
        self.bmc = try .init(gpa, &self.client, base_url, .{ .credentials = credentials });
    }

    pub fn close(self: *Connection) void {
        self.bmc.deinit();
        self.client.deinit();
    }

    /// The interface every operation in this stack is written against.
    pub fn transport(self: *Connection) *core.BmcTransport {
        return self.bmc.asTransport();
    }
};

/// Credentials from `--username` and `--password`, or anonymous when either
/// is missing.
///
/// A service root is readable without credentials on most services — it is
/// the one resource DSP0266 allows to be — so an example that only reads it
/// is worth being able to run without any.
pub fn credentialsFrom(argv: []const []const u8) http.Credentials {
    const username = flag(argv, "username") orelse return .anonymous;
    const password = flag(argv, "password") orelse return .anonymous;
    return .initBasic(username, password);
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "a flag is read in either spelling" {
    const argv = [_][]const u8{ "--bmc", "https://bmc.example", "--username=root" };
    try testing.expectEqualStrings("https://bmc.example", flag(&argv, "bmc").?);
    try testing.expectEqualStrings("root", flag(&argv, "username").?);
    try testing.expectEqual(@as(?[]const u8, null), flag(&argv, "password"));
}

test "a value that looks like a flag is still a value" {
    // `--password --insecure` is a password of `--insecure`, not a missing
    // one: the alternative is a parser that silently drops a password
    // beginning with a dash.
    const argv = [_][]const u8{ "--password", "--insecure" };
    try testing.expectEqualStrings("--insecure", flag(&argv, "password").?);
}

test "a trailing flag with no value reads as empty rather than absent" {
    const argv = [_][]const u8{"--bmc"};
    try testing.expectEqualStrings("", flag(&argv, "bmc").?);
}

test "presence is not the same question as value" {
    const argv = [_][]const u8{ "--insecure", "--bmc", "https://bmc.example" };
    try testing.expect(present(&argv, "insecure"));
    try testing.expect(!present(&argv, "quiet"));
}

test "credentials need both halves" {
    try testing.expect(credentialsFrom(&.{"--username=root"}).isAnonymous());
    try testing.expect(!credentialsFrom(&.{ "--username=root", "--password=x" }).isAnonymous());
}
