import Foundation

// 2.6.0 — IAP gating helpers on CHAIManager.
//
// The stored `gatedProviderIDs` lives on `CHAIManager` itself (Swift extensions
// can't add stored properties); this file is the home for non-state helpers
// that read/write that set.

public extension CHAIManager {

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
    /// Apple Intelligence is intentionally never gated — it's free,
    /// on-device, and ships as the default for users who haven't paid. If a
    /// future free-default provider lands, add it to the always-free
    /// allowlist here.
    func gateAllExceptAppleIntelligence() {
        gatedProviderIDs = [
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
    /// AND at least one provider is gated. Drives the picker's banner
    /// visibility — when this is false, the banner is hidden and gated rows
    /// render normally.
    var isGatingActive: Bool {
        guard let gate = CHIAPGateRegistry.shared else { return false }
        guard !gatedProviderIDs.isEmpty else { return false }
        return !gate.hasUnlockedProviders
    }

    /// True when this specific provider should render with locked chrome
    /// (lock icon, dimmed alpha) in the picker. Returns false for free
    /// providers, for unlocked users, and when no gate is registered.
    func isLocked(providerID: String) -> Bool {
        guard isGatingActive else { return false }
        return gatedProviderIDs.contains(providerID)
    }
}
