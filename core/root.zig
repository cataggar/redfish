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

pub const action = @import("action.zig");
pub const bmc = @import("bmc.zig");
pub const edm = @import("edm.zig");
pub const entity = @import("entity.zig");
pub const nav_property = @import("nav_property.zig");
pub const odata = @import("odata.zig");
pub const owned = @import("owned.zig");
pub const query = @import("query.zig");
pub const redfish_error = @import("redfish_error.zig");
pub const response = @import("response.zig");
pub const sse = @import("sse.zig");

pub const Decimal = edm.Decimal;
pub const DateTimeOffset = edm.DateTimeOffset;
pub const Duration = edm.Duration;
pub const Guid = edm.Guid;
pub const PrimitiveType = edm.PrimitiveType;

pub const ODataId = odata.ODataId;
pub const ODataETag = odata.ODataETag;
pub const ODataType = odata.ODataType;
pub const Owned = owned.Owned;
pub const parseJson = owned.parseJson;

pub const NavProperty = nav_property.NavProperty;
pub const Reference = nav_property.Reference;
pub const ReferenceLeaf = nav_property.ReferenceLeaf;

pub const Action = action.Action;
pub const ActionTarget = action.ActionTarget;

pub const BmcTransport = bmc.BmcTransport;
pub const EventStream = bmc.EventStream;
pub const RawRequest = bmc.RawRequest;
pub const RawResponse = bmc.RawResponse;

pub const Event = sse.Event;
pub const EventReader = sse.EventReader;

pub const Comparison = query.Comparison;
pub const ExpandQuery = query.ExpandQuery;
pub const FilterLiteral = query.FilterLiteral;
pub const FilterQuery = query.FilterQuery;
pub const LogicalOp = query.LogicalOp;
pub const QueryOptions = query.QueryOptions;

pub const Message = redfish_error.Message;
pub const RedfishError = redfish_error.RedfishError;
pub const Severity = redfish_error.Severity;

pub const AsyncTask = response.AsyncTask;
pub const AsyncTaskLocation = response.AsyncTaskLocation;
pub const ModificationResponse = response.ModificationResponse;
pub const SessionCreateResponse = response.SessionCreateResponse;

/// Version of the Redfish Specification (DSP0266) this client targets.
pub const redfish_protocol_version = "1.20.0";

test {
    std.testing.refAllDecls(@This());
    _ = action;
    _ = bmc;
    _ = edm;
    _ = entity;
    _ = nav_property;
    _ = odata;
    _ = owned;
    _ = query;
    _ = redfish_error;
    _ = response;
    _ = sse;
}
