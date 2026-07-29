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

//! The annotations that carry Redfish's semantics.
//!
//! CSDL's own elements describe shape: this property is a string, that one is
//! a collection. Everything a client actually needs to know about behaviour --
//! what is writable, what must be sent when creating a resource, what appears
//! only inside an inlined copy of another resource -- is an annotation. This
//! module is the one place that knows those term names, so the compiler can
//! ask questions instead of matching strings.
//!
//! Terms are matched exactly as written. A schema declares
//! `<edmx:Include Namespace="Org.OData.Core.V1" Alias="OData"/>` and then
//! writes `OData.Description`, so the alias, not the namespace, is what
//! appears at the use site. The DMTF and SNIA corpora use `OData`,
//! `Capabilities` and `Redfish` uniformly, and a term whose namespace has
//! more than one segment is by construction not one of them.

const std = @import("std");

const codemodel = @import("codemodel.zig");
const csdl = @import("csdl.zig");

/// A term split into its namespace and its name.
const Term = struct {
    namespace: []const u8,
    name: []const u8,

    fn parse(text: []const u8) Term {
        const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse
            return .{ .namespace = "", .name = text };
        return .{ .namespace = text[0..dot], .name = text[dot + 1 ..] };
    }
};

/// The first annotation with this term, or null.
pub fn find(
    annotations: []const csdl.Annotation,
    namespace: []const u8,
    name: []const u8,
) ?*const csdl.Annotation {
    for (annotations) |*annotation| {
        const term = Term.parse(annotation.term);
        if (std.mem.eql(u8, term.namespace, namespace) and
            std.mem.eql(u8, term.name, name)) return annotation;
    }
    return null;
}

fn odata(annotations: []const csdl.Annotation, name: []const u8) ?*const csdl.Annotation {
    return find(annotations, "OData", name);
}

fn redfish(annotations: []const csdl.Annotation, name: []const u8) ?*const csdl.Annotation {
    return find(annotations, "Redfish", name);
}

/// Whether a Redfish term is present at all. Several are markers with no
/// value: `Redfish.Required` says only that it applies.
fn hasRedfish(annotations: []const csdl.Annotation, name: []const u8) bool {
    return redfish(annotations, name) != null;
}

/// The value of one member of a record.
fn member(record: []const csdl.PropertyValue, name: []const u8) ?csdl.AnnotationValue {
    for (record) |value| {
        if (std.mem.eql(u8, value.property, name)) return value.value;
    }
    return null;
}

fn memberString(record: []const csdl.PropertyValue, name: []const u8) ?[]const u8 {
    return (member(record, name) orelse return null).asString();
}

/// The name of an enumeration member, dropping the type that qualifies it:
/// `OData.Permission/ReadWrite` names `ReadWrite`.
fn enumMemberName(text: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
    return text[slash + 1 ..];
}

// -- OData ------------------------------------------------------------------

/// `OData.Description`, a one-line summary.
pub fn description(annotations: []const csdl.Annotation) ?[]const u8 {
    return (odata(annotations, "Description") orelse return null).value.asString();
}

/// `OData.LongDescription`, the normative prose.
pub fn longDescription(annotations: []const csdl.Annotation) ?[]const u8 {
    return (odata(annotations, "LongDescription") orelse return null).value.asString();
}

/// `OData.Permissions`. Absent means the element inherits whatever its type
/// says, which is not the same as read/write, so the result is optional.
pub fn permissions(annotations: []const csdl.Annotation) ?codemodel.Permissions {
    const annotation = odata(annotations, "Permissions") orelse return null;
    const text = switch (annotation.value) {
        .enum_member => |value| enumMemberName(value),
        else => return null,
    };
    if (std.mem.eql(u8, text, "Read")) return .read;
    if (std.mem.eql(u8, text, "Write")) return .write;
    if (std.mem.eql(u8, text, "ReadWrite")) return .read_write;
    return null;
}

/// `OData.AdditionalProperties`. False declares the type closed.
pub fn additionalProperties(annotations: []const csdl.Annotation) ?bool {
    return (odata(annotations, "AdditionalProperties") orelse return null).value.asBool();
}

/// `Capabilities.InsertRestrictions` / `Insertable`.
pub fn insertable(annotations: []const csdl.Annotation) ?bool {
    return capability(annotations, "InsertRestrictions", "Insertable");
}

