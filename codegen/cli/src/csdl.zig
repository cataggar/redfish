//! EDMX/CSDL reader.
//!
//! Redfish schemas are OData CSDL documents wrapped in an `edmx:Edmx`
//! envelope: a set of `edmx:Reference`s naming other documents, then one
//! `Schema` per namespace, each holding entity types, complex types, enums,
//! type definitions, actions, and annotations.
//!
//! This is the parsing layer only. It answers "what does this file say",
//! not "what does it mean": base types are not resolved, references are not
//! followed, and annotations are not interpreted. `schema_index.zig` and
//! `compile.zig` do that.
//!
//! Everything is **borrowed from the input text**, which must outlive the
//! `Document`. Only values that need entity decoding, and the lists
//! themselves, are allocated — from an arena the caller owns and frees in
//! one go.
//!
//! References: OData CSDL XML v4.01 (OASIS), DMTF DSP0266 §9 "Schema".

const std = @import("std");

const serde = @import("serde");

const Scanner = serde.xml.Scanner;

/// Mirrors `serde`'s XML scanner error set. It is declared as a sibling of
/// `Scanner` rather than a member, so it cannot be named through the module.
pub const ScanError = error{
    UnexpectedToken,
    UnexpectedEof,
    MalformedXml,
};

pub const Error = error{
    /// The document's root element is not `edmx:Edmx`.
    NotEdmx,
    /// A required attribute was missing — a `Schema` with no `Namespace`,
    /// an `EntityType` with no `Name`, and so on.
    MissingAttribute,
} || ScanError || std.mem.Allocator.Error;

/// A parsed `edmx:Edmx` document.
pub const Document = struct {
    version: []const u8 = "4.0",
    references: []const Reference = &.{},
    schemas: []const Schema = &.{},

    /// The schema declaring `namespace`, if this document has one.
    pub fn schema(self: Document, namespace: []const u8) ?*const Schema {
        for (self.schemas) |*value| {
            if (std.mem.eql(u8, value.namespace, namespace)) return value;
        }
        return null;
    }
};

/// `edmx:Reference` — another CSDL document this one depends on.
pub const Reference = struct {
    uri: []const u8,
    includes: []const Include = &.{},
};

/// `edmx:Include` — a namespace taken from a referenced document, optionally
/// under a local alias.
pub const Include = struct {
    namespace: []const u8,
    alias: ?[]const u8 = null,
};

/// One `Schema` element: everything declared in a single namespace.
///
/// Redfish declares an unversioned namespace (`Chassis`) plus one per
/// version (`Chassis.v1_25_0`), each in its own `Schema` element of the same
/// document.
pub const Schema = struct {
    namespace: []const u8,
    alias: ?[]const u8 = null,
    entity_types: []const EntityType = &.{},
    complex_types: []const ComplexType = &.{},
    enum_types: []const EnumType = &.{},
    type_definitions: []const TypeDefinition = &.{},
    actions: []const Action = &.{},
    containers: []const EntityContainer = &.{},
    annotations: []const Annotation = &.{},
};

/// A type reference as written in an attribute: a qualified name, possibly
/// wrapped in `Collection(...)`.
pub const TypeRef = struct {
    /// The qualified name, with any `Collection(...)` wrapper removed.
    name: []const u8,
    collection: bool = false,

    pub fn parse(text: []const u8) TypeRef {
        if (std.mem.startsWith(u8, text, "Collection(") and std.mem.endsWith(u8, text, ")")) {
            return .{ .name = text["Collection(".len .. text.len - 1], .collection = true };
        }
        return .{ .name = text };
    }

    /// The namespace part, or null for an unqualified name.
    pub fn namespace(self: TypeRef) ?[]const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, self.name, '.') orelse return null;
        return self.name[0..dot];
    }

    /// The final segment of the qualified name.
    pub fn local(self: TypeRef) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, self.name, '.') orelse return self.name;
        return self.name[dot + 1 ..];
    }

    /// True for one of the `Edm.*` built-ins.
    pub fn isPrimitive(self: TypeRef) bool {
        return std.mem.startsWith(u8, self.name, "Edm.");
    }

    pub fn format(self: TypeRef, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.collection) {
            try w.print("Collection({s})", .{self.name});
        } else {
            try w.writeAll(self.name);
        }
    }
};

/// A structural property of an entity or complex type.
pub const Property = struct {
    name: []const u8,
    type: TypeRef,
    /// Absent as written. The compiler supplies the default, which differs
    /// between a structural property and a link.
    nullable: ?bool = null,
    default_value: ?[]const u8 = null,
    annotations: []const Annotation = &.{},
};

/// A link to another entity. Redfish renders one as `{"@odata.id": …}`
/// unless it is expanded.
pub const NavigationProperty = struct {
    name: []const u8,
    type: TypeRef,
    nullable: ?bool = null,
    /// The target is owned by this entity rather than merely linked.
    contains_target: bool = false,
    annotations: []const Annotation = &.{},
};

pub const EntityType = struct {
    name: []const u8,
    base_type: ?TypeRef = null,
    abstract: bool = false,
    open_type: bool = false,
    has_stream: bool = false,
    /// `Key`'s property names, in declaration order.
    key: []const []const u8 = &.{},
    properties: []const Property = &.{},
    navigation_properties: []const NavigationProperty = &.{},
    annotations: []const Annotation = &.{},
};

