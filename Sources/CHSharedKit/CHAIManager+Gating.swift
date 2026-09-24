import Foundation

// 2.6.0 — IAP gating helpers on CHAIManager.
//
// The stored `gatedProviderIDs` lives on `CHAIManager` itself (Swift extensions
// can't add stored properties); this file is the home for non-state helpers
// that read/write that set.

public extension CHAIManager {

    /// Provider IDs that the kit treats as free regardless of what consumer
    /// apps put in ``gatedProviderIDs``. Apple Intelligence is the default
    /// member: it's a free, on-device, OS-provided service — gating it
    /// makes no sense, and a consumer-app misconfiguration that
    /// accidentally adds its id to `gatedProviderIDs` (or a custom set
    /// builder that lumps every provider together) would be visibly wrong
    /// in the picker. The kit shadows the request to keep behavior sane.
    ///
    /// 2.6.1: added as a defensive backstop after Chen's screenshot of
    /// LiftCoach Build 64 showed Apple Intelligence with both a "Free"
    /// pill AND a lock icon — a contradictory state where the consumer
    /// app's gating config had Apple Intelligence's id in the gated set.
    /// The kit now refuses to lock these regardless of misconfiguration.
    static var alwaysFreeProviderIDs: Set<String> = [
        CHAppleIntelligenceProvider.providerID
    ]

    /// Convenience: gate every cloud provider + on-device-LLM, leaving Apple
    /// Intelligence as the only free option. Equivalent to:
    ///
    /// ```swift
    /// gatedProviderIDs = [
    ///     CHOpenAIProvider.providerID,
    ///     CHClaudeProvider.providerID,
    ///     CHCustomEndpointProvider.providerID,
    ///     CHLocalLLMProvider.providerID,
    /// ]
    /// ```
    ///
    /// Apple Intelligence is never added even if consumers manually mutate
    /// `gatedProviderIDs` afterwards — see ``alwaysFreeProviderIDs``.
    /// Sentinel used by the all-provider policy, including providers added after launch.
    static let allProvidersGateID = "*"

    var effectiveGatedProviderIDs: Set<String> {
        let explicit = gatedProviderIDs.subtracting([Self.allProvidersGateID])
        return (gatedProviderIDs.contains(Self.allProvidersGateID)
            ? explicit.union(allProviders.map(\.id)) : explicit)
            .subtracting(Self.alwaysFreeProviderIDs)
    }

    func gateAllExceptAppleIntelligence() {
        gatedProviderIDs = [
            Self.allProvidersGateID,
            CHOpenAIProvider.providerID,
            CHClaudeProvider.providerID,
            CHCustomEndpointProvider.providerID,
            // CHLocalLLMProvider lives in the CHLocalLLM module so CHSharedKit
            // can't reference it directly. The on-device provider's id is a
            // stable string ("on-device-llm" — see Sources/CHLocalLLM/CHLocalLLMProvider.swift).
            "on-device-llm",
        ]
    }

    /// True when the registered gate is active AND the user hasn't unlocked
    /// AND at least one **non-always-free** provider is gated. Drives the
    /// picker's banner visibility.
    var isGatingActive: Bool {
        guard let gate = CHIAPGateRegistry.shared else { return false }
        let effective = gatedProviderIDs.subtracting(Self.alwaysFreeProviderIDs)
        guard !effective.isEmpty else { return false }
        return !gate.hasUnlockedProviders
    }

    /// True when this specific provider should render with locked chrome
    /// (lock icon, dimmed alpha) in the picker. Returns false for
    /// always-free providers (Apple Intelligence), unlocked users, and
    /// when no gate is registered.
    func isLocked(providerID: String) -> Bool {
        if Self.alwaysFreeProviderIDs.contains(providerID) { return false }
        guard isGatingActive else { return false }
        return gatedProviderIDs.contains(Self.allProvidersGateID) || gatedProviderIDs.contains(providerID)
    }

    /// 2.6.1: human-readable display name for a provider id, used by the
    /// banner subtitle. Falls back to a static map of the kit's well-known
    /// providers when the id isn't currently registered (e.g. the on-device
    /// provider before any model is installed). This is what makes the
    /// banner correctly include String(localized: "On-Device AI", bundle: .module) in its subtitle even when no
    /// model has been downloaded yet.
    func displayName(forProviderID id: String) -> String {
        if let registered = allProviders.first(where: { $0.id == id }) {
            return registered.name
        }
        // Fallback for kit-known IDs whose providers aren't currently
        // registered (e.g. on-device-llm before a model is installed).
        switch id {
        case "on-device-llm": return String(localized: "On-Device AI", bundle: .module)
        case CHOpenAIProvider.providerID: return "OpenAI"
        case CHClaudeProvider.providerID: return "Claude (Anthropic)"
        case CHCustomEndpointProvider.providerID: return String(localized: "Custom Endpoint", bundle: .module)
        case CHAppleIntelligenceProvider.providerID: return "Apple Intelligence"
        default: return id
        }
    }
}