/// `Capabilities.UpdateRestrictions` / `Updatable`.
pub fn updatable(annotations: []const csdl.Annotation) ?bool {
    return capability(annotations, "UpdateRestrictions", "Updatable");
}

/// `Capabilities.DeleteRestrictions` / `Deletable`.
pub fn deletable(annotations: []const csdl.Annotation) ?bool {
    return capability(annotations, "DeleteRestrictions", "Deletable");
}

fn capability(
    annotations: []const csdl.Annotation,
    term: []const u8,
    property: []const u8,
) ?bool {
    const annotation = find(annotations, "Capabilities", term) orelse return null;
    const record = switch (annotation.value) {
        .record => |values| values,
        else => return null,
    };
    return (member(record, property) orelse return null).asBool();
}

// -- Redfish ----------------------------------------------------------------

/// `Redfish.Required`: the service always sends this property.
pub fn isRequired(annotations: []const csdl.Annotation) bool {
    return hasRedfish(annotations, "Required");
}

/// `Redfish.RequiredOnCreate`: a client must send this property when it
/// creates the resource, even if the property is otherwise read-only.
pub fn isRequiredOnCreate(annotations: []const csdl.Annotation) bool {
    return hasRedfish(annotations, "RequiredOnCreate");
}

/// `Redfish.ExcerptCopyOnly`: the property exists only inside excerpt copies
/// of the resource, never in the resource itself.
///
/// The term is normally a bare marker; an explicit `Bool="false"` turns it
/// off, which is how a versioned schema withdraws it.
pub fn isExcerptOnly(annotations: []const csdl.Annotation) bool {
    const annotation = redfish(annotations, "ExcerptCopyOnly") orelse return false;
    return annotation.value.asBool() orelse true;
}

/// The excerpt views a property belongs to, in the `codemodel.Property`
/// encoding: empty for a property that is not part of any excerpt, and a
/// single empty string for one that is part of every excerpt.
///
/// `Redfish.Excerpt` with no string means every view; with a string it is a
/// comma-separated list of view names. `Redfish.ExcerptCopyOnly` carries the
/// same list, because a property that exists only in copies is necessarily
/// part of them.
pub fn excerpts(
    arena: std.mem.Allocator,
    annotations: []const csdl.Annotation,
) std.mem.Allocator.Error![]const []const u8 {
    const annotation = redfish(annotations, "Excerpt") orelse
        redfish(annotations, "ExcerptCopyOnly") orelse return &.{};
    const text = annotation.value.asString() orelse return &.{""};

    var keys: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const key = std.mem.trim(u8, part, " \t");
        if (key.len != 0) try keys.append(arena, key);
    }
    if (keys.items.len == 0) return &.{""};
    return keys.toOwnedSlice(arena);
}

/// `Redfish.ExcerptCopy`: the link inlines part of its target rather than
/// pointing at it. With no string the copy takes the target's default
/// excerpt; with one it takes the named view.
pub fn excerptCopy(annotations: []const csdl.Annotation) ?codemodel.ExcerptCopy {
    const annotation = redfish(annotations, "ExcerptCopy") orelse return null;
    return .{ .key = annotation.value.asString() };
}

/// `Redfish.DynamicPropertyPatterns`: properties the schema cannot name,
/// described by a regular expression and a shared type. Only the first
/// complete pattern is kept, which is all the corpus uses.
pub fn dynamicProperties(annotations: []const csdl.Annotation) ?codemodel.DynamicProperties {
    const annotation = redfish(annotations, "DynamicPropertyPatterns") orelse return null;
    const items = switch (annotation.value) {
        .collection => |values| values,
        else => return null,
    };
    for (items) |item| {
        const record = switch (item) {
            .record => |values| values,
            else => continue,
        };
        const pattern = memberString(record, "Pattern") orelse continue;
        const type_name = memberString(record, "Type") orelse continue;
        return .{ .pattern = pattern, .type = type_name };
    }
    return null;
}

/// `Redfish.Uris`: the URI templates a resource of this type is served at.
pub fn uris(
    arena: std.mem.Allocator,
    annotations: []const csdl.Annotation,
) std.mem.Allocator.Error![]const []const u8 {
    const annotation = redfish(annotations, "Uris") orelse return &.{};
    const items = switch (annotation.value) {
        .collection => |values| values,
        else => return &.{},
    };

    var found: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item.asString()) |text| try found.append(arena, text);
    }
    return found.toOwnedSlice(arena);
}