pub const ComplexType = struct {
    name: []const u8,
    base_type: ?TypeRef = null,
    abstract: bool = false,
    open_type: bool = false,
    properties: []const Property = &.{},
    navigation_properties: []const NavigationProperty = &.{},
    annotations: []const Annotation = &.{},
};

pub const EnumMember = struct {
    name: []const u8,
    /// The explicit `Value`, when the schema gave one.
    value: ?i64 = null,
    annotations: []const Annotation = &.{},
};

pub const EnumType = struct {
    name: []const u8,
    underlying_type: ?TypeRef = null,
    is_flags: bool = false,
    members: []const EnumMember = &.{},
    annotations: []const Annotation = &.{},
};

/// A named alias for a primitive, usually with a validation annotation.
pub const TypeDefinition = struct {
    name: []const u8,
    underlying_type: TypeRef,
    annotations: []const Annotation = &.{},
};

pub const Parameter = struct {
    name: []const u8,
    type: TypeRef,
    nullable: ?bool = null,
    annotations: []const Annotation = &.{},
};

pub const ReturnType = struct {
    type: TypeRef,
    nullable: ?bool = null,
    annotations: []const Annotation = &.{},
};

/// A Redfish action. Bound actions take the enclosing resource as their
/// first parameter, which is how the action's target is derived.
pub const Action = struct {
    name: []const u8,
    is_bound: bool = false,
    entity_set_path: ?[]const u8 = null,
    parameters: []const Parameter = &.{},
    return_type: ?ReturnType = null,
    annotations: []const Annotation = &.{},
};

pub const Singleton = struct {
    name: []const u8,
    type: TypeRef,
    annotations: []const Annotation = &.{},
};

pub const EntitySet = struct {
    name: []const u8,
    entity_type: TypeRef,
    annotations: []const Annotation = &.{},
};

/// The service's root container. Redfish has exactly one, `ServiceContainer`,
/// which OEM schemas extend.
pub const EntityContainer = struct {
    name: []const u8,
    extends: ?[]const u8 = null,
    singletons: []const Singleton = &.{},
    entity_sets: []const EntitySet = &.{},
    annotations: []const Annotation = &.{},
};

/// One `PropertyValue` inside an annotation `Record`.
pub const PropertyValue = struct {
    property: []const u8,
    value: AnnotationValue = .none,
    annotations: []const Annotation = &.{},
};

/// An annotation's value.
///
/// CSDL spells constants either as an attribute (`String="…"`) or as a child
/// element (`<String>…</String>`); both land here the same way. `none` is a
/// marker annotation such as `OData.AutoExpandReferences`, whose presence is
/// the whole message.
pub const AnnotationValue = union(enum) {
    none,
    string: []const u8,
    bool: bool,
    int: i64,
    float: f64,
    /// `EnumMember="OData.Permission/Read"`, kept whole.
    enum_member: []const u8,
    /// `Path="…"`, a model path evaluated against the annotated element.
    path: []const u8,
    record: []const PropertyValue,
    collection: []const AnnotationValue,

    pub fn asString(self: AnnotationValue) ?[]const u8 {
        return switch (self) {
            .string => |value| value,
            else => null,
        };
    }

    pub fn asBool(self: AnnotationValue) ?bool {
        return switch (self) {
            .bool => |value| value,
            // A marker annotation asserts its term, so treat it as true.
            .none => true,
            else => null,
        };
    }

    pub fn asInt(self: AnnotationValue) ?i64 {
        return switch (self) {
            .int => |value| value,
            else => null,
        };
    }
};

/// An `Annotation` element. `term` keeps the alias the document used
/// (`Redfish.Excerpt`, `OData.Description`); resolving that alias to a
/// namespace is the schema index's job.
pub const Annotation = struct {
    term: []const u8,
    qualifier: ?[]const u8 = null,
    value: AnnotationValue = .none,
};

/// Find an annotation by term, comparing the term as written.
pub fn findAnnotation(annotations: []const Annotation, term: []const u8) ?*const Annotation {
    for (annotations) |*annotation| {
        if (std.mem.eql(u8, annotation.term, term)) return annotation;
    }
    return null;
}

/// Parse an EDMX document.
///
/// `arena` holds the lists and any decoded text; `input` must outlive the
/// result, which borrows from it wherever no decoding was needed.
pub fn parse(arena: std.mem.Allocator, input: []const u8) Error!Document {
    var parser: Parser = .{ .arena = arena, .scanner = .{ .input = input } };
    return parser.document();
}

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

/// A start tag with its attributes. `empty` marks `<Foo/>`, which has no
/// children and no close event.
const Start = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    empty: bool = false,

    fn get(self: Start, name: []const u8) ?[]const u8 {
        for (self.attrs) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }
};

const Event = union(enum) {
    open: Start,
    close: []const u8,
    text: []const u8,
    end,
};

/// The local name of a possibly namespace-prefixed element or attribute.
fn localName(name: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return name;
    return name[colon + 1 ..];
}

fn isElement(name: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, localName(name), want);
}

