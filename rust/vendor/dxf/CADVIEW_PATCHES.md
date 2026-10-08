# CADView's dxf 0.6.1 patch

The base source is the published crates.io `dxf` 0.6.1 package from
<https://github.com/ixmilia/dxf-rs>. Original sources retain the MIT license in
`LICENSE.txt`; CADView's changes in this directory use the same MIT license.
The original registry package checksum is
`6bb070bbb077a936e2bdf95d4b39aa83e865b38c3a7054f71d704e0796da1821`.

Local changes:

- Buffer ASCII code-pair input in 64 KiB spans and reuse the line byte buffer.
  Codes and numeric values borrow that buffer instead of allocating strings;
  string values become owned before reading the next line.
  ASCII-compatible code pages use the exact ASCII fast path; non-ASCII values
  still use the declared decoder and preserve malformed-string errors. Numeric
  parse error types, line offsets, UTF-8 BOMs and CRLF semantics are retained.
- Expose `Drawing::load_with_entity_sink`: headers, tables and block definitions
  are retained, but assembled model/paper entities are delivered individually.
  It shares the original INSERT/attribute and POLYLINE/vertex collector, handle
  assignment, table defaults and error propagation. The application uses two
  passes for inputs ≥8 MiB (excluding DXB), so late sections cannot change the
  normalization result. All smaller drawings use the original retained loader.

- Decode binary NUL-terminated string bytes with the declared encoding instead
  of casting each byte to a Unicode character. Track byte offsets before decoding.
- Honor the header's `$DWGCODEPAGE` for legacy ASCII and binary files; R2007+
  always switches to UTF-8 and is not reverted by a legacy code-page tag.
- Share an explicit code-page resolver with CADView's bounded ASCII header scan.
- Keep MTEXT group-50 rotation in DXF degrees, as emitted/read by ezdxf,
  LibreCAD/libdxfrw and acadrust (the Autodesk reference's radians label is
  inconsistent with interoperable files). Normalize only in the scene adapter.
  Honor the last angle/vector group, clear stale Y/Z components when a new
  vector starts and the stale Z component when an angle overrides a vector,
  and use the resulting WCS vector for both angle and vector forms. MTEXT does
  not use TEXT's OCS, including for non-default extrusion planes; the scene
  adapter handles this without adding a dependency-specific provenance flag.
- Preserve raw MTEXT background flags (including combined fill/frame values),
  rather than dropping combinations not represented by the legacy enum. Use the
  nominal 1.5 border-scale default. Accept background RGB/name ranges 420–429 and
  430–439, writing canonical 421/431. Track explicit RGB presence so black is not
  confused with an absent background override. Entity RGB before `AcDbMText`
  remains entity ink; an older background-420 alias after the mask flags remains
  readable. Generated code derives these fields from `spec/EntitiesSpec.xml`.
- Keep a separate presence bit for common entity RGB (420), so explicit black
  (`0`) does not become absent/ByLayer. Preserve zero during ASCII/binary writes,
  keep programmatic nonzero RGB compatible, and enforce the R2004 write gate.
  The base-entity generator honors `GenerateReader=false` for provenance fields.
- Preserve LAYER RGB as `Option<i32>` and its color-book name; absence and black
  remain distinct without changing the negative-ACI layer-off flag. MTEXT common
  420/430 before its mask flags or outside its subclass remains entity color,
  while canonical 421/431 and legacy mask-scoped aliases remain mask color.
- Separate the R2018 MTEXT `101/Embedded Object` namespace from ordinary MTEXT
  tags. Embedded 10/20/30 define the WCS direction, 11/21/31 repeat insertion,
  40 repeats reference width, 41 defines column height, 42/43 store total column
  extents, 71–74 define column type/count/flags, 44/45 define column width/gutter,
  and repeated 46 values store manual heights. Never overwrite nominal glyph
  height, attachment, spacing or mask margin with these fields. Preserve total
  extents, defined height and column provenance as read-only generated fields.
  Unknown embedded-object tags are isolated, trailing XDATA and subsequent
  entities remain readable, and embedded height vectors are limited to 4096.
- Preserve the original entity-reader failure when collecting entities, rather
  than treating a parse/resource failure as a normal iterator end and replacing
  it with a misleading `expected 0/ENDSEC` error. This applies inside BLOCKS too.
- Expose `Drawing::raw_code_pairs`, a read-only iterator over the existing
  ASCII/binary code-pair readers. The entity reader still discards types it
  does not model; CADView uses the raw pairs to read HATCH boundaries and to
  diagnose discarded entity types instead of silently omitting them.

The separate Apache-2.0 scene adapter uses the authoritative column width and
normalizes valid unified R2018 column metadata for the shared application
renderer. Invalid/non-unified specifications retain `mtext_columns_flattened`.
These reader changes do not supply legacy linked-column reconstruction or an
interoperable embedded-object writer; application layout tests are documented
in `docs/TESTING.md` at the repository root.

Reproduction and application-level regressions:

```sh
cd rust
cargo run -p cad-formats --example audit_dxf_text_encoding
cargo test --workspace
TZ=UTC cargo test --manifest-path vendor/dxf/Cargo.toml --lib --locked
```

Test fixtures author binary group pairs independently of the library writer;
writer/reader agreement alone cannot prove interoperable text decoding. No
proprietary CAD fonts or user drawings are included in this dependency.
