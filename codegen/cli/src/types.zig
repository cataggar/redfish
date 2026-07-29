// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! What a schema type becomes in Zig.
//!
//! Two mappings live here. The first is a table: `Edm.String` is a byte
//! slice, `Edm.Int64` is an `i64`, and the four EDM types that have no Zig
//! equivalent are the ones `redfish_core` already implements.
//!
//! The second is the interesting one. The same property is a different Zig
//! type depending on whether it is being read or written, because reading and
//! writing ask different questions. A reader wants a value or nothing, and
//! does not care whether the service omitted the property or sent it as null.
//! A writer has to distinguish them: leaving a property out of a PATCH means
//! "don't touch this", and sending null means "clear it".
//!
//! Naming is not decided here. A generated type's Zig name depends on which
//! file it lands in and how versioned namespaces are flattened, which is the
//! emitter's problem; this module takes the name it is given and shapes the
//! type expression around it.

const std = @import("std");

const codemodel = @import("codemodel.zig");

/// The module a generated package imports `redfish_core` as.
pub const core_prefix = "core";

/// The type an unrecognized schema type maps to. Nothing in the corpus should
/// reach it, but a package that still compiles is worth more than one that
/// does not.
pub const unknown_type = "std.json.Value";

/// Whether the type is for a payload being read or one being written.
pub const Shape = enum {
    /// A resource as the service sends it. Absent and null are the same
    /// answer, so both are `null`.
    read,
    /// A payload the client sends: a PATCH body, a create body, an action
    /// argument. Absent and null are different instructions.
    write,
    /// A member of a write payload the service demands. It is always sent,
    /// so it needs no wrapper to say whether it was — not even when the
    /// schema marks it nullable, because a value the request is rejected
    /// without is not one a client sends as null.
    write_required,
};

