//! Services that do not behave the way they say they do.
//!
//! A BMC is a shipped product with a firmware release cycle, and some of them
//! answer a request in a way the specification does not allow. The dangerous
//! ones are not the failures — a client sees those — but the successes: a
//! service that accepts `$expand` and returns a response without the expanded
//! resources has produced something that parses, and a client that trusted it
//! reads absent where a value should be.
//!
//! Nothing in a response says "this service is one of those". The only
//! evidence available is the identity in the service root, so a quirk is a
//! rule from a fingerprint to a set of known deviations.
//!
//! ## What is deliberately not here
//!
//! There is no built-in table of platforms. `nv-redfish` ships one, and it is
//! the most valuable part of that project — but it is operational knowledge
//! about specific third-party firmware, earned by running against it, and
//! copying it into a repository that has never talked to any of that hardware
//! would produce entries nothing here can verify or maintain. A wrong quirk is
//! worse than no quirk: it silently degrades a service that was working.
//!
//! So this is the mechanism, and the table is yours. `Rule` is a plain value;
//! a program declares the deviations it has actually observed and passes them
//! to `Service.applyQuirks`.
//!
//! ## Where the line is
//!
//! `Deviation` names departures **in the protocol**, because those are the
//! ones the stack can act on by itself: it stops sending the query option, or
//! stops sending the conditional header. Departures in the *data* — a field
//! holding a date in the wrong format, a link pointing at the wrong resource —
//! are not here, because there is no general action to take. Those belong to
//! the code that reads the field, which is the only code that knows what the
//! value was supposed to mean.

const std = @import("std");

/// A departure from the protocol that the client can respond to on its own.
pub const Deviation = enum {
    /// `$expand` is advertised, accepted, and does not expand. The response
    /// parses; the resources are simply not in it.
    expand_unreliable,
    /// `$filter` is advertised and does not filter, so the response holds
    /// members the caller asked to exclude.
    filter_unreliable,
    /// `$top` / `$skip` are advertised and do not page as asked, which can
    /// mean a walk repeats or loses members.
    top_skip_unreliable,
    /// ETags are returned but do not change when the resource does, making a
    /// conditional request answer from a stale copy. Not sending `If-Match`
    /// costs a lost-update check and is the lesser harm.
    etag_unreliable,
};

pub const Deviations = std.EnumSet(Deviation);

/// Which services a rule applies to.
///
/// Every criterion is optional and all of the given ones must hold. A `Match`
/// with nothing set matches every service, which is occasionally what a test
/// wants and never what a rule should say.
pub const Match = struct {
    /// `ServiceRoot.Vendor`, exactly.
    vendor: ?[]const u8 = null,
    /// A substring of `ServiceRoot.Product`. Substring rather than equality
    /// because product strings carry model and revision detail that varies
    /// across a range sharing the same firmware.
    product_contains: ?[]const u8 = null,
    /// `ServiceRoot.RedfishVersion`, exactly. The protocol version, not the
    /// firmware's.
    redfish_version: ?[]const u8 = null,
    /// An OEM property under `Oem.<vendor>`, which is often the only place a
    /// firmware build is identified at all.
    oem: ?Oem = null,

    pub const Oem = struct {
        /// The key under `Oem`, such as `"Ami"`.
        vendor: []const u8,
        /// The property under it, such as `"RtpVersion"`.
        property: []const u8,
        /// The value to require, or null to require only that it is present.
        equals: ?[]const u8 = null,
    };

    /// Whether this describes `root`.
    ///
    /// `root` is anything shaped like a generated `ServiceRoot`: fields are
    /// read by name, so this binds to no schema version and no generated
    /// package. It does require all four identifying fields to exist, which
    /// every version has -- `Vendor`, `Product` and `RedfishVersion` from
    /// `ServiceRoot` itself and `Oem` from the `Resource` it derives from.
    /// Their *values* are all optional, and a criterion on a property the
    /// service did not send does not hold: matching on silence would apply a
    /// rule to every service that stayed quiet.
    pub fn matches(self: Match, root: anytype) bool {
        if (self.vendor) |want| {
            const got = root.Vendor orelse return false;
            if (!std.mem.eql(u8, want, got)) return false;
        }

        if (self.product_contains) |want| {
            const got = root.Product orelse return false;
            if (std.mem.indexOf(u8, got, want) == null) return false;
        }

        if (self.redfish_version) |want| {
            const got = root.RedfishVersion orelse return false;
            if (!std.mem.eql(u8, want, got)) return false;
        }

        if (self.oem) |want| {
            const oem = root.Oem orelse return false;
            const vendor = oem.additional_properties.map.get(want.vendor) orelse return false;
            if (vendor != .object) return false;
            const property = vendor.object.get(want.property) orelse return false;
            if (want.equals) |value| {
                if (property != .string) return false;
                if (!std.mem.eql(u8, value, property.string)) return false;
            }
        }

        return true;
    }
};

/// A fingerprint and what is known to be wrong with the services it names.
pub const Rule = struct {
    match: Match,
    deviations: []const Deviation,
};

