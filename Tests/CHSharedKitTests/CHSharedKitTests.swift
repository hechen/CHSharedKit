import Testing
@testable import CHSharedKit

// MARK: - CHAIProviderFilter

@Suite("CHAIProviderFilter")
struct CHAIProviderFilterTests {

    @Test("onDeviceOnly contains local + Apple Intelligence but not cloud")
    func onDeviceOnlyMembership() {
        let set = CHAIProviderFilter.onDeviceOnly
        #expect(set.contains(.onDeviceLocal))
        #expect(set.contains(.appleIntelligence))
        #expect(!set.contains(.cloudProviders))
    }

    @Test("all contains every category")
    func allMembership() {
        let set = CHAIProviderFilter.all
        #expect(set.contains(.onDeviceLocal))
        #expect(set.contains(.appleIntelligence))
        #expect(set.contains(.cloudProviders))
    }

    @Test("Built-in provider IDs resolve to their expected categories")
    func builtInProviderCategories() {
        #expect(CHAppleIntelligenceProvider().category == .appleIntelligence)
        #expect(CHOpenAIProvider().category == .cloudProviders)
        #expect(CHClaudeProvider().category == .cloudProviders)
        #expect(CHCustomEndpointProvider().category == .cloudProviders)
    }
}

// MARK: - CHAIManager filter wiring

@MainActor
@Suite("CHAIManager.availableProvidersFilter")
struct CHAIManagerFilterTests {

    @Test("Default filter is .all — every built-in provider is visible")
    func defaultFilterShowsAll() {
        let manager = CHAIManager.shared
        manager.availableProvidersFilter = .all
        let ids = manager.availableProviders.map(\.id)
        #expect(ids.contains("apple-intelligence"))
        #expect(ids.contains("openai"))
        #expect(ids.contains("claude"))
        #expect(ids.contains("custom"))
    }

    @Test("onDeviceOnly hides cloud providers")
    func onDeviceOnlyHidesCloud() {
        let manager = CHAIManager.shared
        manager.availableProvidersFilter = .onDeviceOnly
        let ids = manager.availableProviders.map(\.id)
        #expect(ids.contains("apple-intelligence"))
        #expect(!ids.contains("openai"))
        #expect(!ids.contains("claude"))
        #expect(!ids.contains("custom"))
        // Restore so other tests don't observe the narrowed list.
        manager.availableProvidersFilter = .all
    }

    @Test("allProviders ignores the filter")
    func allProvidersIgnoresFilter() {
        let manager = CHAIManager.shared
        manager.availableProvidersFilter = .onDeviceOnly
        let ids = manager.allProviders.map(\.id)
        #expect(ids.contains("openai"))
        #expect(ids.contains("claude"))
        manager.availableProvidersFilter = .all
    }
}
