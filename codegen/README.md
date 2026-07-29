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

## Compiling a profile

```
redfish-codegen compile schema_packages/redfish_schema_chassis \
    --csdl schema/redfish-csdl \
    --package-name redfish_schema_chassis \
    --profile chassis \
    --root ServiceRoot.ServiceRoot \
    --entity-type-pattern 'Chassis.*' \
    --rigid-array-pattern 'Chassis.*/Location'
```

`--root` names an entity-container singleton to start traversal from.
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
redfish-codegen compile-oem schema_packages/redfish_schema_oem_dell \
    --oem-csdl schema/oem/dell \
    --csdl schema/redfish-csdl \
    --package-name redfish_schema_oem_dell \
    --profile oem_dell \
    --entity-type-pattern 'Dell*.*'
```

`--oem-csdl` documents are read first and are the only ones allowed to
contribute roots. The standard corpus is still indexed, so vendor schemas
resolve their references against it, but it roots nothing of its own — an OEM
package carries the vendor's surface plus whatever it links to, not the whole
of Redfish.

## Fixtures

`--emit-model <path>` writes the IR as JSON. That is the artifact fixtures pin:
it makes an emitter change reviewable as a diff of generated Zig, with the
input held still.

## Flags

Run `redfish-codegen --help`. The full list lives in `cli/src/main.zig`, which
is the only place it is written down.
