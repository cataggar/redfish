//! What a service says it can do, and whether to believe it.
//!
//! `$expand` is the difference between one request and hundreds, so a client
//! wants it wherever it works. `ServiceRoot.ProtocolFeaturesSupported` is how
//! a service says which forms it accepts, and reading that is most of this
//! file.
//!
//! The rest is the part that matters. An advertised capability is a claim, and
//! a service that makes the claim wrongly is worse than one that never made
//! it: the request succeeds, the response comes back without the expanded
//! resources, and a client that trusted the advertisement reads absent where
//! it should read a value — a silent wrong answer rather than an error. So
//! "can I expand this" is a decision rather than a field, and `Features` is
//! where the decision is made and where a correction has to go through.

const std = @import("std");
const core = @import("redfish_core");

/// The `$expand` forms a service will accept.
///
/// Each is an option in DSP0266's `$expand`, and all default to unsupported:
/// a service that says nothing has promised nothing, and the safe reading of
/// silence is that the request would not work.
pub const Expand = struct {
    /// `$expand=.` — expand the subordinate resources but not the `Links`
    /// section. The schema calls this `NoLinks`, after what it leaves out.
    subordinates: bool = false,
    /// `$expand=~` — expand only what `Links` refers to.
    links: bool = false,
    /// `$expand=*` — expand everything, `Links` and annotation payloads
    /// included.
    all: bool = false,
    /// Whether `$levels` may accompany the option. A service that does not
    /// support it may reject the whole request for carrying it, which is why
    /// this is tracked rather than assumed.
    levels: bool = false,
    /// The largest `$levels` the service accepts, when it said.
    max_levels: ?i64 = null,

    /// Whether any form of `$expand` is usable.
    pub fn any(self: Expand) bool {
        return self.subordinates or self.links or self.all;
    }
};

/// A service's capabilities, as advertised and after any correction.
pub const Features = struct {
    expand: Expand = .{},
    filter: bool = false,
    select: bool = false,
    excerpt: bool = false,
    only: bool = false,
    top_skip: bool = false,

    /// Reads what the service claims, without judging it.
    ///
    /// `root` is anything shaped like a generated `ServiceRoot`. Fields are
    /// read by name rather than by type, so this does not bind to one schema
    /// version or one generated package.
    pub fn advertised(root: anytype) Features {
        const supported = root.ProtocolFeaturesSupported orelse return .{};

        var features: Features = .{
            .filter = supported.FilterQuery orelse false,
            .select = supported.SelectQuery orelse false,
            .excerpt = supported.ExcerptQuery orelse false,
            .only = supported.OnlyMemberQuery orelse false,
            .top_skip = supported.TopSkipQuery orelse false,
        };

        if (supported.ExpandQuery) |expand| features.expand = .{
            .subordinates = expand.NoLinks orelse false,
            .links = expand.Links orelse false,
            .all = expand.ExpandAll orelse false,
            .levels = expand.Levels orelse false,
            .max_levels = expand.MaxLevels,
        };

        return features;
    }

    /// Withdraws every `$expand` form, for a service whose advertisement
    /// cannot be trusted.
    ///
    /// This is a whole-capability switch rather than a per-form one because
    /// the failure it exists for is not "this option is unimplemented" — that
    /// a service can and does report. It is "the option is accepted and the
    /// response is wrong", which is not a property of any one option.
    pub fn withoutExpand(self: Features) Features {
        var corrected = self;
        corrected.expand = .{};
        return corrected;
    }

    /// The strongest `$expand` the service will take, ready to send, or null
    /// if it takes none.
    ///
    /// Two corrections are folded in, and both are the kind of thing that is
    /// easy to get wrong once per call site:
    ///
    /// `.` is preferred over `*`, because `*` also expands `Links` and the
    /// annotation payloads. On a populated chassis that is most of the
    /// response and almost never what was wanted.
    ///
    /// `$levels` is omitted unless the service said it supports it, and capped
    /// at the maximum it named. `ExpandQuery` defaults to one level, so a
    /// caller who forgot this would send `$levels` to a service that never
    /// claimed to accept it — and DSP0266 lets that service reject the whole
    /// request rather than ignore the parameter.
    pub fn bestExpand(self: Features) ?core.ExpandQuery {
        const expression: core.ExpandQuery.Expression =
            if (self.expand.subordinates)
                .current
            else if (self.expand.all)
                .all
            else if (self.expand.links)
                .links
            else
                return null;

        return .{ .expression = expression, .levels = self.levels(1) };
    }

    /// `$levels` clamped to what the service accepts, or null if it accepts
    /// none.
    pub fn levels(self: Features, wanted: u32) ?u32 {
        if (!self.expand.levels) return null;
        const max = self.expand.max_levels orelse return wanted;
        if (max <= 0) return null;
        return @min(wanted, std.math.lossyCast(u32, max));
    }
};

