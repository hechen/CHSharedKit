# IAP gating for AI providers (CHSharedKit 2.6.0+)

Portfolio-wide IAP gating: each consumer app supplies its own ASC product +
IAPManager, the kit owns gating logic + picker UI.

## Quick start

```swift
import CHSharedKit
import StoreKit

@MainActor
@Observable
final class YourIAPManager: CHIAPGate {
    static let shared = YourIAPManager()

    var hasUnlockedProviders: Bool = false
    var unlockPriceLabel: String?

    private let productID = "app.yourapp.unlock_ai"
    private var product: Product?
    private var transactionListener: Task<Void, Never>?

    init() {
        Task { await loadProduct() }
        transactionListener = listenForTransactions()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [productID])
            self.product = products.first
            self.unlockPriceLabel = products.first?.displayPrice
            await refreshTransactionState()
        } catch {
            // log, leave price label nil — banner button shows "Loading…"
        }
    }

    func refreshTransactionState() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, txn.productID == productID {
                hasUnlockedProviders = true
                return
            }
        }
        hasUnlockedProviders = false
    }

    func startPurchase() async throws {
        guard let product else {
            throw NSError(domain: "YourApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Product not loaded yet"])
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let txn) = verification {
                await txn.finish()
                hasUnlockedProviders = true
            }
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshTransactionState()
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await update in Transaction.updates {
                if case .verified(let txn) = update, txn.productID == self.productID {
                    await txn.finish()
                    await MainActor.run {
                        // Refunds and revocations arrive here too, with a
                        // revocation date. Never unlock on a revoked update.
                        self.hasUnlockedProviders = txn.revocationDate == nil
                    }
                }
            }
        }
    }
}
```

Also call `refreshTransactionState()` when the app returns to the
foreground (`scenePhase == .active`), and skip entitlements whose
`revocationDate` is set, so a refund processed while the app was closed
re-locks on the next launch or foreground.

## Wire into your App

