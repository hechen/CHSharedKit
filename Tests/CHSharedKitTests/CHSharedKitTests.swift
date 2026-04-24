import Testing
import Combine
import SwiftUI
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

// MARK: - CHAIManager observability

/// These tests guard the invariant that `CHAIManager.activeProviderID` is
/// observable via Combine — the foundation the `CHAIActiveProviderLabel`
/// view and any `@StateObject` / `@ObservedObject` consumer rely on.
///
/// The Build-18 "Settings → AI cell shows stale provider after picker pop"
/// bug was an app-side observation gap, not a CHAIManager regression, but
/// a future refactor that replaces `@Published` with a manually-fired
/// `PassthroughSubject` (or forgets to invoke `objectWillChange` on a
/// computed wrapper) would silently re-open the bug for every consumer.
/// These tests fail fast if that happens.
@MainActor
@Suite("CHAIManager observability")
struct CHAIManagerObservabilityTests {

    @Test("objectWillChange fires when activeProviderID is set to a new value")
    func objectWillChangeFiresOnProviderWrite() async {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        // Pick a different built-in ID so the write is non-trivial.
        let target: String = {
            let candidates = [
                CHOpenAIProvider.providerID,
                CHClaudeProvider.providerID,
                CHCustomEndpointProvider.providerID,
                CHAppleIntelligenceProvider.providerID
            ]
            return candidates.first { $0 != previous } ?? CHOpenAIProvider.providerID
        }()
        defer { manager.activeProviderID = previous }

        // `objectWillChange` fires synchronously before the setter body
        // on @Published wrappers, so we can flip a flag inline and
        // assert after the write.
        var fired = false
        let cancellable = manager.objectWillChange.sink { _ in fired = true }
        defer { cancellable.cancel() }

        manager.activeProviderID = target
        #expect(fired, "Writing activeProviderID must fire objectWillChange — CHAIActiveProviderLabel and every @StateObject consumer depends on it")
        #expect(manager.activeProviderID == target)
    }

    @Test("activeProviderID writes persist to UserDefaults on the same tick")
    func writesPersistSynchronously() {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        let target = previous == CHOpenAIProvider.providerID
            ? CHClaudeProvider.providerID
            : CHOpenAIProvider.providerID
        defer { manager.activeProviderID = previous }

        manager.activeProviderID = target
        // The didSet hook persists synchronously — by the time the
        // setter returns, a fresh read from UserDefaults must already
        // reflect the new value. Apps that cold-launch and re-read from
        // UserDefaults after a picker write rely on this.
        let persisted = UserDefaults.standard.string(forKey: "clawd_ai_active_provider")
        #expect(persisted == target)
    }
}

// MARK: - CHAIActiveProviderLabel resolution

/// Smoke tests for the display-name resolution used by
/// `CHAIActiveProviderLabel`. We can't instantiate a SwiftUI view and
/// read its rendered body in a unit test without UI infrastructure, but
/// we can pin the underlying `manager.activeProvider?.displayName`
/// projection — the label does exactly that and nothing else.
@MainActor
@Suite("CHAIActiveProviderLabel resolution")
struct CHAIActiveProviderLabelTests {

    @Test("Display name reflects the current provider after a write")
    func displayNameFollowsActiveProviderID() {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        defer { manager.activeProviderID = previous }

        manager.activeProviderID = CHOpenAIProvider.providerID
        #expect(manager.activeProvider?.displayName == CHOpenAIProvider().displayName)

        manager.activeProviderID = CHClaudeProvider.providerID
        #expect(manager.activeProvider?.displayName == CHClaudeProvider().displayName)
    }

    @Test("Display name resolves nil for an unknown provider ID")
    func displayNameIsNilForUnknownID() {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        defer { manager.activeProviderID = previous }

        // Simulates a stored provider ID that no longer maps to a
        // registered provider (app shipped without a plugin the user
        // previously had). The label falls back to its `fallback`
        // string in that case.
        manager.activeProviderID = "provider-does-not-exist"
        #expect(manager.activeProvider == nil)
    }