/// The Zig type for an EDM primitive, or null if the name is not one.
pub fn primitiveType(name: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "Edm.String", "[]const u8" },
        .{ "Edm.Boolean", "bool" },
        .{ "Edm.Byte", "u8" },
        .{ "Edm.SByte", "i8" },
        .{ "Edm.Int16", "i16" },
        .{ "Edm.Int32", "i32" },
        .{ "Edm.Int64", "i64" },
        .{ "Edm.Single", "f32" },
        .{ "Edm.Double", "f64" },
        .{ "Edm.Binary", "[]const u8" },
        // Redfish writes dates as `Edm.DateTimeOffset`; `Edm.Date` and
        // `Edm.TimeOfDay` appear only in vendor schemas, and neither has an
        // offset to anchor it, so they stay text.
        .{ "Edm.Date", "[]const u8" },
        .{ "Edm.TimeOfDay", "[]const u8" },
        .{ "Edm.Decimal", core_prefix ++ ".Decimal" },
        .{ "Edm.DateTimeOffset", core_prefix ++ ".DateTimeOffset" },
        .{ "Edm.Duration", core_prefix ++ ".Duration" },
        .{ "Edm.Guid", core_prefix ++ ".Guid" },
        .{ "Edm.PrimitiveType", core_prefix ++ ".PrimitiveType" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// The type of one element, before collection or optionality is applied.
///
/// `named` is what the emitter decided to call a generated type in the file
/// being written; it is ignored for primitives and may be empty when there is
/// no such type.
pub fn elementType(type_ref: codemodel.TypeRef, named: []const u8) []const u8 {
    if (primitiveType(type_ref.name)) |mapped| return mapped;
    if (named.len != 0) return named;
    return unknown_type;
}

/// The Zig type of a structural property.
///
/// Two rules decide the shape, and neither is the obvious one.
///
/// For a collection, `Nullable` describes the *members*, not the property —
/// OData CSDL is explicit about this (ODATA-543), and it is what lets
/// `AccountService`'s `ServiceAddresses` hold a null between two addresses.
/// 620 of the 795 collection-valued properties in the DMTF corpus take the
/// default, which is nullable members.
///
/// For a read, everything is optional; see the `.read` arm below.
pub fn propertyType(
    arena: std.mem.Allocator,
    property: codemodel.Property,
    named: []const u8,
    shape: Shape,
) std.mem.Allocator.Error![]const u8 {
    const element = elementType(property.type, named);
    if (property.type.collection) {
        const collected = try collection(arena, element, property.nullable);
        return switch (shape) {
            // `Nullable` has already been spent on the members, so what is
            // left to say is whether the property itself arrives at all.
            .read, .write => std.fmt.allocPrint(arena, "?{s}", .{collected}),
            .write_required => collected,
        };
    }
    return switch (shape) {
        // Every read is optional. `Redfish.Required` says what a conformant
        // service sends, not what one does: 177 of DMTF's own 3,778 published
        // mockups omit a property their schema marks required. A client that
        // fails the whole response over an absent `Name` learns nothing from
        // the other forty properties that did arrive.
        .read => std.fmt.allocPrint(arena, "?{s}", .{element}),
        .write => if (property.nullable)
            std.fmt.allocPrint(arena, "{s}.Nullable({s})", .{ core_prefix, element })
        else
            std.fmt.allocPrint(arena, "?{s}", .{element}),
        .write_required => element,
    };
}

/// The Zig type of a link.
///
/// A link inside the compiled surface can be expanded, so it carries the
/// target type; one outside it can only ever be an `@odata.id`, and says so
/// with a distinct type rather than pretending to be an unexpanded link.
///
/// A link annotated `Redfish.ExcerptCopy` is neither: the service inlines a
/// projection of the target in place of the link, so there is nothing to
/// expand and `named` is already the projection's type.
pub fn navPropertyType(
    arena: std.mem.Allocator,
    property: codemodel.NavProperty,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const element = if (property.excerpt_copy != null)
        elementType(property.type, named)
    else if (property.expandable)
        try std.fmt.allocPrint(arena, "{s}.NavProperty({s})", .{
            core_prefix,
            elementType(property.type, named),
        })
    else
        core_prefix ++ ".ReferenceLeaf";

    // OData forbids `Nullable` on a collection-valued navigation property,
    // so a link collection never holds a null. It may still be absent.
    const collected = if (property.type.collection)
        try collection(arena, element, false)
    else
        element;
    return std.fmt.allocPrint(arena, "?{s}", .{collected});
}

/// The Zig type of an action parameter.
///
/// Actions are written, never read, so this follows the same rules as a
/// member of a write payload: a parameter the action requires is sent as it
/// is, and an optional nullable one gets the three-way type so a caller can
/// tell "leave it out" from "send null".
pub fn parameterType(
    arena: std.mem.Allocator,
    parameter: codemodel.Parameter,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const element = elementType(parameter.type, named);
    if (parameter.type.collection) {
        const collected = try collection(arena, element, parameter.nullable);
        if (parameter.required) return collected;
        return std.fmt.allocPrint(arena, "?{s}", .{collected});
    }
    if (parameter.required) return element;
    if (parameter.nullable) {
        return std.fmt.allocPrint(arena, "{s}.Nullable({s})", .{ core_prefix, element });
    }
    return std.fmt.allocPrint(arena, "?{s}", .{element});
}

/// The Zig type an action returns. A return value is always read.
pub fn returnType(
    arena: std.mem.Allocator,
    type_ref: codemodel.TypeRef,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const element = elementType(type_ref, named);
    if (!type_ref.collection) return element;
    return collection(arena, element, false);
}

/// Wraps an element type in a slice.
///
/// `nullable_members` comes from the property's own `Nullable`, which for a
/// collection-valued property describes the members rather than the property.
/// A null member means "this slot has no value", which is how a service
/// reports a fixed-length collection with a gap in it.
fn collection(
    arena: std.mem.Allocator,
    element: []const u8,
    nullable_members: bool,
) std.mem.Allocator.Error![]const u8 {
    if (nullable_members) return std.fmt.allocPrint(arena, "[]const ?{s}", .{element});
    return std.fmt.allocPrint(arena, "[]const {s}", .{element});
}

const testing = std.testing;

test "EDM primitives map onto Zig builtins where one fits" {
    try testing.expectEqualStrings("[]const u8", primitiveType("Edm.String").?);
    try testing.expectEqualStrings("bool", primitiveType("Edm.Boolean").?);
    try testing.expectEqualStrings("i64", primitiveType("Edm.Int64").?);
    try testing.expectEqualStrings("f64", primitiveType("Edm.Double").?);
    try testing.expectEqualStrings("u8", primitiveType("Edm.Byte").?);
}

test "the EDM types without a Zig equivalent come from the core" {
    try testing.expectEqualStrings("core.Decimal", primitiveType("Edm.Decimal").?);
    try testing.expectEqualStrings("core.DateTimeOffset", primitiveType("Edm.DateTimeOffset").?);
    try testing.expectEqualStrings("core.Duration", primitiveType("Edm.Duration").?);
    try testing.expectEqualStrings("core.Guid", primitiveType("Edm.Guid").?);
    try testing.expectEqualStrings("core.PrimitiveType", primitiveType("Edm.PrimitiveType").?);
}

test "a name that is not a primitive is not mapped" {
    try testing.expect(primitiveType("Resource.Status") == null);
    try testing.expect(primitiveType("Edm.Nonesuch") == null);
}

test "a generated type is named by the emitter" {
    const type_ref: codemodel.TypeRef = .{ .name = "Resource.Status", .kind = .complex };
    try testing.expectEqualStrings("Status", elementType(type_ref, "Status"));
    try testing.expectEqualStrings("std.json.Value", elementType(type_ref, ""));
}

test "every read is optional, whatever the schema requires" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string: codemodel.TypeRef = .{ .name = "Edm.String", .kind = .primitive };

    // `Redfish.Required` is a statement about a conformant service, and
    // services are not conformant: 177 of DMTF's own 3,778 published mockups
    // omit a property their own schema marks required.
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "Id", .type = string, .required = true, .nullable = false },
        "",
        .read,
    ));
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "Id", .type = string, .required = true, .nullable = true },
        "",
        .read,
    ));
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "AssetTag", .type = string, .required = false, .nullable = false },
        "",
        .read,
    ));
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "AssetTag", .type = string, .required = false, .nullable = true },
        "",
        .read,
    ));
}