```swift
import CHSharedKit
import CHLocalLLM

@main
struct YourApp: App {
    init() {
        CHIAPGateRegistry.shared = YourIAPManager.shared
        // Default config — Apple Intelligence stays free, everything else gated:
        CHAIManager.shared.gateAllExceptAppleIntelligence()

        // Or pick specific providers to gate:
        // CHAIManager.shared.gatedProviderIDs = [
        //     CHOpenAIProvider.providerID,
        //     CHClaudeProvider.providerID,
        // ]
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

## What you get for free in the picker

`CHAISettingsContent` (used by `CHAIProviderPickerView`) will:

1. **Render an unlock banner** above the AI Provider list when the gate is
   active and the user is locked. Banner shows the locked-provider names +
   `displayPrice` + Unlock and Restore buttons.
2. **Lock-icon + dimmed-row treatment** on every gated provider (60 % alpha
   on icon/title/subtitle, lock SF Symbol next to the title).
3. **Tap-pulses-banner** — tapping a locked row scrolls the user's eye to
   the banner via a brief scale-pulse animation, instead of silently doing
   nothing.
4. **Locked choice falls back (2.18.0)** — if the user's saved provider is
   locked (never bought, refunded, revoked, or picked before gating), the
   picker selects the provider actually in use, normally Apple
   Intelligence, and says why: "OpenAI is locked. Apple Intelligence is
   used until you unlock." The Mac shows it under the Provider menu, iOS
   under Current Provider. Only when nothing unlocked can stand in does the
   locked row keep its checkmark, lock icon and "Locked — purchase
   required" subtitle.
5. **Spring animation** on the banner-to-Restore-link collapse after
   purchase succeeds. The Restore link stays in the section footer so users
   on a fresh install can recover their purchase.
6. **Your accent on the banner (2.19.15)** — the banner is indigo unless
   the host passes its accent:
   `CHAIProviderPickerView(appIdentifier:).chAIAccentColor(theme.accent)`.
   Pick a color that carries white text; the Unlock button is
   `.borderedProminent`.

## Runtime gating

No request ever reaches a locked provider. As of 2.18.0 a locked saved
choice is resolved like a disabled one instead of failing every request:

1. Apple Intelligence, when it is available on the device.
2. Otherwise another enabled, unlocked provider (OpenAI, Claude, then the
   rest in ID order). Never another locked one.
3. Otherwise the locked choice itself, and `send` / `stream` /
   `sendWithVision` throw `CHAIError.providerLocked(displayName: "OpenAI")`.

`effectiveActiveProviderID`, `activeProvider`, the per-feature resolver and
all three dispatch methods share this rule, so what the picker shows is what
requests use. `activeProviderID`, per-feature overrides and API keys are
never rewritten: when the gate reports the unlock again (restore,
re-purchase, Ask to Buy approval), the next request goes to the user's
provider with no migration.

Image requests need a vision-capable stand-in. Apple Intelligence is
text-only, so `sendWithVision` uses an unlocked vision provider when one
exists and otherwise throws `.providerLocked`, which tells the user what to
do, rather than `.visionNotSupported`.

A per-feature override that is locked falls back to the global provider
(itself resolved as above) and resumes after unlock. The per-feature
overloads no longer write `activeProviderID` while a request is in flight.

Registering a gate (`CHIAPGateRegistry.shared = gate`) subscribes
`CHAIManager.shared` to it: every entitlement flip fires the manager's
`objectWillChange`, so `CHAIActiveProviderLabel`, the pickers and any view
observing the manager re-render. Gates may publish from any thread.

When `.providerLocked` does reach your UI, surface its message directly —
it includes the provider name and the actionable next step ("Open
Settings → AI Provider to unlock").

```swift
do {
    let response = try await CHAIManager.shared.send(prompt: "...")
} catch let CHAIError.providerLocked(name) {
    showAlert(title: "\(name) is locked", message: "Open Settings → AI Provider to unlock.")
}
```

## API surface (added in 2.6.0)

| Symbol | Where | Note |
|---|---|---|
| `CHIAPGate` (protocol) | `CHSharedKit/CHIAPGate.swift` | `AnyObject + ObservableObject` (Failure==Never) |
| `CHIAPGateRegistry.shared` | `CHSharedKit/CHIAPGate.swift` | `static var shared: (any CHIAPGate)?` |
| `CHAIManager.gatedProviderIDs` | `CHSharedKit/CHAIManager.swift` | `@Published var gatedProviderIDs: Set<String>` |
| `CHAIManager.gateAllExceptAppleIntelligence()` | `CHSharedKit/CHAIManager+Gating.swift` | convenience |
| `CHAIManager.isGatingActive: Bool` | same | true when banner should show |
| `CHAIManager.isLocked(providerID:) -> Bool` | same | per-provider lock check |
| `CHAIManager.checkProviderUnlocked(_:) throws` | `CHSharedKit/CHAIManager.swift` | called pre-dispatch |
| `CHAIManager.effectiveProviderID(forStoredChoice:)` | `CHSharedKit/CHAIManager.swift` | 2.18.0: disabled/locked fallback for any saved choice |
| `CHAIManager.activeProviderLockedFallbackNotice` | `CHSharedKit/CHAIManager+Gating.swift` | 2.18.0: localized "X is locked. Y is used until you unlock." or `nil` |
| `CHAIManager.lockedFallbackNotice(storedChoice:resolvedProviderID:)` | same | 2.18.0: same notice for a per-feature override |
| `CHAIFeatureProviderResolver.storedOverride(for:)` | `CHSharedKit/CHAIFeatureProviderResolver.swift` | 2.18.0: the saved override, ignoring locks |
| `CHAIError.providerLocked(displayName:)` | `CHSharedKit/CHAIProvider.swift` | new case |
| `CHAIProviderUnlockBanner` | `CHLocalLLM/CHAIProviderUnlockBanner.swift` | reusable banner view |

## Edge cases handled

- **Saved provider becomes locked** (refund, revocation, or an app update
  that enables gating): requests move to Apple Intelligence (or another
  unlocked provider) at once, the picker says so, and the saved choice and
  key stay put for a restore. With no unlocked stand-in,
  `send`/`stream`/`sendWithVision` throw `.providerLocked` and the row
  shows the lock, as before 2.18.0.
- **Launch before entitlements load**: a gate that starts locked and
  unlocks once `Transaction.currentEntitlements` is read serves the first
  requests from Apple Intelligence rather than failing them.
- **Price label not yet loaded** (StoreKit `Product.products(for:)` still
  in flight): banner button label reads "Loading…" and is disabled.
- **Purchase failure** (cancel, network error, StoreKit rejection):
  `CHAISettingsContent` catches and renders a small red error pill above
  the AI Provider section. Banner returns to its unlocked-CTA state.
- **Restore on fresh install**: Restore button on the banner AND a small
  Restore link in the section footer (post-unlock) provide the recovery
  path. Both call `CHIAPGate.restorePurchases()`.
- **No gate registered**: `CHAIManager.isGatingActive` and
  `isLocked(providerID:)` return false, banner hides, picker behaves
  exactly like 2.5.x. Setting `gatedProviderIDs` without registering a gate
  is a no-op.

## Where the unlock cannot be sold (2.19.0; list widened in 2.19.14)

`CHAIRegionPolicy` reads the account's App Store storefront
(`Storefront.current`). In a storefront from
`CHAIRegionPolicy.defaultRestrictedStorefronts` the picker hides the cloud
providers and the unlock banner and the app offers Apple Intelligence only
(`.appleIntelligenceOnly`); where Apple Intelligence is unavailable too, the
app shows no AI feature (`.off`). The default list is China mainland (App
Review Guideline 5: no OpenAI references without a mainland permit) plus
Hong Kong, Macau, Russia, Belarus and Venezuela, where neither OpenAI nor
Anthropic serves API keys, so an unlock would buy nothing.

Keep App Store Connect in step: remove the unlock product from the same
territories (`helm-asc inAppPurchase <id> availability update --territory …`)
so nobody can buy it there before the app update lands. Apps call
`CHAIRegionPolicy.shared.refresh()` at launch and when they become active.
Debug builds can rehearse the layouts with the launch arguments
`-ch.ai.storefrontOverride HKG` and `-ch.ai.appleIntelligenceOverride NO`.

## What CHSharedKit does NOT do

- Sell or verify purchases. Every transaction call goes through your
  `CHIAPGate` conformance; the kit's only StoreKit use is reading
  `Storefront.current` for the region policy. This keeps the kit
  product-agnostic (your ASC product IDs, your sandbox vs production
  config, your error reporting) while standardizing the picker UX.
- Persist unlock state. Your IAPManager owns transaction state via
  `Transaction.currentEntitlements` (recommended — Apple manages the
  source of truth). The kit reads `hasUnlockedProviders` on demand.
- Multi-tier unlocks. v1 supports a single binary unlock (locked /
  unlocked). Tiered IAPs (e.g. "Plus" vs "Pro") are out of scope.
