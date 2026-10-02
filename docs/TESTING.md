# Testing and compatibility corpus

The unit suite covers format magic detection, minimal DXF/SVG/OBJ parsing,
scene normalization, geometry measurement, R-tree queries and SQLite
annotation round trips. `rust/fuzz` contains the shared untrusted-format fuzz
entry point.

Private or licensed drawings must never be committed. CI corpus jobs should
mount them under an external `CADVIEW_CORPUS_ROOT` and emit only aggregate
results. Each format corpus is expected to contain:

- valid files by version, encoding and unit;
- visual gold images and normalized geometry summaries;
- truncated, corrupted and adversarial files;
- deep block/assembly graphs, archive bombs and oversized textures;
- expected diagnostics and parser time/memory ceilings.

DWG remains Beta until at least 500 authorized documents cover all claimed
versions, the open rate reaches 98%, and the common-entity visual comparison
has no material deviation. The planned performance runners use the following
fixed baselines:

- 2D: 100 MB / approximately one million entities; first geometry <=2 s,
  complete parse/index <=10 s, cache reopen <=1 s.
- 3D: 500 MB / five million triangles; progressive display, target 60 fps,
  peak memory <=1.2 GB on the named reference devices.

These are release gates, not assertions about the current preview renderer.

## Offline multilingual text

`flutter test test/cad_fonts_test.dart` checks the actual Unicode cmap of every
bundled font against all translated UI characters and CAD samples (CJK, Latin,
Greek, Cyrillic, Arabic/Persian, Hebrew, Thai, Devanagari, Bengali, Gujarati,
Gurmukhi, Tamil, Telugu, Kannada, Malayalam, Sinhala, Lao, Khmer, Myanmar,
Armenian, Georgian, Ethiopic, Tibetan and engineering symbols).
It also checks first-strong text direction and produces widget/CAD screenshots.

Run `bash scripts/check_cad_fonts.sh` for the independent engine visual check.
It uses the same painter and fixtures without `--use-test-fonts`, since widget
tests replace missing source families with Ahem, whose Latin glyphs are squares.
The generated `artifacts/qa/cad-fonts-{default,missing,bundled,source}.png` files
and `cad-fonts-extended-{default,missing,bundled,source}.png`
allow inspection of accents, shaping, mixed RTL/LTR and missing-source fallback.
Raster assertions verify visible ink for every sample, missing-source fallback,
the bundled default, and preservation of an explicitly available source family.
They also check real glyph pixels against culling envelopes for multiline text,
alignment, rotation, shear, mirroring, width fitting and off-screen origins. The
script removes its compiled intermediate after execution. Set `CADVIEW_FLUTTER_SDK` if
Flutter is not on PATH. This desktop engine check is not a substitute for
Android/iOS device glyph, culling and gesture acceptance tests.

Text-plane tests also reflect the original real-font glyph pixel mask independently
in X, Y and swapped XY directions, then compare it with projected rendering.
They do not rely solely on matching bounds calculations in the same renderer.
Three more pixel oracles apply a complete affine transform to an independently
recorded untransformed glyph picture, checking shear, mirror and nonuniform
scale with the same one-pixel/99% bidirectional tolerance. The envelope suite
also includes wrapped multilingual labels under these nonorthogonal planes.

The DWG reader patch is retained in `rust/vendor/acadrust` under MPL-2.0.
`cargo test --manifest-path rust/vendor/acadrust/Cargo.toml --lib --locked`
runs its library regressions; CI and `scripts/verify.sh` run them as well.
Rust format tests check tilted TEXT OCS and MTEXT WCS vectors through the binary
reader, complete nested-block text frames against independent scalar arithmetic,
and a rotated 2x2 MINSERT against known unscaled grid coordinates. Attribute
regressions cover alignment points, Fit/Aligned, middle/top anchors, X/Y mirror
flags, ByBlock color, zero-layer inheritance, both invisibility flags, tilted
OCS and one-time enclosing transforms. An empty block with a huge attribute
array must hit the resource limit before allocating cells. A writer
round trip is not itself proof of compatibility with all third-party DWGs.

