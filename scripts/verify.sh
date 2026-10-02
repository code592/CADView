#!/usr/bin/env bash
set -euo pipefail

flutter pub get --offline
dart format --output=none --set-exit-if-changed lib test integration_test test_driver scripts/render_cad_fonts.dart
flutter analyze
flutter test
bash scripts/check_cad_fonts.sh

(
  cd rust
  cargo fmt --all --check
  cargo test --workspace --locked --offline
  TZ=UTC cargo test --manifest-path vendor/dxf/Cargo.toml --lib --locked --offline
  cargo test --manifest-path vendor/acadrust/Cargo.toml --lib --locked --offline
)

./scripts/verify_offline_manifest.sh

if test "$(uname -s)" = "Darwin" && test -d /Applications/Xcode.app; then
  CADVIEW_XCODE_APP="${CADVIEW_XCODE_APP:-/Applications/Xcode.app}"
  DEVELOPER_DIR="$CADVIEW_XCODE_APP/Contents/Developer" \
    xcodebuild -version
fi
