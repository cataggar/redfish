//! Getting from a resource's `Oem` property to a vendor's own type.
//!
//! Every OEM extension arrives the same way. `Oem` is an ordinary property
//! whose type is open, and the vendor's content is a member of it keyed by the
//! vendor's name:
//!
//! ```json
//! { "Id": "1", "Oem": { "Hpe": { "VirtualNICEnabled": true } } }
//! ```
//!
//! `open_struct.zig` gets that far: the member survives the parse as a
//! `std.json.Value` in `additional_properties`. What is left is to look the
//! key up and decode the value into the type a vendor schema package
//! generated for it, and this module is that step.
//!
//! It exists rather than leaving `std.json.parseFromValue` at the call site
//! because the plain call is wrong twice, and both are quiet.
//!
//! The first is `ignore_unknown_fields`. `owned.parse_options` sets it for
//! every read from a BMC, precisely because a service may run a newer schema
//! than the package was generated from; `std.json`'s own default is the
//! opposite. So `std.json.parseFromValue(HpeiLo, gpa, value, .{})` rejects
//! `{"@odata.type": "#HpeiLO.v2_11_0.HpeiLO", "VirtualNICEnabled": true}` —
//! not for the property the caller wanted, but for the one every vendor puts
//! beside it. A type would decode differently depending on whether it arrived
//! at its own URI or inside an `Oem`, which is a difference nothing about
//! Redfish justifies.
//!
//! The second is ownership. The `std.json.Value` handed in belongs to the
//! arena of the resource that was read, so a caller who parses out of it and
//! then releases the resource is holding a value backed by freed memory unless
//! every string was copied. `parse` returns an `Owned(T)` with its own arena
//! and `parseFromValue` copies scalars, so the result outlives the resource it
//! came out of. The exception is worth knowing: a `std.json.Value` *field* —
//! the `additional_properties` of a vendor type that is itself open — is
//! returned by reference and not copied, so a `T` with extras still borrows
//! from the resource.
//!
//! ## The key is whatever the payload says
//!
//! There is no rule taking a vendor package to its key and no attempt to
//! guess one. AMI's namespace is `AMIServiceRoot` and its key is `Ami`;
//! Supermicro's schema calls itself `SmcManagerExtensions` and its key is
//! `Supermicro`. Nor is the lookup case-insensitive: DSP0266 leaves the name
//! to the vendor, two vendors may sit in one bag, and decoding one vendor's
//! object into another vendor's type produces a value rather than an error.
//! The caller passes the string it has seen on the wire.
//!
//! ## Three answers, not two
//!
//! `parse` returns null when the resource has no `Oem` or the bag has no such
//! key, and an error when the key is there and the value does not fit the
//! type. Those are different facts — "this is not that vendor's hardware"
//! against "this is, and the payload is not what the schema says" — and a
//! caller that cannot tell them apart will treat a malformed extension as an
//! absent one and read a default where there is a defect.

const std = @import("std");
const open_struct = @import("open_struct.zig");
const owned = @import("owned.zig");

/// The vendor's raw content, still undecoded.
///
/// Use when the key's presence is the whole answer — a vendor that hangs its
/// real resource off a URI elsewhere may write nothing but `{}` under its own
/// name — or when the value is not an object a schema describes.
///
/// `oem` is the `Oem` property itself, optional or not: an open struct, a
/// pointer to one, or an optional of either.
pub fn value(oem: anytype, vendor: []const u8) ?std.json.Value {
    const bag = extras(oem) orelse return null;
    return bag.map.get(vendor);
}

/// The vendor's content decoded as `T`, in an arena of its own.
///
/// Null when there is no such vendor in the bag. An error when there is and it
/// does not decode.
pub fn parse(
    comptime T: type,
    gpa: std.mem.Allocator,
    oem: anytype,
    vendor: []const u8,
) !?owned.Owned(T) {
    const found = value(oem, vendor) orelse return null;

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const decoded = try std.json.parseFromValueLeaky(
        T,
        arena.allocator(),
        found,
        owned.parse_options,
    );
    return .adopt(arena, decoded);
}

