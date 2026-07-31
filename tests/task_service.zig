//! The task a `202` left behind, and what polling one costs.
//!
//! Ports `nv-redfish`'s `test-task-service.rs`, which is one test doing three
//! things: refusing two task locations, accepting a third, and reading the
//! fields off it. The reading is ported straight. The refusing is ported as
//! the absence of the refusal, and that is the argument this file is really
//! about — see the second test.
//!
//! The third test is not a port. Nothing in this suite polls a task to
//! completion through the monitor the service names, which is the whole of
//! what `202 Accepted` buys and the reason `AsyncTask` carries a
//! `Retry-After` at all. `examples/firmware_push.zig` polls the `Task`
//! *resource*, which is the other half and is a different request.
//!
//! No polling loop went into the library. It cannot: honouring a
//! `Retry-After` means sleeping, sleeping needs an `std.Io`, and nothing in
//! `redfish_core` or `redfish` takes one — the transport is synchronous by
//! design and concurrency is the caller's. Everything else about a poll is
//! policy the caller owns: how long to keep trying, what to do with a task
//! the service has expired, and which `TaskState` values it treats as final,
//! which is not the same set for every caller. `Service` is a running-as-a-
//! service task that never finishes, and `Suspended` is finished for some
//! callers and not for others.

const std = @import("std");
const core = @import("redfish_core");
const mock = @import("redfish_bmc_mock");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const testing = std.testing;

const Service = redfish.Service(schema.service_root.ServiceRoot);
const Task = schema.task.Task;
const TaskCollection = schema.task_collection.TaskCollection;

const task_service_uri = "/redfish/v1/TaskService";
const tasks_uri = "/redfish/v1/TaskService/Tasks";
const task_uri = "/redfish/v1/TaskService/Tasks/42";

/// The root links the task service under `Tasks`, not `TaskService`: the
/// property is named for what it points at in the collection sense, and the
/// resource it names is the service.
const root_body =
    \\{"@odata.id":"/redfish/v1",
    \\ "@odata.type":"#ServiceRoot.v1_13_0.ServiceRoot",
    \\ "Id":"RootService","Name":"Root Service",
    \\ "Tasks":{"@odata.id":"/redfish/v1/TaskService"},
    \\ "UpdateService":{"@odata.id":"/redfish/v1/UpdateService"}}
;

