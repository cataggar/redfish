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
pub fn propertyType(
    arena: std.mem.Allocator,
    property: codemodel.Property,
    named: []const u8,
    shape: Shape,
) std.mem.Allocator.Error![]const u8 {
    const element = elementType(property.type, named);
    const collected = try collection(arena, element, property.type.collection, property.rigid_array);
    return switch (shape) {
        // A property the service always sends, and never as null, is the only
        // one a reader can take at face value.
        .read => if (property.required and !property.nullable)
            collected
        else
            std.fmt.allocPrint(arena, "?{s}", .{collected}),
        .write => if (property.nullable)
            std.fmt.allocPrint(arena, "{s}.Nullable({s})", .{ core_prefix, collected })
        else
            std.fmt.allocPrint(arena, "?{s}", .{collected}),
    };
}

/// The Zig type of a link.
///
/// A link inside the compiled surface can be expanded, so it carries the
/// target type; one outside it can only ever be an `@odata.id`, and says so
/// with a distinct type rather than pretending to be an unexpanded link.
pub fn navPropertyType(
    arena: std.mem.Allocator,
    property: codemodel.NavProperty,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const element = if (property.expandable)
        try std.fmt.allocPrint(arena, "{s}.NavProperty({s})", .{
            core_prefix,
            elementType(property.type, named),
        })
    else
        core_prefix ++ ".ReferenceLeaf";

    const collected = try collection(arena, element, property.type.collection, false);
    if (property.required and !property.nullable) return collected;
    return std.fmt.allocPrint(arena, "?{s}", .{collected});
}

/// The Zig type of an action parameter. Actions are always written, never
/// read, so a nullable parameter gets the three-way type.
pub fn parameterType(
    arena: std.mem.Allocator,
    parameter: codemodel.Parameter,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const element = elementType(parameter.type, named);
    const collected = try collection(arena, element, parameter.type.collection, false);
    if (parameter.nullable) {
        return std.fmt.allocPrint(arena, "{s}.Nullable({s})", .{ core_prefix, collected });
    }
    if (parameter.required) return collected;
    return std.fmt.allocPrint(arena, "?{s}", .{collected});
}

/// The Zig type an action returns. A return value is always read.
pub fn returnType(
    arena: std.mem.Allocator,
    type_ref: codemodel.TypeRef,
    named: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return collection(arena, elementType(type_ref, named), type_ref.collection, false);
}

/// Wraps an element type in a slice, if it is a collection.
///
/// A rigid collection has a fixed length the service decides, so its entries
/// are addressable by index and a null entry means "this slot has no value" --
/// which is why only rigid collections have optional elements.
fn collection(
    arena: std.mem.Allocator,
    element: []const u8,
    is_collection: bool,
    rigid: bool,
) std.mem.Allocator.Error![]const u8 {
    if (!is_collection) return element;
    if (rigid) return std.fmt.allocPrint(arena, "[]const ?{s}", .{element});
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

test "only a required property that is never null is read bare" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string: codemodel.TypeRef = .{ .name = "Edm.String", .kind = .primitive };

    try testing.expectEqualStrings("[]const u8", try propertyType(
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

test "a collection is a slice, and a rigid one has optional entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const strings: codemodel.TypeRef = .{
        .name = "Edm.String",
        .kind = .primitive,
        .collection = true,
    };

    try testing.expectEqualStrings("?[]const []const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings },
        "",
        .read,
    ));
    try testing.expectEqualStrings("?[]const ?[]const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .rigid_array = true },
        "",
        .read,
    ));
    try testing.expectEqualStrings("[]const []const u8", try propertyType(
        allocator,
        .{ .name = "Names", .type = strings, .required = true, .nullable = false },
        "",
        .read,
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
    try testing.expectEqualStrings("[]const core.NavProperty(Chassis)", try navPropertyType(
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