const testing = std.testing;

/// Shaped as the emitter writes `ServiceRoot`, down to the optionals.
const Root = struct {
    ProtocolFeaturesSupported: ?struct {
        ExpandQuery: ?struct {
            Links: ?bool = null,
            NoLinks: ?bool = null,
            ExpandAll: ?bool = null,
            Levels: ?bool = null,
            MaxLevels: ?i64 = null,
        } = null,
        FilterQuery: ?bool = null,
        SelectQuery: ?bool = null,
        ExcerptQuery: ?bool = null,
        OnlyMemberQuery: ?bool = null,
        TopSkipQuery: ?bool = null,
    } = null,
};

test "a service that says nothing has promised nothing" {
    const features: Features = .advertised(Root{});

    try testing.expect(!features.expand.any());
    try testing.expect(!features.filter);
    try testing.expect(features.bestExpand() == null);
}

test "a claim of support is read form by form" {
    const features: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .ExpandAll = true, .Levels = true, .MaxLevels = 3 },
        .FilterQuery = true,
        .SelectQuery = false,
    } });

    try testing.expect(features.expand.subordinates);
    try testing.expect(features.expand.all);
    try testing.expect(!features.expand.links);
    try testing.expectEqual(@as(?i64, 3), features.expand.max_levels);
    try testing.expect(features.filter);
    try testing.expect(!features.select);
}

test "expanding everything is the second choice, not the first" {
    const both: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .ExpandAll = true },
    } });
    try testing.expectEqual(core.ExpandQuery.Expression.current, both.bestExpand().?.expression);

    const only_all: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .ExpandAll = true },
    } });
    try testing.expectEqual(core.ExpandQuery.Expression.all, only_all.bestExpand().?.expression);
}

test "levels is not sent to a service that never claimed to accept it" {
    // `ExpandQuery` defaults to one level, so this is the correction a caller
    // building the query by hand would most easily miss.
    const silent: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true },
    } });
    try testing.expectEqual(@as(?u32, null), silent.bestExpand().?.levels);
    try testing.expectEqual(@as(?u32, null), silent.levels(4));

    const supported: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .Levels = true },
    } });
    try testing.expectEqual(@as(?u32, 1), supported.bestExpand().?.levels);
}

test "levels is clamped to the maximum the service named" {
    const capped: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .Levels = true, .MaxLevels = 2 },
    } });

    try testing.expectEqual(@as(?u32, 2), capped.levels(6));
    try testing.expectEqual(@as(?u32, 1), capped.levels(1));

    // A service claiming levels but naming a maximum of zero has contradicted
    // itself; the safe reading is to send none.
    const contradictory: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .Levels = true, .MaxLevels = 0 },
    } });
    try testing.expectEqual(@as(?u32, null), contradictory.levels(1));
}

test "withdrawing expand leaves the other capabilities alone" {
    const claimed: Features = .advertised(Root{ .ProtocolFeaturesSupported = .{
        .ExpandQuery = .{ .NoLinks = true, .ExpandAll = true },
        .FilterQuery = true,
        .TopSkipQuery = true,
    } });
    try testing.expect(claimed.expand.any());

    const corrected = claimed.withoutExpand();
    try testing.expect(!corrected.expand.any());
    try testing.expect(corrected.bestExpand() == null);

    // `$expand` being broken says nothing about `$filter`.
    try testing.expect(corrected.filter);
    try testing.expect(corrected.top_skip);
}

test {
    testing.refAllDecls(@This());
}