const Parser = struct {
    arena: std.mem.Allocator,
    scanner: Scanner,

    fn next(self: *Parser) Error!Event {
        const token = try self.scanner.next();
        switch (token) {
            .eof => return .end,
            .element_close => |name| return .{ .close = name },
            .text, .cdata => |text| return .{ .text = try self.decode(text) },
            .self_closing => |name| return .{ .open = .{ .name = name, .empty = true } },
            .element_open => |name| return .{ .open = try self.attributes(name) },
            // Only reachable from the in-tag state, which `attributes` owns.
            .attribute, .tag_end => return ScanError.UnexpectedToken,
        }
    }

    /// Collect the attributes of the tag just opened.
    ///
    /// The scanner drops back to the content state on its own when a tag has
    /// no attributes, and reports a self-close after attributes as a
    /// `self_closing` token with an empty name.
    fn attributes(self: *Parser, name: []const u8) Error!Start {
        if (self.scanner.state != .in_tag) return .{ .name = name };

        var attrs: std.ArrayList(Attr) = .empty;
        var empty = false;
        while (true) {
            switch (try self.scanner.next()) {
                .attribute => |attr| try attrs.append(self.arena, .{
                    .name = attr.name,
                    .value = try self.decode(attr.value),
                }),
                .tag_end => break,
                .self_closing => {
                    empty = true;
                    break;
                },
                else => return ScanError.UnexpectedToken,
            }
        }
        return .{
            .name = name,
            .attrs = try attrs.toOwnedSlice(self.arena),
            .empty = empty,
        };
    }

    /// Resolve XML entities, borrowing the input when there are none.
    fn decode(self: *Parser, raw: []const u8) Error![]const u8 {
        if (!Scanner.textHasEntities(raw)) return raw;
        return Scanner.unescapeEntities(self.arena, raw);
    }

    fn require(start: Start, name: []const u8) Error![]const u8 {
        return start.get(name) orelse Error.MissingAttribute;
    }

    fn flag(start: Start, name: []const u8, default: bool) bool {
        const text = start.get(name) orelse return default;
        return std.mem.eql(u8, text, "true");
    }

    /// A flag with no default, for attributes whose absence the compiler
    /// reads differently depending on where they appear.
    fn optionalFlag(start: Start, name: []const u8) ?bool {
        const text = start.get(name) orelse return null;
        return std.mem.eql(u8, text, "true");
    }

    fn typeAttr(start: Start, name: []const u8) Error!TypeRef {
        return .parse(try require(start, name));
    }

    /// Consume an element's children without keeping them.
    fn skip(self: *Parser, start: Start) Error!void {
        if (start.empty) return;
        var depth: usize = 1;
        while (depth > 0) {
            switch (try self.next()) {
                .open => |child| {
                    if (!child.empty) depth += 1;
                },
                .close => depth -= 1,
                .text => {},
                .end => return ScanError.UnexpectedEof,
            }
        }
    }

    fn document(self: *Parser) Error!Document {
        const root = while (true) {
            switch (try self.next()) {
                .open => |start| break start,
                .text => continue,
                .close => return Error.NotEdmx,
                .end => return Error.NotEdmx,
            }
        };
        if (!isElement(root.name, "Edmx")) return Error.NotEdmx;

        var result: Document = .{ .version = root.get("Version") orelse "4.0" };
        var references: std.ArrayList(Reference) = .empty;
        var schemas: std.ArrayList(Schema) = .empty;

        if (root.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |start| start,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };

            if (isElement(child.name, "Reference")) {
                try references.append(self.arena, try self.reference(child));
            } else if (isElement(child.name, "DataServices")) {
                try self.dataServices(child, &schemas);
            } else {
                try self.skip(child);
            }
        }

        result.references = try references.toOwnedSlice(self.arena);
        result.schemas = try schemas.toOwnedSlice(self.arena);
        return result;
    }

    fn reference(self: *Parser, start: Start) Error!Reference {
        var result: Reference = .{ .uri = try require(start, "Uri") };
        var includes: std.ArrayList(Include) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };

            if (isElement(child.name, "Include")) {
                try includes.append(self.arena, .{
                    .namespace = try require(child, "Namespace"),
                    .alias = child.get("Alias"),
                });
            }
            // `IncludeAnnotations` selects which annotations to import.
            // Nothing downstream filters on it.
            try self.skip(child);
        }

        result.includes = try includes.toOwnedSlice(self.arena);
        return result;
    }

    fn dataServices(self: *Parser, start: Start, schemas: *std.ArrayList(Schema)) Error!void {
        if (start.empty) return;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };

            if (isElement(child.name, "Schema")) {
                try schemas.append(self.arena, try self.schema(child));
            } else {
                try self.skip(child);
            }
        }
    }

    fn schema(self: *Parser, start: Start) Error!Schema {
        var result: Schema = .{
            .namespace = try require(start, "Namespace"),
            .alias = start.get("Alias"),
        };

        var entity_types: std.ArrayList(EntityType) = .empty;
        var complex_types: std.ArrayList(ComplexType) = .empty;
        var enum_types: std.ArrayList(EnumType) = .empty;
        var type_definitions: std.ArrayList(TypeDefinition) = .empty;
        var actions: std.ArrayList(Action) = .empty;
        var containers: std.ArrayList(EntityContainer) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "EntityType")) {
                try entity_types.append(self.arena, try self.entityType(child));
            } else if (std.mem.eql(u8, name, "ComplexType")) {
                try complex_types.append(self.arena, try self.complexType(child));
            } else if (std.mem.eql(u8, name, "EnumType")) {
                try enum_types.append(self.arena, try self.enumType(child));
            } else if (std.mem.eql(u8, name, "TypeDefinition")) {
                try type_definitions.append(self.arena, try self.typeDefinition(child));
            } else if (std.mem.eql(u8, name, "Action")) {
                try actions.append(self.arena, try self.action(child));
            } else if (std.mem.eql(u8, name, "EntityContainer")) {
                try containers.append(self.arena, try self.container(child));
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                // `Term`, `Function`, and `Annotations` are declared by the
                // vocabularies Redfish imports, never by a Redfish schema.
                try self.skip(child);
            }
        }

        result.entity_types = try entity_types.toOwnedSlice(self.arena);
        result.complex_types = try complex_types.toOwnedSlice(self.arena);
        result.enum_types = try enum_types.toOwnedSlice(self.arena);
        result.type_definitions = try type_definitions.toOwnedSlice(self.arena);
        result.actions = try actions.toOwnedSlice(self.arena);
        result.containers = try containers.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    fn entityType(self: *Parser, start: Start) Error!EntityType {
        var result: EntityType = .{
            .name = try require(start, "Name"),
            .base_type = if (start.get("BaseType")) |text| .parse(text) else null,
            .abstract = flag(start, "Abstract", false),
            .open_type = flag(start, "OpenType", false),
            .has_stream = flag(start, "HasStream", false),
        };

        var key_properties: std.ArrayList([]const u8) = .empty;
        var properties: std.ArrayList(Property) = .empty;
        var navigation: std.ArrayList(NavigationProperty) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "Key")) {
                try self.key(child, &key_properties);
            } else if (std.mem.eql(u8, name, "Property")) {
                try properties.append(self.arena, try self.property(child));
            } else if (std.mem.eql(u8, name, "NavigationProperty")) {
                try navigation.append(self.arena, try self.navigationProperty(child));
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }

        result.key = try key_properties.toOwnedSlice(self.arena);
        result.properties = try properties.toOwnedSlice(self.arena);
        result.navigation_properties = try navigation.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    fn key(self: *Parser, start: Start, out: *std.ArrayList([]const u8)) Error!void {
        if (start.empty) return;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            if (isElement(child.name, "PropertyRef")) {
                try out.append(self.arena, try require(child, "Name"));
            }
            try self.skip(child);
        }
    }

    fn complexType(self: *Parser, start: Start) Error!ComplexType {
        var result: ComplexType = .{
            .name = try require(start, "Name"),
            .base_type = if (start.get("BaseType")) |text| .parse(text) else null,
            .abstract = flag(start, "Abstract", false),
            .open_type = flag(start, "OpenType", false),
        };

        var properties: std.ArrayList(Property) = .empty;
        var navigation: std.ArrayList(NavigationProperty) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "Property")) {
                try properties.append(self.arena, try self.property(child));
            } else if (std.mem.eql(u8, name, "NavigationProperty")) {
                try navigation.append(self.arena, try self.navigationProperty(child));
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }

        result.properties = try properties.toOwnedSlice(self.arena);
        result.navigation_properties = try navigation.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    fn property(self: *Parser, start: Start) Error!Property {
        return .{
            .name = try require(start, "Name"),
            .type = try typeAttr(start, "Type"),
            .nullable = optionalFlag(start, "Nullable"),
            .default_value = start.get("DefaultValue"),
            .annotations = try self.annotationsOf(start),
        };
    }

    fn navigationProperty(self: *Parser, start: Start) Error!NavigationProperty {
        return .{
            .name = try require(start, "Name"),
            .type = try typeAttr(start, "Type"),
            .nullable = optionalFlag(start, "Nullable"),
            .contains_target = flag(start, "ContainsTarget", false),
            .annotations = try self.annotationsOf(start),
        };
    }

    fn enumType(self: *Parser, start: Start) Error!EnumType {
        var result: EnumType = .{
            .name = try require(start, "Name"),
            .underlying_type = if (start.get("UnderlyingType")) |text| .parse(text) else null,
            .is_flags = flag(start, "IsFlags", false),
        };

        var members: std.ArrayList(EnumMember) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "Member")) {
                try members.append(self.arena, .{
                    .name = try require(child, "Name"),
                    .value = if (child.get("Value")) |text|
                        std.fmt.parseInt(i64, text, 10) catch null
                    else
                        null,
                    .annotations = try self.annotationsOf(child),
                });
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }

        result.members = try members.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    fn typeDefinition(self: *Parser, start: Start) Error!TypeDefinition {
        return .{
            .name = try require(start, "Name"),
            .underlying_type = try typeAttr(start, "UnderlyingType"),
            .annotations = try self.annotationsOf(start),
        };
    }

    fn action(self: *Parser, start: Start) Error!Action {
        var result: Action = .{
            .name = try require(start, "Name"),
            .is_bound = flag(start, "IsBound", false),
            .entity_set_path = start.get("EntitySetPath"),
        };

        var parameters: std.ArrayList(Parameter) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "Parameter")) {
                try parameters.append(self.arena, .{
                    .name = try require(child, "Name"),
                    .type = try typeAttr(child, "Type"),
                    .nullable = optionalFlag(child, "Nullable"),
                    .annotations = try self.annotationsOf(child),
                });
            } else if (std.mem.eql(u8, name, "ReturnType")) {
                result.return_type = .{
                    .type = try typeAttr(child, "Type"),
                    .nullable = optionalFlag(child, "Nullable"),
                    .annotations = try self.annotationsOf(child),
                };
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }

        result.parameters = try parameters.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    fn container(self: *Parser, start: Start) Error!EntityContainer {
        var result: EntityContainer = .{
            .name = try require(start, "Name"),
            .extends = start.get("Extends"),
        };

        var singletons: std.ArrayList(Singleton) = .empty;
        var entity_sets: std.ArrayList(EntitySet) = .empty;
        var annotations: std.ArrayList(Annotation) = .empty;

        if (start.empty) return result;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            const name = localName(child.name);

            if (std.mem.eql(u8, name, "Singleton")) {
                try singletons.append(self.arena, .{
                    .name = try require(child, "Name"),
                    .type = try typeAttr(child, "Type"),
                    .annotations = try self.annotationsOf(child),
                });
            } else if (std.mem.eql(u8, name, "EntitySet")) {
                try entity_sets.append(self.arena, .{
                    .name = try require(child, "Name"),
                    .entity_type = try typeAttr(child, "EntityType"),
                    .annotations = try self.annotationsOf(child),
                });
            } else if (std.mem.eql(u8, name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }

        result.singletons = try singletons.toOwnedSlice(self.arena);
        result.entity_sets = try entity_sets.toOwnedSlice(self.arena);
        result.annotations = try annotations.toOwnedSlice(self.arena);
        return result;
    }

    /// The `Annotation` children of an element that has nothing else worth
    /// keeping.
    fn annotationsOf(self: *Parser, start: Start) Error![]const Annotation {
        if (start.empty) return &.{};

        var annotations: std.ArrayList(Annotation) = .empty;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            if (isElement(child.name, "Annotation")) {
                try annotations.append(self.arena, try self.annotation(child));
            } else {
                try self.skip(child);
            }
        }
        return annotations.toOwnedSlice(self.arena);
    }

    fn annotation(self: *Parser, start: Start) Error!Annotation {
        var result: Annotation = .{
            .term = try require(start, "Term"),
            .qualifier = start.get("Qualifier"),
            .value = attributeValue(start),
        };
        if (start.empty) return result;

        // A constant may be an attribute or a child element; a record or a
        // collection can only be a child.
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            if (try self.elementValue(child)) |found| result.value = found;
        }
        return result;
    }

    /// The value of a constant, record, or collection child of an annotation.
    /// Null for a child that carries no value, such as a nested `Annotation`.
    fn elementValue(self: *Parser, start: Start) Error!?AnnotationValue {
        const name = localName(start.name);

        if (std.mem.eql(u8, name, "Record")) return .{ .record = try self.record(start) };
        if (std.mem.eql(u8, name, "Collection")) return .{ .collection = try self.collection(start) };

        if (std.mem.eql(u8, name, "String") or
            std.mem.eql(u8, name, "Bool") or
            std.mem.eql(u8, name, "Int") or
            std.mem.eql(u8, name, "Float") or
            std.mem.eql(u8, name, "Decimal") or
            std.mem.eql(u8, name, "EnumMember") or
            std.mem.eql(u8, name, "Path"))
        {
            const text = try self.textOf(start);
            return constant(name, text);
        }

        try self.skip(start);
        return null;
    }

    fn record(self: *Parser, start: Start) Error![]const PropertyValue {
        if (start.empty) return &.{};

        var values: std.ArrayList(PropertyValue) = .empty;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };

            if (!isElement(child.name, "PropertyValue")) {
                try self.skip(child);
                continue;
            }

            var value: PropertyValue = .{
                .property = try require(child, "Property"),
                .value = attributeValue(child),
            };
            if (!child.empty) {
                var annotations: std.ArrayList(Annotation) = .empty;
                while (true) {
                    const inner = switch (try self.next()) {
                        .open => |element| element,
                        .close => break,
                        .text => continue,
                        .end => return ScanError.UnexpectedEof,
                    };
                    if (isElement(inner.name, "Annotation")) {
                        try annotations.append(self.arena, try self.annotation(inner));
                    } else if (try self.elementValue(inner)) |found| {
                        value.value = found;
                    }
                }
                value.annotations = try annotations.toOwnedSlice(self.arena);
            }
            try values.append(self.arena, value);
        }
        return values.toOwnedSlice(self.arena);
    }

    fn collection(self: *Parser, start: Start) Error![]const AnnotationValue {
        if (start.empty) return &.{};

        var values: std.ArrayList(AnnotationValue) = .empty;
        while (true) {
            const child = switch (try self.next()) {
                .open => |element| element,
                .close => break,
                .text => continue,
                .end => return ScanError.UnexpectedEof,
            };
            if (try self.elementValue(child)) |value| try values.append(self.arena, value);
        }
        return values.toOwnedSlice(self.arena);
    }

    /// The text content of an element, with its children skipped.
    fn textOf(self: *Parser, start: Start) Error![]const u8 {
        if (start.empty) return "";

        var text: []const u8 = "";
        while (true) {
            switch (try self.next()) {
                .text => |value| text = value,
                .open => |child| try self.skip(child),
                .close => break,
                .end => return ScanError.UnexpectedEof,
            }
        }
        return text;
    }
};

