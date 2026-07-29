# Integration tests

## `payloads/` — recorded BMC responses

251 real Redfish responses, taken verbatim from the `mockups/` directory that
DMTF ships in [`Redfish-Publications`][pubs] alongside the CSDL. Each is
re-indented and key-sorted so a diff is stable; nothing else is changed.

[pubs]: https://github.com/DMTF/Redfish-Publications

**The curation rule:** one payload per generated type — the largest recorded
example of it, preferring DMTF's own `DSP2046-examples/`. The corpus has 253
distinct `@odata.type` values; 251 resolve to a type in
`redfish_schema_std`. The two that do not are Contoso's OEM service, which
belongs to the vendor package, and an action *response* that names itself as
though it were a resource.

Each file is named for the type it must deserialize into
(`<module>.<Type>.json`), and `payloads.zig` records where it came from.

### Three payloads are deliberately excluded

They are the only ones of the 3,778 that do not parse, and none of them is a
defect in the generated types:

| Payload | Why |
| --- | --- |
| `Volumes/RenderStorage` | `CapacityBytes` is `23058430092136940000`, which does not fit in the `Edm.Int64` its own schema declares. |
| `Job-v1-example` | `Lifetime` is `P4Y`. `Edm.Duration` is `xs:dayTimeDuration`; a year is not a fixed number of seconds, so the value is unrepresentable by definition rather than by choice. |
| `ConstrainedCompositionCapabilities` | A `@Redfish.CollectionCapabilities` *template*, not a resource. It borrows `ComputerSystem`'s `@odata.type` but follows a different shape convention, in which a collection-valued property may be written as a single object standing for "an element like this". |

For each of the first two a different payload of the same type is checked in
instead, so no coverage is lost.

## Regenerating the corpus

The corpus is checked in, so the test suite needs no network. To re-curate it
against a newer `Redfish-Publications` tag, fetch the corpus the way
`zig build -Dcorpora generate` does and re-run the selection: parse every
`mockups/**/*.json`, resolve its `@odata.type` against
`schema_packages/redfish_schema_std/src/root.zig`, and keep the largest
example of each type.

## Why recorded payloads and not written ones

A schema compiler can be entirely self-consistent and still emit types that no
service can fill, because nothing in its own tests ever plays the part of the
service. Sweeping all 3,780 recorded payloads against the generated package
found four defects that the compiler's own tests could not:

1. **Reachability misses resources the protocol addresses by URI.** Nothing
   links to `ActionInfo`, `Event`, `MessageRegistry` or `AttributeRegistry`,
   so none of them was compiled at all.
2. **`Redfish.Required` describes a conformant service, not a real one.** 177
   payloads omit a property their own schema marks required.
3. **`Nullable` on a collection describes the members.** OData is explicit
   (ODATA-543) and 620 of the corpus's 795 collection-valued properties take
   the default, which is nullable members.
4. **`@odata.id` is not universal.** An event, a registry document and an
   action response each name a type and have no id, because none of them lives
   at a URI.

`doc/architecture.md` records the reasoning for each.