test "writing distinguishes leaving a property alone from clearing it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string: codemodel.TypeRef = .{ .name = "Edm.String", .kind = .primitive };

    // Nullable: absent, null and set are three different instructions.
    try testing.expectEqualStrings("core.Nullable([]const u8)", try propertyType(
        allocator,
        .{ .name = "AssetTag", .type = string, .nullable = true },
        "",
        .write,
    ));
    // Not nullable: null is not a legal value, so absent or set is enough.
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "AssetTag", .type = string, .nullable = false },
        "",
        .write,
    ));
    // Required says the service always sends it, not that a client must.
    try testing.expectEqualStrings("?[]const u8", try propertyType(
        allocator,
        .{ .name = "Id", .type = string, .required = true, .nullable = false },
        "",
        .write,
    ));
}

test "a collection's `Nullable` describes its members, not the collection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const strings: codemodel.TypeRef = .{
        .name = "Edm.String",
        .kind = .primitive,
        .collection = true,
    };

    // `Nullable="false"`: every member is a value.
    try testing.expectEqualStrings("?[]const []const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .nullable = false },
        "",
        .read,
    ));
    // The CSDL default. A member may be null, which is how a service reports
    // a gap in a collection whose length it fixes -- `StaticNameServers` and
    // `ServiceAddresses` both rely on this, and neither is annotated.
    try testing.expectEqualStrings("?[]const ?[]const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .nullable = true },
        "",
        .read,
    ));
    // `Required` never makes a read non-optional.
    try testing.expectEqualStrings("?[]const []const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .required = true, .nullable = false },
        "",
        .read,
    ));
    // A collection is written as a whole, so it never takes `Nullable(T)`:
    // "leave the collection out" is `null` and "empty it" is `&.{}`.
    try testing.expectEqualStrings("?[]const ?[]const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .nullable = true },
        "",
        .write,
    ));
}

