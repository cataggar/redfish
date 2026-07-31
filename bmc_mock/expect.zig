//! What a mock BMC is told to expect, and what it answers with.
//!
//! `nv-redfish-bmc-mock` matches at the *typed* layer: its expectations name
//! a resource type and carry a `serde_json::Value`. This mock matches at the
//! `BmcTransport` seam instead — a method, a URI, and a body — so a test
//! drives the real typed layer, the real JSON encoder, and the real status
//! handling, and only the socket is replaced.
//!
//! Expectation strings are **borrowed**. They are almost always literals in
//! the test that installs them, and they must outlive the mock.

const std = @import("std");

const core = @import("redfish_core");

const bmc = core.bmc;

pub const Header = bmc.Header;
pub const Method = bmc.Method;

/// How an expectation matches a request URI.
pub const UriMatch = union(enum) {
    /// Any URI at all.
    any,
    /// The whole reference, query string included.
    exact: []const u8,
    /// The path only. Use this when the operation appends query options —
    /// `$expand` and friends — that the test does not care about.
    path: []const u8,
    /// A leading substring, for a collection whose member ids are generated.
    prefix: []const u8,

    pub fn matches(self: UriMatch, uri: []const u8) bool {
        return switch (self) {
            .any => true,
            .exact => |want| std.mem.eql(u8, want, uri),
            .path => |want| std.mem.eql(u8, want, pathOf(uri)),
            .prefix => |want| std.mem.startsWith(u8, uri, want),
        };
    }

    pub fn format(self: UriMatch, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .any => try w.writeAll("<any uri>"),
            .exact => |want| try w.writeAll(want),
            .path => |want| try w.print("{s}[?…]", .{want}),
            .prefix => |want| try w.print("{s}…", .{want}),
        }
    }
};

/// The part of a URI reference before the query string.
fn pathOf(uri: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, uri, '?') orelse uri.len;
    return uri[0..query];
}

/// How an expectation matches a request body.
pub const BodyMatch = union(enum) {
    /// Any body, or none.
    any,
    /// No body at all.
    empty,
    /// Equal as JSON: object key order and insignificant whitespace do not
    /// matter, so a test can write the payload the way it reads best.
    json: []const u8,
    /// Byte-for-byte, for a body that is not JSON — a firmware image, say.
    bytes: []const u8,
    /// Contains this substring. The escape hatch for a multipart body, whose
    /// boundary is random.
    contains: []const u8,

    /// `gpa` is scratch for parsing; nothing is retained.
    pub fn matches(self: BodyMatch, gpa: std.mem.Allocator, body: []const u8) !bool {
        return switch (self) {
            .any => true,
            .empty => body.len == 0,
            .json => |want| jsonEql(gpa, want, body),
            .bytes => |want| std.mem.eql(u8, want, body),
            .contains => |want| std.mem.indexOf(u8, body, want) != null,
        };
    }

    pub fn format(self: BodyMatch, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .any => try w.writeAll("<any body>"),
            .empty => try w.writeAll("<no body>"),
            .json => |want| try w.print("json {s}", .{want}),
            .bytes => |want| try w.print("bytes {s}", .{want}),
            .contains => |want| try w.print("containing {s}", .{want}),
        }
    }
};

/// Whether two JSON documents mean the same thing.
///
/// Both are parsed into an arena that is released before returning, so a
/// caller's allocator is only borrowed. Malformed JSON on either side is not
/// an error: it simply does not match, because a test that misspells a
/// payload should see a mismatch report rather than a parse failure from
/// somewhere inside the mock.
pub fn jsonEql(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const left = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        a,
        .{},
    ) catch return false;
    const right = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        b,
        .{},
    ) catch return false;

    return valueEql(left, right);
}

