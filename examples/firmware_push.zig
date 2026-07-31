//! `firmware_push` — send an image to `UpdateService` and watch the task.
//!
//! ```
//! firmware_push --bmc https://bmc.example --username root --password calvin \
//!     --image bmc-2.14.bin --target /redfish/v1/UpdateService/FirmwareInventory/BMC
//! ```
//!
//! Two things here are not like the rest of the client.
//!
//! The image is a `*std.Io.Reader`, never a slice. A firmware image runs to
//! hundreds of megabytes and the multipart form is written straight from the
//! file, so the program's memory does not scale with the image.
//!
//! The push does not finish when the request does. A service answers `202
//! Accepted` with a `Location` naming a task, and the update proceeds without
//! the connection — which is why this program has a polling loop and why
//! `ModificationResponse` has a `task` case at all. A client that treated the
//! `202` as success would report a firmware update that had not happened yet.

const std = @import("std");
const core = @import("redfish_core");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const cli = @import("cli.zig");

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Task = schema.task.Task;

pub const usage =
    \\firmware_push — push a firmware image and follow the resulting task.
    \\
    \\Usage:
    \\  firmware_push --bmc <url> --image <path> [--username <name>]
    \\                [--password <secret>] [--target <uri>] [--polls <n>]
    \\
    \\  --bmc <url>        Required, e.g. https://bmc.example.
    \\  --image <path>     Required. The image to push.
    \\  --target <uri>     A FirmwareInventory member to update. Repeat is not
    \\                     supported here; a service that needs several takes
    \\                     them in UpdateParameters.Targets.
    \\  --polls <n>        How many times to read the task. Default 1.
    \\  -h, --help         This message.
    \\
;

/// The `UpdateParameters` JSON part.
///
/// A struct rather than a generated type because that is what it is: DSP0266
/// defines the part's content inline, and no CSDL entity describes it.
pub const UpdateParameters = struct {
    Targets: ?[]const []const u8 = null,
    @"@Redfish.OperationApplyTime": ?[]const u8 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
    out: *std.Io.Writer,
    image: core.upload.UpdateFile,
    parameters: UpdateParameters,
    random: std.Random,
    polls: usize,
) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    const update = try service.open("UpdateService");
    defer update.deinit();

    const push_uri = update.get().MultipartHttpPushUri orelse {
        // `HttpPushUri` was deprecated in Redfish 1.6 and is still all that
        // many fielded BMCs implement. It takes the image as the whole body,
        // so there is nowhere to put parameters -- see
        // `core.upload.httpPushUriUpdate`.
        try out.writeAll("this service offers no MultipartHttpPushUri\n");
        return;
    };

    try out.print("pushing {s} to {s}\n", .{ image.name, push_uri });

    const pushed = try core.upload.multipartUpdate(
        Task,
        gpa,
        transport,
        .{ .value = push_uri },
        parameters,
        image,
        &.{},
        random,
    );
    defer pushed.deinit();

    const task = pushed.value.taskOrNull() orelse {
        // A service that answers the push synchronously has already applied
        // it, which is unusual enough to be worth saying out loud.
        try out.writeAll("service completed the update without a task\n");
        return;
    };

    try out.print("task at {f}\n", .{task.location});

    var poll: usize = 0;
    while (poll < polls) : (poll += 1) {
        const state = try core.bmc.get(Task, gpa, transport, task.location.value);
        defer state.deinit();
        try describe(state.value, poll, out);
        if (finished(state.value)) break;
    }
}

fn describe(task: Task, poll: usize, out: *std.Io.Writer) !void {
    try out.print("poll {d}:", .{poll + 1});
    if (task.TaskState) |value| try out.print(" state={t}", .{value});
    if (task.TaskStatus) |value| try out.print(" status={t}", .{value});
    if (task.PercentComplete) |value| try out.print(" {d}%", .{value});
    try out.writeByte('\n');

    for (task.Messages orelse &.{}) |message| {
        try out.print("  {s}\n", .{message.Message orelse message.MessageId orelse continue});
    }
}

/// Whether the task has reached a state it will not leave.
///
/// Polling past this is not merely wasteful: a service is allowed to expire a
/// completed task, so a loop that keeps reading one eventually gets a 404 and
/// reports a failure that did not happen.
fn finished(task: Task) bool {
    const state = task.TaskState orelse return false;
    return switch (state) {
        .Completed, .Killed, .Exception, .Cancelled => true,
        else => false,
    };
}

