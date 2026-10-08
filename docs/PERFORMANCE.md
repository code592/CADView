# Performance work and reproducible large-file tests

Recorded on 2026-10-03. Correct geometry, text, draw order and measurement
results take precedence over frame rate. These results are measurements of
specific test workloads, **not** a claim that the mobile release gates in
[TESTING.md](TESTING.md) have been met.

## Changes

- 2D R-tree entries retain scene offsets. Viewport, hit and snap queries visit
  the actual candidates instead of scanning every entity afterwards. Source
  order is preserved for masking, selection and equal-distance snap ties.
- The Flutter viewport loader allows one query/decode at a time and coalesces
  pending camera changes to the latest camera. Exact geometry is retained in
  a guard band and reused inside that coverage; layer changes invalidate it.
  There is no new polling timer or idle frame loop.
- Large DXF files use the existing typed parser's assembled entity stream.
  Metadata/blocks are retained first, then entities are normalized in a second
  pass. This preserves late-section metadata, INSERT attributes and POLYLINE
  vertices without retaining a second heavyweight copy of all entities.
  The vendored reader reuses a buffered line reader and borrows code/numeric
  strings rather than allocating each line. Text metadata is boxed
  in the normalized entity representation, with unchanged JSON/CBOR schemas.
- DWG and DXF files of at least 4 MiB use versioned scene caches. Cache
  serialization borrows the scene and streams to a unique temporary file;
  flush/rename publishes it atomically. Invalid source hash, size, mtime,
  parser/schema version or corrupt CBOR discards the cache and reparses.
- 3D picking uses a retained triangle R-tree and exact ray/triangle tests in
  Rust. Assembly visibility updates return metadata, not another copy of all
  mesh buffers. Native session disposal runs off the Flutter UI thread.
- 3D vertices are projected once per camera, after f64 origin relocation;
  every triangle edge is submitted in bounded batches. Measured faces flush
  the batch at their original position in the draw order. No triangle stride
  sampling or entity truncation was introduced. Foreground entity indices,
  paths and text layout are reused between camera/measurement frames.
- Measurement/property entity lookup verifies direct sequential-ID offsets
  and keeps a bounded 128-item cache. Sparse/block-expanded IDs retain exact
  fallback searches; no complete second entity map is allocated in Dart.
- The 2D UI now uses metadata-first open and lossless CAD2D001 viewport
  packets. Numeric entities remain f64-backed lazy views; rich text retains
  its complete JSON schema. Solid lines enter the same world paths directly,
  without per-line geometry/point maps. Legacy JSON APIs remain available.
- One exact mesh display list per mesh/camera/selection/measured-face state
  is retained. Point-measurement and annotation overlays reuse it without
  processing every triangle. Camera/face changes replace the recording;
  independent pixel tests verify source order and large-coordinate details.
- 3D compact open now uses CAD3D001: contiguous f64 XYZ, native f32 normals,
  u32 indices and small mesh/property metadata. Projection reads these exact
  buffers directly instead of retaining per-vertex maps plus `CadPoint3`
  objects and another index list. Unaligned bridge slices copy into typed
  arrays directly, without temporary boxed-number lists.
- Viewport replacement and viewer disposal explicitly reset native paths
  and release mesh display lists/projection caches. Native snapshots already
  held by recorded frames remain valid; release/rebuild is pixel-tested.

## Corpus and provenance

Downloaded files are kept only under ignored `artifacts/qa/performance/`.
They are not committed, bundled, uploaded or redistributed with the app.
Third-party credit/usage terms must be checked separately before redistribution.