fn valueEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |left| b == .bool and left == b.bool,
        .integer => |left| switch (b) {
            .integer => |right| left == right,
            .float => |right| @as(f64, @floatFromInt(left)) == right,
            else => false,
        },
        .float => |left| switch (b) {
            .float => |right| left == right,
            .integer => |right| left == @as(f64, @floatFromInt(right)),
            else => false,
        },
        .number_string => |left| b == .number_string and std.mem.eql(u8, left, b.number_string),
        .string => |left| b == .string and std.mem.eql(u8, left, b.string),
        .array => |left| {
            if (b != .array) return false;
            const right = b.array;
            if (left.items.len != right.items.len) return false;
            for (left.items, right.items) |l, r| {
                if (!valueEql(l, r)) return false;
            }
            return true;
        },
        .object => |left| {
            if (b != .object) return false;
            const right = b.object;
            if (left.count() != right.count()) return false;
            var it = left.iterator();
            while (it.next()) |field| {
                const other = right.get(field.key_ptr.*) orelse return false;
                if (!valueEql(field.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

/// The request half of an expectation. Every field is optional; an omitted
/// one matches anything, so a test constrains only what it is testing.
pub const RequestMatch = struct {
    method: ?Method = null,
    uri: UriMatch = .any,
    body: BodyMatch = .any,
    /// The expected `Content-Type` of the request body.
    content_type: ?[]const u8 = null,
    /// The expected `If-Match` ETag. `.absent` asserts the write is
    /// unconditional.
    if_match: EtagMatch = .any,
    /// The expected `If-None-Match` ETag.
    if_none_match: EtagMatch = .any,
    /// Headers that must be present with these values. Extra headers on the
    /// request are ignored.
    headers: []const Header = &.{},

    pub const EtagMatch = union(enum) {
        any,
        absent,
        value: []const u8,

        pub fn matches(self: EtagMatch, actual: ?core.ODataETag) bool {
            return switch (self) {
                .any => true,
                .absent => actual == null,
                .value => |want| actual != null and std.mem.eql(u8, want, actual.?.value),
            };
        }
    };
};

/// The response half of an expectation.
///
/// The headers the typed layer reads have named fields rather than living in
/// `headers`: a builder that took a slice would have to point it at a
/// temporary, which does not outlive the call that built it.
pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = &.{},
    /// Defaults to `application/json` when there is a body.
    content_type: ?[]const u8 = null,
    /// `ETag`, which the typed layer feeds back as `If-Match`.
    etag: ?[]const u8 = null,
    /// `Location`: the new resource on a create, the task monitor on a 202.
    location: ?[]const u8 = null,
    /// `X-Auth-Token`, for a session create.
    auth_token: ?[]const u8 = null,
    /// `Retry-After`, in seconds.
    retry_after: ?u32 = null,
    /// Any further headers, appended after the named ones.
    headers: []const Header = &.{},
};

/// What the mock answers a matched request with.
pub const Reply = union(enum) {
    /// A response, of any status. Non-2xx is how a test exercises the error
    /// paths of the typed layer.
    response: Response,
    /// A transport failure, as if the connection itself had failed.
    failure: anyerror,
};

/// What the mock answers a matched `stream` call with.
pub const StreamReply = union(enum) {
    /// The whole `text/event-stream` body, served from memory. The mock
    /// keeps no copy, so it must outlive the stream.
    body: []const u8,
    failure: anyerror,
};

/// One queued expectation.
pub const Expect = union(enum) {
    request: Request,
    event_stream: EventStream,

    pub const Request = struct {
        match: RequestMatch = .{},
        reply: Reply = .{ .response = .{} },
    };

    pub const EventStream = struct {
        uri: UriMatch = .any,
        reply: StreamReply,
    };

    /// A `GET` answered with a JSON body.
    pub fn get(uri: []const u8, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{ .method = .get, .uri = .{ .exact = uri } },
            .reply = .{ .response = .{ .body = body } },
        } };
    }

    /// A `GET` on the path, whatever query options the operation appends.
    pub fn expand(path: []const u8, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{ .method = .get, .uri = .{ .path = path } },
            .reply = .{ .response = .{ .body = body } },
        } };
    }

    /// A `PATCH` whose payload must equal `request` as JSON.
    pub fn patch(uri: []const u8, request: []const u8, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{
                .method = .patch,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .body = body } },
        } };
    }

    /// A `PATCH` accepted as an asynchronous task at `task`.
    ///
    /// `retry_after` is the `Retry-After` a service uses to pace the poll, in
    /// seconds, and is optional because a service is not obliged to offer one.
    pub fn patchAccepted(
        uri: []const u8,
        request: []const u8,
        task: []const u8,
        retry_after: ?u32,
    ) Expect {
        return .{ .request = .{
            .match = .{
                .method = .patch,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{
                .status = 202,
                .location = task,
                .retry_after = retry_after,
            } },
        } };
    }

    /// A `PATCH` answered `204 No Content`.
    pub fn patchNoContent(uri: []const u8, request: []const u8) Expect {
        return .{ .request = .{
            .match = .{
                .method = .patch,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .status = 204 } },
        } };
    }

    /// A `POST` whose payload must equal `request` as JSON.
    pub fn post(uri: []const u8, request: []const u8, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .body = body } },
        } };
    }

    /// A `POST` that creates a resource at `location`.
    pub fn created(
        uri: []const u8,
        request: []const u8,
        location: []const u8,
        body: []const u8,
    ) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .status = 201, .location = location, .body = body } },
        } };
    }

    /// A `POST` accepted as an asynchronous task at `task`.
    ///
    /// A service that cannot finish a create while the client waits answers
    /// this instead of `created`, and the caller gets a task to poll rather
    /// than the member it asked for.
    pub fn postAccepted(
        uri: []const u8,
        request: []const u8,
        task: []const u8,
        retry_after: ?u32,
    ) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{
                .status = 202,
                .location = task,
                .retry_after = retry_after,
            } },
        } };
    }

    /// A `POST` answered `204 No Content`.
    ///
    /// The create succeeded and the service declined to say what it made, so
    /// a caller that wants the member has to go and read the collection.
    pub fn postNoContent(uri: []const u8, request: []const u8) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .status = 204 } },
        } };
    }

    /// A `POST` of a `multipart/form-data` firmware push, matched on method
    /// and URI alone.
    ///
    /// The body cannot be matched. A form boundary is random by requirement,
    /// so no fixed string equals the request and no JSON comparison applies
    /// to it either; a test that cares about the parts asserts on the
    /// recorded request. `reply` is given whole because a push is answered
    /// every way a mutation can be — `202` with a task, `200` with the
    /// result, `204` with nothing.
    pub fn multipartPush(uri: []const u8, reply: Response) Expect {
        return .{ .request = .{
            .match = .{ .method = .post, .uri = .{ .exact = uri } },
            .reply = .{ .response = reply },
        } };
    }

    /// A session create: `201` with both `X-Auth-Token` and `Location`.
    pub fn session(
        uri: []const u8,
        request: []const u8,
        token: []const u8,
        location: []const u8,
        body: []const u8,
    ) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = uri },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{
                .status = 201,
                .location = location,
                .auth_token = token,
                .body = body,
            } },
        } };
    }

    /// An action `POST`. Redfish actions with no parameters send `{}`.
    pub fn action(target: []const u8, request: []const u8, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = target },
                .body = .{ .json = request },
            },
            .reply = .{ .response = .{ .body = body } },
        } };
    }

    /// A `DELETE` answered `204 No Content`.
    pub fn delete(uri: []const u8) Expect {
        return .{ .request = .{
            .match = .{ .method = .delete, .uri = .{ .exact = uri } },
            .reply = .{ .response = .{ .status = 204 } },
        } };
    }

    /// A `DELETE` accepted as an asynchronous task at `task`.
    pub fn deleteAccepted(uri: []const u8, task: []const u8, retry_after: ?u32) Expect {
        return .{ .request = .{
            .match = .{ .method = .delete, .uri = .{ .exact = uri } },
            .reply = .{ .response = .{
                .status = 202,
                .location = task,
                .retry_after = retry_after,
            } },
        } };
    }

    /// Any request to `uri` answered with `code` and no body.
    pub fn status(uri: []const u8, code: u16) Expect {
        return .{ .request = .{
            .match = .{ .uri = .{ .exact = uri } },
            .reply = .{ .response = .{ .status = code } },
        } };
    }

    /// Any request to `uri` answered with a Redfish error body.
    pub fn errorBody(uri: []const u8, code: u16, body: []const u8) Expect {
        return .{ .request = .{
            .match = .{ .uri = .{ .exact = uri } },
            .reply = .{ .response = .{ .status = code, .body = body } },
        } };
    }

    /// Any request to `uri` that fails at the transport.
    pub fn failure(uri: []const u8, err: anyerror) Expect {
        return .{ .request = .{
            .match = .{ .uri = .{ .exact = uri } },
            .reply = .{ .failure = err },
        } };
    }

    /// A `text/event-stream` subscription served from `events`.
    pub fn stream(uri: []const u8, events: []const u8) Expect {
        return .{ .event_stream = .{
            .uri = .{ .exact = uri },
            .reply = .{ .body = events },
        } };
    }

    pub fn format(self: Expect, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .request => |request| {
                if (request.match.method) |method| {
                    try w.writeAll(method.token());
                } else {
                    try w.writeAll("<any method>");
                }
                try w.print(" {f}", .{request.match.uri});
                switch (request.match.body) {
                    .any => {},
                    else => try w.print(" {f}", .{request.match.body}),
                }
            },
            .event_stream => |subscription| {
                try w.print("STREAM {f}", .{subscription.uri});
            },
        }
    }
};

