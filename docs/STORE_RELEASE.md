# App Store, Google Play and lifetime ad-free purchase

## Recommended product layout

- Publish `globalStore` as one free international listing with all CAD
  features and one home-page ad.
- Sell a non-consumable/one-time product named `cadview_remove_ads_lifetime`.
  A verified entitlement disables advertising; it must not unlock CAD file
  formats or upload any CAD metadata.
- Keep `community`, `cnViewer` and `cnPro` separate from the international
  billing implementation. Only `globalStore` may link StoreKit/Play Billing
  and advertising SDKs.
- `CADVIEW_AD_FREE=true` remains useful for an independently priced binary or
  automated testing. It is not proof that a store purchase occurred.

Without a CADView account, purchases restore only within the customer's Apple
or Google ecosystem. Cross-platform entitlement sharing requires an account
and a backend policy that complies with both stores.

## Required account setup

Before producing release binaries, choose permanent bundle/package IDs, app
name, support URL, privacy-policy URL and product ID. Bundle IDs and product
IDs must match the store records exactly and should never be reused for test
apps.

For Apple:

1. Join the Apple Developer Program and accept the latest agreements.
2. In App Store Connect, complete Paid Apps, banking and tax information.
3. Register the final bundle ID, enable In-App Purchase, and create the iOS app
   record before uploading a build.
4. Under Monetization > In-App Purchases, create a **Non-Consumable** product
   `cadview_remove_ads_lifetime`; add all localizations, price, review notes and
   the required review screenshot.

For Google:

1. Complete Play Console identity/developer verification and payments-profile
   setup.
2. Create the app with its permanent package name and enable Play App Signing.
3. Under Monetize with Play > Products > In-app products, create and activate
   the one-time product `cadview_remove_ads_lifetime`.
4. New personal accounts created after 2023-11-13 must complete Google's
   required closed test before production access.

## Client purchase contract

Expose a store-neutral Dart interface only to `globalStore`:

```text
AdFreePurchaseService
  loadProducts()
  purchaseLifetimeAdFree()
  restorePurchases()
  entitlementChanges()
  currentEntitlement()
```

The UI needs a localized price supplied by the store, a purchase button, a
Restore Purchases button and links to terms/privacy. Never hard-code a price.
Until entitlement loading finishes, keep the home advertisement collapsed to
avoid briefly showing ads to a paid customer.

### StoreKit 2

1. Query the non-consumable with `Product.products(for:)`.
2. Start a long-lived `Transaction.updates` task during app startup.
3. Read `Transaction.currentEntitlements` at startup/foreground and on restore.
4. Accept only verified transactions for the expected bundle ID and product
   ID, grant the entitlement, then call `finish()`.
5. Implement Restore Purchases with `AppStore.sync()` and re-read current
   entitlements.
6. Configure App Store Server Notifications V2 and verify signed transactions
   with the App Store Server API for production refund/revocation handling.

Use an Xcode StoreKit configuration for local tests, then App Store sandbox and
TestFlight. Test purchase, cancellation, interrupted purchase, Ask to Buy,
restore after reinstall, refund/revocation and offline startup.

### Google Play Billing

1. Add Play Billing only to `globalStoreImplementation`; use the current
   supported Billing Library rather than a shared app dependency.
2. Create one `BillingClient`, enable automatic reconnection, and query
   `ProductDetails` for the one-time product.
3. Launch the billing flow only from an explicit user action.
4. Handle `PurchasesUpdatedListener`, send the purchase token to the backend,
   and grant the entitlement only after verification.
5. Acknowledge a verified non-consumable purchase. Unacknowledged purchases
   are refunded by Google after its acknowledgement window.
6. Call `queryPurchasesAsync` at startup and foreground for restore/recovery.
   Use Real-time Developer Notifications plus the Google Play Developer API to
   process refunds and revoked purchases.

Test with license testers and internal testing, followed by closed testing.
Cover pending purchases, cancellation, duplicate callbacks, reconnect,
reinstall/restore, refund/revocation and offline startup.

## Verification backend

For production, use a small backend that accepts an Apple signed transaction
or Google purchase token and returns only an ad-free entitlement status. Store
the platform, product ID, original transaction/order identity, status and last
verification time. Do not send CAD paths, file names, hashes or annotations.

The backend should:

- verify Apple JWS/App Store Server API responses and Google purchases through
  the Google Play Developer API;
- reject unexpected app IDs, product IDs, environments and replayed tokens;
- process App Store Server Notifications and Google Real-time Developer
  Notifications idempotently;
- cache a signed entitlement response so a previously verified customer stays
  ad-free during temporary network loss;
- provide account deletion and minimal retention if CADView accounts are used.

## Store release checklist

App Store:

1. Archive `globalStore` with release signing and production AdMob IDs.
2. Upload using Xcode Organizer or Transporter.
3. Add screenshots, description, keywords, support/privacy URLs, age rating,
   export-compliance answers, App Privacy answers and review credentials/notes.
4. Attach the first In-App Purchase to the app-version submission, select the
   uploaded build, add it for review, then submit the draft submission.
5. Start with TestFlight and manual/phased release.

Google Play:

1. Build and sign an AAB, enroll in Play App Signing and upload first to the
   internal track.
2. Complete the main/custom store listing, screenshots, contact details,
   privacy URL, Data Safety, ads declaration, content rating, target audience,
   app access and all policy declarations.
3. Activate the one-time product and verify purchases using license testers.
4. Complete closed testing/production-access requirements when applicable.
5. Promote the tested AAB to production and use staged rollout.

Every store build must receive its own SBOM, NOTICE, privacy manifest, signing
record and permission report. Release builds must use production ad and product
identifiers; test identifiers must fail the release pipeline.

## Official references

- [Apple: add an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [Apple: configure In-App Purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)
- [Apple: create a non-consumable](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases/)
- [Apple: submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
- [Apple: App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)
- [Google: create and set up an app](https://support.google.com/googleplay/android-developer/answer/9859152)
- [Google: integrate Play Billing](https://developer.android.com/google/play/billing/integrate)
- [Google: integrate a billing backend](https://developer.android.com/google/play/billing/backend)
- [Google: personal-account testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)
