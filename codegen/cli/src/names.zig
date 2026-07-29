//! What a schema name is called in the generated package.
//!
//! CSDL names a type by namespace and simple name, and after the optimizer
//! has hoisted everything the namespace is usually one segment: `Chassis`,
//! `Resource`, `ServiceRoot`. That maps onto Zig the way nv-redfish maps it
//! onto Rust — a module per namespace, a type per declaration — so
//! `Chassis.Chassis` is `chassis.Chassis` and `Chassis.Links` is
//! `chassis.Links`.
//!
//! Keeping the namespace is what makes the names stable. Every Redfish
//! schema declares a `Links`, an `Actions`, an `Oem`; flattening the corpus
//! into one namespace would need a disambiguation rule, and any such rule
//! renames existing types the moment a profile gains a schema. Generated code
//! is checked in here, so that churn would land in every review.
//!
//! Names come out of the schema unchanged wherever the wire can see them.
//! Struct fields and enum members keep their exact spelling, quoted when Zig
//! needs it, so `std.json` round-trips them without a rename table. Only
//! things the wire never sees — module names, type names, method names — get
//! converted to Zig's conventions.

const std = @import("std");

const codemodel = @import("codemodel.zig");
const identifiers = @import("identifiers.zig");
const naming = @import("naming.zig");
const schema_index = @import("schema_index.zig");

const Namespace = schema_index.Namespace;
const QualifiedName = schema_index.QualifiedName;

pub const Error = std.mem.Allocator.Error;

/// Which of a type's shapes is being named.
///
/// A resource is read as one struct, written as another, created as a third,
/// and inlined into a link as a fourth. They are different types because they
/// have different fields, and the suffix is what tells them apart.
pub const Shape = union(enum) {
    /// The resource as the service sends it.
    read,
    /// The subset a client may PATCH.
    update,
    /// The subset a client may POST to a collection.
    create,
    /// The subset a link inlines, by excerpt view.
    excerpt: codemodel.ExcerptCopy,
};

/// The module a namespace becomes: `ServiceRoot` is `service_root`,
/// `Chassis.v1_25_0` is `chassis_v1_25_0`.
///
/// A version segment only survives the optimizer when two versions of a name
/// are both reachable, which is rare and worth seeing in the name.
pub fn module(arena: std.mem.Allocator, namespace: Namespace) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var segments = std.mem.splitScalar(u8, namespace.text, '.');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try out.append(arena, '_');
        first = false;
        const converted = try naming.toSnakeCase(arena, segment);
        try out.appendSlice(arena, converted);
    }
    return out.toOwnedSlice(arena);
}

/// The file a namespace's declarations are written to.
pub fn file(arena: std.mem.Allocator, namespace: Namespace) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.zig", .{try module(arena, namespace)});
}

/// The Zig type name for a declaration's simple name.
pub fn typeName(
    arena: std.mem.Allocator,
    simple: []const u8,
    shape: Shape,
) Error![]const u8 {
    const base = try naming.toPascalCase(arena, simple);
    return switch (shape) {
        .read => base,
        .update => std.fmt.allocPrint(arena, "{s}Update", .{base}),
        .create => std.fmt.allocPrint(arena, "{s}Create", .{base}),
        .excerpt => |copy| {
            const key = copy.key orelse return std.fmt.allocPrint(arena, "{s}Excerpt", .{base});
            return std.fmt.allocPrint(arena, "{s}Excerpt{s}", .{
                base,
                try naming.toPascalCase(arena, key),
            });
        },
    };
}

/// The Zig type name for a qualified schema name, without its module.
pub fn localType(
    arena: std.mem.Allocator,
    qualified: []const u8,
    shape: Shape,
) Error![]const u8 {
    return typeName(arena, QualifiedName.parse(qualified).name(), shape);
}

/// The Zig type name for a qualified schema name, as written from outside
/// the module that declares it: `chassis.Chassis`.
pub fn fullType(
    arena: std.mem.Allocator,
    qualified: []const u8,
    shape: Shape,
) Error![]const u8 {
    const parsed: QualifiedName = .parse(qualified);
    return std.fmt.allocPrint(arena, "{f}.{f}", .{
        identifiers.fmt(try module(arena, parsed.namespace())),
        identifiers.fmt(try typeName(arena, parsed.name(), shape)),
    });
}