/// The deprecation announced for an element, if any.
///
/// `Redfish.Revisions` is a log: each record has a `Kind`, and only
/// `Deprecated` records concern a client. The older `Redfish.Deprecated`
/// string says the same thing without a version, and both still appear in
/// the corpus.
pub fn deprecation(annotations: []const csdl.Annotation) ?codemodel.Deprecation {
    if (redfish(annotations, "Revisions")) |annotation| {
        const items = switch (annotation.value) {
            .collection => |values| values,
            else => &.{},
        };
        for (items) |item| {
            const record = switch (item) {
                .record => |values| values,
                else => continue,
            };
            const kind = switch (member(record, "Kind") orelse continue) {
                .enum_member => |value| enumMemberName(value),
                .string => |value| enumMemberName(value),
                else => continue,
            };
            if (!std.mem.eql(u8, kind, "Deprecated")) continue;
            return .{
                .version = memberString(record, "Version"),
                .description = memberString(record, "Description"),
            };
        }
    }
    if (redfish(annotations, "Deprecated")) |annotation| {
        return .{ .description = annotation.value.asString() };
    }
    return null;
}

// -- Combined ---------------------------------------------------------------

/// Everything the model records as documentation for one element.
pub fn docs(annotations: []const csdl.Annotation) codemodel.Docs {
    return .{
        .description = description(annotations),
        .long_description = longDescription(annotations),
        .deprecated = deprecation(annotations),
    };
}

const testing = std.testing;

/// Parse a schema and return the annotations of its only property.
fn propertyAnnotations(arena: std.mem.Allocator, body: []const u8) ![]const csdl.Annotation {
    const head =
        \\<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Test">
        \\      <ComplexType Name="Holder">
        \\
    ;
    const tail =
        \\
        \\      </ComplexType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    ;
    const input = try std.mem.concat(arena, u8, &.{ head, body, tail });
    const document = try csdl.parse(arena, input);
    return document.schemas[0].complex_types[0].properties[0].annotations;
}

test "descriptions come from the OData vocabulary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="OData.Description" String="The name."/>
        \\  <Annotation Term="OData.LongDescription" String="The name of the resource."/>
        \\</Property>
    );

    try testing.expectEqualStrings("The name.", description(found).?);
    try testing.expectEqualStrings("The name of the resource.", longDescription(found).?);
    try testing.expect(permissions(found) == null);
}

test "a term whose namespace has several segments is not the aliased one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Org.OData.Core.V1.Description" String="Unaliased."/>
        \\</Property>
    );

    try testing.expect(description(found) == null);
}

test "permissions name a member of an enumeration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { []const u8, ?codemodel.Permissions }{
        .{ "OData.Permission/Read", .read },
        .{ "OData.Permission/Write", .write },
        .{ "OData.Permission/ReadWrite", .read_write },
        .{ "ReadWrite", .read_write },
        .{ "OData.Permission/Unheard", null },
    };

    for (cases) |case| {
        const body = try std.fmt.allocPrint(arena.allocator(),
            \\<Property Name="Name" Type="Edm.String">
            \\  <Annotation Term="OData.Permissions" EnumMember="{s}"/>
            \\</Property>
        , .{case[0]});
        const found = try propertyAnnotations(arena.allocator(), body);
        try testing.expectEqual(case[1], permissions(found));
    }
}

test "capabilities are members of a record" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Capabilities.InsertRestrictions">
        \\    <Record><PropertyValue Property="Insertable" Bool="true"/></Record>
        \\  </Annotation>
        \\  <Annotation Term="Capabilities.UpdateRestrictions">
        \\    <Record>
        \\      <PropertyValue Property="Updatable" Bool="false"/>
        \\      <Annotation Term="OData.Description" String="Read only."/>
        \\    </Record>
        \\  </Annotation>
        \\</Property>
    );

    try testing.expectEqual(@as(?bool, true), insertable(found));
    try testing.expectEqual(@as(?bool, false), updatable(found));
    try testing.expectEqual(@as(?bool, null), deletable(found));
}

test "additional properties may be declared closed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="OData.AdditionalProperties" Bool="false"/>
        \\</Property>
    );

    try testing.expectEqual(@as(?bool, false), additionalProperties(found));
}

test "requirement markers carry no value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Required"/>
        \\  <Annotation Term="Redfish.RequiredOnCreate"/>
        \\</Property>
    );

    try testing.expect(isRequired(found));
    try testing.expect(isRequiredOnCreate(found));
    try testing.expect(!isExcerptOnly(found));
}

