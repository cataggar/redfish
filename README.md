# redfish

> **⚠️ Experimental** — early scaffolding. The module layout below is the
> target design; only `redfish_core` exists so far, and it is a stub.

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
| `redfish` | `redfish/` | High-level API over the generated types — `ServiceRoot` plus per-service wrappers. |

## Profiles

Zig has no equivalent of Cargo features, so schema selection happens in two
places:

1. **Generation profiles** (`codegen/profiles.yaml`) decide which CSDL files
   and entity-type patterns are compiled into a given
   `redfish_schema_<profile>` package. A profile only carries the schema
   surface reachable from its roots.
2. **Build options** (`-Dchassis=true`, …) gate the high-level wrappers
   compiled into the `redfish` module.

Enable only what your client needs; the full Redfish surface is large.

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
| 0 | Workspace, conventions, CI | in progress |
| 1 | `redfish_core` primitives | not started |
| 2 | `redfish_bmc_http` | not started |
| 3 | `redfish-codegen` | not started |
| 4 | Generated profile packages | not started |
| 5 | `redfish` high-level wrappers | not started |
| 6 | Mock BMC, examples, integration tests | not started |

## License

Apache-2.0 — see [LICENSE](LICENSE).

This project consumes Redfish schema files from DMTF's
[Redfish-Publications](https://github.com/DMTF/Redfish-Publications) and
Swordfish schema files from SNIA's
[Swordfish-Publications](https://github.com/SNIA/Swordfish-Publications),
both licensed under BSD-3-Clause.
