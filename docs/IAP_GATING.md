# Purchase gating for AI providers

The host app owns its StoreKit products, transaction verification, entitlement state, and purchase UI. CHSharedKit reads a `CHIAPGate` to control provider access and render optional purchase controls. An SDK gate does not create or submit an App Store product.

## Supply a host-owned gate

Adapt the app's purchase manager to `CHIAPGate`. The protocol requires `AnyObject` and Combine `ObservableObject`; an Observation `@Observable` annotation alone does not satisfy that conformance.

| Requirement | Host responsibility |
|---|---|
| `hasUnlockedProviders: Bool` | Cached, verified entitlement state; publish changes so observing views update. |
| `unlockPriceLabel: String?` | Localized `Product.displayPrice`, or `nil` while unavailable. |
| `unlockProductDisplayName: String?` | Optional host product name; the default is `nil`. |
| `startPurchase() async throws` | Run the host purchase flow, verify the result, finish handled transactions, and update entitlement state. |
| `restorePurchases() async throws` | Run the host restore flow and refresh verified entitlements. |

Handle cancellation, pending approval, unverified transactions, refunds, revocations, transaction updates, and foreground refresh in the purchase manager. Pending or cancelled purchases do not grant an entitlement. CHSharedKit does not persist an independent unlock flag or validate receipts.

Register the adapter during app setup on the main actor:

```swift
import CHSharedKit

@MainActor
func configureProviderGate<Gate: CHIAPGate>(_ gate: Gate) {
    CHIAPGateRegistry.shared = gate
    CHAIManager.shared.gateAllExceptAppleIntelligence()
}
```

Alternatively, set `CHAIManager.shared.gatedProviderIDs` to selected provider IDs. The all-except-Apple-Intelligence helper uses the wildcard gate so future catalog-defined providers are covered too. With no registered gate, provider gating is inactive even if IDs have been configured.

## Picker presentation

The `CHLocalLLM` product's `CHAISettingsContent` and `CHAIProviderPickerView` display locked providers and an unlock banner while gated access is unavailable. Once unlocked, the default presentation uses an ownership card with Restore Purchases. Restore outcomes distinguish newly restored access, already-confirmed access, and no purchase found.

Pass `.chAIAccentColor(theme.accent)` to use the host's accent. The unlock label chooses a contrasting foreground color.

If the product covers other app features and has its own purchase screen, pass `.chAIUnlockAction { showingPurchase = true }`. The picker then uses a Learn More row and routes locked-provider taps to that action. The host purchase screen owns ownership and Restore presentation in this configuration.

## Runtime gating

When the saved provider is locked, request resolution prefers available Apple Intelligence, then another enabled and unlocked provider. If there is no usable unlocked provider, requests fail with `CHAIError.providerLocked(displayName:)`. Image requests require a vision-capable fallback.

The saved provider, per-feature override, and API key remain intact. Restoring access allows requests to resume using the saved choice. `effectiveActiveProviderID`, `activeProvider`, and per-feature dispatch reflect the resolved choice. `activeProviderLockedFallbackNotice` provides explanatory text for custom UI.

Because an unlocked fallback may be a cloud provider, hosts that promise on-device processing must restrict the enabled provider set. A purchase gate by itself is not a privacy policy.

```swift
do {
    let response = try await CHAIManager.shared.send(prompt: "Summarize this text")
    // Present response in the host UI.
} catch let CHAIError.providerLocked(name) {
    // Explain which provider is locked and offer the host's purchase screen.
    print("Provider requires access: \(name)")
}
```

## Region policy

`CHAIRegionPolicy` reads the App Store storefront and can restrict the picker to Apple Intelligence or turn AI features off when that provider is also unavailable. Its default restricted-storefront set is defined in [CHAIRegionPolicy.swift](../Sources/CHSharedKit/CHAIRegionPolicy.swift). This is a package policy, not a guarantee of current legal or provider availability requirements.

Hosts call `CHAIRegionPolicy.shared.refresh()` at launch and on becoming active and configure their product availability consistently in App Store Connect. Review applicable provider and store requirements for the app's markets. Debug launch arguments `-ch.ai.storefrontOverride HKG` and `-ch.ai.appleIntelligenceOverride NO` can exercise the restricted presentation.

## Validation

Test the host's purchase manager and native purchase UI with its own product configuration. Verify locked and restored provider routing, pending approval, cancellation, failure, revocation, and the no-gate case. Package tests can validate routing contracts without proving that a host app's actual purchase or restore flow works.
