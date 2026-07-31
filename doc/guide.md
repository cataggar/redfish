# A guide to using this client

`doc/architecture.md` explains why the stack is shaped the way it is. This is
the other document: what you need to know to read a chassis and not be wrong
about what you read.

Five things. The first is a lifetime rule you will hit on your first program,
the second is the thing that can lose you an answer without an error, and the
last three are short.

Every Zig block below is a function in [`examples/guide.zig`](../examples/guide.zig),
verbatim, and a test fails if the two stop matching. The blocks marked
`// WRONG` are the exception: they are the mistakes, so they are not compiled.

## 1. `Owned(T)` owns; `Resolved(T)` might not

Two ways in, and they are not spelled the same.

**`core.bmc.get` fetches a URI.** It allocated an arena, parsed into it, and
hands you both. The value is a field.

```zig
/// `core.bmc.get` fetched it, so it owns it. The value is a field.
fn readOne(gpa: std.mem.Allocator, transport: *core.BmcTransport) !void {
    const chassis = try core.bmc.get(Chassis, gpa, transport, .init("/redfish/v1/Chassis/1"));
    defer chassis.deinit();

    std.debug.print("{s}\n", .{chassis.value.Name orelse "?"});
}
```

**`core.follow` reads a link,** and a link is not always a link. Normally it is
a bare `@odata.id` and the resource costs a `GET`; under `$expand` the service
already sent the resource inline and a `GET` would be waste. `follow` hides the
difference so that adding `$expand` to a request changes nothing else in your
program. The price of hiding it is that the value is behind a call, `get()`,
rather than a field.

```zig
/// `core.follow` may not have fetched anything, so the value is behind a
/// call. `deinit` is correct either way and is not optional.
fn readEach(gpa: std.mem.Allocator, transport: *core.BmcTransport) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, gpa, transport, link);
        defer chassis.deinit();

        std.debug.print("{s}\n", .{chassis.get().Name orelse "?"});
    }
}
```

`.value` against `.get()` is the whole of the API difference. The lifetime
difference is the part that bites.

### What borrows what

A `Walker` holds one page at a time and frees it when the walk leaves it, so a
member yielded by `next` is valid **until the next call to `next`**. That is
the same contract `std.Io.Dir.Iterator` offers for an entry's name, and it is
deliberate: a service pages a collection precisely when holding all of it at
once is a bad idea.

A `Resolved` that had to fetch owns its arena and outlives everything. A
`Resolved` for an **expanded** member does not: it points into the walker's
page. So this is a use-after-free, and it will not look like one:

```zig
// WRONG — the walker frees the page the chassis may be pointing into.
var walker = try service.walk("Chassis");
const link = (try walker.next()).?;
const chassis = try core.follow(Chassis, gpa, transport, link);
walker.deinit();
std.debug.print("{s}\n", .{chassis.get().Name orelse "?"});
```

It survives against a service that answers with bare links and segfaults
against one that expands — the same program, the same bytes on your side, a
different BMC. Order the `defer`s so the walker outlives everything taken out
of it, which is what `readEach` above does.

If you need a resource to outlive the walk, `wasFetched()` is the only thing
that can tell you whether it may:

```zig
/// Keeping one past the loop, safely.
///
/// `wasFetched` is the only thing that distinguishes a value that owns its
/// arena from one pointing into a page the walker is about to free.
fn firstFetched(
    gpa: std.mem.Allocator,
    transport: *core.BmcTransport,
) !?core.Resolved(Chassis) {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    var walker = try service.walk("Chassis");
    defer walker.deinit();

    while (try walker.next()) |link| {
        const chassis = try core.follow(Chassis, gpa, transport, link);
        if (chassis.wasFetched()) return chassis;

        // Expanded inline: it borrows the walker's page and cannot leave.
        chassis.deinit();
    }
    return null;
}
```

One more borrow, for the same reason: the `std.json.Value`s in an open struct's
`additional_properties` — everything a vendor wrote that no schema declared —
are pointers into the response arena, not copies. They die with the resource.
`core.oem.parse` is what copies them out; see §3.

## 2. Tolerance, and what it costs you

This client is deliberately hard to make fail. Every rule below exists because
a real service does the thing:

- **`Redfish.Required` is not enforced.** 177 of DMTF's own 3,778 published
  mockups omit a property their own schema marks required. Refusing those would
  be conformance testing, and this is a client. Every generated property is
  optional.
- **An enum value nobody named becomes `UnsupportedValue`.** A service running
  a newer schema will send a `ResetType` this package has never heard of. The
  string is lost, which is a real cost; the rest of the resource is not.
- **An undeclared member is never fatal.** Every read sets
  `ignore_unknown_fields`, because a BMC is free to send properties from a
  schema newer than the one the package was generated from.
- **An empty string, and an all-zero timestamp, read as *absent*** for an
  optional `Guid`, `DateTimeOffset` or `Duration`. An empty string is an
  absence spelled out loud. A *malformed* value still fails, because reading
  `"2024-13-45"` as absent would tell you the service was silent when it was
  not.

```zig
/// What a service is allowed to send, and what this client makes of it.
fn tolerate(gpa: std.mem.Allocator, body: []const u8) !void {
    const chassis = try core.parseJson(Chassis, gpa, body, null);
    defer chassis.deinit();

    // A `ChassisType` no schema names is not an error. The string is lost;
    // the rest of the resource is not.
    std.debug.assert(chassis.value.ChassisType == .UnsupportedValue);

    // An empty `Guid` reads as absent, because an empty string is an absence
    // spelled out loud. A malformed one would still fail.
    std.debug.assert(chassis.value.UUID == null);

    // `Redfish.Required` is not enforced: `Id` is required and missing, and
    // the parse succeeded anyway.
    std.debug.assert(chassis.value.Id == null);
}
```

