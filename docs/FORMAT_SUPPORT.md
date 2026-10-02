# Format support and release gates

| Format | Current level | Current backend | Missing production gate |
|---|---|---|---|
| DXF | Production MVP | Pinned `dxf` 0.6.1 with local text-decoding patch plus normalization | Large licensed corpus, SHX and advanced entities |
| SVG/SVGZ | Beta | `roxmltree` + `flate2` focused adapter | Full path/paint parity with usvg/resvg |
| OBJ | Production MVP | `tobj` | Material/texture gold corpus |
| STL | Production MVP | `stl_io` | Large binary/ASCII corpus |
| glTF/GLB | Production MVP | `gltf` | Full animation/extension policy |
| 3MF | Beta | ZIP/XML focused adapter | Materials/components corpus and archive hard limits |
| PDF | Production MVP | Pinned PDFium mobile runtime | Password UX, calibrated measure, large-file corpus |
| DWG R13-R2018+ | Beta | acadrust 0.4.1 + rooted layout/block traversal + Scene2D normalization | 500 licensed files, every version, >=98% open, visual gold tests |
| STEP AP203/214/242 | Experimental | Planned OCCT module | License review, assembly/topology/mesh pipeline |
| IGES 5.x | Experimental | Planned OCCT module | License review, topology/mesh pipeline |

“Production MVP” describes a working parser and viewer path in this source
tree, not completion of the performance corpus in the product plan. The UI
uses the adapter registry as the sole source of truth and does not expose
disabled backends as openable.

DWG opens in strict mode first and only retries with failsafe recovery after a
strict failure. Model space is preferred; the first non-empty layout is used
when model space contains no displayable content. Nested/array INSERTs,
attributes and acadrust-supported compound-entity decompositions are included,
with cycle, recursion and expanded-entity limits. The current normalized scene
is flattened; persistent GPU block instancing remains part of the native wgpu
milestone.

DXF expands INSERT/MINSERT block references (base point, rotation, scale
including mirroring and non-uniform scale, OCS extrusion, nesting with cycle
and 5,000,000-entity limits), layer-0/ByBlock inheritance, ATTRIB values and
constant ATTDEFs, DIMENSION graphics from their anonymous `*D` blocks, ELLIPSE,
SPLINE (NURBS, rational and fit-point), SOLID/TRACE (filled, 1-2-4-3 order),
3DFACE outlines, LEADER paths and HATCH boundaries. The pinned reader does not
model HATCH, so a raw code-pair pass reads its line, arc, ellipse, spline and
bulged-polyline boundaries; single-loop solid fills are filled and all other
hatches show their outlines (patterns are not drawn). ATTRIBs use the
INSERT's layer and color because the reader drops their own.

MULTILEADER (DXF and DWG) draws its leader lines through the last leader
point (straight or spline), the dogleg, a closed filled arrowhead (custom
arrowhead blocks other than the `_NONE` family are approximated by it), its
MTEXT content placed at the top of the text box with left/center/right
alignment, and block content through the INSERT path. Leader type "none"
hides lines, arrows and landing. Block-content attributes and text frames are
not drawn. ACAD_TABLE (DXF and DWG) is drawn from its anonymous `*T` block,
inserted at the table origin along its horizontal direction; a table without
that block is reported as `TABLE_GRAPHICS_MISSING`. Entity types that remain
unrendered — including IMAGE, WIPEOUT, MLINE, RAY/XLINE and ACIS solids — are
counted by type in the `dxf.unsupported_entities` diagnostic instead of being
silently omitted.

Assimp and Open CASCADE are not linked in the current build. Their unavailable
adapters fail with a structured backend diagnostic instead of silently
misrendering a document. acadrust and PDFium are pinned by the Rust/Dart lock
files and retain their MPL-2.0/BSD/MIT distribution notices.
