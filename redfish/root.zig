//! `redfish` — the high-level client.
//!
//! `redfish_core` gives the protocol's primitives and a generated schema
//! package gives its types. This module is what sits between them and a
//! program: it starts at the service root, remembers what the service said it
//! supports, and hands out the subordinate services through links rather than
//! through URIs a caller had to know.
//!
//! It is generic over the generated `ServiceRoot`, so it names no schema
//! package. The standard package and a vendor's own both work, and switching
//! between them is a type parameter.
//!
//! ```zig
//! const schema = @import("redfish_schema_std");
//!
//! var service = try redfish.Service(schema.service_root.ServiceRoot)
//!     .connect(gpa, &bmc.transport);
//! defer service.deinit();
//!
//! var chassis = try service.walk("Chassis");
//! defer chassis.deinit();
//! while (try chassis.next()) |link| {
//!     const one = try core.follow(schema.chassis.Chassis, gpa, &bmc.transport, link);
//!     defer one.deinit();
//!     std.debug.print("{s}\n", .{one.get().Name orelse "?"});
//! }
//! ```

const std = @import("std");

pub const features = @import("features.zig");
pub const quirks = @import("quirks.zig");
pub const service = @import("service.zig");

pub const Expand = features.Expand;
pub const Features = features.Features;
pub const Deviation = quirks.Deviation;
pub const Quirks = quirks.Quirks;
pub const Rule = quirks.Rule;
pub const Service = service.Service;
pub const root_uri = service.root_uri;

test {
    std.testing.refAllDecls(@This());
}
