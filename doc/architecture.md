# Architecture

The stack is layered so that the transport never depends on the schema and
the schema never depends on the transport.

```
       redfish                 high-level wrappers (ServiceRoot, Chassis, …)
          │
          ├──────────────► redfish_schema_<profile>    generated types
          │                        │
          ▼                        ▼
       redfish_core         primitives + BmcTransport interface
          ▲
          │  implemented by
   ┌──────┴───────┐
redfish_bmc_http  redfish_bmc_mock
```

Generated packages are produced offline by `redfish-codegen` and committed:

```
  schema/redfish-csdl/*.xml
  schema/swordfish-csdl/*.xml     ─┐
  schema/oem/<vendor>/*.xml        │
                                   ▼
                     ┌───────────────────────────┐
                     │  redfish-codegen          │
                     │  csdl.zig  → schema_index │
                     │  compile.zig → CodeModel  │
                     │  optimize.zig (prune)     │
                     │  emit.zig  → Zig source   │
                     │  then `zig fmt`           │
                     └───────────────────────────┘
                                   │
                                   ▼
              schema_packages/redfish_schema_<profile>/
```

`codegen/profiles.yaml` maps a profile to its CSDL files, root patterns,
entity-type patterns, and rigid-array patterns. It is the direct analog of
`nv-redfish`'s `redfish/features.toml`.

## Deviations from the Rust original

`nv-redfish` is the behavioral reference. These are the places where Zig
forces a different shape, and why.

### No async

Zig 0.16 has no `async`/`await`. The Rust API is async top to bottom; ours is
synchronous and threads an `io: std.Io` through the transport. Callers who
want concurrency run their own threads. This is the single largest API-level
deviation and it is intentional.

### `Bmc` is split in two

Rust's `Bmc` trait has generic methods (`fn get<T>(…)`). Zig cannot place a
generic method in a vtable, so the interface is split:

- `BmcTransport` (`core/bmc.zig`) — a function-pointer struct
  (`@fieldParentPtr` for the implementation's own state) operating on raw
  bytes. One `sendFn` taking a `RawRequest` and an arena, plus an optional
  `streamFn` for `text/event-stream`.
- Typed access — generic free functions that call the vtable and then
  decode: `bmc.get(Chassis, gpa, transport, id)`, `expand`, `filter`,
  `update`, `create`, `delete`, `invokeAction`, `createSession`.

`sendFn` returns `anyerror`. Rust gives the trait an associated `Error` type,
but a Zig function pointer has to name one concrete error set, so the open
set is what lets an implementation report its own failures (TLS, DNS, a
mock's expectation mismatch) without `core/` enumerating them. Everything the
typed layer raises on its own is a closed set, `bmc.Error`.

Each operation allocates one arena and the returned `Owned(T)` carries it.
The transport writes the response bytes into that same arena, so decoding can
borrow directly out of the body rather than copying every string.

Status handling lives in `bmc.statusError`, which maps a non-2xx status onto
a named error — `412` is `error.PreconditionFailed`, `304` is
`error.NotModified` — so callers branch on meaning rather than on integers.

### Query builders keep text, not a tree

`FilterQuery` accumulates rendered text instead of an expression tree. The
grammar it produces is left-leaning: `and`/`or` append, `not` prefixes
everything built so far, and `group` wraps it. That yields output identical
to what the Rust AST renders, without the AST.

Chaining a comparison onto a non-empty filter without an intervening `and` or
`or` is `error.MissingLogicalOperator`. `nv-redfish` silently discards the
earlier clause, which turns a narrow query into a broad one — a filter is a
safety mechanism, so this fails loudly instead.

### Traits become structural comptime contracts

`EntityTypeRef` is a Rust trait the generator implements for every resource.
Zig has no traits, so `core/entity.zig` states the contract structurally: a
type is an entity when it has an `@"@odata.id"` field, or supplies an
`odataId` method for the cases where the answer has to be computed.
`entity.assertEntity(T)` turns a violation into a compile error naming the
offending type, rather than a failure deep inside an instantiation.

`NavProperty(T)` satisfies the contract through the method form, since a
reference and an expanded resource keep their identity in different places.
Its expanded arm holds `*const T` rather than `T`: Redfish resource graphs are
cyclic, so an inline `T` would be an infinitely sized type. The pointee lives
in the arena of the `Owned(T)` that produced it, which is also why nothing in
`core/` ever needs to free a `NavProperty` individually.

One consequence of deferred checking is worth remembering: `NavProperty(T)`
cannot call `assertEntity(T)` when the type is instantiated, because a
resource holding a `NavProperty(Self)` would be asking for its own type info
mid-resolution. The check runs inside the methods instead.

### Ownership: `Owned(T)` instead of `Arc<T>`

Rust returns `Arc<T>` so a decoded resource can be shared cheaply. Zig has no
such idiom in the standard library, and refcounting a deeply nested decoded
tree is worse than the alternative: each read allocates into its own
`std.heap.ArenaAllocator` and returns

```zig
Owned(T) = struct { value: T, arena: std.heap.ArenaAllocator }
```

One `deinit()` releases the entire tree. Sharing is the caller's problem.

### Feature flags become profiles plus build options

Cargo features do double duty in `nv-redfish`: they select which CSDL is
compiled *and* which wrapper modules exist. Zig splits these:

- which schema is generated → generation profile (`codegen/profiles.yaml`)
- which wrappers are compiled → `b.option` + `@import("build_options")`

### Absent vs. explicit null

Redfish PATCH semantics distinguish "property omitted" from "property set to
`null`". Rust models this as `Option<Option<T>>`. Zig's `??T` is legal and
carries the same information; the emitter must preserve the distinction when
writing serializers, or PATCH payloads will silently clear properties.

### EDM value types replace third-party crates

`nv-redfish` reaches for `rust_decimal`, `time`, and `uuid`. Zig's standard
library has no equivalent, so `core/edm/` implements the four OData primitives
we need directly. Two consequences are worth calling out:

- **`Decimal` is exact fixed-point** (`mantissa: i128`, `scale: u8`), not a
  float. `Edm.Duration` is built on it, so `PT1.5M` survives a round trip that
  an `f64` would corrupt. It also means `jsonParse` never routes a number
  through `f64`. `std.json.Value`, however, decodes numbers to `.float` before
  a custom hook can see them — parse with `.parse_numbers = false` when the
  document may carry more precision than an `f64` holds.
- **`DateTimeOffset` keeps the civil fields as written** rather than
  normalizing to an instant, so the sender's offset round-trips. The one
  canonicalization is that a zero offset always formats as `Z`, matching
  `time`'s RFC 3339 output.

Where the Rust parsers were accidentally permissive, ours are stricter and the
tightening is called out at the call site:

| Input | `nv-redfish` | Here |
| --- | --- | --- |
| `P5T1H` (digits before `T` with no `D`) | accepted, `5` ignored | rejected |
| `PT1S1H`, `PT1H2H` (out of order, repeated) | accepted | rejected |
| `3.` (trailing decimal point) | rejected | rejected |

Domains differ slightly too: `Decimal` holds an `i128` mantissa rather than
`rust_decimal`'s 96 bits, so a few extreme durations that overflow in Rust
parse here. Nothing silently wraps in either direction.

### No derive macros

There is no `serde` derive. The emitter writes explicit field-rename tables
and `jsonParse`/`jsonStringify` implementations alongside each generated
type. Reflection alone cannot express Redfish's `@odata.id`-style names,
excerpt shapes, or the absent/null distinction above.

### No `build.rs`

`nv-redfish` runs the compiler during `cargo build` into `OUT_DIR`. Zig
generation happens offline and the output is committed, which makes emitter
changes reviewable as diffs. Reproducibility is enforced by regeneration
checks rather than by regenerating on every build.

## Transport security

A Redfish service hands out URI references the client is expected to follow:
`Location` headers, action targets, `HttpPushUri`, `MultipartHttpPushUri`,
event stream URIs. Each is data the *service* controls, and each is about to
receive a request carrying the client's credentials.

`bmc_http/endpoint.zig` resolves every one of them per RFC 3986 and then
rejects any result that is not same-origin with the configured BMC. Origin is
RFC 6454 — scheme, host, and *effective* port, with the scheme's default
filled in — compared structurally rather than as a string prefix, so:

- `https://bmc.example.evil/x` is rejected against base `https://bmc.example`,
  even though it has the base's hostname as a prefix;
- `http://bmc.example/x` is rejected, because a scheme downgrade is both a
  different origin and a plaintext transport;
- `https://bmc.example:8443/x` is rejected against the default port;
- `https://bmc.example:443/x` is accepted against it.

The scheme allow-list and the default-port table are the same function, so a
scheme we do not have a default port for cannot be requested at all.

This mirrors `nv-redfish`'s `with_same_origin_uri_reference`, which wraps
service-provided values in a `UriReference` newtype to force the check at the
call site. Zig has no such affordance, so the check lives inside the one
function that turns a reference into a request URI, and there is no way to
send a request that bypasses it.

Credentials redact themselves in `format`, and `SessionCreateResponse` does
the same for its token.

## Emitter conventions

Borrowed from `azure-sdk-for-zig/codegen/cli`:

- The code model is a **checked-in JSON artifact**, not only an in-memory
  value. Fixtures pin the contract so emitter changes show up as diffs.
- Code-model types stay **open and tolerant** of unknown fields; new schema
  metadata must not break the generator.
- The emitter owns exactly **one file end-to-end** (`src/models.zig`).
  Everything else in a generated package is operator-managed.
- Emitted source is plain text written to a `std.Io.Writer`, then normalized
  by `zig build fmt` before it is committed. No token-tree machinery.
- Every profile has a deterministic regeneration check.