const testing = std.testing;

test "json equality ignores key order and whitespace" {
    try testing.expect(try jsonEql(testing.allocator,
        \\{"a": 1, "b": [true, null]}
    ,
        \\{"b":[true,null],"a":1}
    ));
}

test "json equality is structural" {
    try testing.expect(!try jsonEql(testing.allocator, "{\"a\":1}", "{\"a\":2}"));
    try testing.expect(!try jsonEql(testing.allocator, "{\"a\":1}", "{\"a\":1,\"b\":2}"));
    try testing.expect(!try jsonEql(testing.allocator, "[1,2]", "[2,1]"));
    try testing.expect(try jsonEql(testing.allocator, "1", "1.0"));
}

test "malformed json does not match rather than failing" {
    try testing.expect(!try jsonEql(testing.allocator, "{", "{}"));
    try testing.expect(!try jsonEql(testing.allocator, "{}", "}"));
}

test "a uri match can ignore the query string" {
    const with_query = "/redfish/v1/Chassis?$expand=.($levels=1)";
    try testing.expect(!(UriMatch{ .exact = "/redfish/v1/Chassis" }).matches(with_query));
    try testing.expect((UriMatch{ .path = "/redfish/v1/Chassis" }).matches(with_query));
    try testing.expect((UriMatch{ .prefix = "/redfish/v1/" }).matches(with_query));
    try testing.expect((UriMatch{ .exact = with_query }).matches(with_query));
    const any_uri: UriMatch = .any;
    try testing.expect(any_uri.matches(with_query));
}

