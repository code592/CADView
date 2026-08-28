#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  CADVIEW_ANDROID_KEYSTORE_FILE
  CADVIEW_ANDROID_KEYSTORE_PASSWORD
  CADVIEW_ANDROID_KEY_ALIAS
  CADVIEW_ANDROID_KEY_PASSWORD
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required signing variable: ${variable}" >&2
    exit 2
  fi
done

if [[ ! -f "${CADVIEW_ANDROID_KEYSTORE_FILE}" ]]; then
  echo "Keystore does not exist: ${CADVIEW_ANDROID_KEYSTORE_FILE}" >&2
  exit 2
fi

flutter build apk \
  --release \
  --flavor community \
  --dart-define=CADVIEW_DISTRIBUTION=community

apk_path="build/app/outputs/flutter-apk/app-community-release.apk"
if [[ ! -f "${apk_path}" ]]; then
  echo "Expected APK was not generated: ${apk_path}" >&2
  exit 1
fi

android_sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "${android_sdk_root}" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT is required for signature verification" >&2
  exit 2
fi

apksigner_path="$(find "${android_sdk_root}/build-tools" -type f -name apksigner -print | sort -V | tail -1)"
if [[ -z "${apksigner_path}" ]]; then
  echo "apksigner was not found under ${android_sdk_root}/build-tools" >&2
  exit 2
fi

"${apksigner_path}" verify --verbose --print-certs "${apk_path}"
echo "Signed installable APK: ${apk_path}"
