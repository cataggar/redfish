//! The entity contract that generated resource structs satisfy.
//!
//! `nv-redfish` expresses this as a Rust trait (`EntityTypeRef`). Zig has no
//! traits, so the contract is structural and checked at comptime: a type is an
//! entity when it carries an `@"@odata.id"` field, or supplies an `odataId`
//! method. `assertEntity` turns a violation into a readable compile error at
//! the point of use instead of a deep instantiation failure.
//!
//! Both spellings exist because generated resource structs get the plain
//! fields, while wrappers such as `NavProperty(T)` have to compute the answer.

const std = @import("std");
const odata = @import("odata.zig");

const ODataId = odata.ODataId;
const ODataETag = odata.ODataETag;

/// JSON name of the identity property, per DSP0266.
pub const id_field = "@odata.id";
/// JSON name of the entity tag property, per DSP0266.
pub const etag_field = "@odata.etag";

/// The struct type behind a value, a single-item pointer, or an optional.
fn Entity(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) Entity(p.child) else T,
        .optional => |o| Entity(o.child),
        else => T,
    };
}

fn deref(entity: anytype) Entity(@TypeOf(entity)) {
    return switch (@typeInfo(@TypeOf(entity))) {
        .pointer => |p| if (p.size == .one) deref(entity.*) else entity,
        .optional => deref(entity.?),
        else => entity,
    };
}

/// True when `T` can answer `id`. Use it to gate generated helper methods.
pub fn isEntity(comptime T: type) bool {
    const Base = Entity(T);
    return switch (@typeInfo(Base)) {
        .@"struct", .@"union" => @hasDecl(Base, "odataId") or @hasField(Base, id_field),
        else => false,
    };
}

/// Compile-time guard with a message that names the offending type.
pub fn assertEntity(comptime T: type) void {
    // `comptime` on the condition is load-bearing: without it the call is a
    // runtime call, the branch is analyzed unconditionally, and every type
    // trips the error.
    if (comptime !isEntity(T)) @compileError(
        "'" ++ @typeName(T) ++ "' is not a Redfish entity: it needs an `" ++
            id_field ++ "` field or an `odataId` method",
    );
}

/// The entity's `@odata.id`.
pub fn id(entity: anytype) ODataId {
    const Base = Entity(@TypeOf(entity));
    assertEntity(Base);
    if (@hasDecl(Base, "odataId")) return deref(entity).odataId();
    return @field(deref(entity), id_field);
}

/// The entity's `@odata.etag`, or null when the service did not supply one.
///
/// A resource may omit the property entirely, declare it optional, or declare
/// it required; all three answer here.
pub fn etag(entity: anytype) ?ODataETag {
    const Base = Entity(@TypeOf(entity));
    assertEntity(Base);
    if (@hasDecl(Base, "odataEtag")) return deref(entity).odataEtag();
    if (!@hasField(Base, etag_field)) return null;

    return @field(deref(entity), etag_field);
}

const testing = std.testing;

const Plain = struct {
    @"@odata.id": ODataId,
    Name: []const u8,
};

const Tagged = struct {
    @"@odata.id": ODataId,
    @"@odata.etag": ?ODataETag = null,
};

const AlwaysTagged = struct {
    @"@odata.id": ODataId,
    @"@odata.etag": ODataETag,
};

const Computed = struct {
    target: ODataId,

    pub fn odataId(self: Computed) ODataId {
        return self.target;
    }
};

test "reads the identity from a plain generated struct" {
    const chassis: Plain = .{ .@"@odata.id" = .init("/redfish/v1/Chassis/1"), .Name = "1" };
    try testing.expect(id(chassis).eql(.init("/redfish/v1/Chassis/1")));
    try testing.expectEqual(@as(?ODataETag, null), etag(chassis));
}

test "reads the identity through a pointer and an optional" {
    const chassis: Plain = .{ .@"@odata.id" = .init("/redfish/v1/Chassis/1"), .Name = "1" };
    const maybe: ?Plain = chassis;
    try testing.expect(id(&chassis).eql(.init("/redfish/v1/Chassis/1")));
    try testing.expect(id(maybe).eql(.init("/redfish/v1/Chassis/1")));
}

test "an absent, optional, and required etag all answer" {
    const absent: Plain = .{ .@"@odata.id" = .init("/a"), .Name = "a" };
    try testing.expectEqual(@as(?ODataETag, null), etag(absent));

    const unset: Tagged = .{ .@"@odata.id" = .init("/a") };
    try testing.expectEqual(@as(?ODataETag, null), etag(unset));

    const set: Tagged = .{ .@"@odata.id" = .init("/a"), .@"@odata.etag" = .init("W/\"1\"") };
    try testing.expect(etag(set).?.eql(.init("W/\"1\"")));

    const required: AlwaysTagged = .{ .@"@odata.id" = .init("/a"), .@"@odata.etag" = .init("W/\"2\"") };
    try testing.expect(etag(required).?.eql(.init("W/\"2\"")));
}

test "a method overrides the field lookup" {
    const computed: Computed = .{ .target = .init("/redfish/v1/Systems/1") };
    try testing.expect(id(computed).eql(.init("/redfish/v1/Systems/1")));
}

test "isEntity discriminates" {
    try testing.expect(isEntity(Plain));
    try testing.expect(isEntity(Tagged));
    try testing.expect(isEntity(Computed));
    try testing.expect(isEntity(*const Plain));
    try testing.expect(isEntity(?Plain));

    try testing.expect(!isEntity(u32));
    try testing.expect(!isEntity([]const u8));
    try testing.expect(!isEntity(struct { Name: []const u8 }));
}
