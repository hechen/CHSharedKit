import Foundation

// MARK: - Claude (Anthropic) Provider

/// Anthropic Claude provider for text and vision requests
public struct CHClaudeProvider: CHAIProvider, Sendable {
    public static let providerID = "claude"

    public var id: String { Self.providerID }
    public var displayName: String { "Claude (Anthropic)" }
    public var supportsVision: Bool { true }

    public init() {}

    /// API key for Anthropic Claude. Reads/writes route through
    /// `CHAITokenStore` (2.4.8) — keyed by `<bundleID>.claude`.
    public static var apiKey: String? {
        get { CHAITokenStore.token(for: providerID) }
        set { CHAITokenStore.setToken(newValue, for: providerID) }
    }
    
    public static var model: String {
        get { UserDefaults.standard.string(forKey: "clawd_claude_model") ?? "claude-sonnet-4-6" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_claude_model") }
    }

    /// 2.9.5: the user's currently-selected model resolved against the
    /// canonical lineup. Returns nil when the stored ID is not in
    /// `availableModels` (e.g. a retired ID that hasn't been migrated
    /// yet, or a hand-edited UserDefaults entry). Picker rows use this
    /// to display the active model name in their subtitle.
    public static var currentModel: AIModel? {
        let id = model
        return availableModels.first(where: { $0.id == id })
    }

    /// 2.9.5: the recommended default model for typical BYOK app
    /// workloads. Falls back to the first entry in `availableModels`
    /// if no row is flagged `isRecommended`.
    public static var recommendedModel: AIModel {
        availableModels.first(where: \.isRecommended) ?? availableModels[0]
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
        /// 2.9.5: marks the recommended row for picker subtitle fallback
        /// when no user selection is on file. Exactly one row per
        /// provider should be flagged true.
        public let isRecommended: Bool

        public init(id: String, name: String, isRecommended: Bool = false) {
            self.id = id
            self.name = name
            self.isRecommended = isRecommended
        }

        /// 2.9.5: alias for `name`. Kept as a separate property so a
        /// future refactor can localize / shorten without touching
        /// every call site.
        public var displayName: String { name }
    }

    /// 2.9.5: April 2026 Anthropic lineup. Per the deprecation notice,
    /// `claude-sonnet-3-7` and `claude-haiku-3-5` are retired (see
    /// `retiredModelIDs`); their stored selections are migrated forward
    /// by `CHAIModelMigration.migrateRetiredModels(appName:)` on first
    /// launch under 2.9.5. Earlier 3.x rows retained for users who
    /// explicitly want them and whose Anthropic account still has
    /// access.
    public static let availableModels: [AIModel] = [
        AIModel(id: "claude-opus-4-7",   name: "Claude Opus 4.7 (frontier · agentic coding)"),
        AIModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (recommended)", isRecommended: true),
        AIModel(id: "claude-haiku-4-5",  name: "Claude Haiku 4.5 (fastest, cheapest)"),
        AIModel(id: "claude-opus-4-20250514",   name: "Claude Opus 4"),
        AIModel(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4"),
        AIModel(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet"),
        AIModel(id: "claude-3-opus-20240229",     name: "Claude 3 Opus"),
        AIModel(id: "claude-3-sonnet-20240229",   name: "Claude 3 Sonnet"),
        AIModel(id: "claude-3-haiku-20240307",    name: "Claude 3 Haiku"),
    ]

    /// 2.9.5: identifiers explicitly retired by Anthropic in the
    /// April 2026 deprecation cycle. `CHAIModelMigration` rewrites
    /// stored selections in this set forward to
    /// `migrationFallbackModelID` on first launch under 2.9.5.
    public static let retiredModelIDs: Set<String> = [
        "claude-sonnet-3-7",
        "claude-haiku-3-5",
        // The dated alias of haiku-3-5 that earlier kit versions wrote
        // into UserDefaults — older builds used this exact string.
        "claude-haiku-3-5-20241022",
    ]

    /// 2.9.5: replacement target for any retired Claude identifier.
    /// Mirrors `recommendedModel.id`.
    public static let migrationFallbackModelID: String = "claude-sonnet-4-6"
}
