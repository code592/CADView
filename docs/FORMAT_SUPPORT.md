# Format support and release gates

| Format | Current level | Current backend | Missing production gate |
|---|---|---|---|
| DXF | Production MVP | `dxf` Rust crate plus normalization | Large licensed corpus, SHX and advanced entities |
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

Assimp and Open CASCADE are not linked in the current build. Their unavailable
adapters fail with a structured backend diagnostic instead of silently
misrendering a document. acadrust and PDFium are pinned by the Rust/Dart lock
files and retain their MPL-2.0/BSD/MIT distribution notices.
