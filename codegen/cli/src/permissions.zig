//! Whether a complex type can be written.
//!
//! Redfish annotates properties with `OData.Permissions`, not types. A type
//! that exists only to group read-only properties therefore looks writable,
//! and would get an update shape that nothing can ever fill. Reading the
//! answer back off the members is a heuristic, but it is the same one the
//! service applies when it rejects the PATCH.
//!
//! This lives outside the compiler because the answer is a function of the
//! *whole* model, and the optimizer rewrites the model: merging a base type
//! into its only child changes the member list, and so can change the
//! answer. Computing it where it is used means it cannot go stale. The code
//! model records what the schema said; this records what that implies.

const std = @import("std");
const codemodel = @import("codemodel.zig");
const schema_index = @import("schema_index.zig");

const QualifiedName = schema_index.QualifiedName;

/// Answers "can this complex type be written?" for every type in a model.
///
/// Memoized, so resolving every type in a model costs one pass. A type that
/// reaches itself through its members resolves to writable: an update shape
/// that is never used is noise, but a missing one breaks a PATCH.
pub const Resolver = struct {
    types: std.StringHashMapUnmanaged(*const codemodel.ComplexType) = .empty,
    memo: std.StringHashMapUnmanaged(Answer) = .empty,

    const Answer = union(enum) {
        /// Being computed: a member reached the type it belongs to.
        visiting,
        settled: ?codemodel.Permissions,
    };

    pub fn init(gpa: std.mem.Allocator, model: *const codemodel.Model) !Resolver {
        var self: Resolver = .{};
        errdefer self.deinit(gpa);
        try self.types.ensureTotalCapacity(gpa, @intCast(model.complex_types.len));
        for (model.complex_types) |*complex_type| {
            self.types.putAssumeCapacity(complex_type.name, complex_type);
        }
        return self;
    }

    pub fn deinit(self: *Resolver, gpa: std.mem.Allocator) void {
        self.types.deinit(gpa);
        self.memo.deinit(gpa);
        self.* = undefined;
    }

    /// The effective permissions of a complex type, by qualified name.
    ///
    /// Null means the schema neither said nor implied anything, which the
    /// emitter reads as writable. A name that is not a complex type in this
    /// model is null too — a primitive or an enum carries no permission of
    /// its own.
    pub fn of(
        self: *Resolver,
        gpa: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!?codemodel.Permissions {
        if (self.memo.get(name)) |answer| return switch (answer) {
            .visiting => null,
            .settled => |value| value,
        };
        const complex_type = self.types.get(name) orelse {
            try self.memo.put(gpa, name, .{ .settled = null });
            return null;
        };
        try self.memo.put(gpa, name, .visiting);
        const answer = try self.compute(gpa, complex_type.*);
        try self.memo.put(gpa, name, .{ .settled = answer });
        return answer;
    }

    /// Whether a complex type is read-only, and so needs no update shape.
    pub fn readOnly(
        self: *Resolver,
        gpa: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!bool {
        return try self.of(gpa, name) == .read;
    }

    /// Whether a property can be written, which takes both answers: the
    /// property's own annotation and its type's.
    ///
    /// Both have to agree. A property annotated read is not writable
    /// whatever its type says, and a property of a read-only type is not
    /// writable however the property is annotated -- a `ReadWrite` field
    /// holding a structure the service will not accept is a PATCH that
    /// always fails.
    pub fn propertyWritable(
        self: *Resolver,
        gpa: std.mem.Allocator,
        property: codemodel.Property,
    ) std.mem.Allocator.Error!bool {
        if (property.permissions == .read) return false;
        return !try self.readOnly(gpa, property.type.name);
    }

    fn compute(
        self: *Resolver,
        gpa: std.mem.Allocator,
        complex_type: codemodel.ComplexType,
    ) std.mem.Allocator.Error!?codemodel.Permissions {
        // A member the service demands on create has to be settable, whatever
        // the rest of the type looks like.
        for (complex_type.properties) |property| {
            if (property.required_on_create) return null;
        }
        for (complex_type.navigation_properties) |property| {
            if (property.expandable and property.required_on_create) return null;
        }

        if (complex_type.permissions) |declared| return declared;

        // A type that takes properties the schema does not name cannot be
        // called read-only, since the unnamed ones might not be. `OemActions`
        // is the exception the corpus forces: it is open by definition and
        // every member of it is a link to an action.
        if (complex_type.additional_properties and
            !std.mem.eql(u8, QualifiedName.parse(complex_type.name).name(), "OemActions")) return null;

        if (complex_type.properties.len == 0 and
            complex_type.navigation_properties.len == 0) return .read;

        // A link is a way in: whatever it points at can be written even if
        // everything here is read-only.
        if (complex_type.navigation_properties.len != 0) return null;

        for (complex_type.properties) |property| {
            if (!try self.propertyWritable(gpa, property)) continue;
            return null;
        }
        return .read;
    }
};

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const package: codemodel.Package = .{ .name = "test" };

fn resolve(model: *const codemodel.Model, name: []const u8) !?codemodel.Permissions {
    var resolver: Resolver = try .init(testing.allocator, model);
    defer resolver.deinit(testing.allocator);
    return resolver.of(testing.allocator, name);
}

test "a type with no members at all is read-only" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{ .name = "Root.Empty" }},
    };
    try testing.expectEqual(codemodel.Permissions.read, try resolve(&model, "Root.Empty"));
}

