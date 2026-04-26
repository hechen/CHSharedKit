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

    public var errorDescription: String? {
        switch self {
        case .noProvider: return "No AI provider configured"
        case .noAPIKey: return "API key not set. Go to Settings → AI Provider to add your key."
        case .invalidResponse: return "Could not parse AI response"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .rateLimited: return "Rate limited. Please try again in a moment."
        case .invalidKey: return "Invalid API key. Please check your key in Settings."
        case .visionNotSupported: return "This provider does not support vision/image inputs"
        case .appleIntelligenceUnavailable: return "Apple Intelligence requires iOS 26 or later"
        case .modelLoadFailed(let msg): return msg
        case .unsupportedPlatform: return "On-device AI is not supported on this platform."
        }
    }
}

// MARK: - Keychain Helper

/// Keychain helper for securely storing API keys
public enum CHAIKeychain {
    public static func save(key: String, service: String) {
        let data = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api_key",
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    public static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api_key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    public static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api_key",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
