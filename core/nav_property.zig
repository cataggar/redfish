//! Navigation properties — the OData link that may or may not be expanded.
//!
//! A Redfish service renders a navigation property either as a bare reference:
//!
//! ```json
//! { "@odata.id": "/redfish/v1/Chassis/1/Thermal" }
//! ```
//!
//! or, when the client asked for `$expand`, as the full resource. Generated
//! code wraps every navigation property in `NavProperty(T)` so callers handle
//! both shapes uniformly.
//!
//! `NavProperty(T)` itself satisfies the entity contract in `entity.zig`: `id`
//! always answers, and `etag` answers only for the expanded form, since a
//! reference carries no entity tag.
//!
//! Telling the two shapes apart needs the whole object, so `jsonParse`
//! materializes a `std.json.Value` and then parses the chosen arm out of that
//! tree, exactly as `nv-redfish` does. The tree is allocated from the response
//! arena and freed with it, and a test below pins that an expanded resource
//! parses the same whether it arrives nested or is fetched directly.
//!
//! The test is "does this object carry anything `T` would recognize", not "is
//! `@odata.id` the only member": services decorate their links with members
//! no schema declares, and counting members reads those as an expansion
//! carrying no data. Annotations -- the members whose names begin with `@` --
//! are not what `T` recognizes either: they describe the payload rather than
//! the entity, and a link labelled with the type it points at is still a link.
//!
//! Reference: DMTF DSP0266 and OASIS OData 4.01 CSDL, navigation properties.

const std = @import("std");
const entity = @import("entity.zig");
const odata = @import("odata.zig");

const ODataId = odata.ODataId;
const ODataETag = odata.ODataETag;

/// The unexpanded form: an object whose only recognizable property is
/// `@odata.id`.
pub const Reference = struct {
    @"@odata.id": ODataId,

    pub fn init(odata_id: ODataId) Reference {
        return .{ .@"@odata.id" = odata_id };
    }

    pub fn odataId(self: Reference) ODataId {
        return self.@"@odata.id";
    }

    pub fn format(self: Reference, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.@"@odata.id".format(w);
    }
};

/// The reference form used for a navigation property whose target entity type
/// was pruned from the generated surface. It is a distinct type from
/// `Reference` so that "we chose not to generate this" stays visible in the
/// API rather than looking like an unexpanded link.
pub const ReferenceLeaf = struct {
    @"@odata.id": ODataId,

    pub fn init(odata_id: ODataId) ReferenceLeaf {
        return .{ .@"@odata.id" = odata_id };
    }

    pub fn odataId(self: ReferenceLeaf) ODataId {
        return self.@"@odata.id";
    }

    pub fn toReference(self: ReferenceLeaf) Reference {
        return .init(self.@"@odata.id");
    }

    pub fn format(self: ReferenceLeaf, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.@"@odata.id".format(w);
    }
};