/// The deviations that apply to one service.
pub const Quirks = struct {
    deviations: Deviations = .initEmpty(),

    /// Collects the deviations of every rule matching `root`.
    ///
    /// Rules accumulate rather than the first winning, so a general rule about
    /// a vendor and a specific one about a model both take effect and neither
    /// has to restate the other.
    pub fn identify(root: anytype, rules: []const Rule) Quirks {
        var quirks: Quirks = .{};
        for (rules) |rule| {
            if (!rule.match.matches(root)) continue;
            for (rule.deviations) |deviation| quirks.deviations.insert(deviation);
        }
        return quirks;
    }

    pub fn has(self: Quirks, deviation: Deviation) bool {
        return self.deviations.contains(deviation);
    }

    pub fn any(self: Quirks) bool {
        return self.deviations.count() != 0;
    }
};

const testing = std.testing;

const AdditionalProperties = @import("redfish_core").AdditionalProperties;

/// Shaped as the emitter writes `ServiceRoot`.
const Root = struct {
    Vendor: ?[]const u8 = null,
    Product: ?[]const u8 = null,
    RedfishVersion: ?[]const u8 = null,
    Oem: ?struct { additional_properties: AdditionalProperties = .{} } = null,
};

test "an unset criterion is not a criterion" {
    const anything: Match = .{};
    try testing.expect(anything.matches(Root{}));
    try testing.expect(anything.matches(Root{ .Vendor = "Contoso" }));
}

test "every stated criterion has to hold" {
    const rule: Match = .{ .vendor = "Contoso", .redfish_version = "1.18.0" };

    try testing.expect(rule.matches(Root{ .Vendor = "Contoso", .RedfishVersion = "1.18.0" }));
    try testing.expect(!rule.matches(Root{ .Vendor = "Contoso", .RedfishVersion = "1.6.0" }));
    try testing.expect(!rule.matches(Root{ .Vendor = "Other", .RedfishVersion = "1.18.0" }));

    // A criterion on a property the service did not send cannot hold. Vendor
    // is absent from most service roots, so this is the common case, and
    // matching on silence would apply a rule to everything.
    try testing.expect(!rule.matches(Root{ .RedfishVersion = "1.18.0" }));
}

test "a product is matched by substring, because model detail varies" {
    const rule: Match = .{ .product_contains = "ProLiant" };

    try testing.expect(rule.matches(Root{ .Product = "ProLiant DL380 Gen10" }));
    try testing.expect(rule.matches(Root{ .Product = "ProLiant DL360 Gen11" }));
    try testing.expect(!rule.matches(Root{ .Product = "PowerEdge R750" }));
}

test "an oem property distinguishes firmware a vendor string cannot" {
    // Built the way it arrives: parsed from what the service sent.
    const sent = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"Ami\":{\"RtpVersion\":\"1.2.3\"}}",
        .{},
    );
    defer sent.deinit();

    var oem: AdditionalProperties = .{};
    defer oem.map.deinit(testing.allocator);
    var it = sent.value.object.iterator();
    while (it.next()) |entry| {
        try oem.map.put(testing.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    const root: Root = .{ .Vendor = "AMI", .Oem = .{ .additional_properties = oem } };

    // Present with the right value.
    try testing.expect((Match{ .oem = .{ .vendor = "Ami", .property = "RtpVersion", .equals = "1.2.3" } }).matches(root));
    // Present, value unimportant.
    try testing.expect((Match{ .oem = .{ .vendor = "Ami", .property = "RtpVersion" } }).matches(root));
    // Wrong value.
    try testing.expect(!(Match{ .oem = .{ .vendor = "Ami", .property = "RtpVersion", .equals = "9.9.9" } }).matches(root));
    // Absent property, and absent vendor.
    try testing.expect(!(Match{ .oem = .{ .vendor = "Ami", .property = "Missing" } }).matches(root));
    try testing.expect(!(Match{ .oem = .{ .vendor = "Nobody", .property = "RtpVersion" } }).matches(root));
    // No `Oem` at all.
    try testing.expect(!(Match{ .oem = .{ .vendor = "Ami", .property = "RtpVersion" } }).matches(Root{}));
}

test "rules accumulate, so a general one and a specific one both apply" {
    const rules = [_]Rule{
        .{ .match = .{ .vendor = "Contoso" }, .deviations = &.{.filter_unreliable} },
        .{
            .match = .{ .vendor = "Contoso", .product_contains = "Gen2" },
            .deviations = &.{.expand_unreliable},
        },
        .{ .match = .{ .vendor = "Fabrikam" }, .deviations = &.{.etag_unreliable} },
    };

    const gen2: Quirks = .identify(Root{ .Vendor = "Contoso", .Product = "Contoso BMC Gen2" }, &rules);
    try testing.expect(gen2.has(.filter_unreliable));
    try testing.expect(gen2.has(.expand_unreliable));
    try testing.expect(!gen2.has(.etag_unreliable));

    // The same vendor, an earlier model: only the general rule.
    const gen1: Quirks = .identify(Root{ .Vendor = "Contoso", .Product = "Contoso BMC Gen1" }, &rules);
    try testing.expect(gen1.has(.filter_unreliable));
    try testing.expect(!gen1.has(.expand_unreliable));

    // A service no rule names is left alone.
    const unknown: Quirks = .identify(Root{ .Vendor = "Initech" }, &rules);
    try testing.expect(!unknown.any());
}

test {
    testing.refAllDecls(@This());
}
