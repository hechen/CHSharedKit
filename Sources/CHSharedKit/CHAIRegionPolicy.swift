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

    /// Pretend Apple Intelligence is (un)available, to check the `.off`
    /// layout on a device that has it and the `.appleIntelligenceOnly`
    /// layout on one that does not. Persisted; nil uses the real state.
    /// A UI test passes `-ch.ai.appleIntelligenceOverride NO`.
    @Published public var appleIntelligenceOverride: Bool? {
        didSet {
            if let appleIntelligenceOverride {
                UserDefaults.standard.set(appleIntelligenceOverride, forKey: Self.appleIntelligenceOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.appleIntelligenceOverrideKey)
            }
            apply()
        }
    }
    public static let appleIntelligenceOverrideKey = "ch.ai.appleIntelligenceOverride"

    /// Whether Apple Intelligence is available on this device. Read from
    /// `CHAIManager` unless a test injects a value.
    public var appleIntelligenceAvailability: () -> Bool = { CHAIManager.shared.isAppleIntelligenceAvailable }

    /// Apple Intelligence availability as the policy sees it: the override
    /// when set, otherwise the real state.
    public var isAppleIntelligenceAvailable: Bool {
        appleIntelligenceOverride ?? appleIntelligenceAvailability()
    }

    private init() {
        // Read through the projected storage so the observers do not run:
        // an override passed as a launch argument (`-ch.ai.storefrontOverride
        // CHN`, in the argument domain) must not be written back into the
        // persistent domain, where it would outlive the launch.
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.overrideDefaultsKey)
        _storefrontOverride = Published(initialValue: stored?.isEmpty == false ? stored : nil)
        let appleIntelligence: Bool? = defaults.object(forKey: Self.appleIntelligenceOverrideKey) != nil
            ? defaults.bool(forKey: Self.appleIntelligenceOverrideKey)
            : nil
        _appleIntelligenceOverride = Published(initialValue: appleIntelligence)
        let mode = mode
        Self.currentModeLock.withLock { Self._currentMode = mode }
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
            appleIntelligenceAvailable: isAppleIntelligenceAvailable
        )
    }

    /// False only in `.off`: then no AI entry point, setting, purchase or
    /// copy should be shown.
    public var showsAIFeatures: Bool { mode != .off }

    /// The mode as of the last `apply()`, readable off the main actor for
    /// feature gates that run inside background work. `.full` until the
    /// policy is first created.
    nonisolated public static var currentMode: Mode {
        currentModeLock.withLock { _currentMode }
    }
    nonisolated public static var currentlyShowsAIFeatures: Bool { currentMode != .off }
    nonisolated private static let currentModeLock = NSLock()
    nonisolated(unsafe) private static var _currentMode: Mode = .full

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
        let mode = mode
        Self.currentModeLock.withLock { Self._currentMode = mode }
        let manager = CHAIManager.shared
        manager.availableProvidersFilter = providerFilter
        if !allowsCloudProviders,
           let active = manager.activeProvider,
           active.category.contains(.cloudProviders) {
            manager.activeProviderID = isAppleIntelligenceAvailable
                ? CHAppleIntelligenceProvider.providerID
                : ""
        }
    }
}