The broader vendored `--test roundtrip` suite is **not fully passing**: 91 of
95 pass; `dwg_roundtrip_complex_linetype_shape` and the three
`dwg_roundtrip_deep_r2000/r2013/r2018` cases fail. An unmodified crates.io 0.4.1
baseline independently fails the same four cases (90/94). These cover complex
shape line types and MultiLeader/Shape data and remain unresolved, not ignored.
The comparison helper canonicalizes absent MTEXT directions to the angle-derived
vector emitted by the writer. A new test proves explicit XY and Z differences
still fail comparison; no direction information is discarded to pass a test.

Generate self-authored mobile fixtures with:

```sh
cd rust
cargo run --locked -p cad-formats --example generate_dwg_text_fixtures -- ../artifacts/qa/dwg-text
```

Copy only these generated fixtures to a device-readable directory and add
`--dart-define=CADVIEW_DWG_TEXT_ROOT=DEVICE_READABLE_DIRECTORY` to the mobile
drive command. The five generated fixtures check native nested, tilted, array,
attribute and constant-definition text coordinates/bases, then sample actual multilingual glyph pixels and query
the Rust R-tree at those world coordinates. Generated binary fixtures and
screenshots remain outside tracked source and are not shipped in the app.
The attribute fixture also checks all four array copies, hidden attributes,
alignment/fitting/mirroring, inherited colors and layer visibility. Its labels
deliberately overlap at known coordinates; it is an assertion fixture, not an
original-CAD visual-equivalence gold image.
The constant-definition fixture covers centered/mirrored and tilted multilingual
values, the block base point, a rotated nonuniform 2x2 array, ByBlock/zero-layer
inheritance, invisible definitions, variable prompts and layer toggles. Its
deliberately overlapping array labels are an assertion fixture, not a gold image.

## Mobile native integration

Run the following against an Android device/emulator or iOS simulator:

```sh
flutter drive --driver=test_driver/mobile_accuracy_test.dart \
  --target=integration_test/mobile_accuracy_test.dart --flavor community \
  --dart-define=CADVIEW_DISTRIBUTION=community -d DEVICE_ID --keep-app-running
```

The suite checks fonts loaded from the actual application bundle (no test-font
substitution), missing/default/available font raster behavior, native DXF Unicode
decoding, hit testing, intersection snapping, layer visibility, measurements,
binary R2007+ UTF-8 and legacy Windows-1251/GBK text decoding,
TEXT anchor/style/fit and complete, wrapped MTEXT paragraphs with DXF degree-to-radian conversion,
and multilingual SQLite annotation add/export/delete. No private drawing is
included in the test bundle. Reports and screenshots are written separately to
`artifacts/qa/mobile/{ios,android}`. Generated test drawings use a private temp
directory and are removed after closing their native session. This builds a
test application, **not an installer for end users**. `--keep-app-running`
avoids the Flutter driver's automatic cleanup/uninstall; stop the test app
explicitly when finished.

The pinned `dxf` dependency's decoding patch lives in `rust/vendor/dxf` and
retains its MIT license. Run `cargo run -p cad-formats --example
audit_dxf_text_encoding` from `rust/` for an independently authored ASCII/binary
reproduction; `cargo test --workspace --locked` covers eight legacy code pages,
Unicode layer names, R12 group-code widths, R2007 UTF-8 precedence, unknown-page
diagnostics and bounded header detection. An additional library check is
`TZ=UTC cargo test --manifest-path vendor/dxf/Cargo.toml --lib --locked`.
The upstream date-conversion assertions use historical local offsets; use the
fixed UTC test environment rather than treating a host-zone mismatch as a text
decoding regression. CI runs the vendored library tests as well as core tests.
The version-dependent string encoding follows the
[Autodesk DXF string storage reference](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-DXF/files/GUID-2553CF98-44F6-4828-82DD-FE3BC7448113.htm).