    // MARK: - 2.4.2 — Active Provider summary row

    /// Regression test for the 2.4.2 "Active Provider" summary row that
    /// sits at the top of `CHAISettingsView` / `CHAISettingsContent`.
    /// The row's rendered text comes from
    /// `CHAIActiveProviderLabel.text(for:fallback:)` — the same resolver
    /// every visible "active provider name" surface uses. If someone
    /// accidentally bypasses the resolver (reads the singleton directly,
    /// caches a value in @State, etc.) the row goes stale and these
    /// tests fail loud.
    @Test("text(for:) returns the active provider's displayName")
    func activeProviderTextFollowsActiveID() {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        defer { manager.activeProviderID = previous }

        manager.activeProviderID = CHOpenAIProvider.providerID
        #expect(
            CHAIActiveProviderLabel.text(for: manager)
                == CHOpenAIProvider().displayName
        )

        manager.activeProviderID = CHClaudeProvider.providerID
        #expect(
            CHAIActiveProviderLabel.text(for: manager)
                == CHClaudeProvider().displayName
        )
    }

    @Test("text(for:) returns the configured fallback for an unknown provider ID")
    func activeProviderTextFallsBack() {
        let manager = CHAIManager.shared
        let previous = manager.activeProviderID
        defer { manager.activeProviderID = previous }

        manager.activeProviderID = "does-not-exist"
        #expect(CHAIActiveProviderLabel.text(for: manager) == "None")
        #expect(
            CHAIActiveProviderLabel.text(for: manager, fallback: "Not configured")
                == "Not configured"
        )
    }
}

// MARK: - 2.4.5 — Unified on-device model selection
//
// Regression tests for Chen's Build-257 "three sources diverge" bug:
//
//   - Active Provider cell: "On-Device AI (Qwen 2.5 1.5B)"  ← WRONG
//   - AI Provider row:      "On-Device AI · Phi-3.5 Mini"   ← correct
//   - On-Device section:    "Phi-3.5 Mini · Active"         ← correct
//
// Before 2.4.5, the "Active Provider" label read
// `manager.activeProvider?.displayName`, and `CHLocalLLMProvider`
// composed its displayName as `"On-Device AI (\(modelInfo.displayName))"`
// with modelInfo captured at construction time. Replacing the dict
// entry via `LocalModelStore.setActiveModel(newModel)` would update the
// subtitle and detail sections (both read LocalModelStore.activeModelID
// directly) but the summary label would often keep the previous
// provider's cached `displayName` string, producing the three-way
// divergence.
//
// The 2.4.5 fix: `CHAIManager` owns two @Published properties,
// `activeModelID` and `activeModelDisplayName`, written via
// `setActiveOnDeviceModel(id:displayName:)` and
// `clearActiveOnDeviceModel()`. `CHLocalLLMProvider.displayName` drops
// the model suffix; `CHAIActiveProviderLabel.text(for:)` composes
// `"On-Device AI (<activeModelDisplayName>)"` by reading the manager's
// @Published state, so one write propagates to every observing view.
@MainActor
@Suite("CHAIManager 2.4.5 active on-device model selection")
struct CHAIActiveOnDeviceModelTests {

    /// Matches the constant in CHLocalLLM. Duplicated as a literal here
    /// so the CHSharedKit test target doesn't need a dependency on
    /// CHLocalLLM — the whole point of the 2.4.5 fix is that the
    /// CHSharedKit-side label resolver hardcodes this string too.
    private let onDeviceProviderID = "on-device-llm"