const task_service_body =
    \\{"@odata.id":"/redfish/v1/TaskService",
    \\ "@odata.type":"#TaskService.v1_1_4.TaskService",
    \\ "Id":"TaskService","Name":"Task Service","ServiceEnabled":true,
    \\ "CompletedTaskOverWritePolicy":"Oldest",
    \\ "Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
;

test "a task read through the service that keeps it" {
    // `task_link_fetch_exposes_schema_fields`, the half that fetches. A task
    // is a resource in a collection like any other, so the walk is the walk
    // every other collection gets; what is particular to `Task` is that three
    // of its properties are the only progress a caller ever sees.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get(task_service_uri, task_service_body),
        mock.Expect.get(tasks_uri,
            \\{"@odata.id":"/redfish/v1/TaskService/Tasks",
            \\ "@odata.type":"#TaskCollection.TaskCollection",
            \\ "Name":"Task Collection",
            \\ "Members":[{"@odata.id":"/redfish/v1/TaskService/Tasks/42"}]}
        ),
        mock.Expect.get(task_uri,
            \\{"@odata.id":"/redfish/v1/TaskService/Tasks/42",
            \\ "@odata.type":"#Task.v1_4_3.Task","Id":"42","Name":"Task 42",
            \\ "TaskState":"Running","TaskStatus":"OK","PercentComplete":55,
            \\ "Messages":[{"MessageId":"Base.1.0.TaskMessage",
            \\              "Message":"Task message."}]}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const task_service = try service.open("Tasks");
    defer task_service.deinit();
    try testing.expectEqual(
        schema.task_service.OverWritePolicy.Oldest,
        task_service.get().CompletedTaskOverWritePolicy.?,
    );

    const link = task_service.get().Tasks orelse return error.NoTasks;
    var walker: core.Walker(TaskCollection) = .init(
        testing.allocator,
        &bmc.transport,
        link.odataId() orelse return error.NotAddressable,
    );
    defer walker.deinit();

    const member = (try walker.next()) orelse return error.NoMembers;
    const task = try core.follow(Task, testing.allocator, &bmc.transport, member);
    defer task.deinit();

    try testing.expectEqual(schema.task.TaskState.Running, task.get().TaskState.?);
    try testing.expectEqual(schema.resource.Health.OK, task.get().TaskStatus.?);
    try testing.expectEqual(@as(i64, 55), task.get().PercentComplete.?);
    try testing.expectEqualStrings("Task message.", task.get().Messages.?[0].Message.?);
    try bmc.verify();
}

test "a task monitor the service put outside its own collection" {
    // The half of `task_link_fetch_exposes_schema_fields` that refuses.
    // `nv-redfish` validates the `Location` of a `202` against the task
    // service's own `Tasks` collection and errors when it does not name a
    // member of it, and its own test supplies the case that shows the cost:
    // an iDRAC answers with `/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/
    // Jobs/1`, and the client refuses to poll it.
    //
    // Nothing refuses it here, and that is deliberate. DSP0266 puts a *task
    // monitor* in the `Location` header, whose URI the service chooses and
    // which it does not have to make a member of the tasks collection; `Task`
    // even has a `TaskMonitor` property saying so. The Dell job is a legal
    // answer, and a client that will not follow it has lost the operation it
    // just started for a rule the specification does not make.
    //
    // This is the near-inverse of `viking_with_garbage_in_computer_systems`,
    // where the same evidence — an id that is not under the collection —
    // *was* worth acting on, and the difference is who produced it. A
    // collection listing a member from elsewhere is the service being wrong
    // about its own contents. A `Location` is the service answering the
    // question the client asked, at an address of its choosing.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const job_uri = "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/Jobs/JID_1";
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.patchAccepted("/redfish/v1/Systems/1",
            \\{"AssetTag":"tray-4"}
        , job_uri, 30),
        mock.Expect.get(job_uri,
            \\{"@odata.id":"/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/Jobs/JID_1",
            \\ "@odata.type":"#DellJob.v1_4_0.DellJob","Id":"JID_1",
            \\ "Name":"Configure: Import Server Configuration Profile",
            \\ "JobState":"Running","PercentComplete":18}
        ),
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const accepted = try core.bmc.update(
        schema.computer_system.ComputerSystem,
        testing.allocator,
        &bmc.transport,
        .init("/redfish/v1/Systems/1"),
        null,
        schema.computer_system.ComputerSystemUpdate{ .AssetTag = .init("tray-4") },
    );
    defer accepted.deinit();

    const task = accepted.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqualStrings(job_uri, task.location.value.value);
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), task.retryAfterNanoseconds().?);

    // Read as a `Task`, because that is what the client was told to poll.
    // Dell's job spells its state `JobState`, so `TaskState` is absent and a
    // caller sees exactly that: no state, rather than a wrong one.
    const polled = try core.bmc.get(Task, testing.allocator, &bmc.transport, task.location.value);
    defer polled.deinit();

    try testing.expect(polled.value.TaskState == null);
    try testing.expectEqualStrings("JID_1", polled.value.Id.?);
    try testing.expectEqual(@as(i64, 18), polled.value.PercentComplete.?);

    // Three requests: the root, the write, and the poll. Nothing was spent
    // asking the task service whether the address it was handed was one it
    // would have chosen.
    try testing.expectEqual(@as(usize, 3), bmc.requestCount());
    try bmc.verify();
}

const simple_update_target =
    "/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate";

const simple_update_request =
    \\{"ImageURI":"https://images.example/bmc-2.14.bin","TransferProtocol":"HTTPS"}
;

const completed_task =
    \\{"@odata.id":"/redfish/v1/TaskService/Tasks/42",
    \\ "@odata.type":"#Task.v1_4_3.Task","Id":"42","Name":"Task 42",
    \\ "TaskState":"Completed","TaskStatus":"OK","PercentComplete":100,
    \\ "Messages":[{"MessageId":"Update.1.0.UpdateSuccessful",
    \\              "Message":"Device 'BMC' successfully updated."}]}
;