test "a complex property carries the emitter's name for its type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const status: codemodel.TypeRef = .{ .name = "Resource.Status", .kind = .complex };

    try testing.expectEqualStrings("?ResourceStatus", try propertyType(
        allocator,
        .{ .name = "Status", .type = status },
        "ResourceStatus",
        .read,
    ));
    try testing.expectEqualStrings("core.Nullable(ResourceStatus)", try propertyType(
        allocator,
        .{ .name = "Status", .type = status, .nullable = true },
        "ResourceStatus",
        .write,
    ));
}

test "an expandable link carries its target, a pruned one cannot" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const chassis: codemodel.TypeRef = .{ .name = "Chassis.v1_0_0.Chassis", .kind = .entity };

    try testing.expectEqualStrings("?core.NavProperty(Chassis)", try navPropertyType(
        allocator,
        .{ .name = "Chassis", .type = chassis, .expandable = true },
        "Chassis",
    ));
    try testing.expectEqualStrings("?core.ReferenceLeaf", try navPropertyType(
        allocator,
        .{ .name = "Chassis", .type = chassis, .expandable = false },
        "Chassis",
    ));
}

test "a collection of links is a slice of links" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const members: codemodel.TypeRef = .{
        .name = "Chassis.v1_0_0.Chassis",
        .kind = .entity,
        .collection = true,
    };

    try testing.expectEqualStrings("?[]const core.NavProperty(Chassis)", try navPropertyType(
        allocator,
        .{ .name = "Members", .type = members, .expandable = true },
        "Chassis",
    ));
    // A link collection is optional even when required, for the same reason a
    // property is. OData forbids `Nullable` on one, so its members never are.
    try testing.expectEqualStrings("?[]const core.NavProperty(Chassis)", try navPropertyType(
        allocator,
        .{ .name = "Members", .type = members, .expandable = true, .required = true },
        "Chassis",
    ));
}

test "an action parameter is written, so nullable means three states" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string: codemodel.TypeRef = .{ .name = "Edm.String", .kind = .primitive };

    try testing.expectEqualStrings("[]const u8", try parameterType(
        allocator,
        .{ .name = "ResetType", .type = string, .required = true, .nullable = false },
        "",
    ));
    try testing.expectEqualStrings("?[]const u8", try parameterType(
        allocator,
        .{ .name = "ResetType", .type = string, .nullable = false },
        "",
    ));
    try testing.expectEqualStrings("core.Nullable([]const u8)", try parameterType(
        allocator,
        .{ .name = "ResetType", .type = string, .nullable = true },
        "",
    ));

    // What the action requires is always sent, so it needs no wrapper to say
    // whether it was -- not even when the schema marks it nullable.
    try testing.expectEqualStrings("[]const u8", try parameterType(
        allocator,
        .{ .name = "ResetType", .type = string, .required = true, .nullable = true },
        "",
    ));
}

test "a return type is read, so it is never three-state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("Task", try returnType(
        allocator,
        .{ .name = "Task.v1_0_0.Task", .kind = .entity },
        "Task",
    ));
    try testing.expectEqualStrings("[]const Task", try returnType(
        allocator,
        .{ .name = "Task.v1_0_0.Task", .kind = .entity, .collection = true },
        "Task",
    ));
}

test "an excerpt link is the projection itself, not a link to it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const inlined = try navPropertyType(arena.allocator(), .{
        .name = "PowerSensor",
        .type = .{ .name = "Sensor.Sensor", .kind = .entity },
        .expandable = true,
        .excerpt_copy = .{ .key = "Power" },
    }, "sensor.SensorExcerptPower");
    try testing.expectEqualStrings("?sensor.SensorExcerptPower", inlined);
}