    @Test("setActiveOnDeviceModel writes both @Published properties + fires objectWillChange")
    func setActiveOnDeviceModelFiresObjectWillChange() async {
        let manager = CHAIManager.shared
        let previousID = manager.activeModelID
        let previousName = manager.activeModelDisplayName
        defer {
            if let id = previousID, let name = previousName {
                manager.setActiveOnDeviceModel(id: id, displayName: name)
            } else {
                manager.clearActiveOnDeviceModel()
            }
        }

        var fired = 0
        let cancellable = manager.objectWillChange.sink { _ in fired += 1 }
        defer { cancellable.cancel() }

        manager.setActiveOnDeviceModel(id: "qwen-2.5-1.5b", displayName: "Qwen 2.5 1.5B")
        #expect(manager.activeModelID == "qwen-2.5-1.5b")
        #expect(manager.activeModelDisplayName == "Qwen 2.5 1.5B")
        // Two @Published writes — each fires objectWillChange.
        #expect(fired >= 1, "setActiveOnDeviceModel must fire objectWillChange at least once")

        // The writes persist synchronously — a fresh UserDefaults read
        // after the call must reflect the new values.
        let persistedID = UserDefaults.standard.string(forKey: "clawd_ai_active_model_id")
        let persistedName = UserDefaults.standard.string(forKey: "clawd_ai_active_model_name")
        #expect(persistedID == "qwen-2.5-1.5b")
        #expect(persistedName == "Qwen 2.5 1.5B")
    }

    @Test("clearActiveOnDeviceModel nils both properties")
    func clearActiveOnDeviceModel() {
        let manager = CHAIManager.shared
        let previousID = manager.activeModelID
        let previousName = manager.activeModelDisplayName
        defer {
            if let id = previousID, let name = previousName {
                manager.setActiveOnDeviceModel(id: id, displayName: name)
            } else {
                manager.clearActiveOnDeviceModel()
            }
        }

        manager.setActiveOnDeviceModel(id: "phi-3.5-mini", displayName: "Phi-3.5 Mini")
        #expect(manager.activeModelID != nil)

        manager.clearActiveOnDeviceModel()
        #expect(manager.activeModelID == nil)
        #expect(manager.activeModelDisplayName == nil)
    }

    /// **The exact Chen scenario.** Set Qwen → switch to Phi → assert the
    /// "Active Provider" label text. Before 2.4.5 this would return
    /// "On-Device AI (Qwen 2.5 1.5B)" (the baked-in displayName on the
    /// first-registered provider instance); 2.4.5 returns the composed
    /// "On-Device AI (Phi-3.5 Mini)".
    @Test("Chen scenario — switching active model flips the composed label")
    func chenScenario_switchingModelFlipsLabel() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        let previousID = manager.activeModelID
        let previousName = manager.activeModelDisplayName
        defer {
            manager.activeProviderID = previousProvider
            if let id = previousID, let name = previousName {
                manager.setActiveOnDeviceModel(id: id, displayName: name)
            } else {
                manager.clearActiveOnDeviceModel()
            }
        }

        // Register a stub on-device provider so `activeProvider` resolves —
        // without it, the label would short-circuit to the fallback.
        manager.registerProvider(StubOnDeviceProvider())
        manager.activeProviderID = onDeviceProviderID

