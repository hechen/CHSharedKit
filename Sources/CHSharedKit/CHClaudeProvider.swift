import Foundation

// MARK: - Claude (Anthropic) Provider

/// Anthropic Claude provider for text and vision requests
public struct CHClaudeProvider: CHAIProvider, Sendable {
    public static let providerID = "claude"
    private static let keychainService = "app.chen.clawdappkit.claude"
    
    public var id: String { Self.providerID }
    public var displayName: String { "Claude (Anthropic)" }
    public var supportsVision: Bool { true }
    
    public init() {}
    
    public static var apiKey: String? {
        get { CHAIKeychain.load(service: keychainService) }
        set {
            if let key = newValue {
                CHAIKeychain.save(key: key, service: keychainService)
            } else {
                CHAIKeychain.delete(service: keychainService)
            }
        }
    }
    
    public static var model: String {
        get { UserDefaults.standard.string(forKey: "clawd_claude_model") ?? "claude-sonnet-4-20250514" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_claude_model") }
    }
    
    public static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "clawd_claude_base_url") ?? "https://api.anthropic.com/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_claude_base_url") }
    }
    
    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }
        
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "messages": [["role": "user", "content": prompt]]
        ]
        
        if let system = systemPrompt, !system.isEmpty {
            body["system"] = system
        }
        
        let data = try await makeRequest(apiKey: apiKey, body: body)
        return try parseTextResponse(data)
    }
    
    public func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }
        
        let base64 = imageData.base64EncodedString()
        
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64
                            ]
                        ],
                        ["type": "text", "text": prompt]
                    ]
                ]
            ]
        ]
        
        let data = try await makeRequest(apiKey: apiKey, body: body)
        return try parseTextResponse(data)
    }
    
    public func validate() async throws -> Bool {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Say OK"]]
        ]

        let _ = try await makeRequest(apiKey: apiKey, body: body)
        return true
    }

    // MARK: - Streaming

    /// Stream deltas via Anthropic Messages API SSE (`stream: true`).
    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "messages": [["role": "user", "content": prompt]],
            "stream": true
        ]
        if let system = systemPrompt, !system.isEmpty { body["system"] = system }

        guard let url = URL(string: "\(Self.baseURL)/messages") else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try CHAIStreamingHelpers.checkHTTP(response, domain: "Claude")

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        let type = json["type"] as? String
                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String,
                           !text.isEmpty {
                            continuation.yield(text)
                        } else if type == "message_stop" {
                            break
                        }
                    }
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

    // MARK: - Private
    
    private func makeRequest(apiKey: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(Self.baseURL)/messages") else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw CHAIError.networkError(URLError(.badServerResponse))
        }
        
        switch http.statusCode {
        case 200...299: return data
        case 401: throw CHAIError.invalidKey
        case 429: throw CHAIError.rateLimited
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CHAIError.networkError(NSError(domain: "Claude", code: http.statusCode,
                                                    userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
    
    private func parseTextResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CHAIError.invalidResponse
        }
        
        guard let content = json["content"] as? [[String: Any]] else {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw CHAIError.networkError(NSError(domain: "Claude", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            }
            throw CHAIError.invalidResponse
        }
        
        guard let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            throw CHAIError.invalidResponse
        }
        
        return text
    }
    
    // MARK: - Available Models
    
    public struct AIModel: Identifiable, Sendable {
        public let id: String
        public let name: String
        
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
    
    public static let availableModels: [AIModel] = [
        AIModel(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4 (recommended)"),
        AIModel(id: "claude-opus-4-20250514", name: "Claude Opus 4 (smartest)"),
        AIModel(id: "claude-haiku-3-5-20241022", name: "Claude Haiku 3.5 (fastest)"),
    ]
}
