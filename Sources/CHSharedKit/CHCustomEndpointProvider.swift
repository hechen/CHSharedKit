import Foundation

// MARK: - Custom Endpoint Provider

/// For self-hosted services (Ollama, vLLM, LMStudio, etc.)
/// Uses OpenAI-compatible API format since most self-hosted solutions support it.
public struct CHCustomEndpointProvider: CHAIProvider, Sendable {
    public static let providerID = "custom"

    public var id: String { Self.providerID }
    public var displayName: String { String(localized: "Custom Endpoint", bundle: .module) }
    public var supportsVision: Bool { true }
    /// 2.10.0: assume the user-configured endpoint supports text +
    /// vision. Streaming + function-calling vary by backend (vLLM,
    /// Ollama, LM Studio); we don't claim them so features requiring
    /// those filter Custom Endpoint out of the picker rather than
    /// promising a capability we can't verify.
    public var capabilities: Set<CHAICapability> {
        [.textInput, .visionInput]
    }

    public init() {}

    /// API key for the custom endpoint. Reads/writes route through
    /// `CHAITokenStore` (2.4.8) — keyed by `<bundleID>.custom`.
    public static var apiKey: String? {
        get { CHAITokenStore.token(for: providerID) }
        set { CHAITokenStore.setToken(newValue, for: providerID) }
    }
    
    public static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "clawd_custom_base_url") ?? "http://localhost:11434/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_custom_base_url") }
    }
    
    public static var model: String {
        get { UserDefaults.standard.string(forKey: "clawd_custom_model") ?? "llava" }
        set { UserDefaults.standard.set(newValue, forKey: "clawd_custom_model") }
    }
    
    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
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
        
        let data = try await makeRequest(body: body)
        return try parseOpenAICompatibleResponse(data)
    }
    
    public func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        let base64 = imageData.base64EncodedString()
        
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                    ]
                ]
            ],
            "max_tokens": 4000
        ]
        
        let data = try await makeRequest(body: body)
        return try parseOpenAICompatibleResponse(data)
    }
    
    public func validate() async throws -> Bool {
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "user", "content": "Say OK"]],
            "max_tokens": 5
        ]
        let _ = try await makeRequest(body: body)
        return true
    }

    // MARK: - Streaming

    /// Stream deltas via OpenAI-compatible SSE. Most self-hosted runtimes
    /// (Ollama, vLLM, LM Studio, llama-server) implement this. Endpoints that
    /// don't support SSE will typically return a non-200 which maps to a
    /// `CHAIError` — callers can catch and retry via `sendMessage`.
    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
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

        let endpoint = Self.baseURL.hasSuffix("/") ? "\(Self.baseURL)chat/completions" : "\(Self.baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = Self.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try CHAIStreamingHelpers.checkHTTP(response, domain: "Custom")

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
    
    private func makeRequest(body: [String: Any]) async throws -> Data {
        let endpoint = Self.baseURL.hasSuffix("/") ? "\(Self.baseURL)chat/completions" : "\(Self.baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw CHAIError.networkError(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = Self.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120 // Self-hosted may be slower
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Connection failed"
            throw CHAIError.networkError(NSError(domain: "Custom", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                                    userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return data
    }
    
    private func parseOpenAICompatibleResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CHAIError.invalidResponse
        }
        
        guard let choices = json["choices"] as? [[String: Any]] else {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw CHAIError.networkError(NSError(domain: "Custom", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            }
            throw CHAIError.invalidResponse
        }
        
        guard let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CHAIError.invalidResponse
        }
        
        return content
    }
}