| File | Source | Bytes | Normalized workload |
| --- | --- | ---: | ---: |
| `nasa-pillars.stl` | [NASA Webb Pillars of Creation model](https://science.nasa.gov/asset/webb/pillars-of-creation-model-for-3d-printing/) — full model, credited to STScI | 52,041,984 | 1,040,838 triangles |
| `ezdxf-us-main.dxf` | [ezdxf example map](https://github.com/mozman/ezdxf/blob/master/examples/edgeminer/3_us_main.dxf) | 1,809,590 | 10,053 entities |
| `synthetic-1000000.dxf` | Locally generated line grid; **not an Internet/real drawing** | 100,486,964 | 1,000,000 entities |

SHA-256 of the downloaded bytes:

```text
nasa-pillars.stl
d6c9f77a9b5f9a9c7c60a1f8ed7d2dc875d70ba205ae4896bad4f98da594f522
ezdxf-us-main.dxf
ff424f11aca74246854b64e231d735b4ee4a1914e8fc81a9b59063fdcf7daf76
```

The NASA file is approximately 52 MB decimal / 49.6 MiB, not a 500 MB model.
Neither these files nor the three existing DWG samples establish broad DWG
compatibility or the planned 500-document acceptance corpus.

## Desktop measurements

Host: Apple M1 Pro, 10 CPU cores, 32 GB RAM. Native measurements use release
Rust, one isolated benchmark test and 100 queries at real grid endpoints.
The 1%-width viewport contains approximately 100 entities; it is not the full
million-entity overview. Native timings exclude Flutter transport and raster.
Here "cold" means no valid scene cache; the operating-system file cache was
not flushed. Results are individual recorded runs, not statistical bounds on
all drawings or storage devices.

| Million-entity DXF | Before | After |
| --- | ---: | ---: |
| Native cold open | 5.26 s | 4.49 s |
| Native reopen | 5.24 s (no cache) | 1.60 s (valid cache) |
| Native cropped viewport P95 | 70.16 ms | 0.049 ms |
| Native hit P95 | 46.92 ms | 0.00046 ms |
| Native snap P95 | 46.85 ms | 0.00071 ms |
| Native process peak RSS, uncached run | 2.47 GB | 715 MB |

The initial low-memory two-pass loader took 6.09 s before the subsequent
borrowed numeric-string optimization reduced cold open to 4.49 s. The RSS
figure covers a native benchmark
process, not the whole mobile app with a decoded full overview. Cache reopen
still exceeds the 1 s target, and native peak memory exceeds the 600 MB 2D
target. Both remain open acceptance items.

The downloaded DXF opened in 45 ms on this host. For the downloaded STL,
native open plus triangle-index construction was 692 ms, native ray-pick P95
was 0.013 ms (100/100 test rays hit), and native process peak RSS was 446 MB.
Its initial geometry JSON remains about 57.5 MB.

Flutter test/debug display-list CPU recording of the full STL, with rotating
cameras, decreased from approximately 750–780 ms to 40–58 ms after warmup
(first recording 890 → 160 ms). JSON decode remained approximately 500 ms.
**Display-list recording excludes GPU raster; these are not FPS values.**

## Mobile integration scope

The opt-in mobile test opens both large files through `NativeCadEngine`, fetches
the entire million-entity overview, checks the exact entity count and actual
raster ink, records four camera changes, and exercises real hit/snap endpoints
and native 3D rays. It closes each session afterwards. It does not exercise
every viewer gesture or measure sustained physical-device energy consumption.

On the iPhone 16 / iOS 18.2 simulator in **debug**, both corpus cases passed:
These timing samples precede the final borrowed numeric-string optimization;
the final native reader was subsequently revalidated by the accuracy suite.

- Million-entity DXF: open 43.58 s; full viewport transport/decode 17.47 s;
  first display-list recording 556 ms, retained-path recordings below 1 ms;
  one hit + one snap round trip averaged 0.55 ms.
- Million-face STL: open 12.07 s; rotating-camera display-list recordings
  134 / 62 / 39 / 39 ms; native ray round trip averaged 0.26 ms.
- The separate mobile accuracy suite passed all 14 reported cases, including
  real fonts, MTEXT placement/masks/columns, viewport tails, measurements,
  cancellation and PNG export.

Debug simulator loading is not representative of a release phone. It does
expose the unresolved full-scene transport cost rather than hiding it behind
a small cropped viewport benchmark. Raw reports are written to
`artifacts/qa/performance/mobile/<platform>/report.json`.

On an isolated Android API 36 arm64 emulator (4 GB RAM, two virtual CPUs),
the **profile** build also passed both corpus cases:

- Million-entity DXF: final cold open 5.72 s; full viewport transport/decode
  9.11 s; first recording 851 ms, retained-path recordings below 1 ms;
  one hit + entity resolution + one snap averaged 0.0094 ms. The test also
  resolves the last of all one million entities without a Dart scene scan.
- Million-face STL: open 2.25 s; rotating-camera recordings
  198 / 105 / 75 / 75 ms; native ray round trip averaged 0.64 ms.
- `dumpsys meminfo` after the combined final test reported approximately
  2.35 GB RSS plus 1.27 GB swap PSS (not a sampled peak). Full geometry maps, paths,
  raster allocations and temporary decode data still make the app's memory
  use substantially larger than the isolated native benchmark. This is an
  explicit failed memory gate, not evidence of support on low-memory phones.

The isolated emulator was shut down and its dedicated 3.2 GB AVD removed
after testing; it is disposable and reproducible. Downloads/reports remain.
Existing user emulators and CAD sources were not reset or modified.

Final checks: Flutter static analysis clean; 163 Flutter unit/widget tests
passed (the opt-in renderer benchmark skipped without its corpus variable);
134 Rust workspace tests passed (one opt-in benchmark ignored); 297 vendored
DXF library tests passed with `TZ=UTC`, as required by its timezone-dependent
date conversion tests. Android profile and iOS debug accuracy integration
runs each reported 14 passing cases including teardown. Pixel oracles cover
the batched 3D edges, highlighted faces at batch boundaries and large source
coordinates. These do not replace original-CAD visual goldens or a real-phone
power/FPS run.

## Follow-up: lossless transport and overlay reuse

The following second-round Android API 36 arm64 **profile** run uses the same
4 GB/two-vCPU configuration and complete corpus, not a sampled viewport.
The first packet run was uncached: open 6.78 s, full overview transfer/decode
0.768 s. It overlapped host regression compilation and is not evidence of a
cold-open improvement. After direct solid-line recording was added, a serial
run reused the valid scene cache:

| Operation | Previous JSON run | Final packet/cache run |
| --- | ---: | ---: |
| Full million-entity viewport transfer + decode | 9.11 s | 0.319 s |
| Full overview first display-list recording | 851 ms | 177 ms |
| Subsequent 2D camera recordings | below 1 ms | 0.045 / 0.016 / 0.015 ms |
| Hit + entity resolution + snap, mean | 0.0094 ms | 0.0053 ms |
| Same-camera mesh measurement-overlay recording | not measured | 0.863 / 0.053 / 0.048 / 0.048 ms |

Cached DXF open was 2.48 s, which still misses the 1 s target and must not be
compared with the previous 5.72 s *cold* open. STL open was 1.93 s; complete
rotating-camera recordings remained 185 / 104 / 76 / 76 ms, and native ray
round trip averaged 0.59 ms. All reported recording times exclude GPU raster.
The test rasterizes the first frame, verifies nonblank ink, checks all one
million 2D records, resolves the last entity and performs actual native picks.

The million-line packet is 64,000,464 bytes. Release-native encoding took
121 ms on the host. The final host Flutter/debug packet test measured 33 ms
for packet read/decode, 176 ms for first recording and below 0.4 ms for
retained-path frames. These CPU tests are not end-to-end first-frame timings.

After the final combined Android run, `dumpsys meminfo` reported 1,926,364 KiB
RSS (~1.97 GB) and 1,578,993 KiB swap PSS (~1.62 GB). This is a post-test
snapshot, **not** peak memory. RSS decreased but swap increased relative to
the previous JSON snapshot; this does not prove lower overall memory or the
600 MB acceptance gate. The full mesh JSON, native scenes, retained paths and
raster allocations remain substantial unresolved costs.

One further run invalidated the generated DXF's cache by changing only the
test copy's mtime: open 7.26 s, overview transfer/decode 0.311 s and first
recording 182 ms. It overlapped an Xcode build, so neither new cold run is an
isolated CPU benchmark or proof of a cold-open improvement.

Reports are retained under `artifacts/qa/performance/mobile/android/`:
`report-json-baseline.json`, `report-packet-first.json`,
`report-packet-cached.json` (the serial run above), and `report-2d-packet-cold.json`
(the final cache-invalidated run).
Final unit checks passed 166 Flutter tests (one opt-in benchmark skipped),
136 Rust workspace tests (one opt-in benchmark ignored), with clean analysis
and exact packed-vs-legacy geometry/raster comparisons. Native JSON decode
enables `float_roundtrip` rather than weakening assertions with tolerances.
Final iOS debug and Android profile accuracy integration runs each passed
all 14 reported cases, including teardown, with the packet and retained-mesh
paths enabled (fonts, masks/columns, culling, measurement, annotations,
cancellation and PDF/STL PNG export).

## Follow-up: compact mesh buffers and explicit disposal

The full NASA model retains 520,367 f64 vertices and 1,040,838 triangles.
Its CAD3D001 packet is 24,979,760 bytes, compared with 57,478,829 bytes of
legacy geometry JSON. Release-native encoding took 4.76 ms on the host.
The native compatibility benchmark still opens through the legacy API, so
its approximately 700 ms open time is not a compact-open measurement.

Serial host Flutter/debug comparisons using the same complete model:

| Operation | JSON + vertex-object cache | Typed mesh buffers |
| --- | ---: | ---: |
| File read + decode | 473 ms | 43 ms |
| First complete display-list recording | 167 ms | 59 ms |
| Rotating-camera warmed recordings | 43–55 ms | 39–52 ms |

These are CPU/display-list timings, not GPU raster, physical-device FPS or
battery measurements. All three edges of every triangle are still submitted.

An Android API 36 profile run of both complete corpora passed again. Before
explicit disposal, STL open was 1.12 s; after the final lifecycle change it
was 1.11 s, compared with 1.93 s in the previous JSON run. The final complete
rotating-camera recordings were 91 / 119 / 92 / 95 ms, and same-camera point
measurement overlays 0.327 / 0.055 / 0.049 / 0.124 ms. Native ray round trip
averaged 0.44 ms. Rotation remains above the 16.7 ms CPU gate and varied
between runs; this is not a claim of a reliable rotation frame-rate increase.

The final DXF run reused its valid cache: open 2.61 s, full overview
transfer/decode 0.320 s, first recording 185 ms, later recordings below 0.1 ms.
The earlier uncached run in this round opened in 5.75 s. These are different
cache states and are not directly comparable opening benchmarks.

Post-test `dumpsys meminfo` with explicit disposal reported 1,860,316 KiB
RSS (~1.90 GB) and 1,551,321 KiB swap PSS (~1.59 GB). The before-disposal
snapshot was 1,723,804 KiB RSS and 1,736,911 KiB swap PSS. Both are snapshots,
not peak measurements. Allocated native heap dropped by approximately 50 MB,
but RSS/swap moved in opposite directions; total mobile memory remains high
and neither a low-memory nor an energy acceptance gate is claimed.

`report-mesh-packet-before-dispose.json` and `report.json` retain both runs
under `artifacts/qa/performance/mobile/android/`. Full regressions passed
169 Flutter tests (one opt-in benchmark skipped) and 138 Rust workspace tests
(one opt-in benchmark ignored). New checks preserve f64 bits/signed zero,
native f32 normal bits, exact topology, optional properties, visibility and
measurements. Independent raster oracles cover packed/JSON paths, measured
faces, cache replacement, idempotent disposal and exact reconstruction.
Final iOS debug and Android profile accuracy runs each reported 14 passing
cases including teardown. Both exercised the compact mesh path through the
native bridge and PNG export, alongside fonts, MTEXT, viewport culling,
measurements, annotation persistence and cancellation. The dedicated
`CADView_Mesh_20261003` Android AVD was shut down and removed after testing;
downloaded corpus and reports remain, and the user's existing iOS simulator
was not reset or shut down.

## Conservative viewport culling and sparse lookup (2026-10-03)

This round changes rendering/lookup only, not file geometry or topology.
Projected vertices retain reusable one-byte outcodes. All three edges of
every potentially visible triangle remain in source order. Rejection requires
all three vertices beyond the same viewport side plus a four-pixel margin;
offscreen endpoints crossing the viewport, border strokes, measurement
highlights and large-coordinate detail are retained. Viewport size separately
invalidates recordings, including identical-projection compensated resizing.
No stride sampling, reduced precision, LOD or frame timer is introduced.

On the same M1 Pro host, the million-record sparse-ID packet benchmark
reported numeric linear scan at 4.974 ms/query versus combined property and
selection lookup at 0.054 ms/query. These timings include test assertions,
not just the binary search. Complete first path recording was 138.7 ms;
later selection-change recordings were 0.106, 0.041 and 0.036 ms. Decoding
checks ID order once off the UI isolate. Unsorted IDs still use an exact
numeric scan; duplicates keep first-occurrence property lookup and highlight
every source occurrence. No million-entry map index is allocated.

The final serial Android API-36 profile run used the full NASA STL only
(52,041,984 bytes, 1,040,838 triangles), not the earlier combined DXF/STL
workload. Opening was 1.149 s; overview/orbit recordings were 80.1, 117.1,
91.2 and 90.8 ms. Same-camera measurement-point overlay recordings were
0.178, 0.053, 0.044 and 0.042 ms. Local zoom/pan/orbit CPU recordings:

| Zoom | Conservative renderer, ms | Unculled diagnostic reference, ms |
|---|---|---|
| 1× | 88.7–94.8 | 164.0–180.6 |
| 8× | 36.6–39.0 | 163.2–164.5 |
| 16× | 31.1–31.8 | 165.7–203.1 |
| 32× | 29.9–31.8 | 166.5–178.8 |

The reference independently reconstructs the earlier typed projection and
unculled 4,096-triangle batching algorithm; it is not a previous released
binary, and implementation overhead differs. Its pixels are separately
checked against the production renderer. Do not report these columns as
an end-to-end release speedup or an FPS measurement. Both timings exclude
GPU raster. Host debug local zoom recordings were approximately 8–10 ms,
but the Android profile result still exceeds the 16.7 ms CPU budget.
The post-test memory snapshot was 2,066,148 KiB RSS and 1,258,404 KiB swap
PSS. This workload also executes sixteen unculled reference recordings,
unlike the previous combined-document run; the snapshots are not comparable
peak-memory measurements. Memory remains high and no memory/energy gate is
claimed.

`report-mesh-culling.json` retains the full Android result. The previous
combined-workload final report is preserved as `report-mesh-packet-final.json`;
`report.json` now contains this STL-only run. Flutter regressions passed
172 tests (two opt-in benchmarks skipped), Rust workspace tests passed 138
(one opt-in benchmark ignored), and static analysis passed. Android profile
and iOS debug accuracy runs each reported 15 passing cases including
teardown; both include 24 independent culling pixel checks. The task-owned
`CADView_Culling_20261003` AVD is removed after validation; downloaded files,
reports and the user's existing iOS simulator are preserved.

## Source-chunk index (2026-10-03)

CAD3D001 decode now builds a source-order bounds index off the UI isolate
while validating triangle indices. Each chunk contains up to 512 original
triangles and six exact f64 extrema from actual indexed vertices; no vertices,
triangles or topology are simplified/reordered. Camera changes first reject
fully offscreen chunks by conservative interval projection, then retain the
existing per-vertex outcodes for remaining triangles. Stroke/rounding margins
and overflow fail-open protect visible ink. Measurements use original face
indices, including highlighted faces after entirely hidden chunks.

The full NASA model requires 2,033 bounds records: 97,584 bytes (~95.3 KiB).
Packet/cache schemas and legacy JSON properties are unchanged. Native scene,
normals and exact geometry remain authoritative. Host read/decode/index was
41.5 ms; warmed local 16×/32× zoom recordings were approximately 6.3/4.8 ms.
These debug/host timings are separate from mobile timings below.

The final Android API-36 profile run again used the STL-only workload in the
previous section (4 GB/2-vCPU emulator, 400×400 logical test viewport):

| Zoom | Previous per-triangle culling CPU, ms | Source-chunk culling CPU, ms |
|---|---|---|
| 1× | 88.7–94.8 | 88.5–113.7 |
| 8× | 36.6–39.0 | 18.8–40.9 |
| 16× | 31.1–31.8 | 10.8–11.3 |
| 32× | 29.9–31.8 | 8.5–8.6 |

Columns compare the actual production renderer's same camera sequences,
not the slower independently reconstructed unculled reference. They are
separate emulator runs and include runtime variability; in particular the
8× first frame was 40.9 ms, while later frames were 18.8–20.3 ms. The full
overview still submits all visible edges and does not consistently improve.
Opening was 1.232 s versus the previous 1.149 s; index construction is extra
work, and no opening-speed gain is claimed. Initial overview/orbit CPU
recordings were 95.5/120.1/88.9/86.3 ms; measurement-point overlay recordings
were 0.090/0.048/0.044/0.057 ms. All 1,040,838 source triangles remain present.
Even though local zoom CPU recording meets 16.7 ms in this test, GPU raster,
real gesture P95, sustained physical-device FPS/power and peak-memory gates
remain unverified. This is not an overall 60-fps claim.
Post-test RSS was 2,166,956 KiB and swap PSS was 1,244,951 KiB, including
the benchmark's sixteen unculled reference recordings. This is a snapshot,
not production peak memory. Native allocated heap remains high; no memory
gate or measured battery reduction is claimed by the small bounds index.

`report-mesh-chunks.json` preserves the full run; the previous run remains
`report-mesh-culling.json`. Flutter passed 175 tests (two opt-in benchmarks
skipped), Rust workspace passed 138 (one opt-in benchmark ignored), and
static analysis passed. The culling fixture now contains 1,537 triangles,
two whole hidden chunks and a subsequent measured face, with 24 independent
pixel comparisons. Both Android profile and iOS debug accuracy runs reported
15 passing cases including teardown. A separate 300-view float32 oracle
checks that every rejected chunk has all indexed vertices beyond one shared
viewport side, including large coordinates, orientations and scale changes.
The task-owned `CADView_Chunks_20261003` AVD is removed after testing; corpus,
reports and the user's existing iOS simulator are preserved.

## Demand-driven vertex projection (2026-10-04)

Chunk visibility now precedes projection. When fewer than one quarter of a
packed mesh's source chunks can be visible, only vertices referenced by those
chunks are projected, once per camera/viewport epoch. Dense views still use
linear full projection. Projections always start with the original f64 XYZ
and the same origin-subtracted arithmetic; there is no float32 rescaling,
triangle sampling or source-face renumbering. Fully offscreen meshes skip
projection entirely, with no projection buffers allocated for an initially
offscreen mesh. Sparse bookkeeping costs one extra byte per source vertex,
allocated only when needed (520,367 bytes for the NASA corpus).

The Android API-36 profile run used the same STL-only workload, 4 GB/2-vCPU
emulator, 400×400 viewport and camera sequence as the preceding run:

| Zoom | Previous source-chunk CPU, ms | Demand-driven projection CPU, ms |
|---|---|---|
| 1× | 88.5–113.7 | 91.1–102.7 |
| 8× | 18.8–40.9 | 15.1–26.7 |
| 16× | 10.8–11.3 | 6.3–8.1 |
| 32× | 8.5–8.6 | 3.0–3.2 |

These compare actual production recordings from separate emulator runs, not
the independently reconstructed unculled reference. At the last 32× frame,
only 45,211 of 520,367 vertices needed projection (8.7%); retained picture
estimate was 335,416 bytes, versus 49,962,480 bytes at overview. Projection
storage remains 4,162,936 bytes and clip codes 520,367 bytes. The counters
describe this document's retained buffers/picture only, not process or peak
memory; stamp counting is outside timings and never runs in the normal
viewer. All 1,040,838 source triangles remain present and selectable.

Opening was 1.238 s versus 1.232 s previously; no opening-speed improvement
is claimed. Overview/orbit recordings were 87.3/124.0/90.5/94.4 ms, so full
overview remains a bottleneck. Measurement-point overlays took
0.099/0.049/0.044/0.042 ms, and 30 native picking round trips averaged 0.526 ms.
The post-test snapshot was 2,068,368 KiB RSS and 1,310,006 KiB swap PSS,
including sixteen unculled reference recordings. This is not production peak
memory; the high native heap and physical-device power/memory gates remain
unresolved. No sustained FPS or measured battery-reduction claim is made.

Host packet decode/index took 42.6 ms, and local 32× recordings took
2.7–2.9 ms; these debug host results are separate from mobile results.
`report-mesh-sparse.json` preserves the Android run alongside the earlier
reports. Flutter passed 175 tests (two opt-in benchmarks skipped), Rust
workspace passed 138 (one opt-in benchmark ignored), and analysis passed.
The accuracy fixture contains 4,609 triangles, eight fully hidden chunks
and a measured source face after them. Its 56 independent pixel comparisons
cover selected/unselected meshes, legacy/packed geometry, f64 large origins,
full/sparse transitions, identical-projection viewport resize, offscreen
return and byte-epoch wrap. Android profile and iOS debug accuracy runs each
reported 15 passing cases including teardown. Explicit document release is
checked to clear every retained mesh recording/projection buffer. The
task-owned `CADView_Sparse_20261004` AVD is removed after validation; corpus,
reports and the user's existing iOS simulator are preserved.

## Faster DXF parsing and frames without long UI work (2026-10-04)

Large text DXF files (≥ 8 MiB) were tokenized three times: a typed metadata
pass that parsed and discarded every model entity, the raw HATCH/MLEADER/
ACAD_TABLE scan, and the typed entity pass. Now:

- The metadata pass reads a copy without the ENTITIES sections, located by a
  byte-level group splitter that follows the `dxf` reader's line rules.
  Entities can add layers, linetypes and text styles their tables lack; the
  entity pass adds layers exactly as the reader does (top-level entities, in
  order), added linetypes have no pattern either way, and if the complete
  drawing's layers, styles or blocks still differ, entities are normalized
  again against the complete tables. Block-expanded entities get their final
  IDs once the top-level count is known. Binary DXF, DXB and non-ASCII
  encodings keep the previous passes.
- The raw scan decodes only section/entity boundaries and the collected
  HATCH/ACAD_TABLE/MULTILEADER entities, which the `dxf` reader still parses.

Output is unchanged: scene JSON and diagnostics of the 1M-line file, a real
drawing tiled 64 times (`R20-0000_1.dxf`, 83 MB, 682,368 entities, with
entity-only layers and an implicit `BYLAYER` linetype) and three small files
were byte-identical to the previous parser. Tests check streamed against
in-memory results (CRLF, implicit layers/linetypes/styles, multileaders,
tables) and the raw text scan against the code-pair scan.

Release-native `performance_file` on the same M1 Pro host, without a cache:

| File | Before | After |
| --- | ---: | ---: |
| R20 × 64 (83 MB) cold open | 2.54 s | 1.53 s |
| 1M-line synthetic cold open | 4.52 s | 2.53 s |
| R20 × 64 cached reopen | 1.01 s | 0.99 s |

Peak RSS is unchanged (584 MB / 712 MB). Copying lines without `BufReader`
and a SIMD newline search were measured too and gave no gain; they were not
kept.

On the UI isolate, Flutter host debug timings of the R20 × 64 packet
(800 × 600, JIT warmed, CPU recording only, excluding GPU raster):

| Step | Before | After |
| --- | ---: | ---: |
| World paths + label bounds | 380 ms in the first frame | 177 ms before showing, in slices (p95 6.4 ms) |
| First frame | 380 ms | 7.6 ms |
| Overview frame | 16–29 ms | 4.4 ms |
| 8× / 64× zoom frame | 9.0 / 8.3 ms | 3.9 / 2.0 ms |

- `CadScenePainter.prepareDocument` builds a document's paths, foreground
  index and label bounds in ~6 ms slices between frames. The home page uses it
  before opening the viewer, the viewport loader before replacing the shown
  batch, layer toggles and sheet export before rendering.
- Label visibility uses cached world bounds instead of re-measuring every
  label each frame. Labels whose measured screen bounds are thinner than 2 px
  are drawn as one stroke (a faint block for paragraphs); selected labels and
  exports at paper resolution are unaffected.
- Packed polylines, circles and arcs go straight from f64 records into the
  paths like lines, which avoids temporary maps and their collection pauses.
- Sheet PNG bands and PDF tiles are converted and compressed in background
  isolates. PNG bands are raw deflate ending in sync flushes, concatenated
  into one zlib stream with a combined Adler-32. In the headless test runner
  `Picture.toImage` itself still rasterizes synchronously (100–200 ms per
  2048-pixel tile with software rendering); on devices that runs on the
  raster thread.

The longest remaining slice in that workload (~24 ms) is the first layout of
one label whose mojibake text searches all fallback fonts. Device timings
were not taken: iOS simulators run debug builds only and the Android
emulator does not start on this host.

## Gesture snapshots, path cells, parallel parsing and a smaller scene (2026-10-05)

Same M1 Pro host, release-native `performance_file`, uncached then cached:

| File | Cold open | Cached reopen | Peak RSS cold / cached |
| --- | ---: | ---: | ---: |
| R20 × 64, 2026-10-04 start | 2.54 s | 1.01 s | 584 MB |
| R20 × 64, now | 0.63 s | 0.29 s | 480 / 396 MB |
| 1M-line synthetic, start | 4.52 s | 1.44 s | 712 MB |
| 1M-line synthetic, now | 1.00 s | 0.45 s | 627 / 524 MB |

Scene JSON and diagnostics of all five DXF test files and the three DWG
samples remain byte-identical to the previous parser.

- **Parallel DXF entities.** A canonical text DXF (HEADER, TABLES and BLOCKS
  before one ENTITIES section) is cut at top-level entity starts (never inside
  POLYLINE…SEQEND or an INSERT's attributes) and read on up to eight threads,
  each with the HEADER for version and code page. Chunks are normalized
  against the shared metadata with temporary IDs and their own entity-added
  layers; merging restores the sequential IDs (top-level and block-expanded)
  and layer order. A missing layer table is handled with a placeholder for
  "layer 1". Drawings with objects that add layers, entities using text styles
  the tables lack, or any chunk that fails fall back to sequential reading.
  A test reads a 3.6 MB entity section in parallel, compares it with the
  in-memory parse, and mutating the ID, layer or style handling fails it.
- **Scene cache.** The cache file is a header (versions, source checks,
  metadata, layers) followed by entity chunks. A stale cache is rejected after
  the header, and chunks are decoded on several threads while the source is
  hashed. After open, the spatial index, statistics and (on a first open) the
  cache file are built side by side. Scene cache version 32.
- **Entity size.** TEXT/MTEXT geometry is boxed
  (`Entity2DGeometry::Text(Box<TextGeometry2D>)`), so every entity is 104
  bytes instead of 320. Serde output is unchanged.
- **DWG.** acadrust's object record bytes are shared by the record's four
  bit readers instead of copied five times (about 10% faster opens of the
  two 6–7 MB samples). The remaining DWG time is spread over many object
  decoding steps.
- **Gesture snapshots.** After the 2D view has been still for 250 ms, the
  scene is rendered once (25% beyond each edge, transparent, at the device
  pixel ratio, at most 12 MP). While a pan/zoom gesture only moves the
  camera, that image is scaled and translated over the live backdrop; the
  scene is drawn exactly again when the gesture ends or pauses, which also
  loads the viewport. Software-raster frames of R20 × 64 went from about
  1,100 ms (exact) to 17 ms (snapshot). Magnified snapshots look softer until
  release. Tests check alignment after panning and zooming and that a changed
  scene (selection, document, size) never uses an old snapshot.
- **Path cells.** Documents with at least 20,000 entities split each style's
  path into an 8 × 8 grid; frames skip cells whose bounds (plus stroke) miss
  the viewport or canvas clip, including sheet-export tiles. Software-raster
  exact frames at 8× / 32× zoom: 326 → 104 ms and 257 → 40 ms. Skipping
  cells never changes a pixel (tested); separate paths only change how
  overlapping edges are antialiased.
- **Lazy dashes.** A dashed batch is broken into dashes when it is first
  drawn dashed, i.e. zoomed in enough to see the pattern, for visible cells.

## Accurate mobile picking and engineering-file validation (2026-10-07)

Hit tests and both snap APIs now execute on bridge workers. Preview pointer
moves are coalesced; confirmed taps remain ordered, and cancelled tools/cameras
cannot apply stale results. Dense crossing queries no longer discard curves
after a fixed candidate count. Exact coincident curves are deduplicated and a
temporary bounds index eliminates unrelated pairs. Polyline snap scans borrow
vertices without allocating a string/point array per source vertex. An exact
explicit snap avoids unnecessary intersection work.

Phone/tablet long-press picking uses 3× fine motion, a 144/176-pixel loupe and
smaller pen/mouse apertures. Distance and angle expose undo/clear. Precision
area picks retain their selected point instead of choosing a whole closed
boundary. Raster snapshots are now restricted to unchanged-scale pans within
their captured margin; zoom and uncovered regions render exact geometry. This
corrects blank margins and lost magnified detail, but the earlier scaled-image
zoom timings are no longer representative of the accuracy-first zoom path.

Release-native benchmarks on the same host used fresh cache directories and
actual visible source vertices. The old fixed-grid sampler missed all geometry
in the tiled R20 drawing; its empty-query timings must not be used as evidence
of picking performance. The new benchmark asserts that every sampled hit and
snap succeeds:

| Corpus | Entities | Cold native open | Cache reopen | Hit / snap P95 | Hit / snap checks | Process peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| R20 × 64, 83,249,678 bytes | 682,368 | 0.659 s | 0.295 s | 0.00338 / 0.00229 ms | 89 / 89 | 480,542,720 bytes |
| Synthetic DXF, 100,486,964 bytes | 1,000,000 | 1.101 s | 0.426 s | 0.000625 / 0.000500 ms | 100 / 100 | 630,521,856 bytes |

These native times exclude Flutter data transfer, path preparation and GPU
raster. They confirm the existing opening improvements remain intact; this
change does not claim an additional cold-opening speedup. The native process
alone exceeds the 600 MB gate for the million-entity workload.

The Android API-36 profile run (4 GB/2-vCPU emulator, 400×400 test viewport)
opened the complete million-entity DXF in 2.125 s, then transferred/decoded its
full viewport in 0.257 s. Initial CPU path construction/recording took
238.323 ms; subsequent exact recordings took 0.204/0.082/0.044 ms. Normal viewer
preparation builds paths in slices before showing them; this benchmark paints
directly and includes that preparation in its first recording. All million
entities remained present, the first raster had visible ink, and 30 actual
endpoint hit+snap round trips averaged 0.678 ms (both calls per iteration).
Recording time excludes raster cost and does not establish gesture FPS. The
post-test snapshot, after document release/close, was 442,828 KiB RSS and
337,535 KiB PSS; it is neither loaded-view memory nor a peak-memory result.

The three supplied DWG samples passed the existing geometry checks, including
the title-block regression that rejects the erroneous dimension diagonal:
`A1、A2、A3图框.dwg` (1,162 entities), `Armchair-Dwgfree.com_.dwg` (55,979),
and `Bedside-Table-Dwgfree.com_.dwg` (12,328). This is not an independent
AutoCAD visual gold comparison or a claim of universal DWG fidelity.

Validation: Flutter 189 passed / two opt-in benchmarks skipped; Rust workspace
144 passed / one benchmark normally ignored, with that benchmark executed
separately on both large files. Final native Release regressions also passed.
Android profile and iOS debug accuracy suites each reported 16 passing cases
including teardown, covering the real bridge's dense crossing and long-press
UI, fonts, 56 mesh pixel checks, cancellation and exports. Phone and tablet
widget cases cover 390×844 and 1024×768, including stylus input and delayed
reply/clear/tool-switch sequences. Static analysis passed.

Reports are retained locally as `artifacts/qa/precision/native-large-files-20261007.json`,
`artifacts/qa/performance/mobile/android/report-precision-million-20261007.json`
and each mobile accuracy directory's `report-precision-20261007.json`. The
task-owned Android/iOS test devices and temporary native scene caches are
removed after validation; downloaded corpus and reports remain. Physical
devices, production peak memory, continuous zoom/orbit FPS and energy gates
still require measurement; arbitrary engineering files are not certified.

## Reproduction

Generate the deterministic DXF:

```sh
python3 scripts/generate_performance_dxf.py 1000000
```

After downloading the above public files, run the native API benchmark from
the repository root with an explicit local path and a fresh, dedicated cache
directory. Reusing the directory makes the first timing a cache hit too.

```sh
CADVIEW_PERF_FILE="$PWD/artifacts/qa/performance/synthetic-1000000.dxf" \
CADVIEW_PERF_CACHE="$PWD/artifacts/qa/performance/cache-reproduction" \
cargo test --manifest-path rust/Cargo.toml --locked --release \
  performance_file -- --ignored --nocapture --test-threads=1
```

For the mesh recording test, export the native opened-document JSON with
`CADVIEW_PERF_DOCUMENT_JSON` during the STL benchmark, then run:

```sh
CADVIEW_RENDER_JSON="$PWD/artifacts/qa/performance/nasa-pillars.json" \
flutter test --no-pub test/performance_render_test.dart
```

For complete 2D packet recording, export `CADVIEW_PERF_PACKET` during the
native benchmark, then use `CADVIEW_RENDER_PACKET` instead of
`CADVIEW_RENDER_JSON`. The exported packet is a local diagnostic artifact,
not an application cache or public format.
The CAD3D001 packet benchmark also records zooms 1/8/16/32 against the
independent unculled reference. To run sparse-ID lookup/selection diagnostics
on the deterministic all-line CAD2D001 packet, add
`--dart-define=CADVIEW_BENCH_SPARSE_IDS=true` to the Flutter test command.
Only the test's in-memory packet IDs change; the source drawing is untouched.

For mobile, copy the corpus to a device-readable directory first (prefer the
test app's private files directory on Android; do not bypass production file
provider permissions). Use an isolated test simulator/emulator or a device
authorized for test installs:

```sh
flutter drive --profile --flavor community \
  --dart-define=CADVIEW_DISTRIBUTION=community \
  --dart-define=CADVIEW_PERF_DXF=DEVICE_READABLE_DXF_PATH \
  --dart-define=CADVIEW_PERF_STL=DEVICE_READABLE_STL_PATH \
  --target=integration_test/mobile_performance_test.dart \
  --driver=test_driver/mobile_performance_test.dart \
  -d DEVICE_ID --keep-app-running
```

iOS simulators require debug instead of profile. For a prebuilt Android test
APK, install it in the isolated emulator, stage its corpus and supply
`--use-application-binary=PATH_TO_APK` with the same defines.

## Remaining gates

The 2D preview now receives lossless binary numeric records, but zoom-to-fit
still transfers a complete packet and constructs complete paths. 3D now
uses typed mesh buffers, but rotating a million-face wireframe exceeds a
16.7 ms CPU frame budget. Native wgpu external
textures, progressive first geometry, full-device peak memory, physical-device
gesture P95, the 500 MB/5M-triangle corpus and Perfetto/Xcode energy validation
are not delivered or claimed by this optimization. No details are dropped to
claim smoothness or power savings. Idle work was reduced by reuse/coalescing;
no measured battery-percentage reduction is asserted.
