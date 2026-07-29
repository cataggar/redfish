//! EDM value types — the OData primitives that do not map onto a Zig builtin.
//!
//! Each type parses and formats its OData wire representation exactly, and
//! carries `jsonParse` / `jsonStringify` hooks so generated schema structs can
//! declare a field of the type and get the right encoding for free.
//!
//! Reference: OASIS OData 4.01 CSDL Part 3, "Primitive Types".

const std = @import("std");

pub const decimal = @import("edm/decimal.zig");
pub const date_time_offset = @import("edm/date_time_offset.zig");
pub const duration = @import("edm/duration.zig");
pub const guid = @import("edm/guid.zig");
pub const primitive = @import("edm/primitive.zig");

/// `Edm.Decimal` — exact fixed-point, so a value survives a round trip that
/// `f64` would corrupt.
pub const Decimal = decimal.Decimal;
/// `Edm.DateTimeOffset` — RFC 3339 with a mandatory UTC offset.
pub const DateTimeOffset = date_time_offset.DateTimeOffset;
/// `Edm.Duration` — ISO 8601 `[-]P[nD][T[nH][nM]nS]`.
pub const Duration = duration.Duration;
/// `Edm.Guid` — RFC 9562 UUID.
pub const Guid = guid.Guid;
/// `Edm.PrimitiveType` — the untagged open primitive slot.
pub const PrimitiveType = primitive.PrimitiveType;

test {
    std.testing.refAllDecls(@This());
    _ = decimal;
    _ = date_time_offset;
    _ = duration;
    _ = guid;
    _ = primitive;
}