/// The `additional_properties` of whatever shape the caller passed.
fn extras(oem: anytype) ?open_struct.AdditionalProperties {
    const T = @TypeOf(oem);
    return switch (@typeInfo(T)) {
        .null => null,
        .optional => if (oem) |present| extras(present) else null,
        .pointer => |pointer| if (pointer.size == .one)
            extras(oem.*)
        else
            @compileError("an Oem property is a struct, found " ++ @typeName(T)),
        .@"struct" => if (@hasField(T, open_struct.extras_field))
            @field(oem, open_struct.extras_field)
        else
            @compileError(@typeName(T) ++ " has no `" ++ open_struct.extras_field ++ "` field"),
        else => @compileError("an Oem property is a struct, found " ++ @typeName(T)),
    };
}

const testing = std.testing;

const Oem = struct {
    additional_properties: open_struct.AdditionalProperties = .{},

    const open = open_struct.Open(@This());
    pub const jsonParse = open.jsonParse;
    pub const jsonParseFromValue = open.jsonParseFromValue;
    pub const jsonStringify = open.jsonStringify;
};

const Resource = struct {
    Id: []const u8,
    Oem: ?Oem = null,
};

const Vendor = struct {
    Enabled: ?bool = null,
    Name: ?[]const u8 = null,
};

fn read(body: []const u8) !owned.Owned(Resource) {
    return owned.parseJson(Resource, testing.allocator, body, null);
}

test "a vendor's object is decoded into the vendor's type" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{"Enabled":true,"Name":"tray"}}}
    );
    defer resource.deinit();

    const acme = (try parse(Vendor, testing.allocator, resource.value.Oem, "Acme")).?;
    defer acme.deinit();

    try testing.expectEqual(true, acme.value.Enabled.?);
    try testing.expectEqualStrings("tray", acme.value.Name.?);
}

test "a property no vendor schema declares does not fail the decode" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{"@odata.type":"#Acme.v1_2_0.Acme","Enabled":false}}}
    );
    defer resource.deinit();

    const acme = (try parse(Vendor, testing.allocator, resource.value.Oem, "Acme")).?;
    defer acme.deinit();

    try testing.expectEqual(false, acme.value.Enabled.?);

    // The same value through `std.json`'s defaults, which is what a call site
    // writing the parse by hand would reach for.
    try testing.expectError(error.UnknownField, std.json.parseFromValue(
        Vendor,
        testing.allocator,
        value(resource.value.Oem, "Acme").?,
        .{},
    ));
}

test "the decoded value outlives the resource it was found in" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{"Name":"a name allocated in the response arena"}}}
    );
    const acme = (try parse(Vendor, testing.allocator, resource.value.Oem, "Acme")).?;
    defer acme.deinit();

    resource.deinit();

    try testing.expectEqualStrings("a name allocated in the response arena", acme.value.Name.?);
}

test "an absent Oem, an absent vendor and a malformed one are three answers" {
    const none = try read(
        \\{"Id":"1"}
    );
    defer none.deinit();
    try testing.expectEqual(@as(?std.json.Value, null), value(none.value.Oem, "Acme"));
    try testing.expectEqual(
        @as(?owned.Owned(Vendor), null),
        try parse(Vendor, testing.allocator, none.value.Oem, "Acme"),
    );

    const other = try read(
        \\{"Id":"1","Oem":{"Other":{"Enabled":true}}}
    );
    defer other.deinit();
    try testing.expectEqual(
        @as(?owned.Owned(Vendor), null),
        try parse(Vendor, testing.allocator, other.value.Oem, "Acme"),
    );

    const wrong = try read(
        \\{"Id":"1","Oem":{"Acme":{"Enabled":"true"}}}
    );
    defer wrong.deinit();
    try testing.expectError(
        error.UnexpectedToken,
        parse(Vendor, testing.allocator, wrong.value.Oem, "Acme"),
    );
}

test "a vendor that writes nothing but its own name is still present" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{}}}
    );
    defer resource.deinit();

    // A marker: the key says the hardware is Acme's, and everything Acme has
    // to say lives at a URI built from that fact rather than in the bag.
    try testing.expectEqual(@as(usize, 0), value(resource.value.Oem, "Acme").?.object.count());
}

test "the lookup takes the key the service used and no other" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{"Enabled":true}}}
    );
    defer resource.deinit();

    try testing.expectEqual(@as(?std.json.Value, null), value(resource.value.Oem, "ACME"));
    try testing.expectEqual(@as(?std.json.Value, null), value(resource.value.Oem, "acme"));
}

test "the Oem property may be passed by pointer" {
    const resource = try read(
        \\{"Id":"1","Oem":{"Acme":{"Enabled":true}}}
    );
    defer resource.deinit();

    try testing.expect(value(&resource.value.Oem.?, "Acme") != null);
}
