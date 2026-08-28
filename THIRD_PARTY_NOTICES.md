# Third-party notices

The authoritative dependency versions are `pubspec.lock` and
`rust/Cargo.lock`. Release automation must generate a CycloneDX SBOM and retain
each dependency's license text. The main directly used components are:

The `globalStore` build, but not the Apache-2.0 `community` build, links the
official Google Mobile Ads SDK and Google User Messaging Platform SDK under
Google's applicable SDK terms. They are not relicensed under Apache-2.0 and are
not dependencies of the CAD core. Current native versions are Android Google
Mobile Ads 25.4.0 (including UMP 4.0.0) and iOS Google Mobile Ads 13.9.0 with
Google User Messaging Platform 3.1.0.

| Component | Purpose | License |
|---|---|---|
| Flutter | Android/iOS UI framework | BSD-3-Clause |
| flutter_rust_bridge / Cargokit | Dart-Rust FFI build bridge | MIT |
| acadrust 0.4.1 | DWG R13-R2018+ Beta reader | MPL-2.0 |
| pdfrx_engine / pdfium_flutter / pdfium_dart | PDF API and mobile deployment | MIT |
| PDFium chromium/7811 (build 20260502-190206) | Offline PDF rendering | BSD-3-Clause and bundled third-party terms |
| dxf | DXF parser | MIT |
| gltf | glTF/GLB parser | MIT OR Apache-2.0 |
| tobj | OBJ parser | MIT |
| stl_io | STL parser | MIT |
| roxmltree | SVG/3MF XML | MIT OR Apache-2.0 |
| zip | 3MF container | MIT |
| rusqlite / SQLite | Local annotation database | MIT / public domain |
| rstar | 2D spatial index | MIT OR Apache-2.0 |
| BLAKE3 | Source fingerprint | CC0-1.0 OR Apache-2.0 |
| ciborium | Versioned CBOR scene cache | Apache-2.0 |

Planned, not currently linked:

- Open CASCADE is LGPL-2.1 with its exception. A store build that links it must
  publish the exact version, patches, build scripts and relinking materials.
- Assimp requires a fresh version-specific license review before its adapter
  can replace the current first-party mesh readers.

The PDFium binary version and SHA-256 are pinned by `pdfium_flutter`'s Podspec
and Dart native-assets hook. PDFium's BSD notice is retained in
`third_party_licenses/PDFium-LICENSE.txt`; its upstream root license and
third-party terms must be included in every binary distribution and generated
SBOM.

acadrust is used unmodified from crates.io. Its corresponding source and full
MPL-2.0 license are available from the
[pinned 0.4.1 crate](https://crates.io/crates/acadrust/0.4.1). Any
future modifications to acadrust files must remain MPL-2.0.

GPLv3 LibreDWG is intentionally excluded.
