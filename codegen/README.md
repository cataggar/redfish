# `redfish-codegen`

Compiles Redfish CSDL into a Zig package.

```
zig build
./zig-out/bin/redfish-codegen --help
```

## The pipeline

```
XML  →  csdl.zig          one document per file, streaming XML
     →  schema_index.zig  namespaces, aliases, inheritance both ways
     →  compile.zig       root set, traversal, annotations   →  IR
     →  optimize.zig      prune what the profile cannot reach
     →  emit.zig          a package, in memory
     →  format.zig        `std.zig.Ast`, which is what `zig fmt` is
     →  disk
```

Everything before the last step is a pure function of the input bytes.
`--dry-run` runs all of it and writes nothing, and the tests drive the same
`generate` the CLI does.

Nothing is spawned and no compiler has to be on `PATH`: formatting goes
through `std.zig.Ast`, the same parser and renderer `zig fmt` uses. That makes
formatting a correctness gate too — source the emitter got wrong fails to
parse here, naming the file and line, instead of after a broken package has
been written.

## Generating the packages this repository ships

```
zig build generate
```

That regenerates every package under `schema_packages/` in place, from the
DMTF and SNIA corpora pinned in `build.zig.zon`. They are lazy dependencies,
so this is the only step that fetches them. What each package is called and
how it is rooted lives in `build.zig`; CI regenerates and then diffs, so what
is committed is what the generator produces.

## Compiling a surface by hand

```
redfish-codegen compile out/redfish_schema_chassis \
    --csdl <corpus>/csdl \
    --package-name redfish_schema_chassis \
    --profile chassis \
    --root Service \
    --entity-type-pattern 'Chassis.*' \
    --rigid-array-pattern 'Chassis.*/Location'
```

The standard package uses none of this: it takes `--root Service` and keeps
everything the service reaches, because in Zig an unreferenced declaration
costs a consumer nothing to carry. Cutting the surface is for a target where
something else is scarce.

`--root` names an entity-container singleton to start traversal from — the
`Name` of a `<Singleton>` in an `<EntityContainer>`, which for the Redfish
service root is `Service`, not the type it points at.
`--entity-type-pattern` roots types the singleton does not reach.
`--navigation-pattern` narrows which links are followed and expandable; saying
nothing follows every one, which is what makes an unfiltered compile useful
for exploring a schema you have not seen. `--rigid-array-pattern` names
collections the service keeps at a fixed length, so their entries stay
addressable and a null entry is meaningful — nothing in the schema says which
those are.

`--everything` roots the whole corpus. It is for exploring, not for shipping:
the resulting package carries every type the CSDL declares.

## Compiling an OEM profile

```
redfish-codegen compile-oem out/redfish_schema_oem_dell \
    --oem-csdl <vendor>/dell \
    --csdl <corpus>/csdl \
    --package-name redfish_schema_oem_dell \
    --profile oem_dell
```

`--oem-csdl` documents are read first and are the only ones allowed to
contribute roots — **all** of them, plus whatever their actions bind to. A
vendor extension hangs off an `Oem` object the standard schema describes as
having no members, so no reachability walk finds one and nominating the files
is the whole selection. There is no pattern to write.

The standard corpus is still indexed, so vendor schemas resolve their
references against it, but it roots nothing of its own: an OEM package carries
the vendor's surface plus whatever it links to, not the whole of Redfish.

`schema_packages/redfish_schema_oem_contoso` is the worked example, generated
from DMTF's own fictional vendor under `mockups/public-oem-examples/`.

## Fixtures

`fixtures/csdl/` is a hand-written corpus shaped like the DMTF schemas, cut
down to the smallest surface that still reaches every path in the generator.
`zig build test` compiles it into a package and then **builds that package** —
parsing the emitter's output is not the same as compiling it. See
`fixtures/README.md`.

`--emit-model <path>` writes the IR as JSON, which is how to inspect what the
compiler decided without reading the Zig it turned into.

## Flags

Run `redfish-codegen --help`. The full list lives in `cli/src/main.zig`, which
is the only place it is written down.
