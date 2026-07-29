# redfish

> **⚠️ Experimental** — under construction. The module layout below is the
> target design; only `redfish_core` exists so far.

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
| — | `tests/` | 251 responses recorded from DMTF's published mockups, deserialized into the generated types. See [`tests/README.md`](tests/README.md). |

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

**Build options** (`-Dchassis=true`, …) still gate the high-level wrappers
compiled into the `redfish` module.

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
| 5 | `redfish` high-level wrappers | not started |
| 6 | Mock BMC, examples, integration tests | in progress — `redfish_bmc_mock` |

## License

Apache-2.0 — see [LICENSE](LICENSE).

This project consumes Redfish schema files from DMTF's
[Redfish-Publications](https://github.com/DMTF/Redfish-Publications) and
Swordfish schema files from SNIA's
[Swordfish-Publications](https://github.com/SNIA/Swordfish-Publications),
both licensed under BSD-3-Clause.