/// The constant an annotation or property value carries as an attribute.
fn attributeValue(start: Start) AnnotationValue {
    for (start.attrs) |attr| {
        if (constant(attr.name, attr.value)) |value| return value;
    }
    return .none;
}

/// Interpret `name="text"` as a CSDL constant, or null when `name` is not
/// one of the constant kinds.
fn constant(name: []const u8, text: []const u8) ?AnnotationValue {
    if (std.mem.eql(u8, name, "String")) return .{ .string = text };
    if (std.mem.eql(u8, name, "Bool")) return .{ .bool = std.mem.eql(u8, text, "true") };
    if (std.mem.eql(u8, name, "Int")) {
        return .{ .int = std.fmt.parseInt(i64, text, 10) catch return null };
    }
    if (std.mem.eql(u8, name, "Float") or std.mem.eql(u8, name, "Decimal")) {
        return .{ .float = std.fmt.parseFloat(f64, text) catch return null };
    }
    if (std.mem.eql(u8, name, "EnumMember")) return .{ .enum_member = text };
    if (std.mem.eql(u8, name, "Path")) return .{ .path = text };
    return null;
}

const testing = std.testing;

/// Parse into an arena the caller frees. Every test needs this pair.
fn parseInto(arena: *std.heap.ArenaAllocator, input: []const u8) !Document {
    return parse(arena.allocator(), input);
}

