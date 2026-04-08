import Foundation
import Security

// MARK: - AI Provider Protocol

/// Generic AI provider protocol for text and vision requests.
/// Implement this to add OpenAI, Claude, Gemini, Ollama, or any custom endpoint.
public protocol ClawdAIProvider: Sendable {
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
}

// Default implementation for providers that don't support vision
public extension ClawdAIProvider {
    func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        throw ClawdAIError.visionNotSupported
    }
}

// MARK: - AI Errors

public enum ClawdAIError: LocalizedError {
    case noProvider
    case noAPIKey
    case invalidResponse
    case networkError(Error)
    case rateLimited
    case invalidKey
    case visionNotSupported
    case appleIntelligenceUnavailable
    
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
        }
    }
}

// MARK: - Keychain Helper

/// Keychain helper for securely storing API keys
public enum ClawdAIKeychain {
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
