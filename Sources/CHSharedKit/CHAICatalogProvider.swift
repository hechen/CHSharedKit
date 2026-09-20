import Foundation
import CryptoKit

/// Runtime adapter for catalog-defined, bearer-authenticated Chat Completions APIs.
/// Provider/endpoint-scoped credentials never fall back to another provider's key.
public struct CHAICatalogProvider: CHAIProvider, Sendable {
    public let definition: CHAICloudModelCatalogManifest.Provider
    private let modelOverride: String?
    private let session: URLSession

    public init?(_ definition: CHAICloudModelCatalogManifest.Provider, modelID: String? = nil,
                 session: URLSession = .shared) {
        guard let api = definition.api, api.isSupported,
              CHAICloudModelCatalogManifest.API.isSafeURL(api.baseURL),
              definition.models.contains(where: { $0.id == definition.recommendedModelID }),
              definition.models.contains(where: { $0.id == definition.migrationFallbackModelID }) else { return nil }
        self.definition = definition
        self.modelOverride = modelID
        self.session = session
    }

    public var id: String { definition.id }
    public var displayName: String { definition.displayName ?? id }
    public var baseURL: URL { definition.api!.baseURL }
    public var modelStorageKey: String { "clawd_catalog_model_\(id)" }
    public var credentialID: String {
        let hash = SHA256.hash(data: Data(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "catalog.\(id).\(hash)"
    }
    /// Includes previous destinations so host sync controls can also migrate retired slots.
    public static var storedCredentialIDs: [String] {
        UserDefaults.standard.stringArray(forKey: "clawd_catalog_credential_ids") ?? []
    }
    public var apiKey: String? {
        get { CHAITokenStore.token(for: credentialID) }
        nonmutating set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            CHAITokenStore.setToken(value?.isEmpty == false ? value : nil, for: credentialID)
            if value?.isEmpty == false {
                UserDefaults.standard.set(Array(Set(Self.storedCredentialIDs + [credentialID])).sorted(),
                                          forKey: "clawd_catalog_credential_ids")
            }
        }
    }
    public var selectedModelID: String {
        get {
            let saved = modelOverride ?? UserDefaults.standard.string(forKey: modelStorageKey)
            if let saved, definition.models.contains(where: { $0.id == saved }),
               !definition.retiredModelIDs.contains(saved) { return saved }
            return saved == nil ? definition.recommendedModelID : definition.migrationFallbackModelID
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: modelStorageKey) }
    }
    public var selectedModel: CHAICloudModelCatalogManifest.Model {
        definition.models.first { $0.id == selectedModelID }!
    }
    public var capabilities: Set<CHAICapability> {
        // Only capabilities implemented by this adapter can be advertised.
        Set((selectedModel.capabilities ?? ["textInput"]).compactMap(CHAICapability.init(rawValue:)))
            .intersection([.textInput, .visionInput, .streaming])
    }
    public var supportsVision: Bool { capabilities.contains(.visionInput) }

    func request(prompt: String, systemPrompt: String? = nil, imageData: Data? = nil,
                 streaming: Bool = false, tokenLimit: Int = 4000) throws -> URLRequest {
        guard let key = apiKey, !key.isEmpty else { throw CHAIError.noAPIKey }
        if imageData != nil && !supportsVision { throw CHAIError.visionNotSupported }
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty { messages.append(["role": "system", "content": systemPrompt]) }
        if let imageData {
            let mime = imageData.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "image/png" : "image/jpeg"
            messages.append(["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(imageData.base64EncodedString())"]]
            ]])
        } else { messages.append(["role": "user", "content": prompt]) }
        var body: [String: Any] = ["model": selectedModelID, "messages": messages,
                                  definition.api!.tokenLimitParameter: tokenLimit]
        if streaming { body["stream"] = true }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CHAIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw CHAIError.invalidKey
        case 429: throw CHAIError.rateLimited
        default: throw CHAIError.invalidResponse
        }
    }

    private func complete(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request, delegate: CatalogNoRedirects.shared)
        try check(response)
        let result = try JSONDecoder().decode(Completion.self, from: data)
        guard let content = result.choices.first?.message?.content, !content.isEmpty else {
            throw CHAIError.invalidResponse
        }
        return content
    }
    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        try await complete(request(prompt: prompt, systemPrompt: systemPrompt))
    }
    public func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        try await complete(request(prompt: prompt, imageData: imageData))
    }
    public func validate() async throws -> Bool {
        _ = try await complete(request(prompt: "Reply OK.", tokenLimit: 256))
        return true
    }
    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        let request = try request(prompt: prompt, systemPrompt: systemPrompt, streaming: capabilities.contains(.streaming))
        if !capabilities.contains(.streaming) {
            let text = try await complete(request)
            return AsyncThrowingStream { $0.yield(text); $0.finish() }
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: CatalogNoRedirects.shared)
        try check(response)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { continuation.finish(); return }
                        let chunk = try JSONDecoder().decode(Completion.self, from: Data(payload.utf8))
                        if let delta = chunk.choices.first?.delta?.content { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private struct Completion: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Content?
            let delta: Content?
        }
        struct Content: Decodable { let content: String? }
    }
}

private final class CatalogNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = CatalogNoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A catalog endpoint must handle the request itself; never forward credentials or content.
        completionHandler(nil)
    }
}