test "a type reference splits into namespace and local name" {
    const single: TypeRef = .parse("Chassis.v1_25_0.Chassis");
    try testing.expect(!single.collection);
    try testing.expectEqualStrings("Chassis.v1_25_0", single.namespace().?);
    try testing.expectEqualStrings("Chassis", single.local());
    try testing.expect(!single.isPrimitive());

    const many: TypeRef = .parse("Collection(Resource.Location)");
    try testing.expect(many.collection);
    try testing.expectEqualStrings("Resource.Location", many.name);
    try testing.expectEqualStrings("Location", many.local());

    const primitive: TypeRef = .parse("Edm.String");
    try testing.expect(primitive.isPrimitive());
    try testing.expectEqualStrings("Edm", primitive.namespace().?);

    const unqualified: TypeRef = .parse("Chassis");
    try testing.expectEqual(@as(?[]const u8, null), unqualified.namespace());
    try testing.expectEqualStrings("Chassis", unqualified.local());
}

test "a type reference renders back to its source form" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "Collection(Edm.String)",
        try std.fmt.bufPrint(&buffer, "{f}", .{TypeRef.parse("Collection(Edm.String)")}),
    );
    try testing.expectEqualStrings(
        "Edm.String",
        try std.fmt.bufPrint(&buffer, "{f}", .{TypeRef.parse("Edm.String")}),
    );
}

