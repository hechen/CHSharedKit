import Foundation
import Testing
@testable import CHSharedKit

@Suite("Remote cloud model catalog")
struct CHAICloudModelCatalogTests {
    @Test("Default catalog endpoint is public HTTPS")
    @MainActor
    func defaultRemoteURL() {
        #expect(CHAICloudModelCatalog.defaultRemoteURL.absoluteString ==
            "https://hechen.github.io/apps/closet/cloud-model-catalog.json")
    }

    @Test("Bundled manifest is valid and drives both providers")
    func bundledManifest() throws {
        let manifest = try CHAICloudModelCatalog.snapshot.validated()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.revision >= "2026-09-20.1")
        #expect(manifest.provider(id: CHOpenAIProvider.providerID) != nil)
        #expect(manifest.provider(id: CHClaudeProvider.providerID) != nil)
        #expect(CHOpenAIProvider.availableModels.map(\.id).contains("gpt-5.6-terra"))
        #expect(CHOpenAIProvider.availableModels.map(\.id).contains("gpt-6-astra"))
        #expect(CHClaudeProvider.availableModels.map(\.id).contains("claude-sonnet-5"))
        #expect(CHClaudeProvider.availableModels.map(\.id).contains("claude-opus-5"))
    }

    @Test("Recommended and migration fallback IDs resolve")
    func fallbackIDsResolve() {
        #expect(CHOpenAIProvider.availableModels.contains { $0.id == CHOpenAIProvider.migrationFallbackModelID })
        #expect(CHClaudeProvider.availableModels.contains { $0.id == CHClaudeProvider.migrationFallbackModelID })
        #expect(CHOpenAIProvider.recommendedModel.id == CHOpenAIProvider.migrationFallbackModelID)
        #expect(CHClaudeProvider.recommendedModel.id == CHClaudeProvider.migrationFallbackModelID)
    }

    @Test("Manifest pricing overrides are visible to usage tracking")
    @MainActor
    func manifestPricing() {
        let openAI = CHAICloudModelCatalog.snapshot.provider(id: "openai")!.models[0]
        let price = CHAIUsageTracker.pricing[openAI.id]
        #expect(price?.inputPerMillion == openAI.inputPerMillion)
        #expect(price?.outputPerMillion == openAI.outputPerMillion)
        #expect(price?.imageInputPerMillion == openAI.imageInputPerMillion)
    }

    @Test("Unsupported schemas are rejected")
    func rejectsUnsupportedSchema() throws {
        let data = Data(#"{"schemaVersion":99,"revision":"future","providers":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(CHAICloudModelCatalogManifest.self, from: data)
        #expect(throws: CHAICloudModelCatalogManifest.ValidationError.unsupportedSchema(99)) {
            try decoded.validated()
        }
    }

    @Test("A stale remote response cannot hide newer bundled models")
    @MainActor
    func ignoresOlderRemoteCatalog() async {
        let original = CHAICloudModelCatalog.snapshot
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StaleCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        await CHAICloudModelCatalog.shared.refresh(
            from: URL(string: "https://catalog.test/stale.json")!, session: session
        )

        #expect(CHAICloudModelCatalog.snapshot == original)
        #expect(CHAICloudModelCatalog.shared.revision == original.revision)
        #expect(CHAICloudModelCatalog.shared.lastRefreshError == nil)
    }

    @Test("Missing recommendation target is rejected")
    func rejectsMissingRecommendation() throws {
        let data = Data(#"{"schemaVersion":1,"revision":"test","providers":[{"id":"openai","recommendedModelID":"missing","migrationFallbackModelID":"only","retiredModelIDs":[],"models":[{"id":"only","name":"Only","inputPerMillion":1,"outputPerMillion":2,"imageInputPerMillion":1}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CHAICloudModelCatalogManifest.self, from: data)
        #expect(throws: CHAICloudModelCatalogManifest.ValidationError.missingRecommendedModel("openai")) {
            try decoded.validated()
        }
    }

    @Test("Negative prices are rejected")
    func rejectsNegativePricing() throws {
        let data = Data(#"{"schemaVersion":1,"revision":"test","providers":[{"id":"openai","recommendedModelID":"only","migrationFallbackModelID":"only","retiredModelIDs":[],"models":[{"id":"only","name":"Only","inputPerMillion":-1,"outputPerMillion":2,"imageInputPerMillion":1}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CHAICloudModelCatalogManifest.self, from: data)
        #expect(throws: CHAICloudModelCatalogManifest.ValidationError.invalidModel("openai")) {
            try decoded.validated()
        }
    }
}

private final class StaleCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"schemaVersion":1,"revision":"2000-01-01.1","providers":[]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
