#!/usr/bin/env bash
set -euo pipefail

offline_manifests=(
  "android/app/src/main/AndroidManifest.xml"
  "android/app/src/community/AndroidManifest.xml"
  "android/app/src/cnViewer/AndroidManifest.xml"
  "android/app/src/cnPro/AndroidManifest.xml"
)
for manifest in "${offline_manifests[@]}"; do
  if test -f "$manifest" && grep -q 'android.permission.INTERNET' "$manifest"; then
    echo "Offline manifest must not request INTERNET: $manifest" >&2
    exit 1
  fi
done

# When Gradle output is present, verify the actual release merge as well. The
# Flutter debug source set intentionally adds INTERNET for hot reload and must
# not be used as evidence for a published artifact.
merged_release_manifests=(
  "build/app/intermediates/merged_manifest/communityRelease/processCommunityReleaseMainManifest/AndroidManifest.xml"
  "build/app/intermediates/merged_manifest/cnViewerRelease/processCnViewerReleaseMainManifest/AndroidManifest.xml"
  "build/app/intermediates/merged_manifest/cnProRelease/processCnProReleaseMainManifest/AndroidManifest.xml"
)
for manifest in "${merged_release_manifests[@]}"; do
  if test -f "$manifest" && grep -q 'android.permission.INTERNET' "$manifest"; then
    echo "Offline release merge contains INTERNET: $manifest" >&2
    exit 1
  fi
done

for manifest in android/app/src/globalStore/AndroidManifest.xml; do
  if ! grep -q 'android.permission.INTERNET' "$manifest"; then
    echo "Store networking manifest is incomplete: $manifest" >&2
    exit 1
  fi
done

if ! test -s LICENSE || ! test -s NOTICE || ! test -s THIRD_PARTY_NOTICES.md; then
  echo "Release license artifacts are missing" >&2
  exit 1
fi

if ! test -s ios/Runner/PrivacyInfo.xcprivacy; then
  echo "iOS app privacy manifest is missing" >&2
  exit 1
fi

if grep -Rqs 'GoogleMobileAds\|play-services-ads' \
  android/app/src/community android/app/src/cnViewer android/app/src/cnPro; then
  echo "An offline Android flavor references an advertising SDK" >&2
  exit 1
fi

for flavor in community cnviewer cnpro; do
  for xcconfig in ios/Pods/Target\ Support\ Files/Pods-Runner/Pods-Runner.*-"$flavor".xcconfig; do
    if test -f "$xcconfig" && grep -Eq 'Google-Mobile-Ads|GoogleUserMessagingPlatform|UserMessagingPlatform' "$xcconfig"; then
      echo "An offline iOS flavor references an advertising SDK: $xcconfig" >&2
      exit 1
    fi
  done
done

echo "Offline manifest and license artifacts verified"