test "a body match spans json, bytes, and substrings" {
    const gpa = testing.allocator;
    try testing.expect(try (BodyMatch{ .json = "{\"a\":1}" }).matches(gpa, "{ \"a\" : 1 }"));
    try testing.expect(try (BodyMatch{ .bytes = "raw" }).matches(gpa, "raw"));
    try testing.expect(!try (BodyMatch{ .bytes = "{\"a\":1}" }).matches(gpa, "{ \"a\": 1 }"));
    try testing.expect(try (BodyMatch{ .contains = "name=\"file\"" }).matches(
        gpa,
        "--b\r\nContent-Disposition: form-data; name=\"file\"\r\n",
    ));
    const empty: BodyMatch = .empty;
    try testing.expect(try empty.matches(gpa, ""));
    try testing.expect(!try empty.matches(gpa, " "));
}

test "an etag match distinguishes absent from any" {
    const absent: RequestMatch.EtagMatch = .absent;
    try testing.expect(absent.matches(null));
    try testing.expect(!absent.matches(core.ODataETag.init("\"1\"")));
    const any_etag: RequestMatch.EtagMatch = .any;
    try testing.expect(any_etag.matches(null));
    try testing.expect((RequestMatch.EtagMatch{ .value = "\"1\"" }).matches(
        core.ODataETag.init("\"1\""),
    ));
    try testing.expect(!(RequestMatch.EtagMatch{ .value = "\"1\"" }).matches(
        core.ODataETag.init("\"2\""),
    ));
}

test "an expectation renders as a request line" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "GET /redfish/v1",
        try std.fmt.bufPrint(&buffer, "{f}", .{Expect.get("/redfish/v1", "{}")}),
    );
    try testing.expectEqualStrings(
        "PATCH /redfish/v1/Chassis/1 json {\"IndicatorLED\":\"Lit\"}",
        try std.fmt.bufPrint(&buffer, "{f}", .{Expect.patch(
            "/redfish/v1/Chassis/1",
            "{\"IndicatorLED\":\"Lit\"}",
            "{}",
        )}),
    );
    try testing.expectEqualStrings(
        "STREAM /redfish/v1/EventService/SSE",
        try std.fmt.bufPrint(&buffer, "{f}", .{Expect.stream("/redfish/v1/EventService/SSE", "")}),
    );
}
