import Foundation

// MARK: - CHAIFeatureProviderResolver (2.10.0)
//
// Resolves "which provider should handle this featureID?" by reading
// the per-feature override from UserDefaults, falling back to the
// global active provider when no override is set or the override
// points at an unregistered provider.
//
// Storage keys (UserDefaults.standard):
//   * `ch_ai_feature_provider_<featureID>`  → providerID String
//   * `ch_ai_feature_model_<featureID>_<providerID>`  → modelID String
//   * `ch_ai_feature_enabled_<featureID>`   → Bool (default true)
//
// Apps reach this via the manager-level overloads added in 2.10.0:
//   * `CHAIManager.shared.send(prompt:featureID:)`
//   * `CHAIManager.shared.stream(prompt:featureID:)`
//   * `CHAIManager.shared.sendWithVision(prompt:imageData:featureID:)`
//
// Direct callers (e.g. a custom dispatcher in an app) can call
// `CHAIFeatureProviderResolver.provider(for:)` to get the resolved
// provider instance and then issue the request themselves.

@MainActor
public enum CHAIFeatureProviderResolver {

    // MARK: - Public API

    /// Returns the provider ID that should handle `featureID`. When
    /// the override is empty, missing, or points at an unregistered
    /// provider, returns the manager's effective provider for this device.
    ///
    /// 2.18.0: a locked override (gating active, unlock not owned) also
    /// falls back to the effective global provider when that one is
    /// usable and unlocked (a locked global choice has itself already
    /// resolved to Apple Intelligence when available); otherwise to the
    /// manager's own fallback for the override. The stored override is
    /// kept, so it resumes after a restore. With no unlocked provider at all
    /// the override is returned and dispatch fails with
    /// ``CHAIError/providerLocked(displayName:)``.
    public static func providerID(for featureID: String) -> String {
        let manager = CHAIManager.shared
        let global = manager.effectiveActiveProviderID ?? manager.activeProviderID
        guard let override = storedOverride(for: featureID),
              manager.provider(id: override) != nil else {
            return global
        }
        guard manager.isLocked(providerID: override) else { return override }
        if manager.provider(id: global) != nil, !manager.isLocked(providerID: global) {
            return global
        }
        return manager.effectiveProviderID(forStoredChoice: override) ?? override
    }

