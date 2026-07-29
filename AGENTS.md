# AI Agent Guidelines

## Build and test commands

```bash
zig build                    # build every module, install redfish-codegen
zig build test --summary all
zig build fmt
zig build fmt-check

./zig-out/bin/redfish-codegen --help
```

## Repository structure

- `core/` — `redfish_core`: transport-agnostic Redfish/OData primitives
- `bmc_http/` — `redfish_bmc_http`: `std.http.Client` transport, ETag cache, SSE
- `bmc_mock/` — `redfish_bmc_mock`: expectation-based test BMC
- `codegen/` — `redfish-codegen`: CSDL/EDMX → Zig emitter, profiles, fixtures
- `schema/` — DMTF, SNIA, and vendored OEM CSDL input
- `schema_packages/` — checked-in generator output, one package per profile
- `redfish/` — `redfish`: high-level service wrappers
- `doc/` — architecture, codegen, and profile documentation

## Source ownership

- This is a monorepo. `main` owns all source, including generated packages.
- Generated packages under `schema_packages/` are committed and regenerated
  by `zig build generate-<profile>-package`.
- The emitter owns **every** file in a generated package, `build.zig` and
  `README.md` included. There is no hand-written layer inside one, so there is
  nothing there to protect.
- Do not hand-edit a generated package. Fix the emitter and regenerate.
- The generator formats its own output through `std.zig.Ast`, so regenerated
  files are already normalized. Run `zig build fmt` anyway before committing;
  it is what CI checks.

## Naming conventions

- Types and structs: `PascalCase`
- Functions and methods: `camelCase`
- Constants: `snake_case`
- Files: `snake_case.zig`
- Build modules: `snake_case` with a `redfish_` prefix

## Key patterns

- Runtime interfaces use function-pointer structs with `@fieldParentPtr`.
- `BmcTransport` is byte-oriented; typed access is generic free functions
  layered on top. Zig cannot put generic methods in a vtable.
- Reads return `Owned(T)` — a value plus the arena that owns its whole tree.
  There is no reference counting.
- Zig 0.16 has no `async`/`await`. Every operation is synchronous and takes
  an `io: std.Io`. Concurrency is the caller's concern.
- Generated code distinguishes "absent" (`null`) from "explicit JSON null"
  (`??T` inner `null`) so PATCH payloads stay faithful.
- Vendor deviations from the published CSDL live in `patch_support/`, never
  inline in generated code.

## Reference projects

- `nv-redfish` (Rust) — behavioral parity target. Port its test names first,
  then implement to green.
- `azure-sdk-for-zig/codegen/cli` — structural guide for the emitter
  (`main.zig`, `codemodel.zig`, `types.zig`, `naming.zig`, `identifiers.zig`,
  `emit.zig`), the checked-in JSON fixture model, and the deterministic
  regeneration gates.

## Do not

- Add C dependencies; the stack must remain pure Zig.
- Hardcode credentials or secrets.
- Commit BMC captures containing serial numbers or asset tags.
- Skip `zig fmt`.
- Commit generated code that has not been through `zig build fmt`.
