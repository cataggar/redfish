//! `redfish_bmc_http` — a `BmcTransport` speaking Redfish over HTTP.
//!
//! Depends on `redfish_core` and on `std` alone. There is no C dependency
//! anywhere in the stack.
//!
//! `HttpBmc` owns the protocol; a `Wire` moves the bytes. `HttpWire` is the
//! default and runs on `std.http.Client`. `StreamWire` runs on a stream the
//! caller opened, which is what a BMC behind a tunnel, or one presenting a
//! self-signed certificate, needs -- `std.http.Client` decides both the
//! connection and the trust policy for itself.
//!
//! Contents land through Phase 2; see `doc/architecture.md`.

const std = @import("std");

pub const cache = @import("cache.zig");
pub const car_cache = @import("car_cache.zig");
pub const credentials = @import("credentials.zig");
pub const endpoint = @import("endpoint.zig");
pub const http_wire = @import("http_wire.zig");
pub const stream_wire = @import("stream_wire.zig");
pub const transport = @import("transport.zig");
pub const wire = @import("wire.zig");

pub const CarCache = car_cache.CarCache;
pub const CacheSettings = cache.CacheSettings;
pub const ResponseCache = cache.ResponseCache;
pub const Credentials = credentials.Credentials;
pub const CredentialsError = credentials.CredentialsError;
pub const Endpoint = endpoint.Endpoint;
pub const Diagnostics = transport.Diagnostics;
pub const HttpBmc = transport.HttpBmc;
pub const Exchange = wire.Exchange;
pub const Wire = wire.Wire;
pub const HttpWire = http_wire.HttpWire;
pub const StreamWire = stream_wire.StreamWire;

test {
    std.testing.refAllDecls(@This());
    _ = cache;
    _ = car_cache;
    _ = credentials;
    _ = endpoint;
    _ = http_wire;
    _ = stream_wire;
    _ = transport;
    _ = wire;
    // Test-only: drives `HttpBmc` against a loopback `std.http.Server`.
    _ = @import("loopback.zig");
}
