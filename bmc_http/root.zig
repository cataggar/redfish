//! `redfish_bmc_http` — a `BmcTransport` over `std.http.Client`.
//!
//! Depends on `redfish_core` and on `std` alone. TLS comes from
//! `std.crypto.tls`, so there is no C dependency anywhere in the stack.
//!
//! Contents land through Phase 2; see `doc/architecture.md`.

const std = @import("std");

pub const cache = @import("cache.zig");
pub const car_cache = @import("car_cache.zig");
pub const credentials = @import("credentials.zig");
pub const endpoint = @import("endpoint.zig");
pub const transport = @import("transport.zig");

pub const CarCache = car_cache.CarCache;
pub const CacheSettings = cache.CacheSettings;
pub const ResponseCache = cache.ResponseCache;
pub const Credentials = credentials.Credentials;
pub const CredentialsError = credentials.CredentialsError;
pub const Endpoint = endpoint.Endpoint;
pub const Diagnostics = transport.Diagnostics;
pub const HttpBmc = transport.HttpBmc;

test {
    std.testing.refAllDecls(@This());
    _ = cache;
    _ = car_cache;
    _ = credentials;
    _ = endpoint;
    _ = transport;
    // Test-only: drives `HttpBmc` against a loopback `std.http.Server`.
    _ = @import("loopback.zig");
}