/// A navigation property to `T`.
///
/// The expanded arm holds a pointer rather than a value: Redfish resource
/// graphs are cyclic (a chassis links to systems, which link back to chassis),
/// so an inline `T` would be an infinitely sized type. The pointee lives in
/// the arena of the `Owned(T)` that produced it.
pub fn NavProperty(comptime T: type) type {
    // The entity check is deliberately deferred into the methods below rather
    // than run here: a resource may hold a `NavProperty(Self)`, and querying
    // `@typeInfo(Self)` while `Self` is still being resolved is an error.
    return union(enum) {
        reference: Reference,
        expanded: *const T,

        const Self = @This();

        /// The entity type this property points at, for generated code that
        /// needs to name it.
        pub const Target = T;

        pub fn initReference(odata_id: ODataId) Self {
            return .{ .reference = .init(odata_id) };
        }

        pub fn initExpanded(resource: *const T) Self {
            comptime entity.assertEntity(T);
            return .{ .expanded = resource };
        }

        /// The link target, or null. A reference always has one; an expanded
        /// resource carries whatever the service sent.
        pub fn odataId(self: Self) ?ODataId {
            comptime entity.assertEntity(T);
            return switch (self) {
                .reference => |r| r.@"@odata.id",
                .expanded => |v| entity.id(v),
            };
        }

        /// The entity tag, or null. A reference has none, and an expanded
        /// resource may still omit one.
        pub fn odataEtag(self: Self) ?ODataETag {
            comptime entity.assertEntity(T);
            return switch (self) {
                .reference => null,
                .expanded => |v| entity.etag(v),
            };
        }

        /// The resource, if this property arrived expanded. A null result is
        /// the signal to fetch `odataId()` from the BMC.
        pub fn value(self: Self) ?*const T {
            return switch (self) {
                .reference => null,
                .expanded => |v| v,
            };
        }

        pub fn isExpanded(self: Self) bool {
            return self == .expanded;
        }

        /// Collapse to the reference form, discarding any expanded payload.
        /// Useful when echoing a link back in a PATCH body.
        ///
        /// Null when an expanded payload carried no `@odata.id`: there is then
        /// no link to echo. A service that expanded a resource without saying
        /// where it lives is the only way to get here.
        pub fn toReference(self: Self) ?Self {
            return switch (self) {
                .reference => self,
                .expanded => .initReference(self.odataId() orelse return null),
            };
        }

        /// Reinterpret the link as pointing at a related entity type `D`.
        ///
        /// Redfish subtypes share a URI, so a link typed as the base can be
        /// re-typed to a derived resource. The result is always a reference:
        /// an expanded `T` is not a `D`, so the caller has to re-fetch -- which
        /// needs a URI, so this is null when the payload gave none.
        pub fn downcast(self: Self, comptime D: type) ?NavProperty(D) {
            return NavProperty(D).initReference(self.odataId() orelse return null);
        }

        /// Serializes back to whichever shape it came from. A reference emits
        /// the bare `@odata.id` object; an expanded value emits the resource.
        pub fn jsonStringify(self: Self, jw: anytype) !void {
            return switch (self) {
                .reference => |r| jw.write(r),
                .expanded => |v| jw.write(v.*),
            };
        }

        /// The reference and expanded forms are both JSON objects, so the
        /// discriminator is structural: exactly one property, named
        /// `@odata.id`, means a reference.
        ///
        /// Deciding that requires seeing the whole object, so the token stream
        /// is materialized into a `std.json.Value` first, exactly as
        /// `nv-redfish` does. The tree is allocated from the response arena
        /// and freed with it.
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const tree = try std.json.innerParse(std.json.Value, allocator, source, options);
            return jsonParseFromValue(allocator, tree, options);
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Self {
            const object = switch (source) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };

            if (isReferenceShape(object)) {
                return .{ .reference = try std.json.innerParseFromValue(
                    Reference,
                    allocator,
                    source,
                    options,
                ) };
            }

            const expanded = try allocator.create(T);
            expanded.* = try std.json.innerParseFromValue(T, allocator, source, options);
            return .{ .expanded = expanded };
        }

        /// Whether an object is a link rather than the resource it links to.
        ///
        /// A link is `@odata.id` and no property of `T`. The second half is
        /// what makes this safe against a service that decorates its links:
        /// AMI's Viking firmware writes
        /// `{"@odata.id": "...", "InvalidField": "invalid"}`, and counting
        /// members would read that as an expanded resource -- one with no
        /// properties, which `follow` would then hand back without fetching.
        /// A reference is the conservative reading, because the worst it
        /// costs is the request the caller was going to make anyway.
        ///
        /// A member whose name begins with `@` is an annotation and never
        /// counts. It describes the payload rather than the entity, no CSDL
        /// declares one, and the emitter writes `@odata.type` and
        /// `@odata.etag` onto every resource read shape -- so without this a
        /// link labelled with the type it points at would be an expansion of
        /// nothing, for every resource in Redfish.
        fn isReferenceShape(object: std.json.ObjectMap) bool {
            if (!object.contains(entity.id_field)) return false;

            var members = object.iterator();
            while (members.next()) |member| {
                const name = member.key_ptr.*;
                if (name.len > 0 and name[0] == '@') continue;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return false;
                }
            }
            return true;
        }

        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const target = self.odataId() orelse return w.writeAll("<no @odata.id>");
            return target.format(w);
        }
    };
}

const testing = std.testing;
const owned = @import("owned.zig");

const Thermal = struct {
    @"@odata.id": ODataId,
    @"@odata.etag": ?ODataETag = null,
    Name: []const u8,
};

const StrictThermal = struct {
    @"@odata.id": ODataId,
    Name: u64,
};

const DefaultedThermal = struct {
    @"@odata.id": ODataId = .init("/default/id"),
    Name: []const u8,
};

/// A resource that links to itself, which is only expressible because the
/// expanded arm is a pointer.
const Chassis = struct {
    @"@odata.id": ODataId,
    Contains: ?NavProperty(Chassis) = null,
};

fn parse(comptime T: type, json: []const u8) !owned.Owned(T) {
    return owned.parseJson(T, testing.allocator, json, null);
}

test "an object with only @odata.id is a reference" {
    const parsed = try parse(
        NavProperty(Thermal),
        "{ \"@odata.id\": \"/redfish/v1/Chassis/1/Thermal\" }",
    );
    defer parsed.deinit();

    try testing.expect(!parsed.value.isExpanded());
    try testing.expectEqual(@as(?*const Thermal, null), parsed.value.value());
    try testing.expect(parsed.value.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));
    try testing.expectEqual(@as(?ODataETag, null), parsed.value.odataEtag());
}

