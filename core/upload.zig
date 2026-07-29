//! `UpdateService` firmware upload.
//!
//! DSP0266 §13.4 gives a client two ways to push an image. The current one is
//! a `multipart/form-data` `POST` to `MultipartHttpPushUri`, carrying an
//! `UpdateParameters` JSON part and an `UpdateFile` binary part. The older one
//! is a raw `POST` of the image to `HttpPushUri`, deprecated in Redfish 1.6
//! but still the only thing many fielded BMCs implement.
//!
//! Both take the image as a `*std.Io.Reader` rather than a slice: a firmware
//! image runs to hundreds of megabytes, and `RequestBody.stream` exists so it
//! never has to be held in memory.
//!
//! Unlike `nv-redfish`, an upload carries no per-request timeout. Zig 0.16 has
//! no async and the transport interface is synchronous, so a deadline is the
//! caller's to impose — normally by configuring it on the transport.

const std = @import("std");

const bmc = @import("bmc.zig");
const multipart = @import("multipart.zig");
const odata = @import("odata.zig");
const owned = @import("owned.zig");
const response_mod = @import("response.zig");

const BmcTransport = bmc.BmcTransport;
const ModificationResponse = response_mod.ModificationResponse;
const ODataId = odata.ODataId;
const Owned = owned.Owned;

/// DSP0266 requires an OEM-defined form part to be named with this prefix, so
/// that it can never collide with a part the specification later defines.
pub const oem_part_prefix = "Oem";

/// The image, and the filename to stage it under.
pub const UpdateFile = struct {
    /// The multipart `filename`. A service usually shows it in the resulting
    /// task, and some match it against the image's own metadata.
    name: []const u8,
    /// Read to end of stream as the request is written.
    reader: *std.Io.Reader,
    /// The image's size, when known. Supply it whenever possible: without a
    /// length on every part the form has no `Content-Length` and has to be
    /// sent chunked, which not every BMC accepts.
    len: ?u64 = null,
};

/// An OEM-defined extra part.
pub const OemPart = struct {
    /// Must start with `Oem`.
    name: []const u8,
    reader: *std.Io.Reader,
    content_type: ?[]const u8 = null,
    len: ?u64 = null,

    pub fn isNameValid(self: OemPart) bool {
        return std.mem.startsWith(u8, self.name, oem_part_prefix);
    }
};

pub const Error = error{
    /// An OEM part's name did not start with `Oem`.
    InvalidOemPartName,
};

/// The `UpdateFile` part's media type. DSP0266 names it explicitly.
pub const image_content_type = "application/octet-stream";

/// POST a multipart firmware update to `MultipartHttpPushUri`.
///
/// `parameters` is encoded as the JSON `UpdateParameters` part — normally a
/// value with `Targets`, `@Redfish.OperationApplyTime`, and so on. `random`
/// supplies the form boundary; see `multipart.randomBoundary`.
///
/// A service that accepts the image answers `202 Accepted` with a task, which
/// arrives here as `ModificationResponse.task`.
pub fn multipartUpdate(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    parameters: anytype,
    file: UpdateFile,
    oem_parts: []const OemPart,
    random: std.Random,
) !Owned(ModificationResponse(T)) {
    // Checked before anything is allocated: a misnamed part is the caller's
    // mistake, and there is no point building a form to throw away.
    for (oem_parts) |part| {
        if (!part.isNameValid()) return Error.InvalidOemPartName;
    }

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const allocator = arena.allocator();

    var parts: std.ArrayList(multipart.Part) = .empty;
    try parts.append(allocator, .{
        .name = "UpdateParameters",
        .content_type = "application/json",
        .source = .{
            .bytes = try std.json.Stringify.valueAlloc(allocator, parameters, .{
                .emit_null_optional_fields = false,
            }),
        },
    });
    try parts.append(allocator, .{
        .name = "UpdateFile",
        .filename = file.name,
        .content_type = image_content_type,
        .source = .{ .stream = .{ .reader = file.reader, .len = file.len } },
    });
    for (oem_parts) |part| {
        try parts.append(allocator, .{
            .name = part.name,
            .content_type = part.content_type,
            .source = .{ .stream = .{ .reader = part.reader, .len = part.len } },
        });
    }

    const form: multipart.Form = try .init(
        allocator,
        multipart.randomBoundary(random),
        parts.items,
    );
    var form_reader = form.reader();

    const raw = try transport.send(allocator, .{
        .method = .post,
        .uri = id.value,
        .content_type = form.contentType(),
        .body = .{ .stream = .{
            .reader = &form_reader.interface,
            .len = form.contentLength(),
        } },
    });
    return bmc.modificationResponse(T, .{ .arena = arena, .raw = raw });
}

