# CADView acadrust 0.4.1 patch

Upstream: https://github.com/hakanaktt/acadrust

Crates.io archive checksum:
`d96c49ac7520273f8fb65865995efca78f5d75fdaf11d3ba3c87114f6496b941`.

The original `LICENSE` is retained. All upstream source, including our changes
to the files below, remains MPL-2.0. The application and its format adapters are
separate Apache-2.0 code. Distribute this directory with release source archives.

Local changes:

- `src/entities/insert.rs`: under an INSERT, recover an ellipse's principal
  axes from its transformed conjugate semi-diameters (non-uniform scale with a
  rotated ellipse or arc), negate the former major axis when the axes swap so
  arcs are not reflected across the new major axis, and route ELLIPSE through
  the same transform instead of the generic one that kept a stale ratio.
- `src/entities/transform.rs`: CIRCLE/ARC centers, SOLID corners and 2D
  polyline vertices are OCS coordinates. Transform them through WCS and store
  them in the transformed normal's OCS, rather than treating OCS values as
  WCS (which mirrored them a second time under a (0,0,-1) INSERT or a block
  base-point shift).
- `src/entities/explode.rs`: HATCH boundaries are 2D OCS at the hatch
  elevation; exploded LINE/ELLIPSE/SPLINE edges are converted to WCS, rational
  spline-edge weights (stored in the control point Z) are kept as weights, and
  clockwise arc/ellipse edges use the stored mirrored-angle convention (true
  range −end … −start) instead of swapping the stored angles.
- `src/entities/mtext.rs`: retain an optional complete WCS X-axis direction;
  explicit directions take precedence over angle-based construction and are
  defaulted when deserializing older serde data. Retain the embedded column
  defined height and total width/height separately from ordinary MTEXT extents,
  with defaults for older serde domain data.
- `src/io/dwg/dwg_document_builder.rs`: retain the binary reader's original
  direction instead of discarding its Z coordinate after `atan2`; retain ATTRIB
  generation, visibility, type, field-length and position-lock metadata; map
  standalone and embedded MTEXT with one shared geometry/style conversion;
  preserve ATTDEF alignment, width/slant, OCS, style, mirror, field length and
  position lock instead of replacing them with domain defaults.
- `src/entities/attribute_entity.rs` and `attribute_definition.rs`: retain an
  optional embedded MTEXT object with serde defaults for older domain data.
- `src/io/dwg/dwg_stream_readers/object_reader/mod.rs`: share the entity-mode
  tail with embedded objects, without reading a second object/EED/graphics
  preamble. Preserve all existing standalone entity-header behavior.
- `src/io/dwg/dwg_stream_writers/object_writer/entities.rs`: write the explicit
  vector when supplied, allowing tilted/vertical fixtures and lossless direction
  round trips; emit the MINSERT type and grid fields for array fixtures instead
  of silently writing only one INSERT; preserve attribute/definition mirror flags
  and definition position locks.
- `src/io/dwg/dwg_stream_readers/object_reader/entities.rs`: consume R2004+
  owned-attribute counts before MINSERT grid fields, in agreement with ODA's
  specification and ACadSharp's `readInsertCommonData` implementation; decode
  R2018 embedded MTEXT and conditional annotation payload before attribute tags
  and flags. Independent field-stream tests cover both attribute kinds and
  annotation branches, including cursor/handle sentinels. Preserve R2018 column
  height/total extents previously discarded as redundant; the domain builder
  and writer retain those explicit values and the complete repeated direction.
- `src/io/dwg/dwg_stream_writers/object_writer/mod.rs`: preserve BlockRecord
  base points in generated fixtures when no separate BLOCK entity is present.
- `src/io/dxf/reader/section_reader.rs` and
  `src/io/dxf/writer/section_writer.rs`: retain/write explicit direction vectors.
- `src/entities/transform.rs` and `src/entities/mirror.rs`: transform explicit
  vectors exactly once and keep their projected-angle metadata consistent.
- `src/entities/insert.rs`: rotate MINSERT offsets with the block's rotation;
  do not apply block scale factors to grid spacing.
- `tests/roundtrip.rs`: canonicalize only absent MTEXT direction vectors to
  their writer-equivalent XY representation for comparison; retain and test
  sensitivity to explicit XY/Z direction differences. The original four failing
  complex-line-type/deep-roundtrip cases remain failing and are documented.

No parser compatibility claim is based solely on the modified writer's round
trip tests. CADView additionally uses independent matrix arithmetic and real
pixel assertions; original-CAD comparison and licensed corpus gates still apply.
