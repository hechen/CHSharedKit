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
                        self.hasUnlockedProviders = true
                    }
                }
            }
        }
    }
}
```

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
4. **Active-locked treatment** — if the active provider is locked (e.g. the
   user picked OpenAI before opting into gating, then the app updated), the
   row shows a checkmark + lock icon + "Locked — purchase required"
   subtitle so the path forward is obvious.
5. **Spring animation** on the banner-to-Restore-link collapse after
   purchase succeeds. The Restore link stays in the section footer so users
   on a fresh install can recover their purchase.

## Runtime gating

`CHAIManager.send` / `stream` / `sendWithVision` check
`checkProviderUnlocked(provider)` before dispatch and throw
`CHAIError.providerLocked(displayName: "OpenAI")` when the active provider
is gated and the user is locked. Surface that error message directly in
your UI — it includes the provider name and the actionable next step
("Open Settings → AI Provider to unlock").

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
| `CHAIError.providerLocked(displayName:)` | `CHSharedKit/CHAIProvider.swift` | new case |
| `CHAIProviderUnlockBanner` | `CHLocalLLM/CHAIProviderUnlockBanner.swift` | reusable banner view |

## Edge cases handled

- **Active provider becomes locked mid-session** (app upgrades to enable
  gating with a previously-active provider in the gated set): UI surfaces
  the lock state on the row; `send`/`stream`/`sendWithVision` throw
  `.providerLocked` so the consumer app handles it gracefully.
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

## What CHSharedKit does NOT do

- Talk to StoreKit. The kit never imports `StoreKit` — every transaction
  call goes through your `CHIAPGate` conformance. This keeps the kit
  product-agnostic (your ASC product IDs, your sandbox vs production
  config, your error reporting) while standardizing the picker UX.
- Persist unlock state. Your IAPManager owns transaction state via
  `Transaction.currentEntitlements` (recommended — Apple manages the
  source of truth). The kit reads `hasUnlockedProviders` on demand.
- Multi-tier unlocks. v1 supports a single binary unlock (locked /
  unlocked). Tiered IAPs (e.g. "Plus" vs "Pro") are out of scope.
