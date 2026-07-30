# Vendor CSDL

The one place this repository keeps CSDL in the tree.

Everything else the generator reads is a pinned, lazy `build.zig.zon`
dependency — 44 MB of DMTF and SNIA XML, fetched only when
`zig build -Dcorpora generate` asks for it. These sixteen files are 910 lines
and they are here instead, because there is nowhere to fetch them from.

## Why not fetch them

DMTF publishes the standard schemas, and publishes Contoso's as an example of
what a vendor extension looks like. Actual vendors mostly do not. HPE's iLO
extensions, AMI's `RtpVersion`, Dell's `Attributes` — these appear in service
payloads without a schema document to describe them, or with one that ships
inside a firmware image rather than in a repository anyone can pin.

So these documents are written from observed payloads rather than published by
the vendors named in them. That is what they are, and it matters:

- **They describe only what a client reads.** `HpeiLO_v1.xml` declares one
  property. HPE's iLO declares hundreds. Nothing here is a complete account of
  a vendor's extension and nothing should be read as one.
- **A property missing here is not a property missing from the service.** It
  is a property nobody has needed yet. Adding one is adding a line of XML and
  regenerating.
- **The version namespaces are the ones seen on the wire**, because that is
  the only evidence available. `HpeiLO.v2_11_0` means a payload said so.

They are otherwise ordinary CSDL: the generator resolves their references
against the standard corpus exactly as it resolves Contoso's, and the packages
under `schema_packages/redfish_schema_oem_*` are emitted by the same code path.

## Where they came from

Ported from [`nv-redfish`][nv]'s `schema/oem/`, which is Apache-2.0 and
copyright NVIDIA — the same license this repository is under. The copyright
headers are unchanged. `contoso/` is not among them: DMTF publishes Contoso in
the corpus, so `redfish_schema_oem_contoso` is generated from the pinned
dependency rather than from here.

`nvidia-baseboard/` and `nvidia-bluefield/` were renamed to
`nvidia_baseboard/` and `nvidia_bluefield/` to match the package names they
generate, which have to be Zig identifiers.

[nv]: https://github.com/NVIDIA/nv-redfish

## Adding a vendor

1. Write the CSDL under `schema/oem/<vendor>/`, one document per resource or
   complex type extended, named as the vendor names it.
2. Add a `SchemaPackage` to `packages` in `build.zig` with
   `.oem = &.{.{ .vendored = "schema/oem/<vendor>" }}`.
3. `zig build -Dcorpora generate` on Linux, and commit what it writes. CI
   regenerates and diffs.
