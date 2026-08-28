<p align="center">
  <img src="assets/branding/cadview-app-icon.png" width="144" alt="CADView app icon">
</p>

# CADView Community

CADView Community is an offline, open-source CAD and engineering-document
viewer for Android and iOS. Flutter owns the mobile interface, while a
decoupled Rust workspace handles content-based format detection, parsing,
normalized 2D/3D scenes, spatial queries, measurements, annotations and local
persistence.

The project is licensed under Apache-2.0. Source drawings are always opened
read-only. The Community edition contains the complete available feature set,
has no advertising SDK and requests no network permission.

## Features

- DXF, SVG/SVGZ, OBJ, STL, glTF/GLB and 3MF viewing.
- Fully offline PDF page rendering, pan and zoom.
- DWG R13-R2018+ Beta support with layouts, nested blocks, attributes and a
  validated local reopen cache.
- 2D pan, zoom, layers, selection, snapping, distance measurement and text
  annotations.
- 3D orbit, pan, zoom, mesh selection, surface-anchored measurement and
  annotations.
- Files can be selected in CADView or opened/shared from file managers, cloud
  drives, mail clients and other apps.
- SQLite annotation persistence, undo/redo and portable `.cadnote.json`
  export.

STEP and IGES remain disabled until the separately reviewed Open CASCADE
adapter is integrated. DWG remains Beta until its licensed compatibility
corpus and visual acceptance gates are complete. See
[format support](docs/FORMAT_SUPPORT.md) and
[architecture](docs/ARCHITECTURE.md) for exact capability boundaries.

## Languages

Every Community build includes English, Simplified Chinese, Traditional
Chinese, Spanish, Japanese, French, Korean and Russian. CADView follows the
system language by default, falls back to English when no language matches,
and allows a manual language selection in Settings.

## Build

Prerequisites: Flutter 3.47+, stable Rust, Android SDK/NDK and Xcode 16+ for
iOS.

```bash
flutter pub get
flutter_rust_bridge_codegen generate
flutter run --flavor community \
  --dart-define=CADVIEW_DISTRIBUTION=community
```

Run the Rust checks:

```bash
cd rust
cargo test --workspace --locked
cargo fmt --all --check
```

Run all repository checks with `scripts/verify.sh`. Android supports API 26+
and iOS supports 15.0+. Release signing material is never stored in this
repository.

An installable Community release APK must be built with all four external
signing variables. The helper refuses missing credentials and verifies the
finished APK before reporting success:

```bash
CADVIEW_ANDROID_KEYSTORE_FILE=/secure/path/community.jks \
CADVIEW_ANDROID_KEYSTORE_PASSWORD=... \
CADVIEW_ANDROID_KEY_ALIAS=... \
CADVIEW_ANDROID_KEY_PASSWORD=... \
bash scripts/build_signed_community_apk.sh
```

An unsigned `flutter build apk --release` artifact is not a distributable APK.

On macOS, `scripts/maintain_ios.sh` maintains the project-local Xcode,
CocoaPods and Rust iOS environment without changing the global Xcode
selection:

```bash
bash scripts/maintain_ios.sh --build community
```

## Repository layout

- `lib/`: Flutter application shell, import flow and viewer UI.
- `rust/crates/cad-core`: format-neutral geometry and scene types.
- `rust/crates/cad-formats`: isolated format adapters.
- `rust/crates/cad-storage`: local SQLite annotation persistence.
- `rust/src/api`: Flutter/Rust application API.
- `rust_builder/`: Cargokit integration for Android and iOS.

## Security and privacy

Format identification is based primarily on file content; extensions are only
a low-confidence hint. Files, paths, hashes and annotations remain on the
device. Community release manifests contain no `INTERNET` permission.

## License

CADView Community is licensed under Apache-2.0. Dependencies retain their own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No GPLv3
component is linked. The acadrust dependency remains MPL-2.0.
