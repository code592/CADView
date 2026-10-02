# Architecture

## Dependency direction

```text
Flutter UI
    |
    v
FRB application API ---- SQLite annotation store
    |
    v
format registry --> isolated adapters
    |
    v
cad-core (Scene2D / Scene3D / measurements / spatial index)
```

`cad-core` deliberately has no Flutter, renderer, database or parser
dependency. Adapters may only emit `OpenedDocument` containing `Scene2D`,
`Scene3D` or `PagedScene`. UI code never consumes parser-native objects.

## Format adapter contract

Every `FormatAdapter` provides `probe`, `open`, `open_path`, `stream_scene`,
`metadata`, `capabilities` and cancellation through a shared
`CancellationToken`. Detection examines only the first 4 KiB before
considering the path suffix. Path adapters may then use seekable file access;
the DWG backend does this instead of copying the entire source into registry
memory. The sink contract permits progressive partial scenes without exposing
parser types.

## 2D scene

Geometry remains `f64` in Rust. Layers and entity bounds are serializable;
`SceneIndex2D` is a runtime R-tree intentionally excluded from caches. Hit
testing first queries the R-tree then computes exact primitive distance.
Snapping currently covers point, endpoint, midpoint, vertex, center and text
insertion points.

The transitional Flutter renderer receives the initial geometry only for
scenes of at most 250,000 entities; larger scenes initially return metadata.
Viewport queries return all visible-layer R-tree candidates without stride
sampling or truncating details. A zoom-to-fit query can therefore still return
a large payload: the pending native texture renderer is required for the large
file memory/performance gates. The complete scene remains in Rust.

CAD text is shaped once at a fixed, camera-independent font size. Text-only
metadata pages (up to 64 labels and approximately 64 KiB including style runs;
one oversized label is delivered alone so paging still advances) are measured by the active Flutter font
stack; validated world envelopes are returned to the Rust R-tree before the
session becomes ready. The index is rebuilt once after all labels are measured.
This keeps parser/core crates font- and Flutter-independent while preventing
fitted or wrapped glyphs from escaping approximate native bounds. Measured
bounds are runtime-only, not reused from another device's font environment.

Text height carries an explicit `cap_height` (CAD) or `em` (SVG) reference.
The Flutter font service reads bounded offline font metrics and performs one
reference-capital raster calibration per requested family before measuring
native text bounds. Font metrics revisions participate in the paragraph cache
key; calibration never changes UI/annotation font sizes or adds a frame loop.
Missing families use the same bundled fallback. A failed/bounded calibration
keeps readable default metrics and adds a document diagnostic. Scene cache
version 23 invalidates older font-size/reference, MTEXT spacing, DWG text
instance-plane, attribute placement/visibility, embedded-paragraph and constant
definition semantics.

DWG TEXT retains its OCS frame and MTEXT its complete WCS X-direction vector,
including Z, through the pinned MPL-2.0 reader in `rust/vendor/acadrust`.
Block normalization pairs each original text with its legacy exploded entity
and composes the complete 3D insertion/base-point frame before projecting to
Scene2D. The projected basis carries mirror, shear and nonuniform scale; local
font height and paragraph width are not decomposed into lossy axis lengths.
MINSERT grid spacing rotates once with the insertion and is not multiplied by
block scale. Non-text nested geometry still uses the existing exploded-entity
path; complete affine correctness for every entity is not claimed.

Single-line ATTRIB uses the same OCS/alignment/Fit/Aligned/mirror normalization
as TEXT. Its coordinates already belong to the containing space: the enclosing
frame is applied once, without applying the owning INSERT's scale/rotation a
second time. MINSERT attributes repeat at each rotated, unscaled grid offset;
zero-layer and ByBlock inheritance are preserved. Both entity and attribute
invisibility flags are honored. The resource preflight includes attributes even
for empty block definitions, before allocating exploded array cells.
R2018 embedded MTEXT is read from the entity-mode tail (no second object/EED/
graphics preamble), then through the same MTEXT body decoder as standalone
paragraphs. Conditional annotative bytes are consumed before the attribute tag
and flags, so text/handle/data streams stay synchronized. ATTRIB and ATTDEF
retain the full paragraph; ATTRIB rendering uses its authoritative content,
WCS position/direction, attachment, width, line spacing and style, not the outer
legacy TEXT representation. Only a declared multiline attribute with no
embedded paragraph uses the diagnosed legacy fallback.
Visible constant ATTDEF values are emitted once per block instance, with the
complete enclosing/base-point frame, OCS, alignment, style and mirror fields.
Nonconstant definitions and both forms of invisible definitions are excluded.
Constant-only MINSERT arrays participate in the same resource preflight; nested
constant paragraphs use their authoritative embedded MTEXT geometry. Ordinary
ATTRIB coordinates keep their distinct containing-space convention.
Multi-column layout remains incomplete; full
multiline-attribute fidelity is not claimed. The
vendored writer still emits single-line attributes, so it cannot generate the
new native acceptance fixture yet.

