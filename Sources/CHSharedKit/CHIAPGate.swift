import Foundation
import Combine

// MARK: - CHIAPGate
//
// 2.6.0: portfolio-wide IAP gating for AI providers. Each consumer app supplies
// its own concrete IAPManager conforming to ``CHIAPGate``, registers it via
// ``CHIAPGateRegistry/shared``, and tells `CHAIManager` which providers are
// behind the paywall via ``CHAIManager/gatedProviderIDs``.
//
// The kit owns the gating logic + the picker UI (banner + locked-row chrome +
// post-purchase ownership card). Consumer apps own the StoreKit + product-id
// specifics.

/// Adopted by each consumer app's IAP manager. The kit reads this to decide
/// whether to lock providers in the picker and whether to fail
/// `CHAIManager.send`/`stream`/`sendWithVision` with
/// ``CHAIError/providerLocked(displayName:)``.
///
/// **Conformers must be `AnyObject + ObservableObject`** so SwiftUI can
/// observe state transitions (`hasUnlockedProviders` flips after a successful
/// purchase, `unlockPriceLabel` populates after the first
/// `Product.products(for:)` resolves). Both Combine `@ObservedObject` and the
/// new `@Observable` macro satisfy the constraint — `@Observable` synthesizes
/// `ObservableObject` conformance automatically.
///
/// **`unlockPriceLabel` is sync but the StoreKit world isn't.** Implementations
/// fetch `Product.products(for: [...])` once at app launch, cache the
/// `displayPrice` string, and publish the change through `objectWillChange`.
/// During the load window (typically <1 s) the value is `nil`; the unlock
/// banner shows a placeholder button label and disables tap until the price
/// resolves.
public protocol CHIAPGate: AnyObject, ObservableObject
    where ObjectWillChangePublisher.Failure == Never
{
    /// True when the user has purchased (or restored) the unlock IAP. Reads
    /// the cached transaction state — should not perform StoreKit queries.
    var hasUnlockedProviders: Bool { get }

    /// Localized price string from StoreKit, e.g. `"$4.99"`. `nil` until the
    /// first `Product.products(for:)` callback resolves on app launch.
    var unlockPriceLabel: String? { get }

    /// Trigger the StoreKit purchase flow. Throws on user cancel, network
    /// error, or StoreKit-side rejection. The kit calls this from the
    /// unlock-banner's primary button.
    ///
    /// On success, conformers must update `hasUnlockedProviders` to `true`
    /// and fire `objectWillChange` so the picker re-renders.
    func startPurchase() async throws

    /// Restore previous purchases (handles family-sharing and same-Apple-ID
    /// reinstalls). The kit calls this from the unlock banner and from the
    /// post-purchase ownership card. On success, conformers update
    /// `hasUnlockedProviders` and fire `objectWillChange`.
    func restorePurchases() async throws

    /// 2.16.0: the unlock product's name as the host markets it, e.g.
    /// `"AI Pro"`. Shown on the post-purchase ownership card. Optional —
    /// the default `nil` keeps the generic "AI providers unlocked" wording,
    /// so existing conformers compile and render unchanged.
    var unlockProductDisplayName: String? { get }
}

public extension CHIAPGate {
    var unlockProductDisplayName: String? { nil }
}

// MARK: - CHIAPGateRegistry

/// Singleton hook for the kit. Apps register their gate at launch:
///
/// ```swift
/// @main
/// struct YourApp: App {
///     init() {
///         CHIAPGateRegistry.shared = YourIAPManager.shared
///         CHAIManager.shared.gatedProviderIDs = [
///             CHOpenAIProvider.providerID,
///             CHClaudeProvider.providerID,
///             CHCustomEndpointProvider.providerID,
///             CHLocalLLMProvider.providerID,
///         ]
///     }
/// }
/// ```
///
/// Or use the convenience helper:
///
/// ```swift
/// CHIAPGateRegistry.shared = YourIAPManager.shared
/// CHAIManager.shared.gateAllExceptAppleIntelligence()
/// ```
///
/// Setting `shared` to `nil` disables gating entirely (the picker hides the
/// banner and treats all providers as unlocked, regardless of
/// `gatedProviderIDs`).
///
/// 2.18.0: registering a gate also subscribes `CHAIManager.shared` to it, so
/// an entitlement flip (purchase, restore, refund, revocation) re-renders
/// every view observing the manager and moves requests between the user's
/// provider and its Apple Intelligence fallback without host wiring.
public enum CHIAPGateRegistry {
    nonisolated(unsafe) public static var shared: (any CHIAPGate)? {
        didSet { gateDidChange() }
    }

    private static func gateDidChange() {
        // Hosts register from `App.init` on the main thread; keep that path
        // synchronous so the first render already observes the gate.
        if Thread.isMainThread {
            MainActor.assumeIsolated { CHAIManager.shared.observeIAPGate(shared) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CHAIManager.shared.observeIAPGate(shared) }
            }
        }
    }
}
