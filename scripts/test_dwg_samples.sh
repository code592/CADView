#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sample_root=${CADVIEW_DWG_SAMPLE_ROOT:-/Users/xht/Downloads}
cargo_bin=${CARGO:-/Users/xht/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo}

for sample in \
  "A1、A2、A3图框.dwg" \
  "Armchair-Dwgfree.com_.dwg" \
  "Bedside-Table-Dwgfree.com_.dwg"
do
  path="$sample_root/$sample"
  if [ ! -f "$path" ]; then
    echo "SKIP: sample not found: $path"
    continue
  fi
  CARGO_PROFILE_RELEASE_STRIP=false "$cargo_bin" run \
    --manifest-path "$project_root/rust/Cargo.toml" \
    --release \
    --quiet \
    -p cad-formats \
    --example validate_dwg \
    -- "$path"
done
