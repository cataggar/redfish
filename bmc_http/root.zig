//! `redfish_bmc_http` — a `BmcTransport` over `std.http.Client`.
//!
//! Depends on `redfish_core` and on `std` alone. TLS comes from
//! `std.crypto.tls`, so there is no C dependency anywhere in the stack.
//!
//! Contents land through Phase 2; see `doc/architecture.md`.

const std = @import("std");

pub const credentials = @import("credentials.zig");
pub const endpoint = @import("endpoint.zig");

pub const Credentials = credentials.Credentials;
pub const CredentialsError = credentials.CredentialsError;
pub const Endpoint = endpoint.Endpoint;

test {
    std.testing.refAllDecls(@This());
    _ = credentials;
    _ = endpoint;
}
