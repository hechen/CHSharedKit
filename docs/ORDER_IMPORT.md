# CHOrderImport

Retailer order-import helpers for apps that track purchases. It ships as its own product so an app can use it without pulling in the AI or on-device model targets.

```yaml
dependencies:
  - package: CHSharedKit
    product: CHOrderImport
```

Depends on Foundation, CryptoKit, and WebKit only.

## What it provides

| Type | Role |
|---|---|
| `AmazonOrderPage` | The JavaScript that reads Amazon.com order-history cards and order-detail pages inside a signed-in `WKWebView`: `listScript`, `accessScript`, `navigationScript`, `detailScript`, and `orderHistoryURL`. |
| `AmazonOrderReader` | `@MainActor` helpers that run those scripts on a host-owned web view with bounded payloads: `pageAccess`, `orders`, `pagination`, `orderDetail`. |
| `AmazonOrder`, `AmazonOrderItem` | The decoded order. `isReturnedOrCancelled`, `importStatus(using:)`, `lineDrafts()`, `sanitizedDetailsURL`, `allowedURL`. |
| `AmazonOrderSelection` | Cross-page selection that merges re-read pages without duplicating orders and only allows selecting orders whose details can be read. |
| `OrderLineDraft` | One reviewable purchase line: name, unit amount text, ISO currency, `yyyy-MM-dd` date, quantity, image, status, order and product URLs, warnings, and a SHA-256 `sourceKey`. `amountCents`, `purchaseDate`, `needsOwnershipReview`, `issue`, and `sourceKey(forUnit:)`. |
| `OrderImportText` | Strict parsing: `date`, `isoDay`, `cleanAmount`, `amountCents`, `isCurrencyCode`, `minorUnits(for:)`, `indicatesReturnOrCancellation`, `key`. |
| `OrderImportDuplicateIndex` | Duplicate checks against the `sourceKey:unit` values the host already persisted. |
| `OrderCSVTable` | A bounded CSV/TSV parser for order files with Amazon-style headers, with a column mapping and selectable date format. |
| `AmazonImportArchive`, `AmazonImportArchiveStore` | Optional local recovery of an unfinished import. |
| `AmazonBrowserSession` | A dedicated persistent `WKWebsiteDataStore` for the user's Amazon sign-in, with `clear()`, a `generation` counter for tearing down web views, and `makeWebView` that requests desktop content. |
| `PublicWebURL` | Public HTTPS-only URL policy. |

## Host responsibilities

1. Own the web view. Create it with `AmazonBrowserSession.makeWebView`, load `AmazonOrderPage.orderHistoryURL`, and call `AmazonOrderReader` after each page finishes loading.
2. Present the review. The package does not persist records into the host data model; optional import archives can save draft recovery state. Map each selected `OrderLineDraft` onto the app's model, create `quantity` records, and persist `draft.sourceKey(forUnit: index)` on each so later imports can skip it through `OrderImportDuplicateIndex`.
3. Download images with the app's own bounded downloader. `imageURL` has passed `PublicWebURL.isAllowed`, but no cookies from the Amazon session should be reused.
4. Explain the sign-in. The Amazon cookies stay in the app's local profile; offer a "Clear Amazon sign-in" action that calls `AmazonBrowserSession.clear()`.

## Scope and limits

- Parser fixtures cover English and Spanish amazon.com desktop layouts. Live pages can change; other marketplaces are not covered.
- This is a user-driven browser importer, not an Amazon API. It reads only order containers; recommendations and order totals are never purchase rows.
- Refunds are surfaced as ownership warnings, not netted against prices.

The tests in `Tests/CHOrderImportTests` execute the production scripts inside a real `WKWebView` against inline HTML, so selector changes are caught without network access.

Origin: extracted from Keeps' `KeepsCore` Amazon importer in September 2026.