TEXT uses its second alignment point for non-baseline/left justification;
Aligned scales both dimensions while Fit preserves height. MTEXT preserves all
group-3/group-1 chunks, paragraph width, attachment and direction-vector/rotation
precedence. Layout and culling share shaped metrics; large zoom scales bounded
font shapes back to CAD dimensions rather than capping the displayed text size.
`test/cad_text_layout_test.dart` and the headless real-font envelope check cover
wrapping, cache separation, uniform fit and zoom. These rules follow the
[TEXT reference](https://help.autodesk.com/cloudhelp/2016/ENU/AutoCAD-DXF/files/GUID-62E5383D-8A14-47B4-BFC4-35824CAE8363.htm)
and [MTEXT reference](https://help.autodesk.com/cloudhelp/2016/ENU/AutoCAD-DXF/files/GUID-5E5DB93B-F8D3-4433-ADF7-E92E250D2BAB.htm).
The reference's MTEXT group-50 radians label conflicts with actual DXF
interoperability: [ezdxf's source explicitly documents the error](https://github.com/mozman/ezdxf/blob/master/src/ezdxf/entities/mtext.py),
and both libdxfrw and acadrust use DXF degrees. An independent acadrust writer
produces ASCII and binary fixtures for negative/zero/15/45/90/180/270-degree
rotation; CADView must consume those correctly, not rely on its own round trip.

Text is now shaped at a fixed 128-unit reference height, independent of the camera. The
same layout produces Flutter culling bounds and the Rust R-tree envelopes;
zooming cannot change paragraph breaks. Before a 2D session becomes ready, the
native bridge pages only text metadata (at most 64 labels and approximately
64 KiB including style runs per page; an oversized label travels alone), accepts
validated world bounds, then rebuilds the index once. Geometry and original
files stay unchanged. Measured bounds are runtime-only and are recomputed with
the active bundled/device fonts rather than trusted from a cross-device cache.
The integration suite probes the actual Rust viewport with visible glyph pixel
locations for narrow Aligned text, mirroring, rotation and wrapped multilingual
paragraphs, including negative-Z/tilted DXF TEXT planes and MTEXT's WCS
insertion/direction. The separate optional DWG fixtures cover their own native
text-plane/attribute assertions; DXF assertions alone do not prove DWG correctness.
It also cancels during refinement and checks successful reopening.
These pixel/index assertions extend, rather than replace, original-CAD visual
comparison and physical-device acceptance.

2026-10-01 simulator verification with parser `cadview-7` and scene cache 21,
after height calibration, MTEXT line spacing and DWG
text-frame/attribute corrections: Android API 36 and iPhone 16e/iOS 18.4 simulators each
passed the 14-test mobile suite, with respectively 263/245 DXF and 422/417 DWG
actual-glyph viewport probes, four independent
baseline-spacing pixel checks and 16 cap-height/em/inline-height pixel checks,
scoped font/height/decorations, missing-font fallback, cancellation/reopen,
PDF/STL/DXF PNG and the three authorized DWG samples. Local reports and rich
text screenshots are in `artifacts/qa/mobile/{android,ios}`. The independent
headless engine check passed 82 glyph-envelope cases, three pixel-reflection
orientations and three independent full-affine picture comparisons,
inline/inherited font/fallback/decoration/height pixel assertions
and 16 independent cap-height/em plus four baseline-spacing pixel checks.
Flutter passed 116 tests; the native Rust workspace passed 76 tests, the vendored
DWG reader passed 1,259 library tests and the vendored DXF reader passed 293.
The shared fuzz entry point compiled offline against the patched path dependency.
These are simulator/fixture results, not physical-device or original-CAD
visual-equivalence acceptance.

The current A1/A2/A3 sample returns 1,162 scene entities; Armchair and Bedside
return 55,976 and 12,328. `audit_dwg_attributes` reports only aggregate source
metadata without printing drawing text; the A1/A2/A3 source contains 34 attribute
records across its INSERTs, including three marked attribute-invisible and no
entity-invisible attributes. Direct model-space INSERTs contain 28 attributes,
one of them hidden; honoring this source flag removes one previously displayed
attribute. Source visibility must not be overridden merely to
preserve an older scene count. These aggregates are not an independent parser
or proof that every original-CAD label matches visually.
The current mobile attribute fixture verifies single-line attributes only.

The subsequent embedded-attribute reader/normalizer change (`cadview-8`, cache
22) has separate Rust verification, not a claimed mobile acceptance result:
an independently field-encoded R2018 stream covers eight combinations of
ATTRIB/ATTDEF, annotative/non-annotative paragraphs and absent/present annotation
bytes. It checks conditional common handles, WCS geometry, Unicode paragraph
content, font-style handle, width, attachment, spacing, columns, tags, visibility
flags, lock position and the following data/handle sentinels. It does not use
the modified high-level attribute writer. Another test verifies authoritative
paragraph content instead of the outer legacy TEXT and applies an independently
specified enclosing scale/translation once, while keeping local height/width.
New embedded paragraphs still require native mobile glyph/culling fixtures and
original-CAD comparison. Multi-column/background rendering remains incomplete;
a declared multiline attribute with no paragraph
retains the diagnosed fallback.

The constant-definition change (`cadview-9`, cache 23) additionally verifies a
binary ATTDEF read through the builder and into all four displayed array cells,
including font style, alignment point, width, slant, mirror, flags, field length,
position lock and inherited presentation. Separate tests cover a nested constant
embedded paragraph against independently specified affine coordinates and a
constant-only oversized array rejected before allocation. Invisible-definition
arrays skip empty cell expansion and return the structured no-displayable-geometry
error diagnostic. Normalization reuses the block's resolved source list rather
than rescanning all drawing entities for explosion. At that revision the Rust
workspace had 81 passing unit tests; Flutter had 116 passing tests, the vendored
library with `serde` has 1,260 passing tests, and the fuzz target compiles. The
broader roundtrip suite still has the same four documented upstream failures
(91/95 pass), without ignored cases. These checks are not a substitute
for mobile glyph acceptance or original-CAD comparisons.

The final `cadview-9`/cache-23 build also passed all 14 mobile integration tests
on the Android API 36 emulator and iPhone 16e/iOS 18.4 simulator. All five DWG
fixtures ran, with 642 Android / 637 iOS real-glyph viewport probes; the existing
DXF suite ran 263 / 245 respectively. The three authorized DWG regression scenes
retained counts 1,162 / 55,976 / 12,328 and passed their existing geometry checks.
Screenshots were inspected locally. These mobile constant definitions are
single-line fixtures; embedded attribute paragraphs remain covered separately
at the field-reader and normalizer seams, not full-container mobile acceptance.
On iOS simulators prefer stable host corpus paths: an app install can change its
data-container UUID, invalidating absolute paths compiled into a previous test.

The single-column background-mask revision (`cadview-10`, cache 24) passed
85 Rust workspace tests, 293 vendored DXF library tests, 121 Flutter tests,
static analysis and fuzz-target compilation. Independent ASCII DXF and the
acadrust ASCII/binary writer exercise combined fill/frame flags, explicit black
background RGB versus entity ink, default margin and canvas-color mode. DWG
binary parsing additionally verifies nested ByBlock background inheritance.
Pixel tests cover earlier/later geometry, frame-only mode, nominal-height border
margins and culling. Multi-column masks remain disabled with a diagnostic; this
does not establish original-CAD draw-order or full column-layout fidelity.

All 15 mobile integration cases then passed on Android API 36 and iPhone 16e /
iOS 18.4. The mask fixture retained explicit near-black ink on white, a later
green line, canvas-color fill and a frame; both platforms produced 203 green
pixels. It uses explicit RGB (1,1,1), not ACI 250 (dark grey); its line assertion
tests chroma so subpixel antialiasing on white is not mistaken for missing ink.
Native glyph probes were 642 / 637 for the five DWG fixtures and 271 / 260 for
DXF, respectively. Existing authorized DWG entity counts remained
1,162 / 55,976 / 12,328. PDF/STL PNG export and the R20 DXF 1800x2200 export
passed on both platforms, and generated images were inspected locally.

The subsequent DXF color-presence correction passed 91 Rust workspace tests,
295 vendored DXF tests with `serialize`, 121 Flutter tests and static analysis;
the fuzz target compiles. Three authored regressions first failed on the old
reader (black incorrectly became red, layer RGB became ACI, and an entity color
name became a mask warning), then passed after the fix. A direct group-pair
binary fixture tests true-black ink and black/nonzero layer RGB independently
of both library writers. Vendor ASCII/binary roundtrips preserve absence, black,
nonzero RGB, names and layer-off flags, and check the older-version write gate.
The independent acadrust writer verifies true-black entity ink and indexed
ByLayer ink; its current layer writer discards RGB, so it is not used to claim
RGB-layer interoperability.

Both platforms again passed all 15 mobile integration cases with actual bundled
fonts. The mask fixture now specifies pure RGB zero (not near-black) and a
separate pure-black RGB layer, and verifies hiding that layer without hiding
the other entities. The saved `nativeTrueBlackInk` diagnostic records both
paths; black glyph counts were 8,634 Android / 8,551 iOS, with the later line
remaining visible. Existing glyph-probe counts and authorized CAD entity counts
remained unchanged, and screenshots were inspected locally. Full-column MTEXT,
embedded-attribute container fixtures and independent original-CAD goldens
remain outside this proof; the overall accuracy goal is not declared complete.

The R2018 DXF embedded-object reader correction passed 96 Rust workspace tests,
295 vendored DXF library tests with `serialize`, 123 Flutter tests, static
analysis and fuzz-target compilation. Two independently authored regressions
first failed on the old reader: insertion became the direction vector and
column type/count were lost. ASCII and separately encoded binary fixtures now
verify ordinary glyph geometry, masks, scoped absolute-height runs, static and
dynamic auto/manual column tags, total extents, trailing XDATA and the following
entity. Unknown embedded objects are isolated. Over-4096 height vectors report
the original error in ENTITIES and BLOCKS; a malformed final entity cannot be
accepted as a successful empty/partial scene.

The tag meanings follow the independent
[ezdxf MTEXT internals reference](https://ezdxf.readthedocs.io/en/stable/dxfinternals/entities/mtext.html).
Android API 36 and iOS 18.4 each passed all 16 native integration cases. The
new no-columns R2018 case compares decoded entity values, refined bounds and
PNG bytes against its ordinary MTEXT equivalent under both AtLeast and Exact
spacing. The Exact fixture deliberately overlaps oversized runs according to
its source grid; the AtLeast companion verifies normally separated Chinese,
Japanese, Arabic, Bengali, Korean and Cyrillic text. Their locally inspected
images are `fonts-mtext-embedded.png` and `fonts-mtext-embedded-exact.png`;
`nativeEmbeddedMText` records this parity, not an original-CAD golden result.
The existing glyph probes, authorized drawing entity counts and PDF/STL/DXF
exports remained unchanged. Real column-flow layout, column gutter masks,
legacy linked columns and independent original-CAD goldens remain incomplete.
DXF was not disk-cached; that reader-only change did not invalidate DWG caches.

### Unified column-flow verification (2026-10-02)

The subsequent unified-column implementation passes 131 Flutter tests, 101 Rust
workspace tests, 1,260 vendored acadrust library tests with `serde`, eight focused
DWG MTEXT round-trip cases and static analysis. Independent ASCII and separately
encoded binary DXF fixtures verify static, dynamic-auto (stored count zero) and
dynamic-manual metadata. Rust additionally covers invalid counts/extents/heights,
resource bounds, last-height zero and decoded UTF-16 manual breaks. Vertical or
style-dependent columns stay diagnosed and do not receive horizontal masks. DWG tests
verify preservation of explicit embedded extents through its binary boundary;
these modified-writer tests are not independent compatibility evidence.

Flutter tests use real licensed font assets and verify source row grouping,
manual breaks, rebased styles, combining sequences, camera invariance, reverse
positions, height overflow and cache isolation. Raster tests compare multilingual
columns with independently positioned ordinary paragraphs and check that gutter
geometry remains visible and a visible column tail is not culled by its offscreen
insertion point. Android API 36 and iOS 18.4 each pass 17 native integration
cases. `nativeMTextColumns` records six static/auto/manual × normal/reversed
cases, independent paragraph raster parity and the refined native R-tree tail
query. Local images are `fonts-mtext-columns-{static,auto,manual}[-reversed].png`.
These verify internal glyph placement, not original-CAD golden parity. Existing
licensed/local samples, annotations, PDF/STL/DXF PNG exports and font probes
also remain covered by the full native suite. Scene cache 25 / `cadview-11`
invalidate old flattened DWG scenes. Legacy linked columns, vertical text flow
and independent original-CAD goldens remain pending; the broad accuracy goal is
not declared complete. At the user's request, pause after this validated
increment and restore normal app entry points without deleting application data.

TEXT and single-line attributes preserve literal braces, paths and MTEXT-like
commands; only MTEXT/multiline attributes interpret paragraph/group controls.
Tests cover Unicode escapes, `%%%`, case-preserving unknown percent controls,
malformed decimal escapes and MTEXT hard spaces (U+00A0, not a wrapping space).
ASCII DXF and independently written DWG fixtures test this distinction through
the adapters. Scoped MTEXT fonts, bold/italic, relative/absolute height and
underline/overline/strike-through are retained as decoded UTF-16 ranges; TEXT
percent decoration toggles are retained separately from MTEXT syntax. Bounds
and painting consume the same styled paragraph, including offline fallback on
each inline font. Unit tests check supplementary/combining characters, invalid
ranges, nested scales and bounded-resource fallback; independent real-font
pixel assertions compare an inline font to a whole-label font, a missing font
to the bundled default, decoration strokes and doubled-height ink.
Inline width/tracking/oblique/color, paragraph layout and stacked-fraction
layout remain incomplete and emit diagnostics. Missing original SHX
metrics/outlines are not yet proven CAD-exact.

MTEXT now retains group 44 line spacing and group 73 AtLeast/Exact policy,
including independent ASCII/binary DXF writer fixtures and DWG parser tests.
The supported range and the two policies follow the
[Autodesk MTEXT reference](https://help.autodesk.com/cloudhelp/2023/ENU/AutoCAD-DXF/files/GUID-5E5DB93B-F8D3-4433-ADF7-E92E250D2BAB.htm).
The baseline-grid oracle uses 5/3 times cap height times the factor, also described
in [ezdxf's experimentally derived rendering notes](https://ezdxf.readthedocs.io/en/stable/dxfinternals/rendering_of_dxf_content.html).
Unit tests verify the full 0.25–4.0 range, invalid-factor diagnostics, cache
separation, taller runs in AtLeast versus Exact and camera-independent bounds.
The engine quantizes line metrics at the fixed 128-unit shaping scale, so unit
metric tolerance is bounded by one shape unit transformed into drawing units;
real raster tests independently require baseline gaps within two output pixels
for 0.75, 1, 2 and 4 factors. Forced-grid glyphs outside the paragraph's nominal
height are bounded with natural metrics before native indexing. Twelve new
headless envelope cases cover tall multilingual runs, wrap, rotation/mirroring
and both policies. Two new parsed mobile fixtures verify their visible glyphs
through the actual Rust viewport index. These checks are not an original-CAD
golden-image substitute for every inline/paragraph layout feature.

DXF/DWG TEXT/MTEXT uses `height_reference=cap_height`; SVG `font-size` uses
`em` and must not receive the CAD conversion. `cad_font_metrics.dart` reads
bounded OpenType `head`/`OS/2` metrics from the licensed offline assets and
calibrates each requested family once against the engine's reference capital
A. A close table value is retained to avoid raster quantization; device/missing
families are calibrated with the same offline fallback used by painting.
The 512-family cache/readback fallback is diagnosed and does not discard text.
An independent pixel oracle requires 100 drawing units to paint 88 pixels
under the fixture's known 0.88 camera scale, including doubled inline height,
CJK, a missing family and a device family. SVG/em tests keep their original
font size. Height/decor-only runs explicitly retain the parent's primary
family as well as fallback; otherwise the engine can substitute the default
font and change both glyphs and dimensions.
References: [OpenType cap-height](https://learn.microsoft.com/en-us/typography/opentype/spec/os2#scapheight),
[ezdxf CAD height notes](https://ezdxf.readthedocs.io/en/stable/dxfinternals/rendering_of_dxf_content.html#MTEXT)
and [ezdxf's reference-capital measurement](https://github.com/mozman/ezdxf/blob/master/src/ezdxf/fonts/ttfonts.py).
This improves the actual fallback-font dimensions; it does not establish
equivalence to a missing original CAD font or all complex paragraph layouts.

MTEXT angle and equivalent WCS-vector fixtures must have identical projected
planes for negative/tilted normals; applying TEXT's OCS to MTEXT adds incorrect
mirroring. These adapter assertions are independent of the painter's matrix.

For the three user-authorized DWG regression samples, additionally pass
`--dart-define=CADVIEW_CORPUS_ROOT=DEVICE_READABLE_DIRECTORY`. On an iOS simulator
the local corpus directory can be read directly; an Android device needs copies
inside the debug application's sandbox. The optional corpus test checks complete
finite scenes, known minimum entity counts and the title-block's corrected
dimension line, and captures the actual rendered overview. These are regression
checks, not proof of exact equivalence to an original CAD application or of the
500-document DWG release gate.
Verify device copies by byte length and SHA-256 before running the corpus;
some Android `dd` implementations discard a trailing partial default-size
block when used over adb stdin. Use byte-preserving transfer (for example
`dd bs=1`) and compare the complete hash, not merely the DWG signature.

Near-black neutral 2D ink is display-adapted for the dark canvas so black labels
and lines do not disappear. Source entity ARGB, opacity, geometry and chromatic
colors are retained; properties and original documents are not recolored.

## PNG export and document identity

`flutter test` covers bounded PNG readback, Unicode output names, save/cancel
flows, save-failure recovery and compact menu layout. Export stays disabled while
the save dialog is pending, preventing duplicate exports, and is available again
after cancellation. Pixel assertions verify
that the current zoom/pan and visible annotations are preserved without resetting
the camera. A decoded-pixel 3D regression also checks that different yaw/pitch
produce different exports while retaining zoom/pan and camera angles. Invalid
viewport dimensions are rejected; extreme finite dimensions do not overflow the
readback scale calculation. Export snapshots the current 2D/3D view including painted annotations,
or the current loaded PDF page, without application chrome.
Readback uses at least 2x logical resolution when the size permits, capped at
4096 pixels per edge and 8 megapixels to bound transient memory. It does not
modify the original CAD/PDF file or register a recurring render callback.

The mobile integration suite exercises PDF export without navigation controls
and native STL export. Pass `--dart-define=CADVIEW_DXF_SAMPLE=DEVICE_READABLE_PATH`
to also check the authorized `R20-0000_1.dxf` sample and its 1800x2200 PNG output.
The supplied drawing and generated screenshots remain outside tracked source.

Imports now use a unique parent directory while preserving the original Unicode
file name. Legacy importer prefixes are hidden only for direct import files.
Tap the viewer file name or long-press a recent file to view/select/copy its full
local path; for provider imports this is the readable local copy, not a claimed
physical path inside another app. Android advertises common CAD MIME aliases and
generic text/binary fallback; iOS accepts generic document data. This lets file
providers list CADView, but a provider can still impose its own open/share rules.

On macOS, `scripts/maintain_ios.sh --build` is the canonical iOS environment
and simulator-build check. It owns Xcode selection through `DEVELOPER_DIR`,
CocoaPods availability and all Rust Apple targets; CI calls the same script.

## OCS curves and measurement cross-checks

2026-10-02: DXF previously ignored LWPOLYLINE/POLYLINE bulges (arcs were drawn
and measured as chords) and both DXF and DWG ignored the CIRCLE/ARC extrusion
normal. Rust tests now cover authored ASCII and binary DXF with a mirrored
ARC/CIRCLE, positive/negative bulges and a polyface mesh, plus a DWG written by
acadrust and read back through the binary reader with mirrored arcs in model
space, a translated block, an X-reflected block and a non-zero block base
point. In the local Armchair and Bedside samples, 244 of 254 -Z arcs have both
endpoints on neighbouring geometry under the OCS interpretation versus 8 under
the previous raw interpretation (they sit in uninserted block definitions, so
the overview renders are unchanged). Scene cache 26 / `cadview-12` invalidate
older cached scenes.

`test/measurement_property_test.dart` cross-checks the Dart measurement tools
with fixed-seed random inputs against independent formulas: Heron and
circumradius/inradius identities, three-point circle/arc reconstruction,
two-circle intersection distances, polygon section moments via triangle
decomposition and the parallel-axis theorem, polar stakeout/survey direction
inverses, point-line reconstruction, brute-force segment clearance, Bowditch
closure, simple-curve tangent geometry and unit conversion round trips.

## DXF blocks and DXF/DWG parity

`dxf_dwg_parity_tests.rs` writes one acadrust document (nested, rotated,
mirrored, non-uniform, (0,0,-1)-extruded and 2x3 array INSERTs of a block with
lines, -Z arcs, circles, bulged polylines, an ellipse, a spline, a SOLID, a
two-path HATCH and text, plus an ATTRIB) as DWG and as ASCII and binary DXF.
Every sampled point of each scene must lie within 0.05 drawing units of the
other and all text labels must coincide. acadrust's DXF writer always emits a
zero BLOCK base point, so base points, MINSERT cells, layer-0/ByBlock
inheritance, invisible entities, constant/variable ATTDEFs, DIMENSION blocks,
a missing block, solid single-loop fills, clockwise arc, ellipse and spline
hatch edges and discarded-type diagnostics are covered by an authored R2000
fixture with hand-computed coordinates.

Building the parity test found and fixed DWG defects in vendored acadrust and
the adapter (see `rust/vendor/acadrust/CADVIEW_PATCHES.md`): arcs and ellipses
under non-uniform block scale (reflected or wrongly shaped), OCS entities
under (0,0,-1) INSERTs and block base points, HATCH boundary explosion
(OCS, clockwise edges, spline weights), circular arcs and bulges under
non-uniform scale, and SOLID corner order (now 1-2-4-3). In the local Armchair
sample two mirrored non-uniform INSERTs of a 460-arc block previously produced
large stray circles; they now render as the block's geometry. A 60 MB, 405,156
entity DXF opens in 1.9 s (release, desktop) including the raw HATCH pass.
MULTILEADER and ACAD_TABLE were added to the parity document (two-branch
spline leader with doglegs and text, block-content leader, rotated table with
grid and cell text). acadrust's DXF writer stores the MULTILEADER content type
in group 170 (the leader line type per the DXF reference and ezdxf) and a block
handle in ACAD_TABLE group 2, so the parity leader uses a spline path and the
reader also resolves tables through group 343 or a handle. An authored R2010
fixture (ASCII and binary) checks CmColor decoding, center-aligned text at the
top of its box, arrowhead size and direction, last-point/dogleg geometry,
leader type 0 and a `*T` table rotated by its direction. In the local Armchair
sample the model-space MULTILEADER's connection height equals the middle of its
first text line below the stored top-left text location, confirming that
placement; its leader line, arrowhead and dogleg were previously not drawn.
Scene cache 28 / `cadview-14` invalidate older cached scenes.

## SHX substitute proportions and rebar symbols

SHX fonts are not redistributable. In the local A1/A2/A3 title-block DWG
(style `ebgen.shx` + `hztxt.shx`, height 3.2, width factor 0.8) leader labels
sit on underlines that AutoCAD fitted to the text. Comparing those widths with
our layout showed CJK 46% and Latin 32% too wide: the CJK em had been derived
from the Latin capital height, while a big font draws CJK in a cell whose
height is the text height. Texts now carry their style's SHX files; big-font
CJK uses the text height as its em and `ebgen.shx` uses a generated narrow Noto
Sans (scale 0.758, `scripts/generate_cad_fonts.py`). Fitted labels moved from
1.15–1.40x to 0.98–1.09x of AutoCAD's widths; `test/cad_shx_text_test.dart`
pins four of them within ±7%. Other SHX Latin fonts keep the regular fallback
because their proportions have not been measured. Codes 130–133 (`%%130`–
`%%133`) render bundled rebar symbols instead of missing-glyph boxes, and
ebgen.shx `^`/`*` render as HPB300 and ×. The glyphs and maps follow the
user-supplied AutoCAD plot of this drawing (`钢筋⏀20(Φ10)`, `Φ10@10`,
`2⏀16`, `1.2x1.2`); %%130–%%132 use the corresponding standard symbols.

## Sheet export

`cad_core::detect_drawing_frames` finds title-block sheets: closed
axis-aligned rectangles with ISO A proportions (±6%) that contain an inner
border at least 80% of their size, outermost only, in reading order, with the
matching sheet and round drawing scale. For the A1/A2/A3 sample it returns the
three outer borders, whose sizes equal the pages of the supplied AutoCAD PDF;
the exported PDF's pages are 2355.6×1655.5, 1655.5×1162.3 and 1162.0×803.2 pt
against 2356×1655, 1655×1162 and 1162×802. Image export offers the current view
and each sheet (one PNG per choice); PDF export writes one page per sheet (or
the current view) as a Deflate-compressed raster in the viewer's colours.
`test/sheet_export_test.dart` and the widget flow test cover sizing, the PDF
structure, edge-to-edge rendering, names and the save flow. Rectangles built
from separate LINE entities and single-border sheets are not detected. Scene
cache 30 / `cadview-16` invalidate older cached scenes.

