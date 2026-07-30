//! `parse_payload` — read a recorded response, and say what was dropped.
//!
//! ```
//! parse_payload tests/payloads/service_root.ServiceRoot.json
//! ```
//!
//! `nv-redfish`'s `service-root-parser` deserializes a file and debug-prints
//! the result. That answers "did it parse", which for a Redfish client is
//! nearly always yes and nearly never the question. A generated package parses
//! with `ignore_unknown_fields`, because a BMC is free to send properties from
//! a schema newer than the one the package was generated from — so a payload
//! **parses clean while throwing properties away**, and nothing says so.
//!
//! This prints both halves: what the type read, and every property in the file
//! that did not survive the trip. It is the same question the round-trip suite
//! asks of 251 recorded payloads, pointed at one file — which is what you want
//! when a service in front of you sends something this client does not know.

const std = @import("std");
const core = @import("redfish_core");
const schema = @import("redfish_schema_std");

const cli = @import("cli.zig");

const ServiceRoot = schema.service_root.ServiceRoot;

pub const usage =
    \\parse_payload — parse a Redfish service root and report what was dropped.
    \\
    \\Usage:
    \\  parse_payload <file.json>
    \\
    \\  -h, --help   This message.
    \\
;

pub fn run(gpa: std.mem.Allocator, text: []const u8, out: *std.Io.Writer) !void {
    const root = try core.parseJson(ServiceRoot, gpa, text, null);
    defer root.deinit();

    try out.print("{s} {s} — Redfish {s}\n", .{
        root.value.Vendor orelse "(no vendor)",
        root.value.Product orelse "(no product)",
        root.value.RedfishVersion orelse "?",
    });
    if (root.value.UUID) |uuid| try out.print("UUID: {f}\n", .{uuid});

    // Written back out from the parsed value, so what it contains is exactly
    // what the generated type kept.
    const kept = try std.json.Stringify.valueAlloc(gpa, root.value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(kept);

    var dropped: std.ArrayList([]const u8) = .empty;
    defer {
        for (dropped.items) |path| gpa.free(path);
        dropped.deinit(gpa);
    }
    try collectDropped(gpa, text, kept, &dropped);

    if (dropped.items.len == 0) {
        try out.writeAll("nothing dropped\n");
        return;
    }

    try out.print("dropped {d} propert{s}:\n", .{
        dropped.items.len,
        if (dropped.items.len == 1) "y" else "ies",
    });
    for (dropped.items) |path| try out.print("  {s}\n", .{path});
}

/// Every path present in `before` and absent from `after`, in document order.
fn collectDropped(
    gpa: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    into: *std.ArrayList([]const u8),
) !void {
    const original = try std.json.parseFromSlice(std.json.Value, gpa, before, .{});
    defer original.deinit();
    const survived = try std.json.parseFromSlice(std.json.Value, gpa, after, .{});
    defer survived.deinit();

    try walk(gpa, "", original.value, survived.value, into);
}

/// Recurses in step down two documents, recording what only the first has.
///
/// Only missing *keys* are reported. A value that changed spelling — a number
/// re-rendered, a string re-escaped — is the JSON writer's business, not a
/// property the type failed to declare.
fn walk(
    gpa: std.mem.Allocator,
    prefix: []const u8,
    before: std.json.Value,
    after: std.json.Value,
    into: *std.ArrayList([]const u8),
) !void {
    switch (before) {
        .object => |fields| {
            const kept = switch (after) {
                .object => |value| value,
                else => return,
            };
            var it = fields.iterator();
            while (it.next()) |field| {
                const path = if (prefix.len == 0)
                    try gpa.dupe(u8, field.key_ptr.*)
                else
                    try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, field.key_ptr.* });
                errdefer gpa.free(path);

                if (kept.get(field.key_ptr.*)) |value| {
                    defer gpa.free(path);
                    try walk(gpa, path, field.value_ptr.*, value, into);
                } else {
                    try into.append(gpa, path);
                }
            }
        },
        .array => |items| {
            const kept = switch (after) {
                .array => |value| value,
                else => return,
            };
            for (items.items, 0..) |item, index| {
                if (index >= kept.items.len) break;
                const path = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ prefix, index });
                defer gpa.free(path);
                try walk(gpa, path, item, kept.items[index], into);
            }
        },
        else => {},
    }
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
    if (argv.len != 1) {
        try out.writeAll("parse_payload: one file, please\n\n" ++ usage);
        return 2;
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(io, argv[0], arena, .limited(16 << 20));
    try run(init.gpa, text, out);
    return 0;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "the example names the properties the generated type did not keep" {
    // `@Redfish.Copyright` is on every payload DMTF publishes and is declared
    // by no schema; `Contoso.PowerBudget` is the shape of a vendor property a
    // package generated without that vendor's CSDL cannot see.
    const text =
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "@Redfish.Copyright":"Copyright 2014-2026 DMTF.",
        \\ "Id":"RootService","Name":"Root Service",
        \\ "Vendor":"Contoso","Product":"Contoso BMC","RedfishVersion":"1.18.0",
        \\ "UUID":"92384634-2938-2342-8820-489239905423",
        \\ "Contoso.PowerBudget":1200,
        \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis","Contoso.Cached":true}}
    ;

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, text, &out);

    try testing.expectEqualStrings(
        \\Contoso Contoso BMC — Redfish 1.18.0
        \\UUID: 92384634-2938-2342-8820-489239905423
        \\dropped 3 properties:
        \\  @Redfish.Copyright
        \\  Contoso.PowerBudget
        \\  Chassis.Contoso.Cached
        \\
    , out.buffered());
}

test "a payload the type covers entirely reports nothing" {
    const text =
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "Id":"RootService","Name":"Root Service","RedfishVersion":"1.18.0",
        \\ "Chassis":{"@odata.id":"/redfish/v1/Chassis"}}
    ;

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, text, &out);

    try testing.expectEqualStrings(
        \\(no vendor) (no product) — Redfish 1.18.0
        \\nothing dropped
        \\
    , out.buffered());
}

test "a nested member of a collection is reached by index" {
    const text =
        \\{"@odata.id":"/redfish/v1",
        \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
        \\ "Id":"RootService","Name":"Root Service","RedfishVersion":"1.18.0",
        \\ "Oem":{"Contoso":{"Fans":[{"Name":"Fan1","Contoso.RPM":3200}]}}}
    ;

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(testing.allocator, text, &out);

    // Nothing: `Oem` is an open struct, so a vendor's whole subtree survives
    // rather than being dropped. That is what `Open(T)` is for -- and it is
    // why this program reports paths rather than a count.
    try testing.expectEqualStrings(
        \\(no vendor) (no product) — Redfish 1.18.0
        \\nothing dropped
        \\
    , out.buffered());
}