MTEXT separately retains its line-spacing factor (0.25–4.0) and AtLeast/Exact
policy. The nominal baseline grid is 5/3 of CAD cap height times the factor;
AtLeast permits larger run metrics, while Exact locks the grid even when the
source intentionally overlaps tall text. Forced-grid envelopes additionally
measure natural ascents/descents at the same line breaks, so oversized glyphs
remain visible and indexed outside the grid. Invalid factors fall back to 1.0
with a structured diagnostic. Ordinary TEXT and SVG em-sized text do not
receive an MTEXT strut. Paragraph cache keys include the validated spacing;
no additional recurring frames are introduced.

Single-column MTEXT retains its background fill/frame flags, explicit RGB
(including black), canvas color and inherited layer/block color. The painter
uses the same paragraph transform for text and mask; source-order paint segments
keep later geometry above a mask. Border margins use nominal CAD text height,
not the shaped font's em or the paragraph width, and enter spatial/culling bounds.
Mask paths and text layouts remain cached. Background transparency is retained
and diagnosed rather than interpreted as an undocumented alpha convention.
Invalid/unsupported column layouts are diagnosed and never apply a single wide
mask over gutters. Valid unified columns use separate boxes as described below.
The background-only revision used cache 24 / parser `cadview-10`; the unified
column revision supersedes those cached previews. Explicit CAD draw-order tables
remain outside this source-order fallback's fidelity claim.

DXF entity RGB has explicit presence metadata: `420=0` is pure black, not a
missing color override. LAYER RGB is retained independently of its ACI/on-off
state, and resolved ByLayer ink/backgrounds use the same layer color. Direct
entities without an owning INSERT use ACI 7 for ByBlock, not their layer color;
ByEntity background color uses resolved entity ink. Named entity color-book
fields no longer produce spurious named-mask diagnostics. An unavailable named
mask color without numeric RGB still uses the diagnosed numeric fallback.
These changes do not supply the still-missing DXF block normalization. DXF is
not currently disk-cached, so the unchanged DWG cache is not invalidated.

R2018 DXF MTEXT embedded objects use a separate group-code namespace. Their
WCS direction, defined column height, total extents, type/count/flow, width,
gutter and manual heights are retained by the reader without replacing the
main insertion, nominal glyph height, attachment, line spacing or mask margin.
Trailing XDATA and subsequent entities remain readable; unknown embedded
object tags cannot leak into ordinary MTEXT settings. Valid unified R2018
DXF/DWG column specifications now enter `MTextColumns2D`, including inferred
dynamic-auto counts, individual manual heights, reverse flow and decoded UTF-16
manual breaks. Static/auto column heights and the last manual zero-height tail
remain distinct. Invalid or non-unified specifications still receive a diagnosed
flattened fallback. This is not a claim of legacy linked-column reconstruction
or an embedded-object DXF writer. Entity-iterator failures now propagate their
original cause rather than masquerading as successful end-of-input, including
inside blocks. Excessive embedded height data is bounded to 4096 entries.

Column drawing, attachment offsets, background boxes and spatial refinement
share one cached, camera-independent shaped block. Flow uses actual UTF-16 line
boundaries, not scalar-count wrapping; scoped font runs are rebased per column.
All column masks are painted before glyphs and never cover the entire gutter
or clip tall/overhanging glyphs. Exact-spacing ink envelopes use the same column
source ranges, rather than repartitioning a second natural-height block.
The last column retains excess content instead of silently discarding labels.
Column paragraphs are owned by their block and the LRU additionally bounds the
number of retained paragraphs. DWG embedded height/total extents survive the
vendored reader/domain/writer; parser version `cadview-14` and scene cache 28
invalidate previously flattened cached scenes. Original-CAD visual parity,
vertical text flow and legacy linked-column XDATA remain unverified/incomplete.

Text metadata includes decoded UTF-16 style ranges for scoped MTEXT font,
relative/absolute height, bold/italic and underline/overline/strike-through.
Every inline run explicitly carries both its requested/inherited primary font
and the same bundled fallback families as its parent. Inheriting only part of
that list can cause the engine to substitute another font.
Painting and bound refinement use the same styled paragraph. Parser limits
(64 nested groups, 4096 runs, bounded height factors/font names) preserve the
readable label and emit aggregated diagnostics when styling falls back.
Unsupported inline width, tracking, oblique/color/paragraph/stack formatting
is diagnosed, not claimed as original-CAD-equivalent typography.

