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

On macOS, `scripts/maintain_ios.sh --build` is the canonical iOS environment
and simulator-build check. It owns Xcode selection through `DEVELOPER_DIR`,
CocoaPods availability and all Rust Apple targets; CI calls the same script.
