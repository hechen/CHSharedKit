import SwiftUI
import Testing
@testable import CHSharedKit
@testable import CHLocalLLM

@MainActor
@Suite("Downloadable model settings availability", .serialized)
struct CHAISettingsAvailabilityTests {
    @Test("Disabled local models never resolve storage, including a retained selection")
    func disabledModelsAreInert() {
        withManagerPolicy(disabled: ["on-device-llm"], filter: .all) { manager in
            let previousSelection = manager.activeProviderID
            defer { manager.activeProviderID = previousSelection }
            manager.activeProviderID = "on-device-llm"
            var storeResolutions = 0
            let view = CHAISettingsContent(appIdentifier: .liftcoach) {
                storeResolutions += 1
                return LocalModelStore.shared
            }

            #expect(!view.showsDownloadableModels)
            #expect(view.modelStore == nil)
            _ = view.body
            #expect(storeResolutions == 0)
            #expect(manager.activeProviderID == "on-device-llm")
            #expect(manager.provider(id: "on-device-llm") == nil)
        }
    }

    @Test("A category filter excluding local models also prevents storage access")
    func filteredModelsAreInert() {
        withManagerPolicy(disabled: [], filter: [.appleIntelligence, .cloudProviders]) { _ in
            var storeResolutions = 0
            let view = CHAISettingsContent(appIdentifier: .liftcoach) {
                storeResolutions += 1
                return LocalModelStore.shared
            }

            #expect(!view.showsDownloadableModels)
            #expect(view.modelStore == nil)
            _ = view.body
            #expect(storeResolutions == 0)
        }
    }

    @Test("Default and on-device-only policies keep the existing downloadable offering")
    func defaultBehaviorIsPreserved() {
        for filter in [CHAIProviderFilter.all, .onDeviceOnly] {
            withManagerPolicy(disabled: ["custom"], filter: filter) { _ in
                let view = CHAISettingsContent(appIdentifier: .closet)
                #expect(view.showsDownloadableModels)
            }
        }
    }

    @Test("Availability follows policy changes without recreating the picker")
    func policyChangesAreObserved() {
        withManagerPolicy(disabled: [], filter: .all) { manager in
            var storeResolutions = 0
            let view = CHAISettingsContent(appIdentifier: .liftcoach) {
                storeResolutions += 1
                return LocalModelStore.shared
            }
            #expect(view.showsDownloadableModels)
            manager.disabledProviderIDs.insert("on-device-llm")
            #expect(!view.showsDownloadableModels)
            #expect(view.modelStore == nil)
            manager.disabledProviderIDs.remove("on-device-llm")
            manager.availableProvidersFilter = .cloudProviders
            #expect(!view.showsDownloadableModels)
            #expect(view.modelStore == nil)
            manager.availableProvidersFilter = .onDeviceOnly
            #expect(view.showsDownloadableModels)
            #expect(storeResolutions == 0)
        }
    }

    private func withManagerPolicy(
        disabled: Set<String>, filter: CHAIProviderFilter,
        _ body: (CHAIManager) -> Void
    ) {
        let manager = CHAIManager.shared
        let previousDisabled = manager.disabledProviderIDs
        let previousFilter = manager.availableProvidersFilter
        defer {
            manager.disabledProviderIDs = previousDisabled
            manager.availableProvidersFilter = previousFilter
        }
        manager.disabledProviderIDs = disabled
        manager.availableProvidersFilter = filter
        body(manager)
    }
}
