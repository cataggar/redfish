//! `HttpWire` — the `Wire` that `std.http.Client` backs.
//!
//! This is what `bmc_http` has always done; it moved here so that
//! `transport.zig` names one round trip instead of performing it. Behaviour
//! is unchanged, including the content codings it accepts and decodes, which
//! is the part `StreamWire` deliberately does not reproduce.

const std = @import("std");

const core = @import("redfish_core");

const wire_mod = @import("wire.zig");

const Exchange = wire_mod.Exchange;
const Header = core.bmc.Header;
const RawResponse = core.bmc.RawResponse;
const Wire = wire_mod.Wire;

pub const Error = error{
    /// The response body exceeded `Exchange.max_response_bytes`.
    ResponseTooLarge,
    /// A streamed body declared a `Content-Length` it did not deliver.
    /// Sending it anyway would produce a malformed request.
    UploadLengthMismatch,
};

pub const HttpWire = struct {
    wire: Wire = .{ .roundTripFn = &roundTripImpl },
    /// Borrowed, so one client's connection pool can back several BMCs.
    client: *std.http.Client,

    pub fn init(client: *std.http.Client) HttpWire {
        return .{ .client = client };
    }

    pub fn asWire(self: *HttpWire) *Wire {
        return &self.wire;
    }

    fn roundTripImpl(
        w: *Wire,
        arena: std.mem.Allocator,
        exchange: Exchange,
    ) anyerror!RawResponse {
        const self: *HttpWire = @fieldParentPtr("wire", w);

        var headers: std.ArrayList(std.http.Header) = .empty;
        for (exchange.headers) |header| {
            try headers.append(arena, .{ .name = header.name, .value = header.value });
        }

        var http_request = try self.client.request(
            toStdMethod(exchange.method),
            exchange.uri,
            .{
                // Redirects are followed by `transport.zig`, which re-checks
                // the origin on every hop.
                .redirect_behavior = .unhandled,
                .extra_headers = headers.items,
                .headers = .{
                    .content_type = if (exchange.body.isEmpty())
                        .omit
                    else
                        .{ .override = exchange.content_type },
                    .accept_encoding = .default,
                },
            },
        );
        defer http_request.deinit();

        try sendBody(&http_request, exchange.body);

        var response = try http_request.receiveHead(&.{});
        const status: u16 = @intFromEnum(response.head.status);

        var entries: std.ArrayList(Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            try entries.append(arena, .{
                .name = try arena.dupe(u8, header.name),
                .value = try arena.dupe(u8, header.value),
            });
        }

        return .{
            .status = status,
            .headers = .{ .entries = try entries.toOwnedSlice(arena) },
            .body = try readBody(arena, &response, exchange.max_response_bytes),
        };
    }

    /// Writes the request body, whether it is in memory or arriving from a
    /// reader.
    fn sendBody(
        http_request: *std.http.Client.Request,
        body: core.bmc.RequestBody,
    ) anyerror!void {
        switch (body) {
            .bytes => |bytes| {
                if (bytes.len == 0) return http_request.sendBodiless();
                http_request.transfer_encoding = .{ .content_length = bytes.len };
                var writer = try http_request.sendBodyUnflushed(&.{});
                try writer.writer.writeAll(bytes);
                try writer.end();
                try http_request.connection.?.flush();
            },
            .stream => |source| {
                // A known length is worth declaring: chunked transfer
                // encoding on a firmware push is what several BMCs reject.
                http_request.transfer_encoding = if (source.len) |len|
                    .{ .content_length = len }
                else
                    .chunked;

                var chunk_buffer: [16 << 10]u8 = undefined;
                var writer = try http_request.sendBodyUnflushed(&chunk_buffer);
                const written = try source.reader.streamRemaining(&writer.writer);
                if (source.len) |len| {
                    if (written != len) return Error.UploadLengthMismatch;
                }
                try writer.end();
                try http_request.connection.?.flush();
            },
        }
    }

    fn readBody(
        arena: std.mem.Allocator,
        response: *std.http.Client.Response,
        max_response_bytes: usize,
    ) anyerror![]const u8 {
        var transfer_buffer: [4096]u8 = undefined;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };

        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            decompress_buffer,
        );

        return reader.allocRemaining(arena, .limited(max_response_bytes)) catch |err| {
            return switch (err) {
                error.StreamTooLong => Error.ResponseTooLarge,
                error.ReadFailed => response.bodyErr() orelse err,
                else => err,
            };
        };
    }
};

pub fn toStdMethod(method: core.bmc.Method) std.http.Method {
    return switch (method) {
        .get => .GET,
        .post => .POST,
        .patch => .PATCH,
        .put => .PUT,
        .delete => .DELETE,
    };
}
