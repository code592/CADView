#!/usr/bin/env bash
set -euo pipefail

flutter pub get --offline
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test

(
  cd rust
  cargo fmt --all --check
  cargo test --workspace --locked --offline
)

./scripts/verify_offline_manifest.sh

if test "$(uname -s)" = "Darwin" && test -d /Applications/Xcode.app; then
  CADVIEW_XCODE_APP="${CADVIEW_XCODE_APP:-/Applications/Xcode.app}"
  DEVELOPER_DIR="$CADVIEW_XCODE_APP/Contents/Developer" \
    xcodebuild -version
fi
