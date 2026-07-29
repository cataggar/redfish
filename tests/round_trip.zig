//! Recorded BMC payloads, deserialized into the generated types.
//!
//! Every case here is a real response DMTF publishes in `mockups/`, not a
//! payload written to suit the emitter. That distinction is the whole point:
//! a schema compiler can be self-consistent and still produce types that no
//! service can fill. Sweeping all 3,780 recorded payloads against the 314
//! generated modules is what turned up the defects this suite now pins.

const std = @import("std");
const schema = @import("redfish_schema_std");
const core = @import("redfish_core");
const payloads = @import("payloads.zig");

const testing = std.testing;

/// The parse options a Redfish client has to use. Every recorded payload
/// carries `@Redfish.Copyright`, services are free to add properties from a
/// newer schema version than the client was built against, and DSP0266 allows
/// property annotations the emitter does not know to declare.
const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

fn TypeOf(comptime case: payloads.Case) type {
    return @field(@field(schema, case.module), case.type_name);
}

/// Parses, writes, parses again, and writes again.
///
/// Comparing the two written forms rather than the two parsed values is
/// deliberate. Zig cannot compare a struct containing slices, and comparing
/// against the *input* would fail for reasons that are not defects: the
/// service's key order, its whitespace, and the annotations we skip. What has
/// to hold is that the reader and the writer agree, so a value that survives
/// one trip survives every later one -- which is what a client does when it
/// reads a resource, edits it, and sends it back.
fn roundTrip(comptime T: type, text: []const u8) !void {
    const gpa = testing.allocator;

    const first = try std.json.parseFromSlice(T, gpa, text, options);
    defer first.deinit();
    const once = try std.json.Stringify.valueAlloc(gpa, first.value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(once);

    const second = try std.json.parseFromSlice(T, gpa, once, options);
    defer second.deinit();
    const twice = try std.json.Stringify.valueAlloc(gpa, second.value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(twice);

    try testing.expectEqualStrings(once, twice);
}

test "every recorded payload deserializes into its generated type" {
    inline for (payloads.cases) |case| {
        roundTrip(TypeOf(case), case.text) catch |err| {
            std.debug.print("\n{s}.{s} from {s}: {t}\n", .{
                case.module,
                case.type_name,
                case.source,
                err,
            });
            return err;
        };
    }
}

test "the corpus covers every generated module that a payload names" {
    // A guard against the table silently shrinking: 251 of the 253 distinct
    // `@odata.type` values in DMTF's mockups resolve to a type in this
    // package. The two that do not are Contoso's OEM service, which belongs
    // to the vendor package, and an action *response* named as though it were
    // a resource.
    try testing.expectEqual(@as(usize, 251), payloads.cases.len);
}

test "a required property the service left out is still readable" {
    // `Role` declares `RoleId` `Redfish.Required`, and DMTF's own mockups do
    // not send it. 177 of the 3,780 recorded payloads omit some property
    // their schema requires, which is why no read shape is ever mandatory.
    const parsed = try std.json.parseFromSlice(
        schema.role.Role,
        testing.allocator,
        \\{ "@odata.type": "#Role.v1_3_3.Role", "Id": "ReadOnly",
        \\  "@odata.id": "/redfish/v1/AccountService/Roles/ReadOnly" }
    ,
        options,
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("ReadOnly", parsed.value.Id.?);
    try testing.expectEqual(@as(?[]const u8, null), parsed.value.RoleId);
}

test "a null inside a collection is a value, not a parse error" {
    // `ServiceAddresses` is `Collection(Edm.String)` with no `Nullable`, and
    // OData says that describes the members. DMTF's `public-rackmount1`
    // account service sends two addresses and two empty slots.
    const case = find("account_service", "AccountService");
    const parsed = try std.json.parseFromSlice(
        schema.account_service.AccountService,
        testing.allocator,
        case.text,
        options,
    );
    defer parsed.deinit();

    const addresses = parsed.value.ActiveDirectory.?.ServiceAddresses.?;
    try testing.expectEqual(@as(usize, 4), addresses.len);
    try testing.expectEqualStrings("ad1.example.org", addresses[0].?);
    try testing.expectEqualStrings("ad2.example.org", addresses[1].?);
    try testing.expectEqual(@as(?[]const u8, null), addresses[2]);
    try testing.expectEqual(@as(?[]const u8, null), addresses[3]);
}

test "a payload that is not addressable has no @odata.id" {
    // An event arrives over SSE or a POST to a listener. It names its type
    // and has no id, because it does not live at a URI -- so `redfish_core`
    // answers `null` rather than refusing to parse the resource that the
    // EventService exists to deliver.
    const case = find("event", "Event");
    const parsed = try std.json.parseFromSlice(
        schema.event.Event,
        testing.allocator,
        case.text,
        options,
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(?core.ODataId, null), parsed.value.@"@odata.id");
    try testing.expect(parsed.value.Events.?.len > 0);
}

test "an OEM extension survives a round trip unread" {
    // Two vendors hang objects off `Oem`, and the schema names neither. The
    // open struct keeps both, so a client that reads a system and writes it
    // back does not silently drop another vendor's configuration.
    const case = find("computer_system", "ComputerSystem");
    const parsed = try std.json.parseFromSlice(
        schema.computer_system.ComputerSystem,
        testing.allocator,
        case.text,
        options,
    );
    defer parsed.deinit();

    const written = try std.json.Stringify.valueAlloc(
        testing.allocator,
        parsed.value.Oem.?,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "PacWest Production Facility") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Chipwise") != null);
}

test "a collection reports how many members it has" {
    // `Members@odata.count` annotates a property rather than being one, so no
    // CSDL declares it and nothing in the schema says it exists. DMTF's own
    // mockups carry it 882 times; before the emitter knew to write the field,
    // every one of those counts was parsed and thrown away.
    const case = find("chassis_collection", "ChassisCollection");
    const parsed = try std.json.parseFromSlice(
        schema.chassis_collection.ChassisCollection,
        testing.allocator,
        case.text,
        options,
    );
    defer parsed.deinit();

    const count = parsed.value.@"Members@odata.count".?;
    try testing.expectEqual(@as(i64, @intCast(parsed.value.Members.?.len)), count);

    // This response holds every member, so the service sent no next page.
    try testing.expectEqual(@as(?core.ODataId, null), parsed.value.@"Members@odata.nextLink");
}

test "a recorded collection's next page is not thrown away" {
    // This payload is one of the eight DMTF publishes that page a collection,
    // and all eight use the bare `@odata.nextLink` rather than the
    // `Members@odata.nextLink` DSP0266 specifies. Before the emitter wrote a
    // field for the bare spelling, this parsed cleanly and lost the link --
    // a client would have read the first two log entries of an ongoing log
    // and had no way to tell that from having read all of it.
    const case = find("log_entry_collection", "LogEntryCollection");
    const parsed = try std.json.parseFromSlice(
        schema.log_entry_collection.LogEntryCollection,
        testing.allocator,
        case.text,
        options,
    );
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "/redfish/v1/Systems/437XR1138R2/LogServices/Log1/Entries?$skiptoken=2",
        parsed.value.@"@odata.nextLink".?.value,
    );

    // The spelled-out form is absent, which is exactly the point.
    try testing.expect(parsed.value.@"Members@odata.nextLink" == null);
}

fn find(comptime module: []const u8, comptime type_name: []const u8) payloads.Case {
    return comptime for (payloads.cases) |case| {
        if (std.mem.eql(u8, case.module, module) and
            std.mem.eql(u8, case.type_name, type_name)) break case;
    } else @compileError("no recorded payload for " ++ module ++ "." ++ type_name);
}
