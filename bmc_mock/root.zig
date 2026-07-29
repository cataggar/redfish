//! `redfish_bmc_mock` — an expectation-driven `BmcTransport` for tests.
//!
//! Where `redfish_bmc_http` reaches a real BMC, this module answers from a
//! queue of expectations. It replaces `wiremock`-style HTTP fixtures for
//! everything above the socket: the typed operations, JSON encoding, status
//! handling, and query shaping are all the real ones.
//!
//! ```zig
//! var mock: MockBmc = .init(gpa);
//! defer mock.deinit();
//! try mock.expect(.get("/redfish/v1", service_root_json));
//! ...
//! try mock.verify();
//! ```
//!
//! See `doc/architecture.md`, "Test double".

const std = @import("std");

pub const expect = @import("expect.zig");
pub const mock = @import("mock.zig");

pub const BodyMatch = expect.BodyMatch;
pub const Expect = expect.Expect;
pub const Reply = expect.Reply;
pub const RequestMatch = expect.RequestMatch;
pub const Response = expect.Response;
pub const StreamReply = expect.StreamReply;
pub const UriMatch = expect.UriMatch;
pub const jsonEql = expect.jsonEql;

pub const Error = mock.Error;
pub const MockBmc = mock.MockBmc;
pub const Recorded = mock.Recorded;

test {
    std.testing.refAllDecls(@This());
    _ = expect;
    _ = mock;
}