/// The struct an action's arguments become: `ChassisResetAction`.
///
/// An action is named only within the type it is bound to, so the binding
/// leads. `Reset` is declared by half the schemas in the corpus and they do
/// not mean the same thing.
pub fn actionType(
    arena: std.mem.Allocator,
    action: codemodel.Action,
) Error![]const u8 {
    const binding = if (action.binding_parameter.len != 0)
        action.binding_parameter
    else
        QualifiedName.parse(action.binding).name();
    return std.fmt.allocPrint(arena, "{s}{s}Action", .{
        try naming.toPascalCase(arena, binding),
        try naming.toPascalCase(arena, action.name),
    });
}

/// The function an action becomes: `Reset` is `reset`.
pub fn method(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return naming.toCamelCase(arena, name);
}

/// A struct field, spelled exactly as the wire spells it.
///
/// `@odata.id` and `Members@odata.count` are property names, not accidents,
/// and quoting them costs nothing while renaming them would cost a table.
pub fn field(name: []const u8) std.zig.FormatId {
    return identifiers.fmt(name);
}

/// An enum member, spelled exactly as the wire spells it, so `std.json`
/// decodes it by name with nothing to look up.
pub fn enumMember(name: []const u8) std.zig.FormatId {
    return identifiers.fmt(name);
}

/// Every name the emitter has handed out, so a clash is a diagnostic rather
/// than a package that will not compile.
///
/// Two declarations can want the same Zig name: an entity type and an enum
/// type may share a simple name in one namespace, and an action's generated
/// name can land on a declared one. Neither is in the corpus today, and
/// neither should pass silently if it arrives.
pub const Registry = struct {
    claims: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub const ClaimError = Error || error{NameCollision};

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        var keys = self.claims.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        self.claims.deinit(gpa);
        self.* = undefined;
    }

    /// Records that `source` owns `type_name` in `module_name`.
    pub fn claim(
        self: *Registry,
        gpa: std.mem.Allocator,
        module_name: []const u8,
        type_name: []const u8,
        source: []const u8,
    ) ClaimError!void {
        const key = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ module_name, type_name });
        const entry = try self.claims.getOrPut(gpa, key);
        if (entry.found_existing) {
            gpa.free(key);
            if (std.mem.eql(u8, entry.value_ptr.*, source)) return;
            return error.NameCollision;
        }
        entry.value_ptr.* = source;
    }

    /// What already owns a name, if anything does.
    pub fn owner(self: *const Registry, module_name: []const u8, type_name: []const u8) ?[]const u8 {
        var buffer: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ module_name, type_name }) catch return null;
        return self.claims.get(key);
    }
};

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "a namespace becomes a snake_case module" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("chassis", try module(gpa, .init("Chassis")));
    try testing.expectEqualStrings("service_root", try module(gpa, .init("ServiceRoot")));
    try testing.expectEqualStrings("computer_system", try module(gpa, .init("ComputerSystem")));
    try testing.expectEqualStrings("pcie_device", try module(gpa, .init("PCIeDevice")));
}

test "a version that survives hoisting stays visible in the module name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("chassis_v1_25_0", try module(gpa, .init("Chassis.v1_25_0")));
    try testing.expectEqualStrings("chassis_v1_25_0.zig", try file(gpa, .init("Chassis.v1_25_0")));
}

test "a namespace names the file its declarations are written to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("service_root.zig", try file(arena.allocator(), .init("ServiceRoot")));
}

test "each shape of a type gets its own name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("Chassis", try typeName(gpa, "Chassis", .read));
    try testing.expectEqualStrings("ChassisUpdate", try typeName(gpa, "Chassis", .update));
    try testing.expectEqualStrings("ChassisCreate", try typeName(gpa, "Chassis", .create));
    try testing.expectEqualStrings(
        "ChassisExcerpt",
        try typeName(gpa, "Chassis", .{ .excerpt = .{} }),
    );
    try testing.expectEqualStrings(
        "ChassisExcerptStatus",
        try typeName(gpa, "Chassis", .{ .excerpt = .{ .key = "Status" } }),
    );
}