test "an object with any other property the target declares is expanded" {
    const parsed = try parse(NavProperty(Thermal),
        \\{
        \\  "@odata.id": "/redfish/v1/Chassis/1/Thermal",
        \\  "@odata.etag": "W/\"abc\"",
        \\  "Name": "Thermal"
        \\}
    );
    defer parsed.deinit();

    try testing.expect(parsed.value.isExpanded());
    try testing.expect(parsed.value.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));
    try testing.expect(parsed.value.odataEtag().?.eql(.init("W/\"abc\"")));
    try testing.expectEqualStrings("Thermal", parsed.value.value().?.Name);
}

test "a decorated link is still a link" {
    // AMI's Viking firmware writes an extra member into a reference. Reading
    // that as an expanded resource is worse than wrong: `Thermal` requires
    // `Name`, so the whole payload used to fail, and for a target whose
    // properties all have defaults it would instead have succeeded and
    // handed back an empty resource that was never fetched.
    const parsed = try parse(NavProperty(Thermal),
        \\{ "@odata.id": "/redfish/v1/Chassis/1/Thermal", "InvalidField": "invalid" }
    );
    defer parsed.deinit();

    try testing.expect(!parsed.value.isExpanded());
    try testing.expect(parsed.value.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));
}

test "an annotation is not a property, so an annotated link is still a link" {
    // `@odata.type` is on every generated resource read shape and `@odata.etag`
    // is on most, so a target type declaring them is the normal case rather
    // than a contrived one. A service that labels a link with the type it
    // points at has still sent a link, and reading it as an expansion hands
    // the caller a resource in which every property is absent, with no request
    // made and nothing to say the resource was never read.
    const parsed = try parse(NavProperty(Thermal),
        \\{
        \\  "@odata.id": "/redfish/v1/Chassis/1/Thermal",
        \\  "@odata.type": "#Thermal.v1_7_1.Thermal",
        \\  "@odata.etag": "W/\"abc\""
        \\}
    );
    defer parsed.deinit();

    try testing.expect(!parsed.value.isExpanded());
    try testing.expect(parsed.value.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));

    // The reference form carries no tag, even though one was sent: an
    // unexpanded link is not a version of the resource.
    try testing.expectEqual(@as(?ODataETag, null), parsed.value.odataEtag());
}

test "an object without @odata.id takes the expanded path" {
    const parsed = try parse(NavProperty(DefaultedThermal), "{ \"Name\": \"NoIdObject\" }");
    defer parsed.deinit();

    try testing.expect(parsed.value.isExpanded());
    try testing.expect(parsed.value.odataId().?.eql(.init("/default/id")));
    try testing.expectEqualStrings("NoIdObject", parsed.value.value().?.Name);
}

test "a parse failure in the expanded form surfaces the target's error" {
    try testing.expectError(error.InvalidCharacter, parse(NavProperty(StrictThermal),
        \\{ "@odata.id": "/redfish/v1/Chassis/1", "Name": "not-a-number" }
    ));
}

test "the value tree detour does not change how a resource parses" {
    // The expanded arm goes through `std.json.Value`; a direct fetch does not.
    // Both must agree, including on `std.json`'s coercion of a quoted number,
    // which real BMCs do emit.
    const nested = try parse(NavProperty(StrictThermal),
        \\{ "@odata.id": "/redfish/v1/Chassis/1", "Name": "42" }
    );
    defer nested.deinit();

    const direct = try parse(StrictThermal,
        \\{ "@odata.id": "/redfish/v1/Chassis/1", "Name": "42" }
    );
    defer direct.deinit();

    try testing.expectEqual(@as(u64, 42), nested.value.value().?.Name);
    try testing.expectEqual(direct.value.Name, nested.value.value().?.Name);

    // And they agree on rejection too.
    try testing.expectError(error.InvalidCharacter, parse(StrictThermal,
        \\{ "@odata.id": "/redfish/v1/Chassis/1", "Name": "not-a-number" }
    ));
}

test "rejects a non-object payload" {
    inline for (.{ "\"/redfish/v1\"", "[]", "12", "null" }) |bad| {
        try testing.expectError(error.UnexpectedToken, parse(NavProperty(Thermal), bad));
    }
}

test "an expanded value survives the input buffer" {
    const body = try testing.allocator.dupe(u8,
        \\{ "@odata.id": "/redfish/v1/Chassis/1/Thermal", "Name": "Thermal" }
    );
    const parsed = try owned.parseJson(NavProperty(Thermal), testing.allocator, body, null);
    defer parsed.deinit();

    @memset(body, 'x');
    testing.allocator.free(body);

    try testing.expectEqualStrings("Thermal", parsed.value.value().?.Name);
    try testing.expect(parsed.value.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));
}