test "a declared permission wins over the members" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Declared",
            .permissions = .write,
            .properties = &.{.{ .name = "Name", .type = .{ .name = "Edm.String" } }},
        }},
    };
    try testing.expectEqual(codemodel.Permissions.write, try resolve(&model, "Root.Declared"));
}

test "one writable member makes the whole type writable" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Mixed",
            .properties = &.{
                .{ .name = "State", .type = .{ .name = "Edm.String" }, .permissions = .read },
                .{ .name = "Name", .type = .{ .name = "Edm.String" } },
            },
        }},
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Mixed"));
}

test "read-only membership propagates through complex members" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Root.Outer",
                .properties = &.{.{ .name = "Inner", .type = .{ .name = "Root.Inner" } }},
            },
            .{
                .name = "Root.Inner",
                .properties = &.{
                    .{ .name = "State", .type = .{ .name = "Edm.String" }, .permissions = .read },
                },
            },
        },
    };
    try testing.expectEqual(codemodel.Permissions.read, try resolve(&model, "Root.Outer"));
    try testing.expectEqual(codemodel.Permissions.read, try resolve(&model, "Root.Inner"));
}

test "a writable member deep in the tree reaches the top" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Root.Outer",
                .properties = &.{.{ .name = "Inner", .type = .{ .name = "Root.Inner" } }},
            },
            .{
                .name = "Root.Inner",
                .properties = &.{.{ .name = "Name", .type = .{ .name = "Edm.String" } }},
            },
        },
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Outer"));
}

test "an open type is writable unless it is OemActions" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{
            .{ .name = "Root.Oem", .additional_properties = true },
            .{ .name = "Root.OemActions", .additional_properties = true },
        },
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Oem"));
    try testing.expectEqual(codemodel.Permissions.read, try resolve(&model, "Root.OemActions"));
}

test "a member required on create keeps the type writable" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Create",
            .properties = &.{.{
                .name = "Name",
                .type = .{ .name = "Edm.String" },
                .permissions = .read,
                .required_on_create = true,
            }},
        }},
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Create"));
}

test "a link out of a read-only type is a way to write it" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Links",
            .navigation_properties = &.{.{ .name = "Chassis", .type = .{ .name = "Root.Chassis" } }},
        }},
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Links"));
}

test "a type that reaches itself is writable rather than wrongly read-only" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Loop",
            .properties = &.{.{ .name = "Next", .type = .{ .name = "Root.Loop" } }},
        }},
    };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Root.Loop"));
}

test "a name that is not a complex type has no permissions of its own" {
    const model: codemodel.Model = .{ .package = package };
    try testing.expectEqual(@as(?codemodel.Permissions, null), try resolve(&model, "Edm.String"));
}

test "the answer is memoized, so a shared member is computed once" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{
            .{
                .name = "Root.Left",
                .properties = &.{.{ .name = "Inner", .type = .{ .name = "Root.Inner" } }},
            },
            .{
                .name = "Root.Right",
                .properties = &.{.{ .name = "Inner", .type = .{ .name = "Root.Inner" } }},
            },
            .{
                .name = "Root.Inner",
                .properties = &.{
                    .{ .name = "State", .type = .{ .name = "Edm.String" }, .permissions = .read },
                },
            },
        },
    };

    var resolver: Resolver = try .init(testing.allocator, &model);
    defer resolver.deinit(testing.allocator);

    try testing.expectEqual(codemodel.Permissions.read, try resolver.of(testing.allocator, "Root.Left"));
    try testing.expectEqual(codemodel.Permissions.read, try resolver.of(testing.allocator, "Root.Right"));
    // Left, Right and the Inner they share: three entries, not four.
    try testing.expectEqual(@as(usize, 3), resolver.memo.count());
}

test "a property says whether it can be written" {
    const model: codemodel.Model = .{
        .package = package,
        .complex_types = &.{.{
            .name = "Root.Inner",
            .properties = &.{
                .{ .name = "State", .type = .{ .name = "Edm.String" }, .permissions = .read },
            },
        }},
    };

    var resolver: Resolver = try .init(testing.allocator, &model);
    defer resolver.deinit(testing.allocator);

    const gpa = testing.allocator;
    try testing.expect(!try resolver.propertyWritable(gpa, .{
        .name = "Status",
        .type = .{ .name = "Root.Inner" },
    }));
    try testing.expect(try resolver.propertyWritable(gpa, .{
        .name = "Name",
        .type = .{ .name = "Edm.String" },
    }));
    // Both answers have to agree: a read-write field holding a structure the
    // service will not accept is a PATCH that always fails.
    try testing.expect(!try resolver.propertyWritable(gpa, .{
        .name = "Status",
        .type = .{ .name = "Root.Inner" },
        .permissions = .read_write,
    }));
    try testing.expect(!try resolver.propertyWritable(gpa, .{
        .name = "Name",
        .type = .{ .name = "Edm.String" },
        .permissions = .read,
    }));
}
