import Foundation

// MARK: - OpenAI Provider

/// OpenAI GPT provider for text and vision requests
public struct CHOpenAIProvider: CHAIProvider, Sendable {
    public static let providerID = "openai"
    private static let keychainService = "app.chen.clawdappkit.openai"
    
    public var id: String { Self.providerID }
    public var displayName: String { "OpenAI" }
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
        get { UserDefaults.standard.string(forKey: "clawd_openai_model") ?? "gpt-4o" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_openai_model") }
    }
    
    public static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "clawd_openai_base_url") ?? "https://api.openai.com/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_openai_base_url") }
    }
    
    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }
        
        var messages: [[String: Any]] = []
        if let system = systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])
        
        let body: [String: Any] = [
            "model": Self.model,
            "messages": messages,
            "max_tokens": 4000
        ]
        
        let data = try await makeRequest(apiKey: apiKey, endpoint: "chat/completions", body: body)
        return try parseTextResponse(data)
    }
    
    public func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }
        
        let base64 = imageData.base64EncodedString()
        
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "high"]]
                    ]
                ]
            ],
            "max_tokens": 4000
        ]
        
        let data = try await makeRequest(apiKey: apiKey, endpoint: "chat/completions", body: body)
        return try parseTextResponse(data)
    }
    
    public func validate() async throws -> Bool {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": "Say OK"]],
            "max_tokens": 5
        ]

        let _ = try await makeRequest(apiKey: apiKey, endpoint: "chat/completions", body: body)
        return true
    }

    // MARK: - Streaming

    /// Stream deltas via Server-Sent Events (`stream: true` on chat/completions).
    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw CHAIError.noAPIKey }

        var messages: [[String: Any]] = []
        if let system = systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": Self.model,
            "messages": messages,
            "max_tokens": 4000,
            "stream": true
        ]

        guard let url = URL(string: "\(Self.baseURL)/chat/completions") else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try CHAIStreamingHelpers.checkHTTP(response, domain: "OpenAI")

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty
                        else { continue }
                        continuation.yield(content)
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
    
    private func makeRequest(apiKey: String, endpoint: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(Self.baseURL)/\(endpoint)") else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            throw CHAIError.networkError(NSError(domain: "OpenAI", code: http.statusCode,
                                                    userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
    
    private func parseTextResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CHAIError.invalidResponse
        }
        
        guard let choices = json["choices"] as? [[String: Any]] else {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw CHAIError.networkError(NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            }
            throw CHAIError.invalidResponse
        }
        
        guard let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CHAIError.invalidResponse
        }
        
        return content
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
        AIModel(id: "gpt-4o", name: "GPT-4o (recommended)"),
        AIModel(id: "gpt-4o-mini", name: "GPT-4o Mini (cheaper)"),
        AIModel(id: "gpt-4.1", name: "GPT-4.1"),
        AIModel(id: "gpt-4.1-mini", name: "GPT-4.1 Mini"),
        AIModel(id: "gpt-4.1-nano", name: "GPT-4.1 Nano (fastest)"),
        AIModel(id: "o4-mini", name: "o4-mini (reasoning)"),
    ]
}
