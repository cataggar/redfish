//! `Wire` — one HTTP exchange, and nothing about Redfish.
//!
//! `transport.zig` owns the parts of DSP0266 that are the same for every
//! caller: the `OData-Version` header, conditional request headers,
//! credentials, same-origin redirect re-resolution, and the ETag cache. None
//! of that depends on how bytes reach the service. What does depend on it is
//! a single round trip, and this is the interface for that.
//!
//! The split exists because `std.http.Client` decides two things a BMC caller
//! often needs to decide instead:
//!
//!   * **The connection.** Its only public routes to a `Connection` take a
//!     host and port and connect themselves. A BMC reached through an SSH
//!     `direct-tcpip` channel, or any other tunnel, is a byte stream that was
//!     never a socket the client could name.
//!   * **The trust policy.** `Connection.Tls.create` fixes
//!     `.host = .{ .explicit = ... }` and `.ca = .{ .bundle = ... }`, so
//!     `std.crypto.tls.Client.Options`' `.self_signed` is unreachable. Nearly
//!     every BMC ships a self-signed certificate from the factory, which is
//!     why vendor documentation reaches for `curl -k`.
//!
//! A `Wire` implementation that has already connected -- and, if it wanted
//! TLS, already shaken hands -- hands both decisions back to the caller,
//! where they can actually be made.

const std = @import("std");

const core = @import("redfish_core");

/// One exchange, after the Redfish layer has decided everything about it.
///
/// Every field is borrowed for the duration of the call.
pub const Exchange = struct {
    /// Absolute, already resolved against the endpoint and checked for
    /// same-origin by the caller.
    uri: std.Uri,
    method: core.bmc.Method,
    body: core.bmc.RequestBody,
    /// Every header to send, in order, including credentials and
    /// `OData-Version`. An implementation adds only what framing requires:
    /// `Host`, `Content-Length` or `Transfer-Encoding`, and `Content-Type`.
    headers: []const core.bmc.Header,
    /// `Content-Type` for `body`. Ignored when the body is empty.
    content_type: []const u8,
    /// Cap on the response body, so a service that streams without end
    /// cannot exhaust the caller's memory.
    max_response_bytes: usize,
};

pub const Error = error{
    /// The wire cannot hold a `text/event-stream` open.
    StreamingUnsupported,
};

/// How bytes get to the service.
///
/// A function-pointer struct rather than a generic parameter, for the reason
/// `BmcTransport` is one: a connection is chosen at runtime, and the typed
/// layers above should not be re-instantiated per transport.
pub const Wire = struct {
    /// Send one request and read the whole response. Anything the response
    /// points at must be allocated in `arena`.
    roundTripFn: *const fn (
        self: *Wire,
        arena: std.mem.Allocator,
        exchange: Exchange,
    ) anyerror!core.bmc.RawResponse,

    pub fn roundTrip(
        self: *Wire,
        arena: std.mem.Allocator,
        exchange: Exchange,
    ) anyerror!core.bmc.RawResponse {
        return self.roundTripFn(self, arena, exchange);
    }
};
