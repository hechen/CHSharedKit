import Foundation
import Testing
@testable import CHSharedKit

@Suite("Remote cloud model catalog")
struct CHAICloudModelCatalogTests {
    @Test("Bundled manifest is valid and drives both providers")
    func bundledManifest() throws {
        let manifest = try CHAICloudModelCatalog.snapshot.validated()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.provider(id: CHOpenAIProvider.providerID) != nil)
        #expect(manifest.provider(id: CHClaudeProvider.providerID) != nil)
        #expect(CHOpenAIProvider.availableModels.map(\.id).contains("gpt-5.6-terra"))
        #expect(CHClaudeProvider.availableModels.map(\.id).contains("claude-sonnet-5"))
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
