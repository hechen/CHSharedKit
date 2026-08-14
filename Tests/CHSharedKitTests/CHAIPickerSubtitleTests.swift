import Testing
import Foundation
@testable import CHSharedKit

// MARK: - 2.9.6 — picker subtitle lookup regression pin
//
// Chen reported that switching the picker's model dropdown didn't
// change the OpenAI / Claude row's subtitle. Root cause: the row's
// subtitle was computed via `CHOpenAIProvider.currentModel?.displayName`
// (a static UserDefaults read with no SwiftUI observation), and the
// picker wrote back to UserDefaults via `.onChange` AFTER the body
// re-render that the @State change triggered — so the body's call
// to `currentModel` returned the OLD value during the same pass.
//
// 2.9.6 fix: bind the picker selection to `@AppStorage` so writes
// publish synchronously within the render pass, and look up the
// display name via the @AppStorage value (not the static accessor).
// SwiftUI's @AppStorage machinery is the part we can't test in a
// unit suite — that's a runtime concern. What we CAN pin here:
// the lookup itself is deterministic against `availableModels`.
//
// These tests assert the same lookup expression `cloudProviderMeta`
// uses (`availableModels.first(where: { $0.id == storedID })?.displayName`)
// against every provider's lineup. If a future kit refactor breaks
// the lookup or drops `displayName`, this suite fails before the
// row visually rots.

@Suite("Picker subtitle lookup")
struct CHAIPickerSubtitleTests {

    // MARK: - OpenAI

    @Test("OpenAI lookup returns the recommended model's displayName for the default ID")
    func openAIRecommendedLookup() {
        let recommended = CHOpenAIProvider.recommendedModel
        let lookup = CHOpenAIProvider.availableModels.first(where: { $0.id == recommended.id })
        #expect(lookup != nil)
        #expect(lookup?.displayName == recommended.displayName)
    }

    @Test("OpenAI lookup resolves every entry in the canonical lineup")
    func openAIEveryEntryResolvable() {
        for model in CHOpenAIProvider.availableModels {
            let lookup = CHOpenAIProvider.availableModels.first(where: { $0.id == model.id })
            #expect(lookup?.displayName == model.displayName)
        }
    }

    @Test("OpenAI lookup returns nil for an unknown ID — picker falls back to recommended")
    func openAIUnknownReturnsNil() {
        let lookup = CHOpenAIProvider.availableModels.first(where: { $0.id == "definitely-not-a-real-model" })
        #expect(lookup == nil)
    }

    // MARK: - Claude

    @Test("Claude lookup returns the recommended model's displayName for the default ID")
    func claudeRecommendedLookup() {
        let recommended = CHClaudeProvider.recommendedModel
        let lookup = CHClaudeProvider.availableModels.first(where: { $0.id == recommended.id })
        #expect(lookup != nil)
        #expect(lookup?.displayName == recommended.displayName)
    }

    @Test("Claude lookup resolves every entry in the canonical lineup")
    func claudeEveryEntryResolvable() {
        for model in CHClaudeProvider.availableModels {
            let lookup = CHClaudeProvider.availableModels.first(where: { $0.id == model.id })
            #expect(lookup?.displayName == model.displayName)
        }
    }

    @Test("Claude lookup returns nil for an unknown ID")
    func claudeUnknownReturnsNil() {
        let lookup = CHClaudeProvider.availableModels.first(where: { $0.id == "claude-not-real" })
        #expect(lookup == nil)
    }

    // MARK: - Recommended-fallback contract

    @Test("Switching to a different available ID changes the lookup result")
    func switchingIDChangesLookup() {
        // Pick two distinct entries. The picker's switch is what the
        // body re-render reflects — this test pins that the lookup
        // function will return DIFFERENT displayNames for the two IDs.
        let models = CHOpenAIProvider.availableModels
        guard models.count >= 2 else {
            Issue.record("OpenAI availableModels has fewer than 2 entries; can't exercise switch")
            return
        }
        let a = models[0]
        let b = models[1]
        let lookupA = CHOpenAIProvider.availableModels.first(where: { $0.id == a.id })?.displayName
        let lookupB = CHOpenAIProvider.availableModels.first(where: { $0.id == b.id })?.displayName
        #expect(lookupA != nil)
        #expect(lookupB != nil)
        #expect(lookupA != lookupB,
                "Two distinct IDs must yield distinct displayNames, otherwise the picker row can't visibly update on a switch")
    }

    @Test("Exactly one OpenAI model is flagged isRecommended")
    func openAIExactlyOneRecommended() {
        let recommended = CHOpenAIProvider.availableModels.filter(\.isRecommended)
        #expect(recommended.count == 1, "Exactly one row should be flagged isRecommended; found \(recommended.count)")
        #expect(recommended.first?.id == "gpt-5.6-terra")
        #expect(Set(CHOpenAIProvider.availableModels.map(\.id)).isSuperset(of: [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"
        ]))
    }

    @Test("Exactly one Claude model is flagged isRecommended")
    func claudeExactlyOneRecommended() {
        let recommended = CHClaudeProvider.availableModels.filter(\.isRecommended)
        #expect(recommended.count == 1, "Exactly one row should be flagged isRecommended; found \(recommended.count)")
        #expect(recommended.first?.id == "claude-sonnet-5")
        #expect(Set(CHClaudeProvider.availableModels.map(\.id)).isSuperset(of: [
            "claude-fable-5", "claude-opus-5", "claude-opus-4-8",
            "claude-sonnet-5", "claude-haiku-4-5"
        ]))
    }

    @Test("Current model pricing matches official standard rates")
    @MainActor
    func currentModelPricing() {
        #expect(CHAIUsageTracker.pricing["gpt-5.6-sol"]?.inputPerMillion == 5)
        #expect(CHAIUsageTracker.pricing["gpt-5.6-terra"]?.outputPerMillion == 12)
        #expect(CHAIUsageTracker.pricing["gpt-5.6-luna"]?.outputPerMillion == 1.2)
        #expect(CHAIUsageTracker.pricing["claude-fable-5"]?.outputPerMillion == 50)
        #expect(CHAIUsageTracker.pricing["claude-opus-5"]?.inputPerMillion == 5)
        #expect(CHAIUsageTracker.pricing["claude-opus-4-8"]?.inputPerMillion == 5)
        #expect(CHAIUsageTracker.pricing["claude-sonnet-5"]?.outputPerMillion == 10)
        #expect(CHAIUsageTracker.pricing["claude-haiku-4-5"]?.outputPerMillion == 5)
    }
}
