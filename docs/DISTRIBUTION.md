# Distribution and advertising boundary

| Variant | Intended channel | CAD feature tier | Network permission | Monetization |
|---|---|---|---:|---|
| `community` | GitHub/F-Droid-style distribution | Full | No | None |
| `cnViewer` | Mainland China free listing | View only | No | None |
| `cnPro` | Mainland China paid listing | Full | No | Paid download |
| `globalStore` | Google Play and non-mainland App Store | Full | Yes | One home-page ad; optional ad-free paid artifact |

Select the Flutter policy with the matching compile-time value, for example:

```bash
flutter build apk --flavor community \
  --dart-define=CADVIEW_DISTRIBUTION=community
```

The iOS project contains shared schemes with the same four names. They
deliberately retain the existing bundle identifier until the final brand and
ownership records are approved; assign distinct store bundle identifiers and
signing settings in the release pipeline rather than committing credentials.

`cnViewer` hides measurement, annotations and annotation export in Flutter and
also rejects those calls at the engine boundary. It still supports opening,
view navigation, layers/assembly visibility, selection and properties.
`cnPro`, `community` and `globalStore` expose the complete feature set.

An international ad-free paid artifact uses the same `globalStore` source and
flavor with advertising disabled at compile time:

```bash
flutter build appbundle --flavor globalStore \
  --dart-define=CADVIEW_DISTRIBUTION=globalStore \
  --dart-define=CADVIEW_AD_FREE=true
```

This flag is a release-channel entitlement, not a client-side purchase
receipt. A single-listing in-app purchase must replace it with a verified
StoreKit/Play Billing entitlement once product identifiers and server-side
receipt policy are available; do not unlock a paid purchase using an
unverified local preference.

The open-source tree contains an `AdvertisingService`, a disabled offline
implementation and a native `globalStore` provider. Android uses a
`globalStoreImplementation` dependency; iOS restricts the Google Pod to the
three `globalStore` Xcode configurations. The provider is never a dependency
of the parser, Rust session, viewer, measurement, annotation or export code.

Before a provider may initialize, the store integration must record privacy
policy acceptance. It must request restricted/non-personalized ads by default,
load at most once when entering the foreground home page, collapse on failure
or no-fill, and dispose/suspend before opening a document. CAD contents,
paths, names, hashes, recent files and annotations must never be supplied as
advertising data. Personalized ads and iOS ATT are opt-in only and revocable.

Generate an independent SBOM, NOTICE, privacy manifest and permission report
for every published variant.

Debug builds use Google's official test application and banner identifiers.
Android `globalStore` release builds fail without `CADVIEW_ADMOB_APP_ID` and
`CADVIEW_ADMOB_BANNER_ID` Gradle properties. iOS `Release-globalStore` fails
without `CADVIEW_ADMOB_IOS_APP_ID` and `CADVIEW_ADMOB_IOS_BANNER_ID` supplied
to the flavor configuration script. Never publish the test identifiers.

The app privacy manifest declares only the first-party file timestamp access
used to validate local caches and user-selected files. Google SDK collection
is reported by the SDK's own privacy manifest and must also be reflected in the
App Store privacy label and Google Play Data Safety form.

## Localization

English (`en`), Simplified Chinese (`zh-Hans`), Traditional Chinese
(`zh-Hant`), Spanish (`es`), Japanese (`ja`), French (`fr`), Korean (`ko`) and
Russian (`ru`) are packaged in every variant. The app follows the ordered
system locale list by default, maps Chinese regional locales to the matching
script, and falls back to English when no supported language matches. The
user's Settings override is stored only in the app support directory. A test
requires every translation table to contain the complete English key set.