const chassis_csdl =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!-- A comment the reader must ignore -->
    \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
    \\  <edmx:Reference Uri="http://redfish.dmtf.org/schemas/v1/Resource_v1.xml">
    \\    <edmx:Include Namespace="Resource"/>
    \\    <edmx:Include Namespace="Resource.v1_0_0"/>
    \\  </edmx:Reference>
    \\  <edmx:Reference Uri="http://redfish.dmtf.org/schemas/v1/RedfishExtensions_v1.xml">
    \\    <edmx:Include Namespace="RedfishExtensions.v1_0_0" Alias="Redfish"/>
    \\  </edmx:Reference>
    \\  <edmx:DataServices>
    \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis">
    \\      <EntityType Name="Chassis" BaseType="Resource.v1_0_0.Resource" Abstract="true">
    \\        <Annotation Term="OData.Description" String="A chassis."/>
    \\        <Annotation Term="Redfish.Uris">
    \\          <Collection>
    \\            <String>/redfish/v1/Chassis/{ChassisId}</String>
    \\          </Collection>
    \\        </Annotation>
    \\      </EntityType>
    \\      <Action Name="Reset" IsBound="true">
    \\        <Parameter Name="ComputerSystem" Type="Chassis.v1_0_0.Actions"/>
    \\        <Parameter Name="ResetType" Type="Resource.ResetType">
    \\          <Annotation Term="OData.Description" String="The type of reset."/>
    \\        </Parameter>
    \\      </Action>
    \\    </Schema>
    \\    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" Namespace="Chassis.v1_25_0">
    \\      <EntityType Name="Chassis" BaseType="Chassis.Chassis">
    \\        <Key>
    \\          <PropertyRef Name="Id"/>
    \\        </Key>
    \\        <Property Name="AssetTag" Type="Edm.String">
    \\          <Annotation Term="OData.Permissions" EnumMember="OData.Permission/ReadWrite"/>
    \\          <Annotation Term="Redfish.Excerpt"/>
    \\        </Property>
    \\        <Property Name="PowerState" Type="Chassis.v1_25_0.PowerState" Nullable="false"/>
    \\        <Property Name="Sensors" Type="Collection(Edm.String)" DefaultValue="[]"/>
    \\        <NavigationProperty Name="Thermal" Type="Thermal.Thermal" Nullable="false" ContainsTarget="true">
    \\          <Annotation Term="OData.AutoExpandReferences"/>
    \\        </NavigationProperty>
    \\      </EntityType>
    \\      <ComplexType Name="Links" BaseType="Resource.Links">
    \\        <NavigationProperty Name="ManagedBy" Type="Collection(Manager.Manager)"/>
    \\      </ComplexType>
    \\      <EnumType Name="PowerState">
    \\        <Member Name="On">
    \\          <Annotation Term="OData.Description" String="Powered on."/>
    \\        </Member>
    \\        <Member Name="Off" Value="1"/>
    \\      </EnumType>
    \\      <TypeDefinition Name="Watts" UnderlyingType="Edm.Decimal">
    \\        <Annotation Term="Measures.Unit" String="W"/>
    \\      </TypeDefinition>
    \\    </Schema>
    \\  </edmx:DataServices>
    \\</edmx:Edmx>
;