### The cost, which is real

**A property your type does not declare is dropped in silence.** That is the
same `ignore_unknown_fields` doing the right thing for a service ahead of you
and the wrong thing for a vendor beside you, and nothing in the payload tells
the two apart.

The case to know is LiteOn. It declares `PowerState` on a type derived from
`PowerSupply` and writes it at the top level of the resource; the `Oem` bag is
not there at all. Read that resource as a standard `PowerSupply` and it parses
clean, with no error and no warning, and the only property worth reading is
gone. [`examples/power_shelf.zig`](../examples/power_shelf.zig) runs that both
ways so you can see the silence.

Two things help, and neither is automatic:

- `zig build examples && ./zig-out/bin/parse_payload <file.json>` names every
  property in a recorded response that the generated type dropped. Point it at
  a service you do not know before you trust a read of it.
- If a vendor's property is missing, look for a *derived type* in that vendor's
  schema package, not only in `Oem`.

## 3. `core.oem.parse`, and why the obvious call is wrong

A vendor extension arrives as a member of `Oem` keyed by the vendor's name, and
survives the parse as a `std.json.Value`. Getting from there to the vendor's
generated type is one call:

```zig
/// The vendor's own type, out of the bag the standard type carried.
fn vendorExtension(gpa: std.mem.Allocator, supply: *const PowerSupply) !?bool {
    const found = try core.oem.parse(
        DeltaPowerSupply,
        gpa,
        supply.Oem,
        "deltaenergysystems",
    );
    const extension = found orelse return null;
    defer extension.deinit();

    return extension.value.Power;
}
```

Writing `std.json.parseFromValue(DeltaPowerSupply, gpa, value, .{})` by hand
instead is wrong twice, and both are quiet.

`std.json`'s default is `ignore_unknown_fields = false`, the opposite of what
`core/owned.zig` sets for every read from a BMC. So the hand-written call fails
on `@odata.type` — a property every vendor writes beside its own and no vendor
CSDL declares. Your type would decode differently depending on whether it
arrived at its own URI or inside an `Oem`, which is a difference nothing about
Redfish justifies.

And the `std.json.Value` you passed in belongs to the arena of the resource you
read it out of. `core.oem.parse` returns an `Owned(T)` with an arena of its
own, so the result outlives the resource; a hand-written parse leaves you
holding freed memory the moment you release it.

Three answers, not two: `null` when there is no `Oem` or no such vendor in it,
an error when the key is there and the value does not fit. "This is not that
vendor's hardware" and "this is, and the payload is not what the schema says"
are different facts, and a caller that cannot tell them apart reads a default
where there is a defect.

The key is whatever the payload says. There is no rule from a package to its
key and no guessing: AMI's namespace is `AMIServiceRoot` and its key is `Ami`;
Delta's `Manufacturer` reads `Delta` and its key is `deltaenergysystems`. The
lookup is not case-folded either, because two vendors may sit in one bag and
decoding one vendor's object into another's type produces a value rather than
an error.

## 4. The idiom: read the type you want, tolerate what you get

There is no per-service wrapper layer here, and there will not be one. The
reference project has 11,413 lines of per-service modules; `redfish/` is four
files. That is Decision B in the plan, and it was settled by evidence rather
than taste: eight ported integration increments each looked for something a
wrapper would carry, and each found per-platform or per-caller *strategy* —
which account slot to reuse, how long to poll a task, which `TaskState` counts
as final, how to repair one vendor's boot order. None of that is knowable by a
library.

So the shape of a program here is:

1. Name the generated type you want and read it. `Service.connect`, then
   `walk` for a collection and `open` or `follow` for a link.
2. Let the tolerance rules absorb what the service got wrong, and check the
   optionals you actually need.
3. Keep vendor knowledge — the `Oem` key, the manufacturer fingerprint, the
   derived type — in your own code, next to the decision that needs it.

`examples/power_shelf.zig` is that in one file: two vendors, and the whole
vendor-specific part is two constants and two short functions.

The exceptions to "put it in the caller" are narrow, and they are all in
`core/`: parsing and protocol plumbing that is identical across every vendor
and every service. If you find yourself writing something that fits that
description, it belongs upstream. If it needs to know which vendor or which
service you are talking to, it does not.

One thing this stack *will* do for you: a *protocol* departure — a service that
advertises `$expand` and mishandles it — is a `redfish.Deviation`, and you
supply the rule. A *data* departure — a field spelled wrongly but legibly — is
not, because repairing it needs to know what you wanted.

## 5. There is no async

Zig 0.16 has no `async`/`await`. Every operation here blocks and takes an
`io: std.Io`; concurrency is yours. This is the single largest deviation from
the Rust original and it is intentional.

It is also cheap to work with, because `BmcTransport` is a function-pointer
struct with no global state. Give each thread its own transport and there is
nothing to share and nothing to lock. That is the same reason there is no
dispatcher in this repository: a work queue that happens to have BMCs in it
belongs to whoever needs one, and every policy it would encode — deadlines,
retry intervals, parallelism — is the caller's.

## Where to go next

- [`examples/README.md`](../examples/README.md) — seven programs, each run
  against the mock BMC by `zig build test`.
- [`tests/README.md`](../tests/README.md) — what 3,778 recorded DMTF payloads
  say about the schema, including the three that do not parse and why.
- [`doc/architecture.md`](architecture.md) — why the stack is shaped this way,
  and every deviation from the Rust original.