    /// The raw per-feature override the user saved, or `nil` when the
    /// feature follows the global provider. Unlike ``providerID(for:)`` this
    /// ignores availability and locks, so settings can name the user's pick.
    public static func storedOverride(for featureID: String) -> String? {
        let value = UserDefaults.standard.string(forKey: providerOverrideKey(featureID: featureID))
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Returns the model override for `featureID` against its current
    /// resolved provider. `nil` means "use the provider's globally
    /// selected model" (each provider stores its own model selection
    /// in UserDefaults; callers that just need to issue a request
    /// don't usually need this).
    public static func modelID(for featureID: String) -> String? {
        let resolvedProvider = providerID(for: featureID)
        let key = modelOverrideKey(featureID: featureID, providerID: resolvedProvider)
        let value = UserDefaults.standard.string(forKey: key)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Returns the resolved provider instance. Falls back to
    /// `CHAIManager.shared.activeProvider` when nothing is registered
    /// for the override ID. Returns `nil` only when no provider is
    /// active at all (rare — usually means the app hasn't registered
    /// any providers yet).
    public static func provider(for featureID: String) -> (any CHAIProvider)? {
        let id = providerID(for: featureID)
        return CHAIManager.shared.provider(id: id) ?? CHAIManager.shared.activeProvider
    }

    /// Whether the feature is enabled. Defaults to `true` so newly
    /// registered features are on out of the box; apps can flip the
    /// default by writing `false` to the key explicitly.
    public static func isEnabled(featureID: String) -> Bool {
        let key = enabledKey(featureID: featureID)
        // `register(defaults:)` to ensure unset reads as true.
        UserDefaults.standard.register(defaults: [key: true])
        return UserDefaults.standard.bool(forKey: key)
    }

    // MARK: - Setters (for the picker UI)

    /// Set the provider override. Pass `nil` or empty to clear and
    /// fall back to the global active provider.
    public static func setProviderOverride(_ providerID: String?, for featureID: String) {
        let key = providerOverrideKey(featureID: featureID)
        if let providerID, !providerID.isEmpty {
            UserDefaults.standard.set(providerID, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Set the model override for the given feature + provider. Pass
    /// `nil` or empty to clear.
    public static func setModelOverride(_ modelID: String?, for featureID: String, providerID: String) {
        let key = modelOverrideKey(featureID: featureID, providerID: providerID)
        if let modelID, !modelID.isEmpty {
            UserDefaults.standard.set(modelID, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Toggle the feature on/off.
    public static func setEnabled(_ enabled: Bool, for featureID: String) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(featureID: featureID))
    }

    // MARK: - Capability filtering helpers (used by the picker)

    /// Provider IDs (registered) whose `capabilities` is a superset of
    /// `feature.requiredCapabilities`. Excludes On-Device LLM and
    /// Apple Intelligence when `feature.isCloudOnly == true`.
    ///
    /// Note: `"on-device-llm"` is referenced as a string literal here
    /// rather than via `CHLocalLLMProvider.providerID` because that
    /// type lives in the `CHLocalLLM` module and CHSharedKit doesn't
    /// import upward. The string is the canonical id and is stable
    /// — see `CHLocalLLMProvider.swift`.
    public static func eligibleProviderIDs(for feature: CHAIFeature) -> [String] {
        let manager = CHAIManager.shared
        return manager.allProviders
            .compactMap { entry -> String? in
                guard let provider = manager.provider(id: entry.id) else { return nil }
                if feature.isCloudOnly,
                   provider.id == CHAppleIntelligenceProvider.providerID
                    || provider.id == "on-device-llm" {
                    return nil
                }
                guard feature.requiredCapabilities.isSubset(of: provider.capabilities) else {
                    return nil
                }
                return provider.id
            }
    }

    // MARK: - Storage keys

    public static func providerOverrideKey(featureID: String) -> String {
        "ch_ai_feature_provider_\(featureID)"
    }

    public static func modelOverrideKey(featureID: String, providerID: String) -> String {
        "ch_ai_feature_model_\(featureID)_\(providerID)"
    }

    public static func enabledKey(featureID: String) -> String {
        "ch_ai_feature_enabled_\(featureID)"
    }
}

// MARK: - CHAIManager dispatch overloads
//
// Per-feature overloads route the request through the resolver
// before falling into the same code path as the global versions.
// Apps migrate `send(prompt:)` → `send(prompt:featureID:)` for any
// AI surface that's been registered as a `CHAIFeature`.

extension CHAIManager {

    // 2.18.0: the overloads dispatch to the resolved provider directly.
    // Before, they temporarily wrote `activeProviderID` (persisted, and
    // synced by some hosts) across the request's `await`; overlapping
    // requests could restore each other's temporary value and leave a
    // fallback provider saved as the user's choice.

    /// 2.10.0: send a text request through the per-feature provider
    /// resolution. Equivalent to `send(prompt:systemPrompt:)` when no
    /// override is set for `featureID`.
    public func send(
        prompt: String,
        systemPrompt: String? = nil,
        featureID: String
    ) async throws -> String {
        guard let provider = CHAIFeatureProviderResolver.provider(for: featureID) else {
            throw CHAIError.noProvider
        }
        return try await send(prompt: prompt, systemPrompt: systemPrompt, to: provider)
    }

    /// 2.10.0: stream variant of the per-feature dispatch.
    public func stream(
        prompt: String,
        systemPrompt: String? = nil,
        featureID: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let provider = CHAIFeatureProviderResolver.provider(for: featureID) else {
            throw CHAIError.noProvider
        }
        return try await stream(prompt: prompt, systemPrompt: systemPrompt, to: provider)
    }

    /// 2.10.0: vision variant of the per-feature dispatch. The
    /// resolver's capability filter prevents apps from registering
    /// a vision feature against a text-only provider, but at runtime
    /// we still respect the provider's `supportsVision` to avoid a
    /// silently-broken request.
    public func sendWithVision(
        prompt: String,
        imageData: Data,
        featureID: String
    ) async throws -> String {
        guard let provider = CHAIFeatureProviderResolver.provider(for: featureID) else {
            throw CHAIError.noProvider
        }
        let override = CHAIFeatureProviderResolver.storedOverride(for: featureID)
        let storedChoice = override.flatMap { self.provider(id: $0) == nil ? nil : $0 } ?? activeProviderID
        let imageProvider = try visionProvider(for: provider, storedChoice: storedChoice)
        return try await sendWithVision(prompt: prompt, imageData: imageData, to: imageProvider)
    }
}