## 3D scene

The normalized scene stores assembly nodes, mesh instances, materials,
positions, normals, indices, bounds and statistics. Current Flutter rendering
is a triangle-budgeted preview intended for development and small files.
Production 500 MB / five-million-triangle acceptance requires the pending
`cad-render` wgpu module, native Flutter external textures, BVH, instancing,
frustum culling and disk-backed LOD.

## Document lifetime and annotations

Opening creates a Rust session. The source fingerprint, scene, R-tree, camera,
annotation document and undo/redo history stay in that session. Annotation
SQLite rows are partitioned by source fingerprint. An anchor stores an entity
path plus world-coordinate fallback; the original file is never modified.

The application-support directory is obtained through a small first-party
MethodChannel implemented in `MainActivity` and `AppDelegate`. This keeps the
storage path API stable without pulling a native-assets toolchain into the
viewer. Non-file provider URIs are copied as a stream into the private imports
directory before Rust opens them, so large files are not buffered in Dart.

DWG sessions use a versioned CBOR scene cache validated against source size,
nanosecond modification time, complete content hash, parser version and scene
version. Cache writes use a temporary file and atomic rename; invalid or
incompatible cache entries are deleted automatically.

## Native rendering integration gate

`create_viewport` is already stable in the public API, but currently reports
`texture_id = -1` and `flutter_vector_preview`. The eventual implementation
must preserve that API while creating an Android Vulkan or iOS Metal wgpu
surface and registering its texture with Flutter. It must also handle texture
recreation after backgrounding and GPU device loss.

## Distribution boundary

Distribution is selected at compile time. `community`, `cnViewer` and `cnPro`
contain no advertising provider and have no Android Internet permission.
`cnViewer` is view-only and enforces its feature boundary in both UI and the
Dart engine facade; `cnPro` is the full offline paid-download edition.
`globalStore` provides an Android/iOS flavor-local Google Ads/UMP platform
view unless `CADVIEW_AD_FREE=true`; it cannot be initialized before local
privacy acceptance and defaults to non-personalized requests. The service
destroys its placement before navigation or background. Parser, document,
annotation and viewport APIs never receive an advertising dependency.

Locale selection is UI-only state stored in the application-support
directory. A null Flutter locale follows the platform locale list; the custom
resolver maps supported Chinese scripts/regions and otherwise returns English.
No format adapter, scene or cache depends on the presentation locale.

Opening also has a ticket API. A named Rust worker owns its cancellation token
and emits coalesced probe/parse/first-frame/terminal events. Dart polls a small
native queue without blocking its isolate; application backgrounding cancels
all unfinished tickets. The old `open_document` remains a compatibility
wrapper for one API version.

## Entity coordinate systems

DXF/DWG CIRCLE, ARC, LWPOLYLINE and 2D POLYLINE store centers, vertices,
elevation and angles in the entity OCS (Autodesk arbitrary-axis algorithm).
`cad-formats/src/ocs_curves.rs` converts them once at normalization: a -Z
normal (the usual result of CAD mirroring) maps angles through the plane and
swaps start/end so the stored arc stays counter-clockwise in world XY, while a
tilted plane is emitted as its projected ellipse outline. Polyline bulges are
tessellated (at most ten degrees per chord) and end exactly on the next vertex.
DWG block base points shift OCS curve centers in their own OCS, matching
acadrust's INSERT explosion. DXF polyface and polygon meshes are reported as
unsupported rather than drawn as one path through their location-less face
records.

## DXF block expansion

`DxfNormalizer` (in `dxf_adapter.rs`) normalizes each entity in its block's
coordinates and maps it to the parent with `affine2d::Affine2`
(OCS(N)·T(P)·Rz(r)·[cell]·S·T(−B)). Circles and arcs stay exact under a
similarity and are tessellated as ellipses otherwise; text composes the linear
map into its plane. Top-level entities keep `index + 1` IDs; expanded children
and extra hatch loops take IDs after the top-level count. `dxf_raw.rs` reads
HATCH boundaries and counts reader-discarded types from the same file through
the vendored crate's raw code-pair iterator. The DWG adapter uses the same
affine path for circular geometry under non-similarity block frames.

`mleader.rs` holds a format-independent MULTILEADER model (filled from
acadrust's parsed context for DWG and from `dxf_raw.rs` for DXF) and builds
leader lines, doglegs and arrowheads. Text and block content go back through
each adapter's MTEXT and INSERT normalization, and ACAD_TABLE becomes a
synthetic INSERT of its `*T` block in both formats.

