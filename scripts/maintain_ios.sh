#!/usr/bin/env bash
set -euo pipefail

CADVIEW_XCODE_APP="${CADVIEW_XCODE_APP:-/Applications/Xcode.app}"
CADVIEW_DEVELOPER_DIR="$CADVIEW_XCODE_APP/Contents/Developer"

if ! test -x "$CADVIEW_XCODE_APP/Contents/MacOS/Xcode"; then
  echo "Full Xcode is missing at $CADVIEW_XCODE_APP" >&2
  if command -v mas >/dev/null 2>&1; then
    echo "Installing Xcode from the Mac App Store..."
    mas install 497799835
  else
    echo "Install Xcode from the Mac App Store, or install mas and rerun." >&2
    exit 1
  fi
fi

export DEVELOPER_DIR="$CADVIEW_DEVELOPER_DIR"

if test "$(xcode-select -p)" != "$CADVIEW_DEVELOPER_DIR"; then
  echo "System xcode-select points elsewhere; CADView will use its project-local xcrun wrapper."
fi

if ! command -v pod >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "CocoaPods is missing and Homebrew is unavailable." >&2
    exit 1
  fi
  brew install cocoapods
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required for the native iOS library." >&2
  exit 1
fi

xcodebuild -runFirstLaunch
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
flutter config --enable-ios
flutter pub get

CADVIEW_COCOAPODS_ROOT="$(cd "$(dirname "$(command -v pod)")/../Cellar/cocoapods" 2>/dev/null && pwd || true)"
if test -d "$CADVIEW_COCOAPODS_ROOT"; then
  CADVIEW_COCOAPODS_VERSION="$(ls -1 "$CADVIEW_COCOAPODS_ROOT" | sort -V | tail -1)"
  CADVIEW_GEM_HOME="$CADVIEW_COCOAPODS_ROOT/$CADVIEW_COCOAPODS_VERSION/libexec"
  GEM_HOME="$CADVIEW_GEM_HOME" /opt/homebrew/opt/ruby/bin/ruby \
    scripts/configure_ios_flavors.rb
else
  echo "CocoaPods Ruby environment was not found; skipping flavor regeneration." >&2
fi

# Flutter's project migrator enables unrestricted ProMotion when this key is
# absent. CADView renders on demand and intentionally caps the default build
# at 60 Hz to avoid doubling idle/interaction GPU work on 120 Hz devices.
/usr/libexec/PlistBuddy -c "Set :CADisableMinimumFrameDurationOnPhone false" \
  ios/Runner/Info.plist

echo "iOS toolchain is ready:"
xcodebuild -version
pod --version
rustup target list --installed | grep apple-ios

if test "${1:-}" = "--build"; then
  CADVIEW_IOS_FLAVOR="${2:-}"
  if test -n "$CADVIEW_IOS_FLAVOR"; then
    flutter build ios --simulator --no-codesign \
      --flavor "$CADVIEW_IOS_FLAVOR" \
      --dart-define="CADVIEW_DISTRIBUTION=$CADVIEW_IOS_FLAVOR"
  else
    flutter build ios --simulator --no-codesign
  fi
fi
