# Codegen fixtures

`csdl/` is a hand-written CSDL corpus: six documents shaped like the DMTF
schemas they are named after, cut down to the smallest surface that still
reaches every path in the generator.

`zig build test` compiles it into a package and then **builds that package**,
which is the point. Parsing the emitter's output is not the same as compiling
it — a field whose type was never emitted, or a name that resolves to nothing,
is still valid Zig text. Only the compiler catches those, so it runs on every
test.

## What each document is here to prove

| Document | What it exercises |
| --- | --- |
| `Resource_v1.xml` | The abstract base every resource inherits from, type definitions (`Resource.Id`), enumerations, and an open type (`Resource.Oem`) |
| `ServiceRoot_v1.xml` | The `EntityContainer` and the `Service` singleton the profile roots from; links to two collections |
| `Chassis_v1.xml` | Three versioned namespaces merged into one type, a bound action, an `Actions` structure, a links-only complex type, a collection with nullable members, and links both inside and outside the surface |
| `ChassisCollection_v1.xml` | A collection and its `Members` link |
| `SessionCollection_v1.xml` | `Capabilities.InsertRestrictions` on the collection, which is what makes its members creatable; a write-only property and two required on create |
| `Sensor_v1.xml` | Excerpts: a default view, a named view, and a property that exists only inside copies |
| `ThermalMetrics_v1.xml` | A resource the profile deliberately does not follow, so the out-of-surface link is emitted as a bare reference |

## Regenerating by hand

```bash
zig build fixture
```

writes the package under `.zig-cache`. To read it somewhere convenient:

```bash
zig build && ./zig-out/bin/redfish-codegen compile /tmp/fixture \
    --csdl codegen/fixtures/csdl \
    --package-name redfish_schema_fixture \
    --profile fixture \
    --root Service \
    --navigation-pattern 'ServiceRoot.*' \
    --navigation-pattern 'ChassisCollection.*' \
    --navigation-pattern 'Chassis.*' \
    --navigation-pattern 'SessionCollection.*' \
    --navigation-pattern 'Session.*' \
    --navigation-pattern 'Sensor.*' \
    --emit-model /tmp/fixture.json
```

The flags are the same ones `build.zig` passes; they live in `fixture_args`
there.

## Why the IR is not checked in

The generator's own tests pin the emitter's output as expected text, and the
compiler's tests pin the IR the same way. A checked-in `fixture.json` would
pin the seam between them a third time, and it would have to be regenerated
on every compiler change — a file nobody reads, guarded by a script nobody
runs.

The reference generator this project follows checks its IR in because that IR
comes from a tool it does not own, so a diff is the only way to see the input
change. Here the input is the CSDL in this directory, which is already
readable and already reviewed.
