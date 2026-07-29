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
  DMTF/Redfish-Publications csdl/*.xml        ─┐
  SNIA/Swordfish-Publications csdl-schema/*.xml│  pinned, lazy `.zon` deps
  <vendor>/*.xml                               │
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
              schema_packages/redfish_schema_<name>/
```

The packages worth generating are listed in `build.zig`, which gives each one
a `generate-<name>` step; `zig build -Dcorpora generate` does all of them.
There is no
`profiles.yaml` — see "Zig does not need `features.toml`" below.

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

### Feature flags become build options, and mostly nothing at all

Cargo features do double duty in `nv-redfish`: they select which CSDL is
compiled *and* which wrapper modules exist. Zig needs neither job done the
same way. Schema selection is unnecessary because unreferenced declarations
cost nothing to analyze, so there is one standard package; which wrappers are
compiled is still a choice, made with `b.option` + `@import("build_options")`.

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

## Server-sent events

DSP0266 §13.2 has a Redfish service publish events as a `text/event-stream`,
the WHATWG "server-sent events" format. The parser is `core/sse.zig`, in
`redfish_core` rather than `bmc_http`, because it reads from a
`*std.Io.Reader` and knows nothing about HTTP — `bmc_mock` can drive it from a
fixed buffer exactly as `bmc_http` drives it from a socket.

`EventReader` implements the spec's dispatch rules: `data` lines join with
newlines, a blank line dispatches, an event with no data dispatches nothing,
the `event` name defaults to `message` and resets between events, the last
event id persists until replaced, comments are heartbeats, and CR, LF, and
CRLF are all line terminators. `max_event_bytes` bounds a single event across
all of its lines, so a service that never sends the terminating blank line
cannot exhaust the client.

Where `nv-redfish` returns a `Stream` of decoded values, `stream` here returns
a reader and the caller builds an `EventReader` over it. Zig has no async, so
there is nothing to poll; `next` blocks until an event arrives, which is what
a caller would do with a stream anyway.

An event stream outlives the call that opened it, which no other request does.
`EventSession` therefore holds the `std.http.Client.Request`, its `Response`,
and the body reader's buffers in one heap allocation at a stable address —
`Response` points at its `Request`, and the reader points into both. `close`
releases the lot. Note that initializing the body stream invalidates every
pointer in the response head, so `Location` is copied out before that happens.

## Firmware upload

DSP0266 §13.3 offers two ways to push an image at `UpdateService`: a
`multipart/form-data` POST to `MultipartHttpPushUri`, and a raw body POST to
`HttpPushUri`. Both are in `core/upload.zig`, with the form encoder in
`core/multipart.zig`, because neither needs HTTP — only a body and a
content type.

A firmware image is far larger than a Redfish document, so `RawRequest.body`
became a union:

```zig
pub const RequestBody = union(enum) {
    empty,
    bytes: []const u8,
    stream: struct { reader: *std.Io.Reader, len: ?u64 },
};
```

A separate `uploadFn` on the vtable would have confined streaming to uploads.
As a body kind it is available to every method and to `bmc_mock`, and the
typed operations that encode JSON simply produce `.bytes`.

`Form.init` precomputes each part's header block into an arena, so
`FormReader` is a plain concatenation of `bytes` and `stream` segments and no
part is buffered. `contentLength` sums the segments and returns null when any
part's length is unknown, in which case `bmc_http` sends
`Transfer-Encoding: chunked` instead of `Content-Length`. When a length *is*
declared, the transport counts what it wrote and fails with
`UploadLengthMismatch` rather than emitting a truncated body.

A streamed body cannot be replayed, so a 307 or 308 redirect — which must
resend the body — fails with `StreamNotReplayable`; 301, 302, and 303 are
still followed, since they convert the request to a bodiless `GET`.

The multipart boundary needs randomness, and `redfish_core` deliberately takes
no `std.Io`, so `Form.init` accepts a caller-supplied `std.Random`. That also
makes a form reproducible under test: `multipart.test_boundary` renders a
fixed 32-character boundary. A part name or filename containing `"`, `\`, CR,
or LF is rejected with `InvalidPartName` rather than escaped, because escaping
is not interoperable across servers.

`nv-redfish` gives uploads their own `upload_timeout`, separate from the
request timeout, because a large image legitimately takes minutes. There is no
equivalent here: the transport is synchronous and Zig 0.16 has no async, so a
timeout would have to interrupt a blocking write. Callers that need one impose
it around the whole call.

## Test double

`redfish_bmc_mock` replaces the socket and nothing else. `nv-redfish-bmc-mock`
implements the `Bmc` *trait*, so its expectations name a resource type and
carry a `serde_json::Value`, and everything above the trait — the typed
operations, the JSON encoding, the status handling — is bypassed. Zig splits
that trait in two, and the lower half is a byte-oriented vtable, so the mock
implements `BmcTransport` instead: a test that queues
`Expect.patch(uri, request_json, response_json)` exercises the real encoder,
the real query-string builder, and the real `ModificationResponse` shaping.

Expectations are matched in order, as the Rust mock's `VecDeque` is. Every
field of a `RequestMatch` is optional and an omitted one matches anything, so
a test constrains only what it is about. Payloads are compared as JSON rather
than as text: object key order is not part of the contract, and a test should
not break when the emitter reorders a struct's fields. A multipart body has a
random boundary and so is matched with `.contains`.

The response half names the headers the typed layer actually reads — `ETag`,
`Location`, `X-Auth-Token`, `Retry-After` — as fields rather than taking a
header slice. A builder such as `Expect.patchAccepted(uri, body, task)` would
otherwise have to return a slice pointing at a temporary that dies with the
call.

`verify()` fails when an expectation was never met, because an operation that
is silently skipped is as much a bug as one performed wrongly. A mismatch is
reported with both the expectation and the request that did not match it: the
error itself reaches the test as a bare `error.UnexpectedRequest`, several
frames above where the mismatch was found.

## CSDL parsing

`codegen/cli/src/csdl.zig` reads EDMX/CSDL with the streaming XML **scanner**
from [`serde.zig`](https://github.com/cataggar/serde.zig) rather than a
document deserializer. The corpus is thousands of attribute-dense files, and a
scanner lets the reader keep only the elements it cares about. It is the one
dependency in the repository; `redfish_core`, `redfish_bmc_http` and
`redfish_bmc_mock` still have none.

The reader is deliberately **parse-only**: it reports exactly what a single
document says, and it never resolves a `BaseType`, follows a `Reference`, or
interprets an annotation. Cross-document work belongs to `schema_index.zig`,
and meaning belongs to `compile.zig`. Keeping those apart means a malformed or
surprising document fails in one obvious place.

Everything borrows from the input text. Only entity-decoded strings (the rare
`&#xNN;` case) and the backing memory for lists are arena-allocated, so
parsing a document costs roughly the size of its structure, not its bytes.

Annotation values are modelled as a union rather than raw text, because
Redfish leans on structured annotations — `Redfish.DynamicPropertyPatterns`
is a collection of records and `Redfish.Revisions` is a collection of records
with enum members inside. `compile.zig` needs those shapes, not their source.

## Versions are inheritance

Redfish models schema versions as inheritance: `Chassis.v1_25_0.Chassis`
derives from `Chassis.v1_24_0.Chassis`, back to an abstract, unversioned
`Chassis.Chassis`. "The newest version of a type" is therefore "the most
derived type", and `schema_index.zig` finds it by walking down the chain
rather than by comparing version numbers.

The walk descends only while exactly one derived type **contributes** — has
properties of its own, or has something below it that does. That rule comes
from the Rust compiler and it matters twice over: a version bump that adds
nothing must not stop the walk, and a genuine fork in the hierarchy must,
because picking one branch there would be a guess.

`Version` still exists and is still parsed, for ordering and for naming, but
it deliberately rejects OData's uppercase `V1` (as in `Org.OData.Core.V1`)
so an OData namespace is never mistaken for a versioned Redfish one.

## Generated names

| Schema name | Zig name | Source |
| --- | --- | --- |
| `EntityType Name` | `PascalCase` type | `naming.toPascalCase` |
| `Action Name` | `camelCase` function | `naming.toCamelCase` |
| namespace root | `snake_case.zig` file | `naming.toSnakeCase` |
| `Property Name` | **verbatim**, quoted if needed | `identifiers.fmt` |

Property names are the deviation from the Rust generator, which snake-cases
fields and restores the wire name with a `#[serde(rename)]` attribute. Zig has
no derive macros, so a rename table would have to be emitted and then
interpreted by hand-written `jsonParse` / `jsonStringify` for hundreds of
types. Naming the field `@"@odata.id"` instead makes `std.json` line up with
the wire format for free, and it is what `core/entity.zig` already does.

Casing is ported from `nv-redfish`'s `casemungler.rs`, test table included.
Its acronym heuristic is what makes `NVMe` → `nvme` while `nVMEFoobar` →
`nvme_foobar`, and it is easier to match than to reinvent: the generated names
should not churn against the Rust generator's. Its one weak spot, a digit
ending an acronym run (`IPv4Address` → `ipv4address`), is pinned by a test so
a future change to it is a deliberate one.

Escaping is delegated to `std.zig.fmtId` rather than a hand-kept keyword list,
so it cannot drift from the language. `identifiers.isBare` is deliberately
stricter than Zig requires — it treats primitive type names and bare
underscores as needing quotes — because a generated name is never worth a
subtle shadowing bug.

The namespace survives into the generated package, as a module: a file per
namespace, so `Chassis.Chassis` is `chassis.Chassis` and `Chassis.Links` is
`chassis.Links`. This is the one structural thing kept from the Rust
generator, and it is kept for a reason. Every Redfish schema declares a
`Links`, an `Actions` and an `Oem`, so flattening the corpus into a single
namespace needs a disambiguation rule, and any such rule renames existing
types the moment a profile gains a schema. Generated packages are checked in
here, so that churn would land in every review of an unrelated change. A
module per namespace means a name is decided by the schema that declares it
and by nothing else.

Each type is emitted in as many shapes as it is used in — `Chassis`,
`ChassisUpdate`, `ChassisCreate`, `ChassisExcerpt`, `ChassisExcerptStatus` —
because they have different fields, not different spellings of the same
fields. An action becomes a struct named for what it is bound to,
`ChassisResetAction`, since half the corpus declares a `Reset` and they do
not agree on what it takes.

## The code model is the seam

`compile.zig` produces a `Model`; `emit.zig` consumes one. Neither knows the
other exists, and the model between them is JSON in both directions, so
`--emit-model` can dump what the compiler decided without reading the Zig it
turned into, and a test can hand the emitter a model no CSDL produced.

Two properties make that work. Every collection is an **ordered slice**, so
the same input yields byte-identical JSON; hash-map iteration order would
make output churn between runs. And every field has a **default**, with
unknown fields ignored on parse, so a model written before a field existed
still loads. A `format` version exists for the changes that defaults cannot
absorb.

The model holds schema names exactly as CSDL writes them — qualified types,
verbatim wire property names — and says nothing about Zig. Casing, escaping
and type mapping are the emitter's business, so the same model could be
rendered to another language without touching the compiler.

## Reachability is the profile

Nothing in the Redfish corpus says where a service begins. Every schema is a
peer of every other, and a client that generated all of them would get tens of
thousands of types for a BMC that serves a few dozen. The compiler starts at
the service singletons a profile names and follows properties and links from
there; what it cannot reach is not generated.

That alone would still generate everything, because `ServiceRoot` links to
every service there is. A second filter decides which links are worth
following. A link outside it is still emitted, but only as a bare
`@odata.id` — the resource keeps its true shape, and the schema behind the
link stays out. This is why `Chassis.*` and `Chassis.*.*` are different
patterns: the segment counts must match exactly, so a profile can pull in the
unversioned base without dragging in every version of it.

Some types are compiled whether or not anything links to them, because the
protocol refers to them by name rather than by link: `Resource.Resource` and
`Resource.ResourceCollection` are the bases every resource inherits from, and
`Settings.Settings` and `Settings.PreferredApplyTime` are the targets of
`@Redfish.Settings`. Unlike the Rust compiler, a corpus that omits them is
compiled anyway rather than rejected, so the generator is usable on a single
schema file.

Two deviations are worth naming. A link left unexpanded keeps the name of the
type it points at, which the Rust compiler discards; it costs nothing and lets
a later emitter type the reference. And a `Nullable` attribute is now recorded
as written, absent from the parse when the schema omits it, because a missing
`Nullable` means true on a property and false on a link — a default the
parser has no business choosing.

## Read-only is inferred, not declared

The schema annotates properties with `OData.Permissions`, never complex
types. A type that exists only to group read-only properties therefore looks
writable, and would get an update shape a client can construct but a service
will always reject.

So the compiler reads permission back off the members: a complex type is
read-only when it has no properties at all, or when every structural property
is read-only and there are no links out of it. A link is a way in, so one
link makes the type writable. A member marked `RequiredOnCreate` forces it
writable too — it has to be serializable at least once. `OemActions` is the
one type in the corpus that is open and still read-only, because everything
in it is a link to an action, and it is special-cased by name.

This is a heuristic, and it is the same heuristic nv-redfish arrived at. It
is worth keeping because the alternative is not a better answer but a
generated API that lies about what can be written.

It does not live in the compiler, though, and this is where we part company
with nv-redfish. The answer depends on a type's whole member list, and the
optimizer rewrites member lists: merging a base type into its only child can
turn a read-only type writable. nv-redfish computes the answer during
compilation, caches it on every property that names the type, and then
carries a comment admitting the optimizer can leave it stale. Here the code
model records only what the schema declared, and `permissions.zig` derives
the rest on the finished model, where it cannot go out of date.

## Reading and writing are different types

The same property is a different Zig type depending on the direction. Reading
a resource, a property the service omitted and one it sent as null are the
same answer: no value. `?T` says that, and `std.json` decodes both into it.

Writing one, they are opposite instructions. A PATCH that omits a property
leaves it alone; a PATCH that sends it as null clears it. A client that cannot
express the difference cannot clear anything, so a nullable property in a
write shape is `core.Nullable(T)` -- absent, null, or set. A property that is
not nullable has no third state to express, so it stays `?T`.

`Nullable(T)` exists because `?T` cannot carry the distinction: `std.json`
decodes a null token into the same `null` an absent field defaults to. A value
also cannot leave itself out of an object, so the emitted write shapes carry a
`jsonStringify` that skips absent fields -- the same reason the Rust generator
emits its own serializers.

Only a rigid collection has optional elements. Its length is fixed by the
service, so entry three is always entry three and a null there means that slot
has no value; in an ordinary collection a null would just be a hole.

## Versions are folded, not flattened

The compiler leaves the schema's shape intact: twenty-five published versions
of `Chassis` arrive as twenty-five entity types in an inheritance chain, most
of them adding one property to the one before, sitting under abstract types
that declare nothing at all. Emitting that verbatim would produce a package
that is mostly empty structs.

The optimizer folds it back down in three moves. A type with no members is
replaced by the nearest ancestor that has some, since nothing can be read out
of it that could not be read out of the ancestor. A type with exactly one
child is merged into that child -- a base several types share is a real
shape worth naming, but a base with one child is just where half of that
child's properties were written down. What survives is then hoisted to the
shortest namespace where its name is still unique, which is what turns
`Chassis.v1_25_0.Chassis` into `Chassis.Chassis`.

Each pass rewrites the whole model: it works out what each name becomes,
rebuilds the declarations, and pushes the same map through every reference,
including the package root. Anything recorded against a type that goes away
-- the excerpt copies some link asked for, whether a collection can create
one -- moves to the type that replaces it.

Two types are spared. `Resource.Item` and `Resource.ItemOrCollection` declare
nothing but are what every resource ultimately derives from, so folding them
away would leave no name for "some resource". And a type that owns a key
keeps it, because the key is what makes it a resource rather than a shape.

Two departures from nv-redfish, both in the direction of losing less. A
complex type that admits properties the schema does not name is not empty,
even with no members of its own, because "the service may add anything here"
is worth keeping; nv-redfish drops it. And a property redeclared by a later
version keeps the position it was first written in but takes the newer
definition, where nv-redfish emits it twice.

## Emitter conventions

Borrowed from `azure-sdk-for-zig/codegen/cli`:

- Code-model types stay **open and tolerant** of unknown fields; new schema
  metadata must not break the generator.
- Emitted source is plain text written to a `std.Io.Writer`, then normalized
  by `zig build fmt` before it is committed. No token-tree machinery.
- Every profile has a deterministic regeneration check.

Azure's emitter owns exactly one file (`src/models.zig`) and leaves the rest
of a generated package operator-managed. Here the emitter owns **every file**
in a schema package, `build.zig` and `build.zig.zon` included. Azure's packages
have hand-written clients layered over the generated models; a Redfish schema
package is nothing but schema, and the hand-written layer lives in a separate
module (`redfish`). With no file to protect, `--force` and a `sync.sh`
allow-list would only be ceremony.

## An emitted package is a build product, not a source tree

`emit()` returns `[]const File{ path, contents }` in memory rather than
writing to disk. The whole package is then a value: a test can render one and
assert on the bytes, or render the same model twice and compare, without a
temporary directory or a filesystem mock. `main.zig` is the only code that
writes bytes, and all it does is write them.

The layout is fixed:

```
schema_packages/redfish_schema_<profile>/
  build.zig          exposes module redfish_schema_<profile>
  build.zig.zon      depends on .redfish = .{ .path = "../.." }
  README.md          profile name, generator, root, declaration counts
  src/root.zig       re-exports every namespace module, aliases the root type
  src/<module>.zig   one file per namespace, snake_case
```

Two consequences worth stating:

- **A namespace is a module.** Every Redfish schema declares `Links`,
  `Actions` and `Oem`, so a flattened namespace would need a disambiguation
  rule, and that rule would rename existing types the moment a profile gained
  a schema. For checked-in generated code, that churn is worse than a longer
  path.
- **The `build.zig.zon` fingerprint is derived from the package name.** Zig
  wants a random id; a random id would make every regeneration a diff. The id
  is `crc32(name)` folded into the low 32 bits instead, so regenerating an
  unchanged model is a no-op in `git status`.

Name collisions are an error, not a silent rename. CSDL keeps enums, complex
types and type definitions in separate symbol spaces; Zig does not. When two
declarations want one Zig name, the emitter fails with `error.NameCollision`
and names both claimants, because the alternative — appending a suffix — makes
the generated API depend on schema iteration order.

## Inheritance is copied in, not nested

CSDL entity and complex types derive from one another, and Redfish leans on it
hard: nearly every resource is a `Resource.Resource`. The Rust generator keeps
the base as a real field and lets `#[serde(flatten)]` erase it on the wire:

```rust
pub struct Chassis {
    #[serde(flatten)]
    pub base: Resource,
    pub SKU: Option<String>,
}
```

`std.json` has no `flatten`. The choices were to emit a hand-written
`jsonParse` for every struct that has a base — hundreds of them, each a place
for the generator to be subtly wrong — or to copy the base's properties into
the derived struct. This port copies them.

The wire format is identical either way, because the wire has no nesting to
begin with; what changes is the Zig API, and it changes for the better:
`chassis.Id` rather than `chassis.base.base.Id`. It also makes the
`redfish_core` entity contract trivially satisfied — a resource has an
`@"@odata.id"` field directly, so nothing has to walk a base chain to find it.

Two rules make the copy well-defined:

- **Base first, derived last.** A derived type may redeclare a property to
  narrow it (`Name` optional in `Resource`, required in `Chassis`). The last
  declaration wins, but the field stays in the position the base gave it, so
  adding a schema version cannot reshuffle a struct.
- **The chain is walked with a depth limit.** A cycle in `BaseType` is a
  compiler bug, and stopping is better than looping.

The cost is duplicated field declarations in the generated source. That is
paid by the compiler, once, in a package nobody reads top to bottom.

## Links are read three ways

A navigation property is emitted as one of three things, and which one it is
says something real about the schema:

| Situation | Emitted type |
| --- | --- |
| Target is in the compiled surface | `core.NavProperty(T)` — an id, or the resource inlined when `$expand` was used |
| Target is outside it | `core.ReferenceLeaf` — an id, and there is no type to expand into |
| Link is annotated `Redfish.ExcerptCopy` | `TExcerpt…` — the service inlines a projection, so there is no link at all |

The second case is the interesting one. A profile is a reachable subset of the
corpus, so a link out of the subset is normal, not an error. Emitting
`ReferenceLeaf` rather than `NavProperty(T)` makes the boundary of the profile
visible in the generated API instead of hiding it behind a type that could
never be expanded.

## Every generated enum is open

A BMC implements the schema version its vendor shipped, which is routinely
newer than the version a package was generated from. A strict enum would turn
`"Status": "Degraded"` from a firmware update into a parse failure for the
whole resource.

The Rust generator handles this with `#[serde(other)]` and a trailing
`UnsupportedValue` variant. This port emits the same member and pulls its JSON
hooks from `core.OpenEnum`:

```zig
pub const State = enum {
    Enabled,
    Disabled,

    /// A value this package's schema version does not name.
    UnsupportedValue,

    const open = core.OpenEnum(@This());
    pub const jsonParse = open.jsonParse;
    pub const jsonParseFromValue = open.jsonParseFromValue;
};
```

Only parsing needs a hook. Members are emitted with their wire spelling
verbatim (quoted with `@"..."` when they are not valid Zig identifiers), so
`std.json` serializes them correctly with no rename table — and a value that
came back as `UnsupportedValue` cannot be echoed back, which is the honest
outcome: the package never knew what it was.

## A write shape is a separate type, not the read shape made optional

Reading and writing ask different questions of the same property, and
[Reading and writing are different types](#reading-and-writing-are-different-types)
explains why that means two Zig types. This is what the emitter builds.

Every type gets a read shape. It additionally gets:

- `XUpdate`, a PATCH body, when the type is writable at all. A complex type
  qualifies when it is not read-only by the inference in
  [Read-only is inferred, not declared](#read-only-is-inferred-not-declared);
  an entity type qualifies when any level of its inheritance chain is
  `updatable`.
- `XCreate`, a POST body, when any level of the chain is `creatable`.

A structure nothing can write gets neither. An update shape of a read-only
type would be empty, and an empty one is worse than none: a caller could
construct it and watch the service reject the request.

**A property is in a write shape only if the service will accept it.** The
rule is the reference generator's: a property is included when it is
`RequiredOnCreate` for a create body, or when *both* its own
`OData.Permissions` and its type's permit writing. A write-only property —
`Password` — is therefore in the write shapes and absent from the read shape,
which is the mirror image of how it appears in the schema.

Nullability is where the two shapes diverge most:

| | read | update | create, required | create, optional |
| --- | --- | --- | --- | --- |
| nullable | `?T = null` | `core.Nullable(T) = .absent` | `T` | `core.Nullable(T) = .absent` |
| not nullable | `?T = null` | `?T = null` | `T` | `?T = null` |

A reader does not care whether the service omitted a property or sent it as
null, so both are `null`. A writer must distinguish them: omitting a property
from a PATCH means "leave this alone" and sending null means "clear it", which
is what `core.Nullable`'s third state is for. A required-on-create property
needs no wrapper at all — the request is rejected without it, so it is always
sent.

Serialization comes from `core.Payload(@This()).jsonStringify`, which drops
absent `Nullable` members and null optionals. There is no `jsonParse`: a write
shape is never received.

Two smaller rules:

- **`Update` suffixes only follow complex types.** A property typed
  `Boot.Boot` becomes `boot.BootUpdate` in a write shape, because a complex
  type has a shape of its own to write. An enum, a type definition and a
  primitive are written exactly as they are read, so they keep their plain
  names.
- **Links are left out.** A navigation property is a link the service owns;
  changing one is a different operation from changing a value. The reference
  generator excludes them too. This is a known limitation, not a discovery:
  the few writable navigation properties in the corpus are unreachable through
  the generated write shapes.

There are no builder methods. The Rust generator emits one per field because
a struct literal cannot omit fields; Zig's designated initializers with
defaults already give the caller exactly that:

```zig
const body: chassis.ChassisUpdate = .{ .AssetTag = .init("rack-4") };
```

## An action is a property, a request struct and a method

Redfish does not model an action as an operation on a resource. It models it
as a *property* of the resource's `Actions` structure, holding an object whose
`target` is where to POST:

```json
"Actions": {
  "#ComputerSystem.Reset": {
    "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
    "ResetType@Redfish.AllowableValues": ["On", "ForceOff"]
  }
}
```

So the emitter produces three things per action, and the property is the one
that comes off the wire:

1. **A request struct**, `ChassisResetAction`. It is a write payload like any
   other: `core.Payload` serialization, parameters the action requires sent as
   they are, optional nullable ones three-state. A parameter whose type the
   service will not accept is left out, and a parameter naming a resource
   becomes `core.Reference` — the client sends the `@odata.id` it already has,
   not a copy of the resource.
2. **A property** on the bound structure, `?core.Action(Params, Result)`,
   named `#{namespace}.{action}` exactly as the service advertises it. It is
   optional because a service omits an action it does not implement.
3. **A method**, `reset`, which unwraps the property and calls
   `core.bmc.invokeAction`.

The struct is named for the type the action is bound to, not for the action
alone: half the schemas in the corpus declare `Reset` and they do not mean the
same thing. It is emitted into the module of the namespace that *declares* the
action, which for an OEM action is not the namespace of the resource it is
bound to — `NvidiaChassis` declares `ResetToDefaults` and binds it to
`Chassis.Actions`, so `chassis.zig` imports `nvidia_chassis.zig`.

An action bound to a base `Actions` type is offered by the derived one, for
the same reason [a base type's properties are copied in](#inheritance-is-copied-in-not-nested).

Two deliberate differences from the reference generator:

- **There is no flattened-argument variant.** The Rust generator emits a
  method taking loose arguments when an action has few enough parameters,
  because a Rust caller cannot omit struct fields. A Zig caller can, so the
  struct is the friendlier form at every size — the same reasoning that
  removed the write-shape builders.
- **An action with no declared return type yields `std.json.Value`, not
  `void`.** Rust uses `()`, which is safe because it never parses a body. A
  Zig `void` would fail to parse one, and a service that answers a
  no-return-type action with a body is not violating anything.

## Formatting is the generator's own parser, not a subprocess

The reference generator shells out to `rustfmt`. `azure-sdk-for-zig`'s
generator shells out to `zig fmt`. This one calls `std.zig.Ast.parse` and
`renderAlloc` directly, which is exactly what the `zig fmt` subcommand does.

The obvious gain is that nothing is spawned and no compiler has to be on
`PATH`. The real one is that formatting becomes a correctness gate. The
emitter writes text, and text can be malformed; running every generated file
through the parser means a generator bug is reported here, naming the file and
the line, instead of surfacing as a compile error in a package that has
already been written to disk. `main.zig` treats a parse failure as a fatal
error and writes nothing.

`README.md` and `build.zig.zon` pass through untouched. `.zon` has its own
grammar that `std.zig.Ast` will not parse as Zig, and the emitter already
writes it in canonical form.

## The CLI is a pure function with a thin shell around it

`main.zig` is two things that do not touch each other:

- `parse(arena, argv)` turns arguments into a `Command`, returning a *message*
  rather than an error for a bad command line — that is the user's mistake,
  not an exceptional condition, and a message can be tested for.
- `generate(arena, command, sources, rooted, blame)` runs csdl → index →
  compile → optimize → emit over bytes that are already in memory, and
  returns the IR and the rendered package. `blame` is how a parse failure
  names the document it failed on: a corpus is thousands of files, and an
  error that does not say which one is not actionable.

Only `main` itself reads or writes a file. So `--dry-run` runs the entire
pipeline and writes nothing, the fixtures exercise the same `generate` the CLI
does, and a test can compile a schema without a temporary directory.

Directory arguments are sorted before they are read. The compile depends on
document order — `compile-oem` roots only the documents before a cut point —
and a package that depends on the order `readdir` happened to return is not
reproducible.

One flag from the plan is deliberately absent. `--redfish-core-commit` and
`--redfish-core-hash` would pin the generated package's dependency on
`redfish_core` by commit and package hash, as `azure-sdk-for-zig` does across
repositories. This is a monorepo with checked-in generated packages, so
`--redfish-core-path` is the whole story; adding a hash to pin one directory
against another in the same commit would be ceremony with nothing behind it.

## A fixture is a package that compiles, not a golden file

`codegen/fixtures/csdl/` is a hand-written corpus shaped like the DMTF
schemas. `zig build test` runs the generator over it and then **builds the
package that comes out**, linked against the real `redfish_core`.

The distinction matters more than it looks. The emitter already formats its
own output through `std.zig.Ast`, so anything it produces is known to *parse*.
But a field whose type was never emitted, a module that names a sibling it
does not import, a write shape referenced after being suppressed — all of
those are valid Zig text and none of them compile. Only the compiler finds
them, and it finds them for the whole surface at once rather than one
expectation at a time.

Every generated module therefore ends with

```zig
test {
    std.testing.refAllDecls(@This());
}
```

because a struct's field types stay unanalyzed until something asks for them.
Without the reference, building the package would check that the files parse
and little else.

The corpus is deliberately small and deliberately odd: a links-only complex
type, a resource nothing follows, a property that exists only inside excerpt
copies, three schema versions of one entity. Each one is there because it
reaches a branch nothing else reaches. `codegen/fixtures/README.md` says
which is which.

What is *not* checked in is the IR. `azure-sdk-for-zig` pins its code model as
JSON because that model arrives from a tool it does not own, so the diff is
the only way to see the input change. Here the input is the CSDL in that
directory — already readable, already reviewed — and the compiler's own tests
pin the model it produces. A third copy would be a file nobody reads behind a
script nobody runs.

## An empty write shape is worse than no write shape

A complex type holding nothing but links is *writable* by the permission
rules: a link is a way in, so whatever it points at might be. But write shapes
leave navigation properties out, so what is left is a struct with no fields —
one a caller can construct, fill with nothing, and PATCH, learning only from
the service that they said nothing at all.

So the emitter asks a second question after the permission rules: would this
shape have any fields? The answer recurses, because a property counts toward
its parent only if the shape *it* names is itself worth emitting, and it is
memoized per payload, since update and create select different properties.
A type that answers no gets no shape, and every property that would have
referenced that shape is dropped from the shape holding it — otherwise the
parent would name a type that was never emitted, which parses and does not
compile.

One exception: an **open** type is never empty to write. Its shape carries
`additional_properties`, which is the entire point of a vendor extension, so
`Resource.Oem` keeps its update shape even though the schema names nothing
inside it.

## A failure has to name what it was about

The standard corpus is 333 documents — 279 from DMTF, 54 from SNIA — declaring
some 1,400 types that refer to each other by qualified name. `error.TypeNotFound`
on its own leaves the operator to bisect a directory.

So both halves of the pipeline carry a `Diagnostics` out-parameter: the index
already reported which namespace was declared twice and which inheritance
cycle closed, and `compile.zig` now reports which name would not resolve.
`main.zig` funnels all of them, plus the path of a document that would not
parse, into one `blame` string:

```
redfish-codegen: FeaturesRegistry.FeaturesRegistry: TypeNotFound
```

That one line is what identified `Volume_v1.xml`'s reference into the
Swordfish bundle, which is why the standard profile takes both.

## The bundles overlap, and the first path wins

DMTF publishes `csdl/`; SNIA publishes `csdl-schema/`. Nine documents —
`ServiceRoot_v1.xml`, `Endpoint_v1.xml`, `DriveCollection_v1.xml` among them —
ship in both, and indexing the same namespace twice is an error.

`read` therefore keeps the base names it has already taken and skips a repeat.
Paths are searched in the order given, so the first `--csdl` wins and an
`--oem-csdl` wins over both, which is what a search path has always meant.
The alternative — making the operator name all 333 files to avoid nine
collisions — is how the reference project does it, and it is a manifest that
goes stale every time the corpus gains a schema.

## Not every complex type has a write shape, and callers must agree

Suppressing the empty write shapes had a consequence the fixture corpus was
too small to show: an **action parameter** of a complex type also names the
write shape, and `TelemetryService.SubmitMetricReport` takes a `MetricValue`
that has none. The generated package named `MetricValueUpdate`, which parses
and does not compile.

An action parameter now falls back to the read shape when there is no write
shape. The parameter still has to be sent, and the read shape names the same
members; the property permissions that suppressed the write shape describe
what a client may PATCH onto a resource, which is a different question from
what an action accepts as an argument.

This was the only such defect in 71,645 lines of generated Zig, and the
generated package compiling is the only reason it was found rather than
shipped.

## A vendor extension is not reachable, so nomination is the root set

Reachability is how the standard profile stays small: start at the service
singleton, follow links, keep what you arrive at. It cannot work for OEM
schemas, because the standard corpus describes a vendor extension as
`Resource.Oem`, an open object with no members. Nothing in DSP8010 names a
Contoso type, so no walk will ever reach one.

`compile-oem` therefore roots **everything the nominated documents declare**.
`--root` and `--entity-type-pattern` are not how an OEM package is selected;
passing the vendor's files is. The standard corpus is still read, but only to
resolve what those documents refer to.

That includes what their **actions bind to**. DMTF's own Contoso example is the
case that proves it: `ContosoAccountService_v1.xml` declares one action,
`AutoConfig`, and no types whatsoever. The action binds to
`AccountService.OemActions` — a standard type — so with only the vendor's own
declarations rooted, the action had nowhere to attach and the package came out
empty. Rooting an action's binding pulls in the one complex type it hangs on,
and the emitted package gets `account_service.OemActions` carrying
`@"#ContosoAccountService.AutoConfig"` and the method that invokes it.

## The example vendor is in the corpus already

`nv-redfish` vendors nineteen OEM CSDL documents from seven vendors under
`schema/oem/`. Copying them here would mean carrying third-party schemas of
uncertain provenance in order to demonstrate a code path.

DMTF publishes a fictional vendor, **Contoso**, in `Redfish-Publications`
itself, under `mockups/public-oem-examples/Contoso.com/` — three CSDL
documents covering the three shapes an extension takes: a complex type behind
`Oem` (`ContosoServiceRoot`), a whole OEM resource behind a link
(`ContosoTurboencabulatorService`), and a bare action (`ContosoAccountService`).
The same directory ships the matching JSON payloads.

So the OEM path is demonstrated, and round-tripped, against a dependency the
repository already has, with no vendoring at all. Real vendors point
`--oem-csdl` at their own files.
## Zig does not need `features.toml`

`nv-redfish` splits the schema into thirty cargo features — `chassis`,
`sensors`, `telemetry-service`, and so on — each naming its CSDL files and
root patterns in a 552-line `features.toml`. The reason is that a Rust crate
pays to compile every item it declares, so a client that only reads a chassis
cannot afford a crate that describes the whole of DSP8010.

Zig analyzes a declaration only when something references it, and the
granularity is per declaration, not per module. That makes the question
measurable, so it was measured, against the real package: 314 modules,
71,645 lines, generated from the pinned DMTF and SNIA corpora.

| Build (build runner and `std` already warm) | Time |
| --- | --- |
| A program that constructs one `Chassis` | 0.91 s |
| The package's own test binary, every declaration analyzed | 1.15 s |

Analyzing *everything* costs a quarter of a second more than analyzing one
type. And the laziness is real rather than an artifact of the measurement: a
deliberate type error planted in `thermal_metrics.zig` fails the second build
and is invisible to the first, because the first never looks at that module.

So there are no per-feature packages here, and no `profiles.yaml`. There is
one standard package, and one package per vendor — a list short enough to be
a `const` array in `build.zig`. Two things do survive from `features.toml`:
the rigid-array patterns, which are semantic rather than about size, and
which after thirty features number exactly two.

Selection is not gone, only unused by the standard profile: `--root`,
`--entity-type-pattern`, `--navigation-pattern` and `--everything` all still
work, and the fixture corpus exercises them. An operator with a reason to cut
the surface — a constrained target, an embedded service — still can.

## The corpora are lazy dependencies, and the output is committed

The schemas arrive as two pinned `git+https` dependencies, DMTF's
`Redfish-Publications` (also the source of the Contoso OEM example and of the
recorded payloads under `mockups/`) and SNIA's `Swordfish-Publications`. They
are **lazy**, and `-Dcorpora` is what asks for them, because `lazyDependency`
marks a dependency as needed the moment it is *called* rather than when the
step that uses it runs — and the build runner does not tell `build` which
steps were requested. Without the flag, `generate` fails with the flag as its
message. Nothing else in the repository reads them.

Being deliberate about this is not only about the download. **196 paths in the
Swordfish bundle differ only by case**, all under `mockups/`, so the bundle
cannot be unpacked onto a case-insensitive filesystem at all; an unconditional
fetch broke the macOS and Windows builds outright. Regeneration is a Linux
operation, and now it is one only when asked for.

That works because the generated packages are checked in. The reference
project generates into `OUT_DIR` from `build.rs`, which keeps the repository
small at the cost of making every consumer fetch 44 MB of XML and run a
compiler over it before they can build. Committing the output inverts that:
a consumer gets the schemas by fetching this repository, and a schema bump
becomes a reviewable diff rather than an invisible change of behaviour.

The cost is a gate, and there is exactly one: CI runs
`zig build -Dcorpora generate` on Linux and then diffs. A hand-edit of generated code fails it, a stale
package after an emitter change fails it, and so would any non-determinism in
the emitter. The reference project needs a `verify-*-regeneration.sh` per
package for the same reason; one diff covers every package here.

## What the schema says a service sends, and what it sends

Everything in this section came out of one exercise: taking all 3,780 payloads
DMTF ships in `mockups/`, resolving each `@odata.type` against the generated
package, and parsing it. 204 failed. None of the failures was visible to the
compiler's own tests, because in those tests nothing plays the part of a
service — the compiler writes the types *and* the expectations, so it can be
entirely self-consistent and still emit types that nothing can fill.

The suite that now guards this lives in `tests/`, and `tests/README.md`
describes the corpus.

### Reachability cannot find a resource nothing links to

The root set is the entity-container singletons, and the compiler walks
navigation properties out from there. That misses `ActionInfo`, `Event`,
`MessageRegistry` and `AttributeRegistry` entirely: the protocol addresses
each of them by a URI it learns some other way — from an action's
`@Redfish.ActionInfo`, from an SSE stream, from a registry's `Location`. No
navigation property points at any of them, so none was compiled.

`SchemaIndex.addressed_by_uri` names those four and `compile` roots them.
Hard-coding a list is unsatisfying, but the alternative is to root every
entity type in the corpus, which is what `--everything` is for and is not what
a client wants. The reference project reaches the same list by hand, in
`features.toml`.

### `Redfish.Required` is a statement about a conformant service

177 of the recorded payloads omit a property their own schema marks required.
Every `Role` mockup omits `RoleId`; the `Drive` mockups omit `Id` and `Name`.
These are DMTF's own published examples, and real BMCs are less careful than
DMTF.

So no read shape is mandatory: `Redfish.Required` becomes documentation, and
every field of every read struct is optional. The asymmetry decides it. Making
a field optional costs the caller an unwrap; making it required costs the
caller the entire response, including the forty properties that did arrive,
because one was missing.

Writes go the other way. `Redfish.RequiredOnCreate` and a required action
parameter stay non-optional, because there the compiler is checking what *we*
are about to send, and catching a missing required field before it leaves is
exactly what a type is for.

The reference project makes a required property non-optional in both
directions, so it would fail these same 177 payloads.

### `Nullable` on a collection describes the members

OData CSDL is explicit about this — a collection-valued property always
exists, and `Nullable` says whether its *members* may be null (ODATA-543) —
and Redfish leans on it. `EthernetInterface/StaticNameServers` and
`AccountService/ExternalAccountProvider/ServiceAddresses` are both fixed-length
collections in which a null means "this slot is empty", and in CSDL the two
declarations are byte-for-byte identical: `Collection(Edm.String)`, no
`Nullable` attribute, so members are nullable by default.

The reference project instead maintains an allowlist of "rigid arrays" in
`features.toml`, which names `StaticNameServers` and does not name
`ServiceAddresses` — which is why DMTF's own account-service example does not
parse. Reading the attribute the way the spec defines it covers all 620 of the
corpus's collection properties that take the default, and deletes both the
allowlist and the `--rigid-array-pattern` flag that fed it. That was the last
thing `features.toml` was still needed for.

### `@odata.id` is not universal

It is how the protocol addresses a resource, and 3,767 of the 3,780 payloads
have one. The 13 that do not are not sloppiness — they are systematically the
payloads that are not resources: an event delivered over SSE, a message or
attribute registry document, an action response. None of them lives at a URI,
so none of them has an id.

This matters more than the count suggests. `redfish_bmc_http` has an SSE
reader, and an `Event` that requires `@odata.id` cannot parse anything that
reader produces — the EventService support would have been unusable.

So `@odata.id` is optional like every other read field, and `entity.id` returns
`?ODataId`, exactly as `entity.etag` already did for the same reason. The
knock-on is small and honest: `NavProperty.toReference` and `downcast` return
null when an expanded payload carried no id, and `updateEntity` fails with
`error.NotAddressable` rather than PATCHing an address it does not have.

### Timestamps are parsed leniently and written canonically

21 payloads carry a timestamp RFC 3339 rejects: `2012-03-07T14:44` has no
seconds, `2024-11-15T06:18:37` has no offset, `+6:00` writes the offset hour
with one digit, and one has a trailing space. All four are now accepted.

Only the missing offset needs care, because it is the only one where the
sender left out something that cannot be reconstructed. Reading `14:44` as
`14:44:00` invents nothing; reading a naive timestamp as UTC invents a
timezone. So `DateTimeOffset` records whether an offset was given and writes
the value back the way it arrived.

Two payloads are still rejected, and both should be. `CapacityBytes:
23058430092136940000` does not fit in the `Edm.Int64` its schema declares, and
`Lifetime: "P4Y"` is not an `Edm.Duration` — that type is `xs:dayTimeDuration`,
and a year is not a fixed number of seconds.