test "an edmx document yields its references and schemas" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);

    try testing.expectEqualStrings("4.0", document.version);
    try testing.expectEqual(@as(usize, 2), document.references.len);
    try testing.expectEqualStrings(
        "http://redfish.dmtf.org/schemas/v1/Resource_v1.xml",
        document.references[0].uri,
    );
    try testing.expectEqual(@as(usize, 2), document.references[0].includes.len);
    try testing.expectEqualStrings("Resource.v1_0_0", document.references[0].includes[1].namespace);
    try testing.expectEqualStrings("Redfish", document.references[1].includes[0].alias.?);

    try testing.expectEqual(@as(usize, 2), document.schemas.len);
    try testing.expectEqualStrings("Chassis", document.schemas[0].namespace);
    try testing.expectEqualStrings("Chassis.v1_25_0", document.schemas[1].namespace);
}

test "an entity type keeps its base, key, and properties" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const versioned = document.schema("Chassis.v1_25_0").?;
    const chassis = versioned.entity_types[0];

    try testing.expectEqualStrings("Chassis", chassis.name);
    try testing.expectEqualStrings("Chassis.Chassis", chassis.base_type.?.name);
    try testing.expect(!chassis.abstract);
    try testing.expectEqual(@as(usize, 1), chassis.key.len);
    try testing.expectEqualStrings("Id", chassis.key[0]);

    try testing.expectEqual(@as(usize, 3), chassis.properties.len);
    try testing.expectEqualStrings("AssetTag", chassis.properties[0].name);
    try testing.expectEqualStrings("Edm.String", chassis.properties[0].type.name);
    try testing.expect(chassis.properties[0].nullable == null);
    try testing.expect(chassis.properties[1].nullable == false);
    try testing.expect(chassis.properties[2].type.collection);
    try testing.expectEqualStrings("[]", chassis.properties[2].default_value.?);
}

test "an abstract entity type is marked as such" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const unversioned = document.schema("Chassis").?;

    try testing.expect(unversioned.entity_types[0].abstract);
    try testing.expectEqualStrings(
        "Resource.v1_0_0.Resource",
        unversioned.entity_types[0].base_type.?.name,
    );
}

test "a navigation property keeps containment and nullability" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const chassis = document.schema("Chassis.v1_25_0").?.entity_types[0];
    const thermal = chassis.navigation_properties[0];

    try testing.expectEqualStrings("Thermal", thermal.name);
    try testing.expect(thermal.contains_target);
    try testing.expect(thermal.nullable == false);
    try testing.expect(findAnnotation(thermal.annotations, "OData.AutoExpandReferences") != null);
}

test "a complex type carries its own navigation properties" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const links = document.schema("Chassis.v1_25_0").?.complex_types[0];

    try testing.expectEqualStrings("Links", links.name);
    try testing.expectEqualStrings("Resource.Links", links.base_type.?.name);
    try testing.expect(links.navigation_properties[0].type.collection);
    try testing.expectEqualStrings("Manager.Manager", links.navigation_properties[0].type.name);
}

test "an enum keeps member order and explicit values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const power_state = document.schema("Chassis.v1_25_0").?.enum_types[0];

    try testing.expectEqualStrings("PowerState", power_state.name);
    try testing.expectEqual(@as(usize, 2), power_state.members.len);
    try testing.expectEqualStrings("On", power_state.members[0].name);
    try testing.expectEqual(@as(?i64, null), power_state.members[0].value);
    try testing.expectEqual(@as(?i64, 1), power_state.members[1].value);
    try testing.expectEqualStrings(
        "Powered on.",
        findAnnotation(power_state.members[0].annotations, "OData.Description").?.value.asString().?,
    );
}

test "a type definition keeps its underlying type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const watts = document.schema("Chassis.v1_25_0").?.type_definitions[0];

    try testing.expectEqualStrings("Watts", watts.name);
    try testing.expectEqualStrings("Edm.Decimal", watts.underlying_type.name);
    try testing.expectEqualStrings(
        "W",
        findAnnotation(watts.annotations, "Measures.Unit").?.value.asString().?,
    );
}

test "an action keeps its binding and parameters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const reset = document.schema("Chassis").?.actions[0];

    try testing.expectEqualStrings("Reset", reset.name);
    try testing.expect(reset.is_bound);
    try testing.expectEqual(@as(usize, 2), reset.parameters.len);
    try testing.expectEqualStrings("Chassis.v1_0_0.Actions", reset.parameters[0].type.name);
    try testing.expectEqualStrings(
        "The type of reset.",
        findAnnotation(reset.parameters[1].annotations, "OData.Description").?.value.asString().?,
    );
}

test "an annotation value comes from an attribute or a child element" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const chassis = document.schema("Chassis").?.entity_types[0];

    try testing.expectEqualStrings(
        "A chassis.",
        findAnnotation(chassis.annotations, "OData.Description").?.value.asString().?,
    );

    const uris = findAnnotation(chassis.annotations, "Redfish.Uris").?.value.collection;
    try testing.expectEqual(@as(usize, 1), uris.len);
    try testing.expectEqualStrings("/redfish/v1/Chassis/{ChassisId}", uris[0].asString().?);
}

test "a marker annotation has no value but reads as true" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena, chassis_csdl);
    const asset_tag = document.schema("Chassis.v1_25_0").?.entity_types[0].properties[0];

    const excerpt = findAnnotation(asset_tag.annotations, "Redfish.Excerpt").?;
    try testing.expect(excerpt.value == .none);
    try testing.expect(excerpt.value.asBool().?);

    const permissions = findAnnotation(asset_tag.annotations, "OData.Permissions").?;
    try testing.expectEqualStrings("OData.Permission/ReadWrite", permissions.value.enum_member);
}