test "a qualified name is written through its module" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("chassis.Chassis", try fullType(gpa, "Chassis.Chassis", .read));
    try testing.expectEqualStrings("chassis.Links", try fullType(gpa, "Chassis.Links", .read));
    try testing.expectEqualStrings(
        "thermal.Links",
        try fullType(gpa, "Thermal.Links", .read),
    );
    try testing.expectEqualStrings(
        "resource.StatusUpdate",
        try fullType(gpa, "Resource.Status", .update),
    );
    try testing.expectEqualStrings("Links", try localType(gpa, "Chassis.Links", .read));
}

test "the module keeps names apart that flattening would collide" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const left = try fullType(gpa, "Chassis.Actions", .read);
    const right = try fullType(gpa, "ComputerSystem.Actions", .read);
    try testing.expect(!std.mem.eql(u8, left, right));
}

test "an action is named for the type it is bound to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("ChassisResetAction", try actionType(gpa, .{
        .name = "Reset",
        .binding = "Chassis.Chassis",
        .namespace = "Chassis",
        .binding_parameter = "Chassis",
    }));
    try testing.expectEqualStrings("ComputerSystemResetAction", try actionType(gpa, .{
        .name = "Reset",
        .binding = "ComputerSystem.ComputerSystem",
        .namespace = "ComputerSystem",
        .binding_parameter = "ComputerSystem",
    }));
    // Without a binding parameter name, the bound type supplies one.
    try testing.expectEqualStrings("ChassisResetAction", try actionType(gpa, .{
        .name = "Reset",
        .binding = "Chassis.Chassis",
        .namespace = "Chassis",
    }));
}

test "an action's method reads as a Zig function" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqualStrings("reset", try method(gpa, "Reset"));
    try testing.expectEqualStrings("gracefulShutdown", try method(gpa, "GracefulShutdown"));
}

test "a field keeps the wire's spelling, quoted when Zig needs it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "@\"@odata.id\"",
        try std.fmt.allocPrint(arena.allocator(), "{f}", .{field("@odata.id")}),
    );
    try testing.expectEqualStrings(
        "Manufacturer",
        try std.fmt.allocPrint(arena.allocator(), "{f}", .{field("Manufacturer")}),
    );
    try testing.expectEqualStrings(
        "@\"Members@odata.count\"",
        try std.fmt.allocPrint(arena.allocator(), "{f}", .{field("Members@odata.count")}),
    );
}

test "an enum member keeps the wire's spelling, so JSON needs no table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "GracefulShutdown",
        try std.fmt.allocPrint(arena.allocator(), "{f}", .{enumMember("GracefulShutdown")}),
    );
    try testing.expectEqualStrings(
        "@\"null\"",
        try std.fmt.allocPrint(arena.allocator(), "{f}", .{enumMember("null")}),
    );
}

test "a name claimed twice by the same declaration is not a clash" {
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    try registry.claim(testing.allocator, "chassis", "Chassis", "Chassis.Chassis");
    try registry.claim(testing.allocator, "chassis", "Chassis", "Chassis.Chassis");
    try testing.expectEqualStrings("Chassis.Chassis", registry.owner("chassis", "Chassis").?);
}

test "two declarations wanting one name is a diagnostic" {
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    try registry.claim(testing.allocator, "chassis", "Chassis", "Chassis.Chassis");
    try testing.expectError(error.NameCollision, registry.claim(
        testing.allocator,
        "chassis",
        "Chassis",
        "Chassis.ChassisEnum",
    ));
}

test "the same name in two modules is not a clash" {
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    try registry.claim(testing.allocator, "chassis", "Links", "Chassis.Links");
    try registry.claim(testing.allocator, "thermal", "Links", "Thermal.Links");
    try testing.expectEqualStrings("Thermal.Links", registry.owner("thermal", "Links").?);
    try testing.expect(registry.owner("power", "Links") == null);
}
