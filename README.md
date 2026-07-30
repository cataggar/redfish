# redfish

> **⚠️ Experimental** — under construction, and the API is not yet stable.

A modular Redfish BMC client stack for Zig 0.16, in pure Zig — no C
dependencies.

The design follows [`nv-redfish`](https://github.com/NVIDIA/nv-redfish): a
CSDL/OData compiler turns DMTF and vendor schemas into typed Zig source, a
small transport abstraction keeps HTTP out of the schema layer, and
ergonomic wrappers sit on top for common Redfish services.

## Modules

| Module | Path | Role |
| --- | --- | --- |
| `redfish_core` | `core/` | Transport-agnostic primitives: `ODataId`, `ODataETag`, `NavProperty(T)`, `Action(T, R)`, `ModificationResponse(T)`, EDM value types, `$expand`/`$filter` builders, and the `BmcTransport` interface. No HTTP. |
| `redfish_bmc_http` | `bmc_http/` | `BmcTransport` over `std.http.Client`: basic and `X-Auth-Token` credentials, ETag caching, conditional requests, SSE, multipart firmware push. |
| `redfish_bmc_mock` | `bmc_mock/` | Expectation-based test BMC used by the test suite and examples. |
| `redfish-codegen` | `codegen/` | CSDL/EDMX compiler and Zig emitter. Reads Redfish, Swordfish, and OEM schemas, resolves inheritance and references, prunes to the reachable surface, and writes a Zig package. |
| `redfish_schema_*` | `schema_packages/` | Checked-in generator output, one package per profile. |
| `redfish` | `redfish/` | High-level API over the generated types: the service root, what the service says it supports, and links followed rather than URIs guessed. |
| — | `tests/` | 251 responses recorded from DMTF's published mockups, deserialized into the generated types. See [`tests/README.md`](tests/README.md). |
| — | `examples/` | Six worked programs, each run against the mock BMC by the test suite. See [`examples/README.md`](examples/README.md). |

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

Vendor extensions get their own package — `redfish_schema_oem_contoso` is the
worked example — because nothing in the standard corpus names an OEM type,
which makes them unreachable rather than merely unused.

`zig build -Dcorpora generate` rebuilds every package in place, on Linux; CI
regenerates and diffs, so what is committed is what the generator produces.

**There are no per-service build options.** The reference project gates each
wrapper behind a Cargo feature because a Rust crate pays to compile every item
it declares; Zig analyzes a declaration only when something references it, so
naming one type costs you nothing for the other thirteen hundred.

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
| 4 | Generated schema packages | done — standard and Contoso OEM, with a recorded-payload suite |
| 5 | `redfish` high-level wrappers | done — service root, features, paging, quirks, deferred writes, session login |
| 6 | Mock BMC, examples, integration tests | in progress — `redfish_bmc_mock` and the worked examples |

## License

Apache-2.0 — see [LICENSE](LICENSE).

This project consumes Redfish schema files from DMTF's
[Redfish-Publications](https://github.com/DMTF/Redfish-Publications) and
Swordfish schema files from SNIA's
[Swordfish-Publications](https://github.com/SNIA/Swordfish-Publications),
both licensed under BSD-3-Clause.
