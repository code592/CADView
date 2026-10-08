# Scene runtime transport

## CAD2D001

This private, versioned bridge protocol replaces geometry JSON for the 2D UI.
It is not a disk-cache or export format. Unsupported versions fail explicitly;
the legacy JSON APIs remain available.

All numeric fields are little-endian. Geometry coordinates are exact IEEE-754
f64 values; no quantization, LOD sampling or entity truncation is performed.

| Section | Layout |
| --- | --- |
| Header, 32 bytes | 8-byte `CAD2D001` magic; six u32 values: metadata byte length, entity count, coordinate count, style count, dash count, rich-text byte length |
| Metadata | Existing document-summary UTF-8 JSON; padding to an 8-byte boundary |
| Entities, 32 bytes each | u64 ID, u64 layer ID, u32 style index, u32 kind/flags, u32 start, u32 length |
| Styles, 24 bytes each | u32 ARGB, u32 filled flag, f64 stroke width, u32 dash start, u32 dash count |
| Coordinates | Contiguous f64 values |
| Dashes | Contiguous f64 values |
| Rich text | Complete existing entity JSON, including masks, SHX provenance, columns and diagnostics |

Kinds: 0 text, 1 point, 2 line, 3 polyline, 4 circle, 5 arc.
Polyline closed is bit 8; other flag bits are reserved. Start/length address
coordinates except for text, where they address bytes in the rich-text section.
Coordinate layouts are respectively XY; start XY/end XY; consecutive XY;
center XY/radius; center XY/radius/start angle/end angle (radians).

Encoding interns identical styles while preserving original entity order.
The Rust scene is read-locked across metadata and entity selection so a packet
cannot mix visibility generations. Flutter validates lengths, flags, counts,
style indices, coordinate spans and text identities off the UI isolate before
publishing the document. The current entity ceiling is 5 million; the bridge
also rejects payloads exceeding its signed 32-bit byte-list length.

Numeric entities and sliced lists are read-only lazy views over the packet;
only styles, metadata and rich text become eager maps. Solid lines can be
recorded directly from f64 buffers, still using the established path commands
and origin relocation. Text retains its full existing rendering semantics.
The validation pass also checks ID order. Verified nondecreasing IDs use
lower-bound binary search for sparse property/selection lookup; duplicate IDs
return the first property occurrence and all selected source occurrences.
Unsorted packets use one exact numeric scan without materializing entity
maps. Range views retain these guarantees, and no full-scene ID map is built.

A million solid lines use approximately 64 MB rather than millions of nested
maps. This is not zero-copy native rendering: FRB/isolate transfer, complete
overview packets, path construction and GPU raster still have costs. No
physical-device power, peak-memory or 60-fps claim follows from this protocol.

## CAD3D001

The 3D UI also uses metadata-first open followed by `documentPacket`. Existing
JSON APIs remain compatible. A packet contains all meshes, including hidden
assembly members, so visibility changes can retain the same geometry buffers.

All fields are little-endian:

| Section | Layout |
| --- | --- |
| Header, 32 bytes | 8-byte `CAD3D001` magic; six u32: metadata byte length, mesh count, total vertices, total normals, total indices, reserved zero |
| Metadata | Document-summary JSON with mesh IDs/names/material indices and all optional measurement properties; align the following directory to 8 bytes |
| Mesh directory | Three u32 per mesh: vertex count, normal count, index count; align the following positions to 8 bytes |
| Positions | f64 XYZ triplets, concatenated in mesh/source order |
| Normals | Native f32 XYZ triplets, concatenated in mesh/source order |
| Indices | u32 values local to each mesh, concatenated in source order |

Coordinates are never rounded to f32. Normals preserve the original native
f32 bits, rather than the shorter decimal representation used by JSON.
No vertex deduplication, topology reordering, sampling or triangle omission
is introduced by transport. The decoder rejects nonfinite geometry, invalid
topology, malformed ranges, duplicate IDs, incomplete sections and reserved
flags. Indices are bounded to 5 million triangles and total payload size to
the bridge's signed 32-bit length. Empty meshes remain representable.

Aligned little-endian buffers use read-only typed views; other slices copy
exact values directly into typed arrays without a boxed-number staging list.
Mesh/vertex-list views support the same map/list API for properties and
measurement, but the painter reads f64 XYZ and u32 indices directly. Only
vertices needed for a measurement/fallback ray are converted to `CadPoint3`.
One exact per-camera display list is retained, replacing the previous entry
when camera/viewport-size/selection/measured-face state changes. Conservative
screen-space outcodes reject only triangles entirely beyond one shared side
with a four-pixel margin; all visible and crossing edges are still drawn.
Outcode storage is one byte per vertex, reused across camera changes. This does not eliminate
GPU raster cost or make a full wireframe automatically meet a 60-fps gate.
Decode derives a source-order f64 bounds index (512 triangles/chunk) while
validating indices. It is private runtime acceleration, not metadata/wire
geometry: JSON compatibility, topology, normals and exact measurements stay
unchanged. Chunk interval rejection has stroke/rounding margins and fails
open on nonfinite or float32-overflow projections. Fully offscreen chunks
can be skipped without scanning every triangle on camera changes.
For sparse packed views, vertex projection is also demand-driven and cached
by a one-byte epoch per source vertex (allocated only when needed). Dense
overview views retain linear projection. Camera/size changes, epoch wrap,
full/sparse transitions and explicit document release cannot reuse stale
points/codes. Geometry/topology and face indices never change. Local opt-in
render-cache counters describe this document's retained buffers/picture only;
they are neither process peak-memory measurements nor remote telemetry.
