import Foundation
import SwiftUI

// MARK: - CHAIFeature (2.10.0)
//
// ## Why this exists
//
// Pre-2.10.0 every consuming app routed every AI call through
// `CHAIManager.shared.activeProvider`. That meant a single global
// "active provider" decision applied to every AI surface in the app.
// Closet's AI Features page had a footer that said "Per-feature
// provider override coming soon" for builds — Chen flagged that.
//
// 2.10.0 ships the per-feature override. Apps register a list of
// `CHAIFeature` descriptors at launch (one per AI-powered surface),
// and the kit owns:
//   * Per-feature provider override (UserDefaults).
//   * Per-feature model override (UserDefaults).
//   * Per-feature enabled toggle (UserDefaults).
//   * Resolution: `CHAIFeatureProviderResolver` returns the right
//     provider for any featureID, falling back to the global active
//     provider when no override is set.
//   * Capability filtering: the picker for a vision-only feature
//     hides Apple Intelligence (text-only). The picker for a feature
//     marked `isCloudOnly` hides On-Device LLM.
//   * Drop-in settings UI (`CHAIFeaturesSettingsContent`) that any
//     app can embed in its Settings → AI page.
//
// Apps continue to call `CHAIManager.shared.send(prompt:)` for global
// requests; the new overloads `send(prompt:featureID:)`,
// `stream(prompt:featureID:)`, and `sendWithVision(prompt:imageData:featureID:)`
// route through the resolver.

/// Capabilities a provider supports. Used to filter the per-feature
/// provider picker so vision-only features don't list text-only
/// providers, function-calling features don't list providers without
/// JSON-schema support, etc.
public enum CHAICapability: String, Sendable, Hashable, CaseIterable {
    /// Plain text input + text output. Every provider has this.
    case textInput
    /// Image input. OpenAI, Claude, Custom Endpoint (assumed).
    /// Apple Intelligence + On-Device LLM (most models) do NOT.
    case visionInput
    /// Tool/function calling. OpenAI + Claude have this; others don't.
    case functionCalling
    /// Server-sent events token streaming.
    case streaming
}

/// Descriptor for one AI-powered surface inside an app. Apps register
/// a list of these at launch via `CHAIFeatureRegistry.register(_:)`,
/// and the kit drives the per-feature override UI + resolution off
/// the registry.
public struct CHAIFeature: Identifiable, Sendable, Hashable {
    /// App-unique stable identifier. Convention: `<appname>.<feature>`
    /// e.g. `closet.ai_stylist`, `eatwisely.food_parser`,
    /// `liftcoach.workout_namer`. The string is used as a UserDefaults
    /// key suffix, so it must be ASCII / shell-safe.
    public let id: String

    /// User-facing label for the feature row.
    public let displayName: String

    /// SF Symbol name for the row's icon badge.
    public let symbol: String

    /// Tint color applied to the icon badge.
    public let tint: Color

    /// What the feature needs from a provider. The picker filters
    /// providers by `requiredCapabilities.isSubset(of: provider.capabilities)`.
    public let requiredCapabilities: Set<CHAICapability>

    /// When `true`, On-Device LLM and Apple Intelligence are hidden
    /// from the picker. Use for features that need >7B-class models
    /// (complex reasoning, structured generation against large schemas)
    /// or that need a real-time API.
    public let isCloudOnly: Bool

    /// Optional one-line "what this controls" copy shown under the row.
    public let footnote: String?

    public init(
        id: String,
        displayName: String,
        symbol: String,
        tint: Color = .accentColor,
        requiredCapabilities: Set<CHAICapability> = [.textInput],
        isCloudOnly: Bool = false,
        footnote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.tint = tint
        self.requiredCapabilities = requiredCapabilities
        self.isCloudOnly = isCloudOnly
        self.footnote = footnote
    }

    // Hashable / Equatable purely on `id` so two registrations of the
    // same feature ID dedupe correctly.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    public static func == (lhs: CHAIFeature, rhs: CHAIFeature) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - CHAIFeatureRegistry

/// Process-wide registry of features per app. Apps register at launch
/// and the kit's settings UI + resolver query through this.
@MainActor
public enum CHAIFeatureRegistry {

    nonisolated(unsafe) private static var registry: [String: [CHAIFeature]] = [:]

    /// Register a list of features for an app. Calling this more than
    /// once for the same app replaces the previous list (so app code
    /// can rebuild registrations on hot reload). Order is preserved
    /// for the settings UI.
    public static func register(_ features: [CHAIFeature], appName: String) {
        registry[appName] = features
    }

    /// Returns features registered for `appName`, in registration order.
    /// Empty array when no registration has happened (apps that haven't
    /// migrated to the per-feature surface yet).
    public static func features(for appName: String) -> [CHAIFeature] {
        registry[appName] ?? []
    }

    /// Lookup by feature ID across every registered app. Used by the
    /// resolver, which doesn't know which app owns a given ID. Linear
    /// scan; the registry is small (a dozen features per app, fewer
    /// than ten apps).
    public static func feature(id: String) -> CHAIFeature? {
        for (_, features) in registry {
            if let match = features.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Test seam — clears all registrations. Production code should
    /// never call this; tests use it to isolate cases.
    public static func _resetForTesting() {
        registry.removeAll()
    }
}