/// POST a raw firmware image to the deprecated `HttpPushUri`.
///
/// Deprecated in Redfish 1.6 in favour of `multipartUpdate`, and kept because
/// many fielded BMCs implement nothing else. The body is the image itself,
/// with no envelope, so `ETag` preconditions and parameters have no place to
/// go — a service that needs them requires the multipart form.
pub fn httpPushUriUpdate(
    comptime T: type,
    gpa: std.mem.Allocator,
    transport: *BmcTransport,
    id: ODataId,
    image: *std.Io.Reader,
    len: ?u64,
) !Owned(ModificationResponse(T)) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const raw = try transport.send(arena.allocator(), .{
        .method = .post,
        .uri = id.value,
        .content_type = image_content_type,
        .body = .{ .stream = .{ .reader = image, .len = len } },
    });
    return bmc.modificationResponse(T, .{ .arena = arena, .raw = raw });
}

const testing = std.testing;

/// A transport that reads whatever body it is given, so a test can inspect
/// the bytes an upload would put on the wire.
const RecordingTransport = struct {
    transport: BmcTransport = .{ .sendFn = &sendImpl, .streamFn = null },
    gpa: std.mem.Allocator,
    reply: bmc.RawResponse = .{ .status = 204 },
    method: bmc.Method = .get,
    uri: []const u8 = &.{},
    content_type: []const u8 = &.{},
    declared_len: ?u64 = null,
    body: []u8 = &.{},

    fn deinit(self: *RecordingTransport) void {
        self.gpa.free(self.body);
    }

    fn sendImpl(
        t: *BmcTransport,
        arena: std.mem.Allocator,
        request: bmc.RawRequest,
    ) anyerror!bmc.RawResponse {
        const self: *RecordingTransport = @fieldParentPtr("transport", t);
        self.method = request.method;
        self.uri = try arena.dupe(u8, request.uri);
        self.content_type = try arena.dupe(u8, request.content_type);

        switch (request.body) {
            .bytes => |bytes| {
                self.gpa.free(self.body);
                self.body = try self.gpa.dupe(u8, bytes);
                self.declared_len = bytes.len;
            },
            .stream => |source| {
                self.declared_len = source.len;

                var out: std.Io.Writer.Allocating = .init(self.gpa);
                defer out.deinit();
                _ = try source.reader.streamRemaining(&out.writer);

                self.gpa.free(self.body);
                self.body = try self.gpa.dupe(u8, out.written());
            },
        }

        return .{
            .status = self.reply.status,
            .headers = self.reply.headers,
            .body = try arena.dupe(u8, self.reply.body),
        };
    }
};

const Task = struct {
    @"@odata.id": []const u8,
    TaskState: []const u8,
};

test "a multipart update sends both parts and a measured body" {
    var bmc_double: RecordingTransport = .{
        .gpa = testing.allocator,
        .reply = .{
            .status = 202,
            .headers = .{ .entries = &.{
                .{ .name = "Location", .value = "/redfish/v1/TaskService/Tasks/1" },
            } },
        },
    };
    defer bmc_double.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");
    var prng: std.Random.DefaultPrng = .init(1);

    var result = try multipartUpdate(
        Task,
        testing.allocator,
        &bmc_double.transport,
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{ .Targets = [_][]const u8{"/redfish/v1/UpdateService/FirmwareInventory/BMC"} },
        .{ .name = "firmware.bin", .reader = &image, .len = "firmware-bytes".len },
        &.{},
        prng.random(),
    );
    defer result.deinit();

    try testing.expectEqual(bmc.Method.post, bmc_double.method);
    try testing.expectEqualStrings(
        "/redfish/v1/UpdateService/update-multipart",
        bmc_double.uri,
    );
    try testing.expect(std.mem.startsWith(
        u8,
        bmc_double.content_type,
        "multipart/form-data; boundary=",
    ));

    try testing.expect(std.mem.indexOf(u8, bmc_double.body, "name=\"UpdateParameters\"") != null);
    try testing.expect(std.mem.indexOf(u8, bmc_double.body, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        bmc_double.body,
        "{\"Targets\":[\"/redfish/v1/UpdateService/FirmwareInventory/BMC\"]}",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        bmc_double.body,
        "name=\"UpdateFile\"; filename=\"firmware.bin\"",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, bmc_double.body, "firmware-bytes") != null);

    // Every part had a length, so the request could declare one.
    try testing.expectEqual(@as(?u64, bmc_double.body.len), bmc_double.declared_len);

    // 202 with a Location is the normal answer to an accepted image.
    try testing.expectEqualStrings(
        "/redfish/v1/TaskService/Tasks/1",
        result.value.task.location.value.value,
    );
}

