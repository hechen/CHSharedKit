import Foundation

// MARK: - Provider filter

/// Classifies where an AI provider executes so apps can advertise — or
/// actively restrict — which providers their users see. Each `CHAIProvider`
/// declares a single category via its `category` property; this type is an
/// `OptionSet` combining those categories.
///
/// Setting `CHAIManager.shared.availableProvidersFilter = .onDeviceOnly`
/// makes only providers in `[.onDeviceLocal, .appleIntelligence]` visible
/// to `availableProviders` and the `CHAISettingsView` picker. This is the
/// primary knob an app built around the "runs entirely on your device"
/// promise should reach for — it means the settings UI will never display
/// a key-entry row for OpenAI or Claude.
///
/// Defaults to `.all` so existing integrations behave exactly as they did
/// before this type was added.
public struct CHAIProviderFilter: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// On-device local LLM (e.g., CHLocalLLM's llama.cpp-backed provider).
    public static let onDeviceLocal     = CHAIProviderFilter(rawValue: 1 << 0)

    /// Apple's on-device `FoundationModels` (Apple Intelligence, iOS 26+).
    public static let appleIntelligence = CHAIProviderFilter(rawValue: 1 << 1)

    /// Cloud-hosted providers (OpenAI, Claude, and custom
    /// OpenAI-compatible endpoints by default).
    public static let cloudProviders    = CHAIProviderFilter(rawValue: 1 << 2)

    // MARK: - Convenience sets

    /// Restrict to providers that execute entirely on-device — useful for
    /// apps whose privacy story promises "nothing leaves your device".
    public static let onDeviceOnly: CHAIProviderFilter = [.onDeviceLocal, .appleIntelligence]

    /// Expose every provider CHSharedKit knows about.
    public static let all: CHAIProviderFilter = [.onDeviceLocal, .appleIntelligence, .cloudProviders]
}

// MARK: - CHAIProvider category

public extension CHAIProvider {
    /// Which filter bucket this provider belongs to. The default resolves
    /// the well-known provider IDs CHSharedKit ships with; external apps
    /// providing a custom `CHAIProvider` implementation should override
    /// this property so their provider lands in the right bucket for any
    /// host app that has set `availableProvidersFilter`.
    var category: CHAIProviderFilter {
        switch id {
        case "apple-intelligence":      return .appleIntelligence
        case "on-device-llm":           return .onDeviceLocal
        case "openai", "claude":        return .cloudProviders
        case "custom":
            // Custom endpoints default to cloud — the overwhelmingly
            // common case. A provider pointing at a LAN-only endpoint
            // can override `category` on its concrete type.
            return .cloudProviders
        default:
            return .cloudProviders
        }
    }
}