test "a record annotation keeps its property values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Test">
        \\      <ComplexType Name="Oem">
        \\        <Annotation Term="Redfish.DynamicPropertyPatterns">
        \\          <Collection>
        \\            <Record>
        \\              <PropertyValue Property="Pattern" String="^[A-Za-z0-9_]+$"/>
        \\              <PropertyValue Property="Type" String="Resource.OemObject"/>
        \\            </Record>
        \\          </Collection>
        \\        </Annotation>
        \\        <Annotation Term="Redfish.Revisions">
        \\          <Collection>
        \\            <Record>
        \\              <PropertyValue Property="Kind" EnumMember="Redfish.RevisionKind/Deprecated"/>
        \\              <PropertyValue Property="Version" String="v1_2_0"/>
        \\              <PropertyValue Property="Description">
        \\                <String>Superseded.</String>
        \\              </PropertyValue>
        \\            </Record>
        \\          </Collection>
        \\        </Annotation>
        \\      </ComplexType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    );

    const oem = document.schema("Test").?.complex_types[0];

    const patterns = findAnnotation(oem.annotations, "Redfish.DynamicPropertyPatterns").?;
    const first = patterns.value.collection[0].record;
    try testing.expectEqualStrings("Pattern", first[0].property);
    try testing.expectEqualStrings("^[A-Za-z0-9_]+$", first[0].value.asString().?);
    try testing.expectEqualStrings("Resource.OemObject", first[1].value.asString().?);

    const revisions = findAnnotation(oem.annotations, "Redfish.Revisions").?;
    const revision = revisions.value.collection[0].record;
    try testing.expectEqualStrings(
        "Redfish.RevisionKind/Deprecated",
        revision[0].value.enum_member,
    );
    try testing.expectEqualStrings("Superseded.", revision[2].value.asString().?);
}

test "an entity container lists singletons and entity sets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="ServiceRoot.v1_0_0">
        \\      <EntityContainer Name="ServiceContainer" Extends="ServiceRoot.v1_0_0.ServiceContainer">
        \\        <Singleton Name="Chassis" Type="ChassisCollection.ChassisCollection"/>
        \\        <EntitySet Name="Sessions" EntityType="Session.Session">
        \\          <Annotation Term="OData.Description" String="The sessions."/>
        \\        </EntitySet>
        \\      </EntityContainer>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    );

    const container = document.schema("ServiceRoot.v1_0_0").?.containers[0];
    try testing.expectEqualStrings("ServiceContainer", container.name);
    try testing.expectEqualStrings("ServiceRoot.v1_0_0.ServiceContainer", container.extends.?);
    try testing.expectEqualStrings(
        "ChassisCollection.ChassisCollection",
        container.singletons[0].type.name,
    );
    try testing.expectEqualStrings("Session.Session", container.entity_sets[0].entity_type.name);
    try testing.expectEqualStrings(
        "The sessions.",
        findAnnotation(container.entity_sets[0].annotations, "OData.Description").?.value.asString().?,
    );
}

test "xml entities in attributes and text are decoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Test">
        \\      <EntityType Name="Thing">
        \\        <Annotation Term="OData.Description" String="A &quot;thing&quot; &amp; more"/>
        \\        <Annotation Term="OData.LongDescription">
        \\          <String>Less &lt; greater &gt; done</String>
        \\        </Annotation>
        \\      </EntityType>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    );

    const thing = document.schema("Test").?.entity_types[0];
    try testing.expectEqualStrings(
        "A \"thing\" & more",
        findAnnotation(thing.annotations, "OData.Description").?.value.asString().?,
    );
    try testing.expectEqualStrings(
        "Less < greater > done",
        findAnnotation(thing.annotations, "OData.LongDescription").?.value.asString().?,
    );
}

test "a document that is not edmx is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(Error.NotEdmx, parseInto(&arena, "<html><body/></html>"));
    try testing.expectError(Error.NotEdmx, parseInto(&arena, ""));
}

test "a schema without a namespace is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(Error.MissingAttribute, parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices><Schema/></edmx:DataServices>
        \\</edmx:Edmx>
    ));
}

test "an empty edmx document parses to nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.01"/>
    );
    try testing.expectEqualStrings("4.01", document.version);
    try testing.expectEqual(@as(usize, 0), document.schemas.len);
    try testing.expectEqual(@as(?*const Schema, null), document.schema("Nothing"));
}

test "unknown elements are skipped without disturbing their siblings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = try parseInto(&arena,
        \\<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
        \\  <edmx:DataServices>
        \\    <Schema Namespace="Test">
        \\      <Term Name="Excerpt" Type="Edm.String">
        \\        <Annotation Term="OData.Description" String="Ignored."/>
        \\      </Term>
        \\      <Function Name="Unused"><ReturnType Type="Edm.String"/></Function>
        \\      <EntityType Name="Thing"/>
        \\    </Schema>
        \\  </edmx:DataServices>
        \\</edmx:Edmx>
    );

    const schema = document.schema("Test").?;
    try testing.expectEqual(@as(usize, 1), schema.entity_types.len);
    try testing.expectEqualStrings("Thing", schema.entity_types[0].name);
}
