import Foundation
import Testing
@testable import CHSharedKit

@Suite("Catalog provider runtime", .serialized)
final class CHAICatalogProviderTests {
    let priorCredentialIDs = UserDefaults.standard.stringArray(forKey: "clawd_catalog_credential_ids")
    init() { CHAITokenStore._testOverride = CHAITokenStore.TestBacking() }
    deinit {
        CHAITokenStore._testOverride = nil
        UserDefaults.standard.set(priorCredentialIDs, forKey: "clawd_catalog_credential_ids")
    }
    func definition(host: String = "catalog.test", format: String = "openai-chat-completions") throws -> CHAICloudModelCatalogManifest.Provider {
        let json = """
        {"schemaVersion":1,"revision":"test","providers":[{
          "id":"catalog-test","displayName":"Catalog Test",
          "api":{"format":"\(format)","baseURL":"https://\(host)/v1","tokenLimitParameter":"max_completion_tokens"},
          "recommendedModelID":"vision","migrationFallbackModelID":"text","retiredModelIDs":["retired"],
          "models":[
            {"id":"vision","name":"Vision","inputPerMillion":2,"outputPerMillion":6,"imageInputPerMillion":2,"capabilities":["textInput","visionInput","streaming"]},
            {"id":"text","name":"Text","inputPerMillion":1,"outputPerMillion":2,"imageInputPerMillion":0,"capabilities":["textInput"]}
          ]}]}
        """
        return try JSONDecoder().decode(CHAICloudModelCatalogManifest.self, from: Data(json.utf8)).validated().providers[0]
    }
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogMockProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func requestsResponsesAndStreaming() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = try #require(CHAICatalogProvider(definition(), modelID: "vision", session: session))
        provider.apiKey = "test-catalog-token"
        defer { provider.apiKey = nil }
        let request = try provider.request(prompt: "hello", systemPrompt: "system")
        #expect(request.url?.absoluteString == "https://catalog.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-catalog-token")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "vision")
        #expect(body["max_completion_tokens"] as? Int == 4000)
        #expect(body["max_tokens"] == nil)
        #expect(body["temperature"] == nil)
        #expect(try await provider.sendMessage(prompt: "hello", systemPrompt: nil) == "Hello")
        #expect(try await provider.sendVisionMessage(prompt: "photo", imageData: Data([0x89,0x50,0x4e,0x47])) == "Hello")
        let visionBody = try JSONSerialization.jsonObject(with: provider.request(prompt: "photo", imageData: Data([0x89,0x50,0x4e,0x47])).httpBody!) as! [String: Any]
        let messages = visionBody["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        #expect((content[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,iVBORw==")
        var text = ""
        for try await chunk in try await provider.stream(prompt: "hello", systemPrompt: nil) { text += chunk }
        #expect(text == "Hello")
        #expect(try await provider.validate())
    }

    @Test func credentialAndModelIsolation() throws {
        let provider = try #require(CHAICatalogProvider(definition()))
        let changed = try #require(CHAICatalogProvider(definition(host: "other.test")))
        #expect(provider.credentialID != changed.credentialID)
        #expect(provider.credentialID != "openai")
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: provider.modelStorageKey)
        defer {
            defaults.set(prior, forKey: provider.modelStorageKey)
            provider.apiKey = nil
        }
        provider.apiKey = "isolated-test-token"
        #expect(changed.apiKey == nil)
        provider.selectedModelID = "retired"
        #expect(provider.selectedModelID == "text")
        #expect(!provider.supportsVision)
        #expect(throws: CHAIError.self) { try provider.request(prompt: "photo", imageData: Data([1])) }
        provider.selectedModelID = "vision"
        #expect(provider.supportsVision)
    }

    @Test func rejectsUnsafeAndSkipsUnknownFormats() throws {
        #expect(try CHAICatalogProvider(definition(format: "future-format")) == nil)
        #expect(throws: (any Error).self) { try definition(host: "user:password@catalog.test") }
        #expect(!CHAICloudModelCatalogManifest.API.isSafeURL(URL(string: "http://catalog.test")!))
        #expect(!CHAICloudModelCatalogManifest.API.isSafeURL(URL(string: "https://catalog.test?key=secret")!))
    }

    @Test @MainActor func registrationRefreshRemovalAndGating() throws {
        let manager = CHAIManager.shared
        let priorActive = manager.activeProviderID
        let priorGating = manager.gatedProviderIDs
        let priorFilter = manager.availableProvidersFilter
        let priorGate = CHIAPGateRegistry.shared
        defer {
            manager.synchronizeCatalogProviders(CHAICloudModelCatalog.snapshot)
            manager.activeProviderID = priorActive
            manager.gatedProviderIDs = priorGating
            manager.availableProvidersFilter = priorFilter
            CHIAPGateRegistry.shared = priorGate
        }
        let manifest = CHAICloudModelCatalogManifest(schemaVersion: 1, revision: "test", providers: [try definition()])
        manager.gateAllExceptAppleIntelligence()
        CHIAPGateRegistry.shared = CatalogLockedGate()
        manager.synchronizeCatalogProviders(manifest)
        #expect(manager.provider(id: "catalog-test") is CHAICatalogProvider)
        #expect(manager.isLocked(providerID: "catalog-test"))
        #expect(throws: CHAIError.self) { try manager.checkProviderUnlocked(manager.provider(id: "catalog-test")!) }
        manager.activeProviderID = "catalog-test"
        manager.availableProvidersFilter = .onDeviceOnly
        #expect(manager.activeProvider == nil)
        #expect(manager.provider(id: "catalog-test") == nil)
        manager.availableProvidersFilter = .all
        manager.synchronizeCatalogProviders(.init(schemaVersion: 1, revision: "test2", providers: []))
        #expect(manager.activeProvider == nil)
        #expect(manager.activeProviderID == "catalog-test") // no silent switch to a different cloud
    }

    @Test func authenticationAndRateLimitErrors() async throws {
        for (host, code) in [("unauthorized.test", 401), ("rate.test", 429)] {
            let session = session()
            let provider = try #require(CHAICatalogProvider(definition(host: host), session: session))
            provider.apiKey = "test-token"
            defer { provider.apiKey = nil; session.invalidateAndCancel() }
            do { _ = try await provider.sendMessage(prompt: "test", systemPrompt: nil); Issue.record("Expected HTTP \(code)") }
            catch CHAIError.invalidKey { #expect(code == 401) }
            catch CHAIError.rateLimited { #expect(code == 429) }
        }
    }
}

private final class CatalogLockedGate: CHIAPGate {
    let hasUnlockedProviders = false
    let unlockPriceLabel: String? = nil
    func startPurchase() async throws {}
    func restorePurchases() async throws {}
}

private final class CatalogMockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
            }
            body = result
        } else { body = Data() }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let streaming = object?["stream"] as? Bool == true
        let code = request.url?.host == "unauthorized.test" ? 401 : request.url?.host == "rate.test" ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = streaming ? "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n" : #"{"choices":[{"message":{"content":"Hello"}}]}"#
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