test "an image of unknown length leaves the body unmeasured" {
    var bmc_double: RecordingTransport = .{ .gpa = testing.allocator };
    defer bmc_double.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");
    var prng: std.Random.DefaultPrng = .init(1);

    var result = try multipartUpdate(
        Task,
        testing.allocator,
        &bmc_double.transport,
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{},
        .{ .name = "firmware.bin", .reader = &image },
        &.{},
        prng.random(),
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u64, null), bmc_double.declared_len);
    try testing.expect(std.mem.indexOf(u8, bmc_double.body, "firmware-bytes") != null);
}

test "OEM parts are appended after the required ones" {
    var bmc_double: RecordingTransport = .{ .gpa = testing.allocator };
    defer bmc_double.deinit();

    var image: std.Io.Reader = .fixed("image");
    var oem: std.Io.Reader = .fixed("vendor-blob");
    var prng: std.Random.DefaultPrng = .init(1);

    var result = try multipartUpdate(
        Task,
        testing.allocator,
        &bmc_double.transport,
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{},
        .{ .name = "firmware.bin", .reader = &image, .len = 5 },
        &.{.{
            .name = "OemVendorManifest",
            .reader = &oem,
            .content_type = "application/json",
            .len = "vendor-blob".len,
        }},
        prng.random(),
    );
    defer result.deinit();

    const file_at = std.mem.indexOf(u8, bmc_double.body, "name=\"UpdateFile\"").?;
    const oem_at = std.mem.indexOf(u8, bmc_double.body, "name=\"OemVendorManifest\"").?;
    try testing.expect(file_at < oem_at);
    try testing.expect(std.mem.indexOf(u8, bmc_double.body, "vendor-blob") != null);
}

test "an OEM part not named Oem is refused before anything is sent" {
    var bmc_double: RecordingTransport = .{ .gpa = testing.allocator };
    defer bmc_double.deinit();

    var image: std.Io.Reader = .fixed("image");
    var oem: std.Io.Reader = .fixed("blob");
    var prng: std.Random.DefaultPrng = .init(1);

    try testing.expectError(Error.InvalidOemPartName, multipartUpdate(
        Task,
        testing.allocator,
        &bmc_double.transport,
        .init("/redfish/v1/UpdateService/update-multipart"),
        .{},
        .{ .name = "firmware.bin", .reader = &image, .len = 5 },
        &.{.{ .name = "VendorManifest", .reader = &oem }},
        prng.random(),
    ));

    try testing.expectEqual(bmc.Method.get, bmc_double.method);
    try testing.expectEqualStrings("", bmc_double.body);
}

test "a raw push sends the image with no envelope" {
    var bmc_double: RecordingTransport = .{
        .gpa = testing.allocator,
        .reply = .{
            .status = 202,
            .headers = .{ .entries = &.{
                .{ .name = "Location", .value = "/redfish/v1/TaskService/Tasks/2" },
            } },
        },
    };
    defer bmc_double.deinit();

    var image: std.Io.Reader = .fixed("firmware-bytes");

    var result = try httpPushUriUpdate(
        Task,
        testing.allocator,
        &bmc_double.transport,
        .init("/redfish/v1/UpdateService/FirmwareInventory"),
        &image,
        "firmware-bytes".len,
    );
    defer result.deinit();

    try testing.expectEqual(bmc.Method.post, bmc_double.method);
    try testing.expectEqualStrings("application/octet-stream", bmc_double.content_type);
    try testing.expectEqualStrings("firmware-bytes", bmc_double.body);
    try testing.expectEqual(@as(?u64, "firmware-bytes".len), bmc_double.declared_len);
    try testing.expectEqualStrings(
        "/redfish/v1/TaskService/Tasks/2",
        result.value.task.location.value.value,
    );
}

test "an OEM part name is validated against the prefix" {
    var reader: std.Io.Reader = .fixed("");
    try testing.expect((OemPart{ .name = "Oem", .reader = &reader }).isNameValid());
    try testing.expect((OemPart{ .name = "OemAcme", .reader = &reader }).isNameValid());
    try testing.expect(!(OemPart{ .name = "oem", .reader = &reader }).isNameValid());
    try testing.expect(!(OemPart{ .name = "Vendor", .reader = &reader }).isNameValid());
    try testing.expect(!(OemPart{ .name = "", .reader = &reader }).isNameValid());
}
