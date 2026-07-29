//! `redfish_core` — transport-agnostic Redfish and OData primitives.
//!
//! This module deliberately knows nothing about HTTP. It provides the value
//! types and the `BmcTransport` interface that both the HTTP client
//! (`redfish_bmc_http`), the test double (`redfish_bmc_mock`), and generated
//! schema packages are written against.
//!
//! Scope, per DMTF DSP0266 (Redfish Specification) and OData CSDL:
//!   * resource identity — `ODataId`, `ODataETag`, `ODataType`
//!   * navigation and actions — `NavProperty(T)`, `Action(T, R)`
//!   * request shaping — `$expand` / `$filter` / `$select` query builders
//!   * EDM value types — date-time offset, duration, decimal, UUID
//!   * response ownership — `Owned(T)`, one arena per response
//!
//! Contents land in Phase 1; see `doc/architecture.md`.

const std = @import("std");

/// Version of the Redfish Specification (DSP0266) this client targets.
pub const redfish_protocol_version = "1.20.0";

test {
    std.testing.refAllDecls(@This());
}
