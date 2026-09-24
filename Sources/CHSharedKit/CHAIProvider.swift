import Foundation
import Security

// MARK: - AI Provider Protocol

/// Generic AI provider protocol for text and vision requests.
/// Implement this to add OpenAI, Claude, Gemini, Ollama, or any custom endpoint.
public protocol CHAIProvider: Sendable {
    /// Unique identifier for this provider
    var id: String { get }

    /// Display name for UI
    var displayName: String { get }

    /// Whether this provider supports vision/image inputs
    var supportsVision: Bool { get }

    /// 2.10.0: capabilities the provider supports. Drives the
    /// per-feature picker filter — features registered with
    /// `requiredCapabilities` only see providers whose `capabilities`
    /// is a superset. Default implementation derives `[.textInput]`
    /// + adds `.visionInput` when `supportsVision` is true so existing
    /// concrete providers without an explicit override still classify
    /// correctly. Override on each concrete type for accuracy
    /// (function-calling, streaming).
    var capabilities: Set<CHAICapability> { get }
    
    /// Send a text message and get a response
    func sendMessage(prompt: String, systemPrompt: String?) async throws -> String
    
    /// Send a message with an image (for vision-capable providers)
    func sendVisionMessage(prompt: String, imageData: Data) async throws -> String

    /// Validate that the API key / endpoint is working
    func validate() async throws -> Bool

    /// Stream a text response as it is produced. Yields partial text deltas
    /// through an `AsyncThrowingStream`. Providers that support server-sent
    /// events (OpenAI, Anthropic, Apple Intelligence, local llama.cpp) should
    /// override this to emit tokens as they arrive; others inherit a default
    /// that yields the full `sendMessage` response as one chunk, so consumers
    /// can always call `.stream(...)` regardless of the active provider.
    func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error>
}

// Default implementation for providers that don't support vision
public extension CHAIProvider {
    func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        throw CHAIError.visionNotSupported
    }

    /// Default capability derivation — pure-text by default, plus
    /// vision when `supportsVision` is true. Concrete providers
    /// override for finer granularity (function calling, streaming).
    var capabilities: Set<CHAICapability> {
        var caps: Set<CHAICapability> = [.textInput]
        if supportsVision { caps.insert(.visionInput) }
        return caps
    }

    /// Default streaming fallback: call `sendMessage` and yield the full
    /// response as a single chunk. Concrete providers override with real
    /// token-by-token streaming where the underlying API supports it.
    func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await sendMessage(prompt: prompt, systemPrompt: systemPrompt)
                    try Task.checkCancellation()
                    if !result.isEmpty { continuation.yield(result) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience matching the spec: stream with no system prompt.
    func stream(_ prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        try await stream(prompt: prompt, systemPrompt: nil)
    }
}

// MARK: - AI Errors

public enum CHAIError: LocalizedError {
    case noProvider
    case noAPIKey
    case invalidResponse
    case networkError(Error)
    case rateLimited
    case invalidKey
    case visionNotSupported
    case appleIntelligenceUnavailable
    /// On-device model could not be loaded (file missing, corrupted, OOM, etc.).
    /// The associated string is an actionable user-facing message.
    case modelLoadFailed(String)
    /// The current platform (e.g. Mac Catalyst) cannot run on-device inference.
    case unsupportedPlatform
    /// 2.6.0: the active provider is in `CHAIManager.gatedProviderIDs` and
    /// `CHIAPGateRegistry.shared.hasUnlockedProviders == false`. Display name
    /// (e.g. "OpenAI") is the associated value so apps can compose the
    /// "<provider> requires a one-time purchase" message.
    case providerLocked(displayName: String)

    public var errorDescription: String? {
        switch self {
        case .noProvider: return String(localized: "No AI provider configured", bundle: .module)
        case .noAPIKey: return String(localized: "API key not set. Go to Settings → AI Provider to add your key.", bundle: .module)
        case .invalidResponse: return String(localized: "Could not parse AI response", bundle: .module)
        case .networkError(let e): return String(localized: "Network error: \(e.localizedDescription)", bundle: .module)
        case .rateLimited: return String(localized: "Rate limited. Please try again in a moment.", bundle: .module)
        case .invalidKey: return String(localized: "Invalid API key. Please check your key in Settings.", bundle: .module)
        case .visionNotSupported: return String(localized: "This provider does not support vision/image inputs", bundle: .module)
        case .appleIntelligenceUnavailable: return CHAppleIntelligenceProvider.unavailableErrorDescription
        case .modelLoadFailed(let msg): return msg
        case .unsupportedPlatform: return String(localized: "On-device AI is not supported on this platform.", bundle: .module)
        case .providerLocked(let name): return String(localized: "\(name) requires a one-time purchase. Open Settings → AI Provider to unlock.", bundle: .module)
        }
    }
}

// MARK: - Keychain Helper
//
// 2.9.0: this is now a thin facade over `CHSyncedKeychain`. Direct
// callers continue to work unchanged but their reads/writes now
// follow the user across devices via `kSecAttrSynchronizable: true`.
// Marked deprecated to encourage migration to `CHSyncedKeychain`
// directly — the indirection here is kept only for backwards
// compatibility with any straggler call sites.

/// Keychain helper for securely storing API keys.
///
/// - Important: New code should call `CHSyncedKeychain` directly. This
///   helper is preserved to keep pre-2.9.0 callsites compiling.
@available(*, deprecated, message: "Use CHSyncedKeychain directly. CHAIKeychain is preserved for back-compat and routes through CHSyncedKeychain so existing call sites get the sync flag automatically.")
public enum CHAIKeychain {
    private static let account = "api_key"

    public static func save(key: String, service: String) {
        CHSyncedKeychain.setString(key, forKey: account, service: service)
    }

    public static func load(service: String) -> String? {
        CHSyncedKeychain.string(forKey: account, service: service)
    }

    public static func delete(service: String) {
        CHSyncedKeychain.remove(forKey: account, service: service)
    }
}
