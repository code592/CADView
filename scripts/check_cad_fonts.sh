#!/usr/bin/env bash
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk=${CADVIEW_FLUTTER_SDK:-${FLUTTER_ROOT:-}}
if [ -z "$sdk" ]; then
  flutter_binary=$(command -v flutter)
  while [ -L "$flutter_binary" ]; do
    link=$(readlink "$flutter_binary")
    case "$link" in
      /*) flutter_binary=$link ;;
      *) flutter_binary=$(dirname "$flutter_binary")/$link ;;
    esac
  done
  sdk=$(CDPATH= cd -- "$(dirname "$flutter_binary")/.." && pwd)
fi
case "$(uname -s)-$(uname -m)" in
  Darwin-*) engine=darwin-x64 ;;
  Linux-x86_64) engine=linux-x64 ;;
  Linux-aarch64) engine=linux-arm64 ;;
  *) echo 'This visual check requires a macOS or Linux Flutter SDK.' >&2; exit 1 ;;
esac

cd "$project_root"
mkdir -p artifacts/qa
output="$project_root/artifacts/qa/cad-font-render.dill"
trap 'rm -f -- "$output"' EXIT
if ! "$sdk/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$sdk/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk" \
  --target=flutter --packages=.dart_tool/package_config.json \
  --output-dill="$output" scripts/render_cad_fonts.dart \
  >artifacts/qa/cad-font-compile.log 2>&1; then
  tail -n 60 artifacts/qa/cad-font-compile.log >&2
  exit 1
fi
"$sdk/bin/cache/artifacts/engine/$engine/flutter_tester" \
  --disable-vm-service --enable-software-rendering \
  --skia-deterministic-rendering --run-forever \
  --packages=.dart_tool/package_config.json "$output"
