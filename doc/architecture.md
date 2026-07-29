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

Redirects are followed by `HttpBmc.sendImpl`, not by `std.http.Client`
(`redirect_behavior = .unhandled`), so every hop goes back through
`Endpoint.resolve` and the same-origin check. 301/302/303 downgrade the method
to GET and drop the body; 307/308 preserve both; `max_redirects` bounds the
chain. Credentials are sent as ordinary `extra_headers` rather than
`std.http.Client`'s `privileged_headers`, because that field is only consulted
by the client's own redirect logic and is never written to the wire — and the
protection it offers is redundant here, since a cross-origin hop is refused
outright rather than merely stripped of its credentials.

`bmc_http/loopback.zig` is a test-only fixture that runs a real
`std.http.Server` on a loopback port and records what arrived on the wire. It
is what verifies these rules end to end: that a cross-origin `Location` never
produces a second request, that a redirect chain is bounded, and that a
response larger than `max_response_bytes` is refused rather than buffered.

## Response caching

A Redfish service is expected to answer a conditional `GET` with
`304 Not Modified`, which carries no replacement body. That is only useful to a
client that kept the previous one, so `bmc_http` holds response bodies against
their URIs and remembers the ETag each was served with.

`HttpBmc` consults the cache on every `GET` the caller did not already make
conditional, attaches the stored ETag as `If-None-Match`, and turns the `304`
back into the `200` the caller would have received. Nothing above the transport
sees a `304` it did not ask for, so caching is transparent to `redfish_core`'s
typed operations. A caller-supplied `If-None-Match` — what
`core.bmc.getIfNoneMatch` sends — bypasses the cache entirely, because such a
caller wants the `304` itself. `CacheSettings.capacity` of zero disables the
whole path, so no `If-None-Match` this transport cannot answer is ever sent.

Writes are not invalidated, and do not need to be. A `PATCH` that changes a
resource changes its ETag, so the stored one no longer matches and the next
conditional `GET` is answered with a fresh body; a `PATCH` that changes nothing
leaves the ETag alone, and the cached body is still correct.

Unlike `nv-redfish`, which caches deserialized values behind `Box<dyn Any>`,
the Zig cache holds raw bytes. The typed layer in `redfish_core` is a set of
generic free functions over a byte-oriented `BmcTransport` vtable, which cannot
carry a type-erased value without a runtime type tag; and every decoded value
owns an arena, so handing the same one to two callers would need reference
counting. Caching bytes keeps both the vtable and `Owned(T)` simple, and still
avoids what costs a BMC the most — the transfer.

The replacement policy is CAR — Clock with Adaptive Replacement (Bansal &
Modha, USENIX FAST 2004) — ported from `nv-redfish`'s `cache.rs`, which follows
the paper's pseudocode line by line. Two resident lists, `T1` for pages seen
once and `T2` for pages seen again, are each swept by a clock hand; two ghost
lists remember the keys of pages recently demoted out of them. A hit on a ghost
is evidence that the corresponding resident list was too small, and moves the
target size `p` toward it. The result is scan-resistant — walking a large
collection once does not flush the resources a caller keeps returning to —
without the per-access list surgery LRU needs.

Two deviations from the Rust:

- **Keys are duplicated once.** Rust clones a key into the index and again into
  whichever list holds it. `CarCache` allocates one copy when the key first
  enters, shares it between the index and the lists, and frees it when the key
  leaves the index, so a demotion from `T1` to `B1` costs no allocation. The
  `Evicted.key` handed back to the caller is borrowed from the ghost list and
  is only valid until the next mutation.
- **All allocation happens before any mutation.** `replace()` moves a page into
  a ghost list, so a failure partway through `put` would leave the cache one
  entry short of full with ghosts present — breaking invariant I5 for every
  later call. The first `put` reserves every slot the four lists can ever hold,
  after which list operations cannot fail; an idle cache still holds no slot
  storage. A test drives an allocation failure at each index in turn and
  asserts the invariants still hold and the cache still works afterwards.

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