test "an update that says come back in five seconds, and then in one" {
    // Not a port: no reference test polls a monitor. This is what the `202`
    // path is for, end to end — an action the service cannot finish while the
    // client waits, a monitor to ask, and a `Retry-After` that the service
    // revises downward as the work nears its end.
    //
    // The loop is here rather than in the library, and reads the hint again
    // on every answer rather than once. A service that says five seconds and
    // then one is telling the client something it did not know at the start,
    // and a client that paced itself off the first hint would still be
    // sleeping when the update finished.
    var bmc: mock.MockBmc = .init(testing.allocator);
    defer bmc.deinit();

    const monitor_uri = "/redfish/v1/TaskService/Tasks/42/Monitor";
    try bmc.expectAll(&.{
        mock.Expect.get("/redfish/v1", root_body),
        mock.Expect.get("/redfish/v1/UpdateService",
            \\{"@odata.id":"/redfish/v1/UpdateService",
            \\ "@odata.type":"#UpdateService.v1_15_0.UpdateService",
            \\ "Id":"UpdateService","Name":"Update Service",
            \\ "Actions":{"#UpdateService.SimpleUpdate":{
            \\   "target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}}}
        ),
        .{ .request = .{
            .match = .{
                .method = .post,
                .uri = .{ .exact = simple_update_target },
                .body = .{ .json = simple_update_request },
            },
            .reply = .{ .response = .{
                .status = 202,
                .location = monitor_uri,
                .retry_after = 5,
            } },
        } },
        // Still working, and with no body at all -- which DSP0266 allows and
        // a plain `get` would have reported as a missing response body.
        .{ .request = .{
            .match = .{ .method = .get, .uri = .{ .exact = monitor_uri } },
            .reply = .{ .response = .{ .status = 202, .retry_after = 1 } },
        } },
        .{ .request = .{
            .match = .{ .method = .get, .uri = .{ .exact = monitor_uri } },
            .reply = .{ .response = .{ .body = completed_task } },
        } },
    });

    const service = try Service.connect(testing.allocator, &bmc.transport);
    defer service.deinit();

    const update_service = try service.open("UpdateService");
    defer update_service.deinit();

    const started = try update_service.get().Actions.?.simpleUpdate(
        testing.allocator,
        &bmc.transport,
        .{
            .ImageURI = "https://images.example/bmc-2.14.bin",
            .TransferProtocol = .HTTPS,
        },
    );
    defer started.deinit();

    const accepted = started.value.taskOrNull() orelse return error.NotATask;
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), accepted.retryAfterNanoseconds().?);

    // The monitor is polled at the URI the caller already holds, so nothing
    // in the loop borrows from a response it then frees. Only the pacing hint
    // crosses a round, and a `Duration` is a value. The result does not: it
    // is read inside the branch that has it, while its arena is alive.
    var wait = accepted.retryAfterNanoseconds().?;
    var rounds: usize = 0;
    var completed = false;
    while (rounds < 4 and !completed) : (rounds += 1) {
        // A real caller sleeps `wait` here. This one checks what it was told
        // instead, because a test that waited six seconds is a test nobody
        // runs.
        const polled = try core.bmc.pollTask(
            Task,
            testing.allocator,
            &bmc.transport,
            accepted.location.value,
        );
        defer polled.deinit();

        switch (polled.value) {
            .task => |pending| {
                wait = pending.retryAfterNanoseconds() orelse wait;
                // No `Location` on the poll, so the monitor stayed put.
                try testing.expectEqualStrings(monitor_uri, pending.location.value.value);
            },
            .entity => |task| {
                try testing.expectEqual(schema.task.TaskState.Completed, task.TaskState.?);
                try testing.expectEqual(@as(i64, 100), task.PercentComplete.?);
                try testing.expectEqualStrings(
                    "Device 'BMC' successfully updated.",
                    task.Messages.?[0].Message.?,
                );
                completed = true;
            },
            .empty => return error.MonitorReturnedNothing,
        }
    }

    try testing.expect(completed);
    try testing.expectEqual(@as(u64, std.time.ns_per_s), wait);

    // Two polls, not four: the second answer was the result, and a caller
    // that kept reading would eventually be told the task no longer exists.
    try testing.expectEqual(@as(usize, 2), rounds);
    try bmc.verify();
}
