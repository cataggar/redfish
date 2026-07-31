# redfish

> **⚠️ Experimental** — under construction, and the API is not yet stable.

A modular Redfish BMC client stack for Zig 0.16, in pure Zig — no C
dependencies.

The design follows [`nv-redfish`](https://github.com/NVIDIA/nv-redfish): a
CSDL/OData compiler turns DMTF and vendor schemas into typed Zig source, and a
small transport abstraction keeps HTTP out of the schema layer. Where the
reference project adds a wrapper module per Redfish service, this one does not:
a generated `ServiceRoot` already names every subordinate service with a typed
link, so what sits on top is only the handful of decisions that are easy to get
wrong.

## Modules

| Module | Path | Role |
| --- | --- | --- |
| `redfish_core` | `core/` | Transport-agnostic primitives: `ODataId`, `ODataETag`, `NavProperty(T)`, `Action(T, R)`, `ModificationResponse(T)`, EDM value types, `$expand`/`$filter` builders, and the `BmcTransport` interface. No HTTP. |
| `redfish_bmc_http` | `bmc_http/` | `BmcTransport` over `std.http.Client`: basic and `X-Auth-Token` credentials, ETag caching, conditional requests, SSE, multipart firmware push. |
| `redfish_bmc_mock` | `bmc_mock/` | Expectation-based test BMC used by the test suite and examples. |
| `redfish-codegen` | `codegen/` | CSDL/EDMX compiler and Zig emitter. Reads Redfish, Swordfish, and OEM schemas, resolves inheritance and references, prunes to the reachable surface, and writes a Zig package. |
| `redfish_schema_*` | `schema_packages/` | Checked-in generator output, one package per profile. |
| `redfish` | `redfish/` | High-level API over the generated types: the service root, what the service says it supports, and links followed rather than URIs guessed. |
| — | `tests/` | 251 responses recorded from DMTF's published mockups, deserialized into the generated types, plus the integration suite ported from the reference project's. See [`tests/README.md`](tests/README.md). |
| — | `examples/` | Seven worked programs, each run against the mock BMC by the test suite. See [`examples/README.md`](examples/README.md). |

## Use it in your project

```sh
zig fetch --save=redfish git+https://github.com/cataggar/redfish
```

The package is called `redfish_workspace`, because that is what it is, so
`--save=redfish` is what makes the rest of this read the way you want. The
fetch resolves the default branch to a commit and pins it:

```zig
.dependencies = .{
    .redfish = .{
        .url = "git+https://github.com/cataggar/redfish#b0c6278b0ec7d31408b54e63e2bb3d029f393edb",
        .hash = "redfish_workspace-0.1.0-RQ--FoZ9VQCS1pvQrRw2X7LVDrHStad3JR872ujd1MWW",
    },
},
```

Every module hangs off that one dependency. Name the ones your own code
imports; the rest cost nothing:

```zig
const dep = b.dependency("redfish", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "probe",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "redfish_core", .module = dep.module("redfish_core") },
            .{ .name = "redfish_bmc_http", .module = dep.module("redfish_bmc_http") },
            .{ .name = "redfish", .module = dep.module("redfish") },
            .{ .name = "redfish_schema_std", .module = dep.module("redfish_schema_std") },
        },
    }),
});
```

`redfish_bmc_mock` is named the same way, and so is any OEM package —
`dep.module("redfish_schema_oem_delta")`. Each generated package under
`schema_packages/` carries a `build.zig.zon` of its own, but its dependencies
are relative paths inside this repository, so a consumer selects one by naming
its module here rather than fetching it separately.

What that costs, measured rather than assumed:

- Under a megabyte fetched. The 44 MB of DMTF and SNIA CSDL are lazy
  dependencies of `generate` and are **not** fetched by a consumer's build,
  `zig build --fetch` included. `serde` resolves transitively and is 128 KB.
- Importing `redfish_schema_std` is free; parsing through it is not. A first
  Debug build of the program below took about 30 seconds longer than the same
  program without it, and naming a generated type without deserializing one
  cost nothing measurable. That time is the compiler instantiating
  `std.json` over `ServiceRoot` and `Chassis`, it is paid per type you
  actually parse, and it is cached afterwards.

## Getting started

A whole program — [`examples/readme.zig`](examples/readme.zig), which a test
keeps identical to what you see here:

```zig
const std = @import("std");
const core = @import("redfish_core");
const http = @import("redfish_bmc_http");
const redfish = @import("redfish");
const schema = @import("redfish_schema_std");

const Service = redfish.Service(schema.service_root.ServiceRoot);

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var bmc: http.HttpBmc = try .init(init.gpa, &client, "https://bmc.example", .{
        .credentials = .initBasic("root", "calvin"),
    });
    defer bmc.deinit();

    try run(init.gpa, bmc.asTransport(), out);
    return 0;
}

fn run(gpa: std.mem.Allocator, transport: *core.BmcTransport, out: *std.Io.Writer) !void {
    const service = try Service.connect(gpa, transport);
    defer service.deinit();

    try out.print("{s} {s}\n", .{
        service.vendor() orelse "?",
        service.product() orelse "?",
    });

    var chassis = try service.walk("Chassis");
    defer chassis.deinit();

    while (try chassis.next()) |link| {
        const one = try core.follow(schema.chassis.Chassis, gpa, transport, link);
        defer one.deinit();
        try out.print("  {s}\n", .{one.get().Name orelse "?"});
    }
}
```

`run` takes a `*core.BmcTransport` rather than a URL, so the same code runs
against `redfish_bmc_mock` in a test — which is how every example here is
checked. See [`examples/README.md`](examples/README.md).

Two things in that loop are doing more than they look:

- `walk` returns members across page boundaries. A Redfish collection is not
  necessarily all of itself — a service may answer with one page and a
  `Members@odata.nextLink` — and nothing else in the response distinguishes
  that from the whole collection.
- `follow` fetches the chassis only if the service did not already send it.
  Add `$expand` to the request and the same loop stops making those requests,
  with no other change.

[`doc/guide.md`](doc/guide.md) is the rest of what a caller needs: `Owned(T)`
against `Resolved(T)` and which one borrows, what this client tolerates and
what that tolerance can cost you, when to reach for `core.oem.parse`, and why
there is no async.

## Schema packages

`schema_packages/redfish_schema_std` is the whole of Redfish and Swordfish,
generated from pinned DMTF and SNIA corpora and committed. Import it and use
what you need: Zig analyzes a declaration only when something references it,
so naming one type does not cost you the other thirteen hundred.

The types are checked against real traffic, not just against the compiler that
wrote them: every one of DMTF's 3,780 published mockups is swept against the
package, and 251 of them — one per type — are committed under `tests/` so
`zig build test` re-checks them. 3,775 parse. The three that do not are
defects in the recorded payloads, and `tests/README.md` says which and why.

Vendor extensions get their own package, because nothing in the standard
corpus names an OEM type, which makes them unreachable rather than merely
unused. There are ten: DMTF's fictional `redfish_schema_oem_contoso`, and nine
real vendors whose CSDL is vendored under `schema/oem/` — AMI, Dell, Delta,
HPE, Lenovo, LiteOn, NVIDIA (baseboard and BlueField) and Supermicro.

An OEM package holds only what the vendor adds; every standard type it refers
to comes from `redfish_schema_std`, which it depends on rather than copies.
All nine real vendors' packages together are 956 lines. Re-emitting the
standard types they reach would have made one of them 63,396 lines on its own,
and — worse — a different Zig type from the standard one.

[`examples/power_shelf.zig`](examples/power_shelf.zig) reads two of them end to
end, and is the shortest honest answer to what a vendor costs a caller: two
constants and two short functions, because Delta and LiteOn answer the same
question in two different places and only one of them can be discovered.

`zig build -Dcorpora generate` rebuilds every package in place, on Linux; CI
regenerates and diffs, so what is committed is what the generator produces.

**There are no per-service build options, and no per-service wrappers.** The
reference project gates each wrapper behind a Cargo feature because a Rust
crate pays to compile every item it declares; Zig analyzes a declaration only
when something references it, so naming one type costs you nothing for the
other thirteen hundred. There is nothing to gate.

## Design notes

- **Synchronous.** Zig 0.16 has no `async`/`await`. Operations block and take
  an `io: std.Io`. This is a deliberate deviation from the async Rust API.
- **Arena-owned responses.** Reads return `Owned(T)`, a value plus the arena
  that owns its entire tree. One `deinit()` frees everything.
- **Byte-oriented transport.** `BmcTransport` is a function-pointer struct;
  typed access is generic free functions layered over it.

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Workspace, conventions, CI | done |
| 1 | `redfish_core` primitives | done |
| 2 | `redfish_bmc_http` | done — transport, credentials, ETag cache, SSE, uploads |
| 3 | `redfish-codegen` | done — CSDL reader, compiler, optimizer, emitter |
| 4 | Generated schema packages | done — standard and ten OEM packages, with a recorded-payload suite |
| 5 | `redfish` high-level module | done — service root, features, paging, quirks, deferred writes, session login |
| 6 | Mock BMC, examples, integration tests | done — the mock, seven worked examples, and the reference project's service and OEM suite ported onto it |
| 7 | `redfish_dispatcher` | not planned — the reference's is built on `Future`s and boxed async work, which Zig 0.16 has no counterpart for; a caller that wants concurrency owns its own threads |

## License

Apache-2.0 — see [LICENSE](LICENSE).

This project consumes Redfish schema files from DMTF's
[Redfish-Publications](https://github.com/DMTF/Redfish-Publications) and
Swordfish schema files from SNIA's
[Swordfish-Publications](https://github.com/SNIA/Swordfish-Publications),
both licensed under BSD-3-Clause.