test "nests, because the expanded arm is a pointer" {
    const parsed = try parse(NavProperty(Chassis),
        \\{
        \\  "@odata.id": "/redfish/v1/Chassis/1",
        \\  "Contains": {
        \\    "@odata.id": "/redfish/v1/Chassis/1/Sub",
        \\    "Contains": { "@odata.id": "/redfish/v1/Chassis/1/Sub/Leaf" }
        \\  }
        \\}
    );
    defer parsed.deinit();

    const outer = parsed.value.value().?;
    const middle = outer.Contains.?.value().?;
    try testing.expect(middle.@"@odata.id".eql(.init("/redfish/v1/Chassis/1/Sub")));

    const leaf = outer.Contains.?.value().?.Contains.?;
    try testing.expect(!leaf.isExpanded());
    try testing.expect(leaf.odataId().?.eql(.init("/redfish/v1/Chassis/1/Sub/Leaf")));
}

test "toReference discards the expanded payload but keeps the link" {
    const parsed = try parse(NavProperty(Thermal),
        \\{ "@odata.id": "/redfish/v1/Chassis/1/Thermal", "Name": "Thermal" }
    );
    defer parsed.deinit();

    const collapsed = parsed.value.toReference().?;
    try testing.expect(!collapsed.isExpanded());
    try testing.expect(collapsed.odataId().?.eql(.init("/redfish/v1/Chassis/1/Thermal")));

    // Collapsing a reference is a no-op.
    try testing.expect(!collapsed.toReference().?.isExpanded());
}

test "downcast keeps the link and drops to the reference form" {
    const parsed = try parse(NavProperty(Thermal),
        \\{ "@odata.id": "/redfish/v1/Chassis/1", "Name": "Thermal" }
    );
    defer parsed.deinit();

    const derived = parsed.value.downcast(Chassis).?;
    try testing.expectEqual(NavProperty(Chassis), @TypeOf(derived));
    try testing.expect(!derived.isExpanded());
    try testing.expect(derived.odataId().?.eql(.init("/redfish/v1/Chassis/1")));
}

test "serializes back to the shape it came from" {
    var buf: [256]u8 = undefined;

    const reference = NavProperty(Thermal).initReference(.init("/redfish/v1/Chassis/1/Thermal"));
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(reference, .{}, &w);
    try testing.expectEqualStrings(
        "{\"@odata.id\":\"/redfish/v1/Chassis/1/Thermal\"}",
        w.buffered(),
    );

    const thermal: Thermal = .{
        .@"@odata.id" = .init("/redfish/v1/Chassis/1/Thermal"),
        .Name = "Thermal",
    };
    const expanded = NavProperty(Thermal).initExpanded(&thermal);
    w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(expanded, .{}, &w);
    try testing.expectEqualStrings(
        "{\"@odata.id\":\"/redfish/v1/Chassis/1/Thermal\"," ++
            "\"@odata.etag\":null,\"Name\":\"Thermal\"}",
        w.buffered(),
    );
}

test "satisfies the entity contract" {
    try testing.expect(entity.isEntity(NavProperty(Thermal)));

    const reference = NavProperty(Thermal).initReference(.init("/redfish/v1/Chassis/1"));
    try testing.expect(entity.id(reference).?.eql(.init("/redfish/v1/Chassis/1")));
    try testing.expectEqual(@as(?ODataETag, null), entity.etag(reference));
}

test "ReferenceLeaf carries a link to a type that was not generated" {
    const parsed = try parse(ReferenceLeaf, "{ \"@odata.id\": \"/redfish/v1/Oem/Vendor\" }");
    defer parsed.deinit();

    try testing.expect(parsed.value.odataId().eql(.init("/redfish/v1/Oem/Vendor")));
    try testing.expect(entity.isEntity(ReferenceLeaf));
}

test "Reference is a plain struct, so strict options reject extra properties" {
    const body = "{ \"@odata.id\": \"/redfish/v1\", \"Name\": \"x\" }";
    try testing.expectError(
        error.UnknownField,
        owned.parseJson(Reference, testing.allocator, body, .{}),
    );

    // Such an object is never reached through `NavProperty`: two properties
    // means the expanded shape, not a reference.
    const tolerant = try owned.parseJson(Reference, testing.allocator, body, null);
    defer tolerant.deinit();
    try testing.expect(tolerant.value.odataId().eql(.init("/redfish/v1")));
}

test "formats as the link target" {
    var buf: [64]u8 = undefined;
    const reference = NavProperty(Thermal).initReference(.init("/redfish/v1/Chassis/1"));
    try testing.expectEqualStrings(
        "/redfish/v1/Chassis/1",
        try std.fmt.bufPrint(&buf, "{f}", .{reference}),
    );
}