test "an excerpt with no string belongs to every view" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Excerpt"/>
        \\</Property>
    );

    const views = try excerpts(arena.allocator(), found);
    try testing.expectEqual(@as(usize, 1), views.len);
    try testing.expectEqualStrings("", views[0]);
}

test "an excerpt string lists the views by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Excerpt" String="Voltage,Current"/>
        \\</Property>
    );

    const views = try excerpts(arena.allocator(), found);
    try testing.expectEqual(@as(usize, 2), views.len);
    try testing.expectEqualStrings("Voltage", views[0]);
    try testing.expectEqualStrings("Current", views[1]);
}

test "an excerpt-only property is also an excerpt member" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.ExcerptCopyOnly" String="Voltage"/>
        \\</Property>
    );

    try testing.expect(isExcerptOnly(found));
    const views = try excerpts(arena.allocator(), found);
    try testing.expectEqual(@as(usize, 1), views.len);
    try testing.expectEqualStrings("Voltage", views[0]);
}

test "an excerpt-only marker can be withdrawn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.ExcerptCopyOnly" Bool="false"/>
        \\</Property>
    );

    try testing.expect(!isExcerptOnly(found));
}

test "an excerpt copy names the view it takes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.ExcerptCopy" String="Voltage"/>
        \\</Property>
    );

    try testing.expectEqualStrings("Voltage", excerptCopy(found).?.key.?);
}

test "an excerpt copy with no string takes the default view" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.ExcerptCopy"/>
        \\</Property>
    );

    try testing.expect(excerptCopy(found).?.key == null);
}

test "dynamic properties pair a pattern with a type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Oem" Type="Resource.Oem">
        \\  <Annotation Term="Redfish.DynamicPropertyPatterns">
        \\    <Collection>
        \\      <Record>
        \\        <PropertyValue Property="Pattern" String="^[A-Za-z0-9_]+$"/>
        \\        <PropertyValue Property="Type" String="Resource.OemObject"/>
        \\      </Record>
        \\    </Collection>
        \\  </Annotation>
        \\</Property>
    );

    const dynamic = dynamicProperties(found).?;
    try testing.expectEqualStrings("^[A-Za-z0-9_]+$", dynamic.pattern);
    try testing.expectEqualStrings("Resource.OemObject", dynamic.type);
}

test "uris are a collection of templates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Uris">
        \\    <Collection>
        \\      <String>/redfish/v1/Chassis/{ChassisId}</String>
        \\      <String>/redfish/v1/Chassis/{ChassisId}/</String>
        \\    </Collection>
        \\  </Annotation>
        \\</Property>
    );

    const templates = try uris(arena.allocator(), found);
    try testing.expectEqual(@as(usize, 2), templates.len);
    try testing.expectEqualStrings("/redfish/v1/Chassis/{ChassisId}", templates[0]);
}

test "only a deprecating revision is a deprecation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Revisions">
        \\    <Collection>
        \\      <Record>
        \\        <PropertyValue Property="Kind" EnumMember="Redfish.RevisionKind/Added"/>
        \\        <PropertyValue Property="Version" String="v1_1_0"/>
        \\      </Record>
        \\      <Record>
        \\        <PropertyValue Property="Kind" EnumMember="Redfish.RevisionKind/Deprecated"/>
        \\        <PropertyValue Property="Version" String="v1_2_0"/>
        \\        <PropertyValue Property="Description" String="Use Status instead."/>
        \\      </Record>
        \\    </Collection>
        \\  </Annotation>
        \\</Property>
    );

    const found_deprecation = deprecation(found).?;
    try testing.expectEqualStrings("v1_2_0", found_deprecation.version.?);
    try testing.expectEqualStrings("Use Status instead.", found_deprecation.description.?);
}

test "the older deprecation term has no version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String">
        \\  <Annotation Term="Redfish.Deprecated" String="Use Status instead."/>
        \\</Property>
    );

    const found_deprecation = deprecation(found).?;
    try testing.expect(found_deprecation.version == null);
    try testing.expectEqualStrings("Use Status instead.", found_deprecation.description.?);
}

test "an element with no annotations has no documentation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try propertyAnnotations(arena.allocator(),
        \\<Property Name="Name" Type="Edm.String"/>
    );

    const found_docs = docs(found);
    try testing.expect(found_docs.description == null);
    try testing.expect(found_docs.long_description == null);
    try testing.expect(found_docs.deprecated == null);
}