/// A seed for the boundary generator.
///
/// The wall clock, because a form boundary needs only to be a string the
/// parts do not contain — it is not a secret and nothing authenticates with
/// it. `redfish_core` takes no `std.Io` and so cannot read a clock itself,
/// which is why `multipartUpdate` asks the caller for the randomness.
fn seed(io: std.Io) u64 {
    return @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .real).nanoseconds)));
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const argv = try cli.arguments(arena, init);
    if (cli.present(argv, "help") or cli.present(argv, "h")) {
        try out.writeAll(usage);
        return 0;
    }

    const url = cli.flag(argv, "bmc") orelse "";
    const path = cli.flag(argv, "image") orelse "";
    if (url.len == 0 or path.len == 0) {
        try out.writeAll("firmware_push: --bmc and --image are required\n\n" ++ usage);
        return 2;
    }

    const polls: usize = if (cli.flag(argv, "polls")) |text|
        std.fmt.parseInt(usize, text, 10) catch 1
    else
        1;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var image_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &image_buffer);

    var targets: [1][]const u8 = undefined;
    const parameters: UpdateParameters = if (cli.flag(argv, "target")) |target| blk: {
        targets[0] = target;
        break :blk .{ .Targets = targets[0..1] };
    } else .{};

    var connection: cli.Connection = undefined;
    try connection.open(init.gpa, io, url, cli.credentialsFrom(argv));
    defer connection.close();

    var prng: std.Random.DefaultPrng = .init(seed(io));

    try run(init.gpa, connection.transport(), out, .{
        .name = std.fs.path.basename(path),
        .reader = &file_reader.interface,
        .len = (try file.stat(io)).size,
    }, parameters, prng.random(), polls);
    return 0;
}

// -- Tests ------------------------------------------------------------------

const mock = @import("redfish_bmc_mock");
const testing = std.testing;

const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_18_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService"}}
;

const update_service_body =
    \\{"@odata.id":"/redfish/v1/UpdateService",
    \\ "@odata.type":"#UpdateService.v1_15_0.UpdateService",
    \\ "Id":"UpdateService","Name":"Update service",
    \\ "HttpPushUri":"/redfish/v1/UpdateService/update",
    \\ "MultipartHttpPushUri":"/redfish/v1/UpdateService/update-multipart"}
;

/// The push, matched on method and URI alone; see `Expect.multipartPush`.
fn pushAccepted(task: []const u8) mock.Expect {
    return mock.Expect.multipartPush(
        "/redfish/v1/UpdateService/update-multipart",
        .{ .status = 202, .location = task },
    );
}

test "the example pushes an image and follows the task to completion" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/UpdateService", update_service_body),
        pushAccepted("/redfish/v1/TaskService/Tasks/545"),
        mock.Expect.get("/redfish/v1/TaskService/Tasks/545",
            \\{"@odata.id":"/redfish/v1/TaskService/Tasks/545",
            \\ "@odata.type":"#Task.v1_7_4.Task","Id":"545","Name":"Task 545",
            \\ "TaskState":"Running","TaskStatus":"OK","PercentComplete":20}
        ),
        mock.Expect.get("/redfish/v1/TaskService/Tasks/545",
            \\{"@odata.id":"/redfish/v1/TaskService/Tasks/545",
            \\ "@odata.type":"#Task.v1_7_4.Task","Id":"545","Name":"Task 545",
            \\ "TaskState":"Completed","TaskStatus":"OK","PercentComplete":100,
            \\ "Messages":[{"MessageId":"Update.1.0.UpdateSuccessful",
            \\              "Message":"Device 'BMC' successfully updated."}]}
        ),
    });

    var image: std.Io.Reader = .fixed("firmware-image-bytes");
    var prng: std.Random.DefaultPrng = .init(0);

    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(
        testing.allocator,
        &bmc.transport,
        &out,
        .{ .name = "bmc-2.14.bin", .reader = &image, .len = "firmware-image-bytes".len },
        .{ .Targets = &.{"/redfish/v1/UpdateService/FirmwareInventory/BMC"} },
        prng.random(),
        4,
    );

    try testing.expectEqualStrings(
        \\pushing bmc-2.14.bin to /redfish/v1/UpdateService/update-multipart
        \\task at /redfish/v1/TaskService/Tasks/545
        \\poll 1: state=Running status=OK 20%
        \\poll 2: state=Completed status=OK 100%
        \\  Device 'BMC' successfully updated.
        \\
    , out.buffered());

    // Four polls were allowed and two were spent: the loop stops at a state
    // the task will not leave, rather than reading a task the service is
    // entitled to have expired.
    const push = bmc.request(2);
    try testing.expect(std.mem.startsWith(u8, push.content_type, "multipart/form-data; boundary="));
    try testing.expect(std.mem.indexOf(u8, push.body, "firmware-image-bytes") != null);
    try testing.expect(std.mem.indexOf(u8, push.body, "name=\"UpdateParameters\"") != null);
    try testing.expect(std.mem.indexOf(u8, push.body, "filename=\"bmc-2.14.bin\"") != null);
    try testing.expect(std.mem.indexOf(u8, push.body, "FirmwareInventory/BMC") != null);

    try bmc.verify();
}

test "a service with no multipart push URI says so rather than guessing" {
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/UpdateService",
            \\{"@odata.id":"/redfish/v1/UpdateService",
            \\ "@odata.type":"#UpdateService.v1_15_0.UpdateService",
            \\ "Id":"UpdateService","Name":"Update service",
            \\ "HttpPushUri":"/redfish/v1/UpdateService/update"}
        ),
    });

    var image: std.Io.Reader = .fixed("firmware-image-bytes");
    var prng: std.Random.DefaultPrng = .init(0);

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try run(
        testing.allocator,
        &bmc.transport,
        &out,
        .{ .name = "bmc-2.14.bin", .reader = &image, .len = null },
        .{},
        prng.random(),
        1,
    );

    try testing.expectEqualStrings(
        "this service offers no MultipartHttpPushUri\n",
        out.buffered(),
    );

    try bmc.verify();
}
