import Combine
import Foundation
import StoreKit

// MARK: - CHAIRegionPolicy
//
// 2.19.0: where AI can be offered. Third-party cloud AI (OpenAI, Claude,
// custom endpoints) cannot be used from some App Store storefronts, and
// Apple Intelligence is not available everywhere either. The policy turns
// the storefront and the device's Apple Intelligence availability into one
// of three modes an app can build its UI around:
//
// - `.full`: everything the app offers.
// - `.appleIntelligenceOnly`: a restricted storefront where Apple
//   Intelligence works. Cloud providers and their unlock purchase are
//   hidden; on-device features stay.
// - `.off`: a restricted storefront without Apple Intelligence. The app
//   shows no AI feature at all.
//
// The storefront comes from StoreKit (`Storefront.current`), so a Chinese
// speaker with a Canadian Apple ID keeps AI and a mainland account does
// not, whatever the device language. When Apple Intelligence later becomes
// available on a device in a restricted storefront, the mode moves to
// `.appleIntelligenceOnly` by itself; no app update is needed.

/// Where AI features can be offered on this device, for the App Store
/// storefront the user's account belongs to.
@MainActor
public final class CHAIRegionPolicy: ObservableObject {
    public static let shared = CHAIRegionPolicy()

    public enum Mode: String, Sendable, CaseIterable {
        case full
        case appleIntelligenceOnly
        case off
    }

    /// Storefronts (ISO 3166-1 alpha-3, as StoreKit reports them) where
    /// third-party cloud AI cannot be offered.
    public var restrictedStorefronts: Set<String> = ["CHN"]

    /// The filter the app would use without any regional restriction.
    /// Apps that are on-device-only set this to `.onDeviceOnly` before the
    /// first `refresh()`; the policy only ever removes cloud providers.
    public var baseProviderFilter: CHAIProviderFilter = .all

    /// The storefront StoreKit reported, alpha-3 uppercased. Nil until the
    /// first `refresh()` or when StoreKit has no storefront (no account).
    @Published public private(set) var storefrontCode: String?

    /// A storefront to pretend to be, for testing regional behavior from a
    /// developer menu. Persisted; nil uses the real storefront.
    @Published public var storefrontOverride: String? {
        didSet {
            UserDefaults.standard.set(storefrontOverride, forKey: Self.overrideDefaultsKey)
            apply()
        }
    }
    public static let overrideDefaultsKey = "ch.ai.storefrontOverride"

    /// Whether Apple Intelligence is available on this device. Read from
    /// `CHAIManager` unless a test injects a value.
    public var appleIntelligenceAvailability: () -> Bool = { CHAIManager.shared.isAppleIntelligenceAvailable }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.overrideDefaultsKey)
        storefrontOverride = stored?.isEmpty == false ? stored : nil
    }

    // MARK: Reading the policy

    /// The storefront the policy is judged against: the override when set,
    /// otherwise the real one.
    public var effectiveStorefront: String? {
        (storefrontOverride ?? storefrontCode)?.uppercased()
    }

    public var isRestrictedStorefront: Bool {
        Self.isRestricted(storefront: effectiveStorefront, restricted: restrictedStorefronts)
    }

    public var mode: Mode {
        Self.mode(
            storefront: effectiveStorefront,
            restricted: restrictedStorefronts,
            appleIntelligenceAvailable: appleIntelligenceAvailability()
        )
    }

    /// False only in `.off`: then no AI entry point, setting, purchase or
    /// copy should be shown.
    public var showsAIFeatures: Bool { mode != .off }

    /// True only in `.full`: cloud providers and their unlock can be shown.
    public var allowsCloudProviders: Bool { mode == .full }

    /// The provider filter for `CHAIManager` under this policy.
    public var providerFilter: CHAIProviderFilter {
        allowsCloudProviders ? baseProviderFilter : baseProviderFilter.subtracting(.cloudProviders)
    }

    // MARK: Pure rules (testable)

    nonisolated public static func isRestricted(storefront: String?, restricted: Set<String>) -> Bool {
        guard let storefront else { return false }
        return restricted.contains(storefront.uppercased())
    }

    nonisolated public static func mode(storefront: String?, restricted: Set<String>, appleIntelligenceAvailable: Bool) -> Mode {
        guard isRestricted(storefront: storefront, restricted: restricted) else { return .full }
        return appleIntelligenceAvailable ? .appleIntelligenceOnly : .off
    }

    // MARK: Refreshing

    /// Reads the storefront from StoreKit and applies the policy to
    /// `CHAIManager`. Call at launch and when the app becomes active
    /// (the account, and Apple Intelligence, can change while the app
    /// is in the background).
    public func refresh() async {
        let code = await Storefront.current?.countryCode
        storefrontCode = code?.uppercased()
        apply()
    }

    /// Applies the provider filter for the current mode to `CHAIManager`,
    /// and moves the active provider off a cloud provider it can no longer
    /// offer. Published so views re-read `mode`.
    public func apply() {
        objectWillChange.send()
        let manager = CHAIManager.shared
        manager.availableProvidersFilter = providerFilter
        if !allowsCloudProviders,
           let active = manager.activeProvider,
           active.category.contains(.cloudProviders) {
            manager.activeProviderID = manager.isAppleIntelligenceAvailable
                ? CHAppleIntelligenceProvider.providerID
                : ""
        }
    }
}