        // Initial selection: Qwen.
        manager.setActiveOnDeviceModel(id: "qwen-2.5-1.5b", displayName: "Qwen 2.5 1.5B")
        #expect(
            CHAIActiveProviderLabel.text(for: manager)
                == "On-Device AI (Qwen 2.5 1.5B)"
        )

        // User switches to Phi in the picker — setActiveModel writes
        // through to setActiveOnDeviceModel. (In the live app this is
        // called from LocalModelStore.setActiveModel; here we invoke the
        // manager method directly since CHLocalLLM lives in another
        // target.)
        manager.setActiveOnDeviceModel(id: "phi-3.5-mini", displayName: "Phi-3.5 Mini")

        // The label must reflect Phi — no stale Qwen suffix.
        #expect(
            CHAIActiveProviderLabel.text(for: manager)
                == "On-Device AI (Phi-3.5 Mini)",
            "Active Provider label must reflect the latest selection — this is the Chen Build-257 regression"
        )
    }

    /// **2.4.7 regression guard.** Cold-launch path: the host SDK
    /// (`LocalModelStore.init`) restores `activeProviderID == "on-device-llm"`
    /// from UserDefaults and mirrors the persisted model into
    /// `setActiveOnDeviceModel(id:displayName:)`, BUT must also call
    /// `registerProvider(CHLocalLLMProvider(...))` so the dict has an
    /// entry for the persisted id. Skipping the registration was the
    /// 2.4.5/2.4.6 gap — `providers` is not @Published, so a later
    /// registration cannot un-stick the "Active Provider" label once it
    /// has rendered "None".
    ///
    /// Test simulates the post-2.4.7 cold-launch state: register the
    /// on-device provider stub, set the persisted IDs and model name,
    /// assert `activeProvider` resolves and the label composes the
    /// model suffix. If a future refactor drops the 2.4.7 registration
    /// from `LocalModelStore.init`, this test still passes — it only
    /// pins the contract that the host SDK must honor. The actual
    /// `LocalModelStore.init` path is verified by the host CHLocalLLM
    /// module's integration tests + on-sim verification.
    @Test("2.4.7 cold-launch — host registration path produces a non-nil activeProvider")
    func coldLaunchRegistrationProducesNonNilProvider() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        let previousID = manager.activeModelID
        let previousName = manager.activeModelDisplayName
        defer {
            manager.activeProviderID = previousProvider
            if let id = previousID, let name = previousName {
                manager.setActiveOnDeviceModel(id: id, displayName: name)
            } else {
                manager.clearActiveOnDeviceModel()
            }
        }

        // Simulate the 2.4.7 LocalModelStore.init sequence: register
        // first, then mirror persisted selection.
        manager.registerProvider(StubOnDeviceProvider())
        manager.activeProviderID = onDeviceProviderID
        manager.setActiveOnDeviceModel(
            id: "deepseek-r1-1.5b",
            displayName: "DeepSeek-R1 1.5B"
        )

        // The bug Chen reported: this used to resolve to nil because
        // LocalModelStore.init mirrored the model name but didn't
        // register the provider, leaving providers["on-device-llm"]
        // unpopulated. The 2.4.7 fix in LocalModelStore.swift adds the
        // missing `registerProvider()` call alongside the existing
        // `setActiveOnDeviceModel()` call.
        #expect(
            manager.activeProvider != nil,
            "Active provider must resolve on cold launch when host SDK registers + restores"
        )
        #expect(
            CHAIActiveProviderLabel.text(for: manager)
                == "On-Device AI (DeepSeek-R1 1.5B)",
            "Cold-launch label must compose provider + model suffix from persisted state"
        )
    }

    @Test("Label falls back to bare provider displayName when no model selected")
    func labelOmitsSuffixWhenModelCleared() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        let previousID = manager.activeModelID
        let previousName = manager.activeModelDisplayName
        defer {
            manager.activeProviderID = previousProvider
            if let id = previousID, let name = previousName {
                manager.setActiveOnDeviceModel(id: id, displayName: name)
            } else {
                manager.clearActiveOnDeviceModel()
            }
        }

        manager.registerProvider(StubOnDeviceProvider())
        manager.activeProviderID = onDeviceProviderID
        manager.clearActiveOnDeviceModel()

        // Bare provider displayName — no "(nil)" or "()" leaked into UI.
        #expect(CHAIActiveProviderLabel.text(for: manager) == "On-Device AI")
    }
}

/// Minimal in-test stub that mirrors the CHLocalLLM module's
/// `CHLocalLLMProvider.id == "on-device-llm"` so the 2.4.5 label
/// composition branch activates. Its `displayName` is the bare
/// "On-Device AI" string — matches the post-2.4.5 production provider.
private struct StubOnDeviceProvider: CHAIProvider, Sendable {
    var id: String { "on-device-llm" }
    var displayName: String { "On-Device AI" }
    var supportsVision: Bool { false }
    // `category` is inferred from `id` via the extension in
    // CHAIProviderFilter.swift — "on-device-llm" → .onDeviceLocal, so no
    // explicit override needed here.

    func sendMessage(prompt: String, systemPrompt: String?) async throws -> String { "" }
    func validate() async throws -> Bool { true }
    func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
