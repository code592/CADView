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

The transitional Flutter renderer receives at most 75,000 overview entities
or 150,000 R-tree-selected viewport candidates. The complete scene and index
remain in the Rust session, so camera updates no longer serialize every entity.

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
