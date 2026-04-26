import Testing
import Combine
import SwiftUI
import Foundation
@testable import CHSharedKit
@testable import CHLocalLLM

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

// MARK: - 2.4.8 — CHAIActiveProviderLabelView resolution
//
// Pins the resolver shape consumers (closet-ios SettingsView.swift:357-363,
// GymLog SettingsView_GL.swift:23, EatWisely AIService.swift:176) hand-rolled
// inline. The view is a bare-Text wrapper around `label(for:)` plus an
// @ObservedObject binding to CHAIManager.shared, so test coverage on the
// resolver is sufficient — SwiftUI body re-evaluation is the framework's
// concern once the binding is in place, and the
// `CHAIManager observability` suite above already pins that
// `objectWillChange` fires on the writes the view observes.
@MainActor
@Suite("CHAIActiveProviderLabelView resolution (2.4.8)")
struct CHAIActiveProviderLabelViewTests {

    private let onDeviceProviderID = "on-device-llm"

    @Test("Cloud provider set — label is the provider's displayName")
    func cloudProviderRendersDisplayName() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        defer { manager.activeProviderID = previousProvider }

        manager.activeProviderID = CHOpenAIProvider.providerID
        #expect(CHAIActiveProviderLabelView.label(for: manager) == "OpenAI")

        manager.activeProviderID = CHClaudeProvider.providerID
        #expect(CHAIActiveProviderLabelView.label(for: manager) == "Claude (Anthropic)")
    }

    @Test("On-device with model — label is 'On-Device AI · <model>'")
    func onDeviceWithModelComposesDotSeparator() {
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
        manager.setActiveOnDeviceModel(id: "phi-3.5-mini", displayName: "Phi-3.5 Mini")
        #expect(
            CHAIActiveProviderLabelView.label(for: manager)
                == "On-Device AI · Phi-3.5 Mini"
        )
    }

    @Test("On-device without model — label is bare 'On-Device AI'")
    func onDeviceWithoutModelOmitsSuffix() {
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
        #expect(CHAIActiveProviderLabelView.label(for: manager) == "On-Device AI")
    }

    @Test("Unknown provider ID — label is 'Not Set'")
    func unknownProviderFallsBackToNotSet() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        defer { manager.activeProviderID = previousProvider }

        manager.activeProviderID = "provider-does-not-exist"
        #expect(CHAIActiveProviderLabelView.label(for: manager) == "Not Set")
    }
}

// MARK: - 2.4.8 — CHAITokenStore per-provider isolation
//
// Pins the per-provider keychain isolation contract: writing a token
// for provider A must not affect provider B's slot, and switching the
// CHAIManager active provider back to A must surface A's token (not
// the value that was overwriting it pre-2.4.8).
//
// Tests use `CHAITokenStore._testOverride` so they don't touch the
// real keychain — `swift test` on macOS without entitlements often
// returns errSecMissingEntitlement on `SecItemAdd`, and we don't want
// CI flakiness here.
@MainActor
@Suite("CHAITokenStore per-provider isolation (2.4.8)")
struct CHAITokenStoreTests {

    /// Install the in-memory backing for each test and reset after.
    /// `@MainActor` keeps the suite serialized so the static override
    /// doesn't race between tests.
    private func withInMemoryStore(_ body: (CHAITokenStore.TestBacking) -> Void) {
        let backing = CHAITokenStore.TestBacking()
        CHAITokenStore._testOverride = backing
        defer { CHAITokenStore._testOverride = nil }
        body(backing)
    }

    @Test("setToken / token round-trips per provider")
    func roundTripPerProvider() {
        withInMemoryStore { _ in
            CHAITokenStore.setToken("sk-openai-A", for: "openai")
            CHAITokenStore.setToken("sk-claude-B", for: "claude")
            #expect(CHAITokenStore.token(for: "openai") == "sk-openai-A")
            #expect(CHAITokenStore.token(for: "claude") == "sk-claude-B")
        }
    }

    @Test("Setting provider B's token does not overwrite provider A's slot")
    func writingBLeavesAIntact() {
        withInMemoryStore { _ in
            CHAITokenStore.setToken("sk-openai-A", for: "openai")
            CHAITokenStore.setToken("sk-claude-B", for: "claude")
            // Mutate B again — the bug spec scenario.
            CHAITokenStore.setToken("sk-claude-B-rotated", for: "claude")
            #expect(CHAITokenStore.token(for: "openai") == "sk-openai-A")
            #expect(CHAITokenStore.token(for: "claude") == "sk-claude-B-rotated")
        }
    }

    @Test("Chen scenario — pick OpenAI → switch to On-Device → switch back to OpenAI keeps the token")
    func chenScenarioTokenSurvivesProviderSwitch() {
        let manager = CHAIManager.shared
        let previousProvider = manager.activeProviderID
        defer { manager.activeProviderID = previousProvider }

        withInMemoryStore { _ in
            // 1. Pick OpenAI, enter token.
            manager.activeProviderID = CHOpenAIProvider.providerID
            CHOpenAIProvider.apiKey = "sk-openai-CHEN"
            #expect(CHOpenAIProvider.apiKey == "sk-openai-CHEN")

            // 2. Switch to on-device — token field for OpenAI no longer
            // bound, but the keychain entry must survive.
            manager.activeProviderID = "on-device-llm"

            // 3. Switch back to OpenAI — token must still be there.
            manager.activeProviderID = CHOpenAIProvider.providerID
            #expect(
                CHOpenAIProvider.apiKey == "sk-openai-CHEN",
                "OpenAI token must survive provider-switch round-trip — this is the 2.4.8 keychain isolation contract"
            )
        }
    }

    @Test("deleteToken removes the slot but leaves siblings intact")
    func deleteIsolatesPerProvider() {
        withInMemoryStore { _ in
            CHAITokenStore.setToken("sk-openai", for: "openai")
            CHAITokenStore.setToken("sk-claude", for: "claude")
            CHAITokenStore.deleteToken(for: "openai")
            #expect(CHAITokenStore.token(for: "openai") == nil)
            #expect(CHAITokenStore.token(for: "claude") == "sk-claude")
        }
    }

    @Test("setToken(nil) is equivalent to delete")
    func setNilDeletes() {
        withInMemoryStore { _ in
            CHAITokenStore.setToken("sk-openai", for: "openai")
            CHAITokenStore.setToken(nil, for: "openai")
            #expect(CHAITokenStore.token(for: "openai") == nil)
        }
    }

    @Test("setToken(\"\") is equivalent to delete")
    func setEmptyDeletes() {
        withInMemoryStore { _ in
            CHAITokenStore.setToken("sk-openai", for: "openai")
            CHAITokenStore.setToken("", for: "openai")
            #expect(CHAITokenStore.token(for: "openai") == nil)
        }
    }

    @Test("account string embeds bundle ID and provider ID")
    func accountFormatPinsBundleAndProviderID() {
        let account = CHAITokenStore.account(for: "openai", bundleID: "com.chen.ClosetExample")
        #expect(account == "com.chen.ClosetExample.openai")
    }

    @Test("Different bundle IDs get isolated slots")
    func bundleIDIsolation() {
        withInMemoryStore { backing in
            // Simulate two apps: write directly via the backing using
            // distinct bundle IDs.
            backing.write(
                value: "sk-closet",
                service: CHAITokenStore.service,
                account: CHAITokenStore.account(for: "openai", bundleID: "com.chen.Closet")
            )
            backing.write(
                value: "sk-eatwisely",
                service: CHAITokenStore.service,
                account: CHAITokenStore.account(for: "openai", bundleID: "com.chen.EatWisely")
            )

            #expect(
                backing.read(
                    service: CHAITokenStore.service,
                    account: CHAITokenStore.account(for: "openai", bundleID: "com.chen.Closet")
                ) == "sk-closet"
            )
            #expect(
                backing.read(
                    service: CHAITokenStore.service,
                    account: CHAITokenStore.account(for: "openai", bundleID: "com.chen.EatWisely")
                ) == "sk-eatwisely"
            )
        }
    }
}

// MARK: - 2.5.0 — MLX repo-id parsing

@Suite("CHLocalMLXRepoID")
struct CHLocalMLXRepoIDTests {

    @Test("Parses canonical mlx-community repo URL")
    func parsesCanonicalRepoURL() {
        let url = URL(string: "https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit")!
        #expect(CHLocalMLXRepoID.from(url) == "mlx-community/Qwen2.5-3B-Instruct-4bit")
    }

    @Test("Parses repo URL with trailing slash")
    func parsesTrailingSlash() {
        let url = URL(string: "https://huggingface.co/mlx-community/Qwen2-VL-2B-Instruct-4bit/")!
        #expect(CHLocalMLXRepoID.from(url) == "mlx-community/Qwen2-VL-2B-Instruct-4bit")
    }

    @Test("Stops at /resolve/ path component (file-view URL)")
    func stopsAtResolvePath() {
        let url = URL(string: "https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit/resolve/main/config.json")!
        #expect(CHLocalMLXRepoID.from(url) == "mlx-community/Qwen2.5-3B-Instruct-4bit")
    }

    @Test("Stops at /tree/ path component")
    func stopsAtTreePath() {
        let url = URL(string: "https://huggingface.co/mlx-community/Phi-3.5-mini-instruct-4bit/tree/main")!
        #expect(CHLocalMLXRepoID.from(url) == "mlx-community/Phi-3.5-mini-instruct-4bit")
    }

    @Test("Returns nil for non-Hugging-Face URLs")
    func nilForNonHF() {
        let url = URL(string: "https://example.com/foo/bar")!
        #expect(CHLocalMLXRepoID.from(url) == nil)
    }

    @Test("Returns nil for HF URL with only one path segment")
    func nilForBareOrgPath() {
        let url = URL(string: "https://huggingface.co/mlx-community")!
        #expect(CHLocalMLXRepoID.from(url) == nil)
    }
}

// MARK: - 2.5.0 — Cold-start latency estimate

@Suite("CHLocalMLXColdStart")
struct CHLocalMLXColdStartTests {

    @Test("Estimate is monotonic in model size")
    func monotonicInSize() {
        let small = CHLocalMLXColdStart.estimate(forBytes: 280_000_000)   // 280 MB
        let mid   = CHLocalMLXColdStart.estimate(forBytes: 1_700_000_000) // 1.7 GB
        let big   = CHLocalMLXColdStart.estimate(forBytes: 3_500_000_000) // 3.5 GB
        #expect(small <= mid)
        #expect(mid <= big)
    }

    @Test("Tiny models still get the 1.5 s floor")
    func tinyModelGetsFloor() {
        let tiny = CHLocalMLXColdStart.estimate(forBytes: 50_000_000) // 50 MB
        #expect(tiny >= 1.5)
    }

    @Test("3 GB model is at least 5 s")
    func multiGBHasReasonableEstimate() {
        let est = CHLocalMLXColdStart.estimate(forBytes: 3_000_000_000)
        #expect(est >= 5.0)
    }
}

// MARK: - 2.5.0 — Catalog & vision capability

@Suite("LocalModelCatalog (MLX 2.5.0)")
struct LocalModelCatalogMLXTests {

    @Test("Default model is Qwen 2.5 3B per 2.5.0 spec")
    func defaultIsQwen3B() {
        #expect(LocalModelCatalog.default.id == "qwen2.5-3b-q4km")
    }

    @Test("Every catalog entry has a parseable Hugging Face repo id")
    func everyEntryParsesAsRepo() {
        for model in LocalModelCatalog.all {
            let repoID = CHLocalMLXRepoID.from(model.downloadURL)
            #expect(repoID != nil, "\(model.id) downloadURL must parse: \(model.downloadURL)")
            // mlx-community is the canonical org for the 2.5.0 catalog,
            // but custom forks (e.g. Microsoft's official Phi-3 4-bit)
            // use other orgs — just check the form is org/name.
            #expect(repoID?.split(separator: "/").count == 2)
        }
    }

    @Test("Vision-capable check matches Qwen2-VL only")
    func visionCapabilityMatchesCatalog() {
        #expect(LocalModelCatalog.isVisionCapable("qwen2-vl-2b-q4"))
        #expect(!LocalModelCatalog.isVisionCapable("qwen2.5-3b-q4km"))
        #expect(!LocalModelCatalog.isVisionCapable("phi3.5-mini-q4km"))
        #expect(!LocalModelCatalog.isVisionCapable("does-not-exist"))
    }

    @Test("All 2.4.x catalog ids are still present (recommendation/taskHint switches keep resolving)")
    func legacyIdsPreserved() {
        let legacyIDs: Set<String> = [
            "qwen2.5-0.5b-q4km", "qwen2.5-1.5b-q4km", "qwen2.5-3b-q4km",
            "llama3.2-1b-q4km", "llama3.2-3b-q4km",
            "phi3-mini-4k-q4", "phi3.5-mini-q4km",
            "gemma2-2b-q4km", "smollm2-1.7b-q4km", "deepseek-r1-1.5b-q4km",
        ]
        let presentIDs = Set(LocalModelCatalog.all.map(\.id))
        for id in legacyIDs {
            #expect(presentIDs.contains(id), "Legacy id \(id) missing — recommendationScore/taskHint switches will break for it")
        }
    }
}

// MARK: - 2.5.0 — Storage layout

@Suite("CHLocalMLXStorage")
struct CHLocalMLXStorageTests {

    @Test("Local directory layout matches HubApi convention (<base>/models/<repo>)")
    func localDirectoryLayout() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        defer { CHLocalMLXStorage.baseDirectory = originalBase }

        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHLocalMLXStorageTest-\(UUID().uuidString)", isDirectory: true)
        CHLocalMLXStorage.baseDirectory = tmpBase

        let dir = CHLocalMLXStorage.localDirectory(forRepoID: "mlx-community/Qwen2.5-3B-Instruct-4bit")
        let relative = dir.path.replacingOccurrences(of: tmpBase.path, with: "")
        #expect(relative == "/models/mlx-community/Qwen2.5-3B-Instruct-4bit")
    }
}

// MARK: - 2.5.0 — Error cases

@Suite("CHAIError 2.5.0 cases")
struct CHAIError250Tests {

    @Test("modelLoadFailed surfaces its associated message")
    func modelLoadFailedMessage() {
        let err = CHAIError.modelLoadFailed("Insufficient memory — close other apps and try again.")
        #expect(err.errorDescription == "Insufficient memory — close other apps and try again.")
    }

    @Test("unsupportedPlatform has a stable user-facing message")
    func unsupportedPlatformMessage() {
        let err = CHAIError.unsupportedPlatform
        #expect(err.errorDescription == "On-device AI is not supported on this platform.")
    }
}

// MARK: - 2.5.0 — LocalModelStore preserved API

@MainActor
@Suite("LocalModelStore preserved API (2.5.0)")
struct LocalModelStoreAPITests {

    @Test("modelURL routes catalog entries through CHLocalMLXStorage layout")
    func modelURLLayout() {
        let store = LocalModelStore.shared
        let qwen3B = LocalModelCatalog.qwen2_5_3B
        let url = store.modelURL(for: qwen3B)
        #expect(url.path.contains("models/mlx-community/Qwen2.5-3B-Instruct-4bit"))
    }

    @Test("isInstalled is false when the model directory doesn't exist")
    func isInstalledFalseForMissing() {
        let store = LocalModelStore.shared
        let qwen3B = LocalModelCatalog.qwen2_5_3B
        // Smoke-test runs may have downloaded this; only assert when missing.
        if !FileManager.default.fileExists(atPath: store.modelURL(for: qwen3B).path) {
            #expect(!store.isInstalled(qwen3B))
        }
    }

    @Test("Custom model registration surfaces it in allModels")
    func customModelRegistration() {
        let store = LocalModelStore.shared
        let id = "test-custom-\(UUID().uuidString)"
        let url = URL(string: "https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct-4bit")!
        store.addCustomModel(
            id: id,
            displayName: "Test Custom",
            downloadURL: url,
            sizeBytes: 1_000_000_000,
            chatTemplate: .chatML
        )
        defer {
            // No public delete by id; deleteModel removes the entry too.
            if let entry = store.customModels.first(where: { $0.id == id }) {
                store.deleteModel(store.localModelInfo(for: entry))
            }
        }
        let ids = store.allModels.map(\.id)
        #expect(ids.contains(id))
    }
}

// MARK: - 2.5.3 — P0 storage path stability

@Suite("CHLocalMLXStorage 2.5.3 (P0 fix)", .serialized)
struct CHLocalMLXStorage253Tests {

    @Test("baseDirectory points at Application Support, never the App Group container")
    func baseDirectoryIsApplicationSupport() {
        let path = CHLocalMLXStorage.baseDirectory.path
        #expect(path.contains("Application Support"))
        #expect(!path.contains("Containers/Shared/AppGroup"))
    }

    @Test("baseDirectory has no version components")
    func baseDirectoryHasNoVersionComponents() {
        let path = CHLocalMLXStorage.baseDirectory.path
        // Sanity guard against accidental Bundle.main.shortVersionString
        // creeping into the path. Always bare "<App Support>/CHSharedKit/".
        #expect(path.hasSuffix("/CHSharedKit") || path.hasSuffix("/CHSharedKit/"))
    }

    @Test("resolvedDirectory returns canonical when canonical has the snapshot")
    func resolvedReturnsCanonicalWhenPresent() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        let originalLegacy = CHLocalMLXStorage.legacyBaseDirectories
        defer {
            CHLocalMLXStorage.baseDirectory = originalBase
            CHLocalMLXStorage.legacyBaseDirectories = originalLegacy
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHStorage253-\(UUID().uuidString)", isDirectory: true)
        CHLocalMLXStorage.baseDirectory = tmp.appendingPathComponent("canonical")
        CHLocalMLXStorage.legacyBaseDirectories = [tmp.appendingPathComponent("legacy")]

        let canonicalDir = CHLocalMLXStorage.localDirectory(forRepoID: "mlx-community/Test-1B")
        try? FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: canonicalDir.appendingPathComponent("config.json"))
        try? Data().write(to: canonicalDir.appendingPathComponent("model.safetensors"))

        let resolved = CHLocalMLXStorage.resolvedDirectory(forRepoID: "mlx-community/Test-1B")
        #expect(resolved.standardizedFileURL == canonicalDir.standardizedFileURL)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("resolvedDirectory falls back to legacy when canonical is missing but legacy has it")
    func resolvedFallsBackToLegacy() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        let originalLegacy = CHLocalMLXStorage.legacyBaseDirectories
        defer {
            CHLocalMLXStorage.baseDirectory = originalBase
            CHLocalMLXStorage.legacyBaseDirectories = originalLegacy
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHStorage253-\(UUID().uuidString)", isDirectory: true)
        let canonical = tmp.appendingPathComponent("canonical")
        let legacy = tmp.appendingPathComponent("legacy")
        CHLocalMLXStorage.baseDirectory = canonical
        CHLocalMLXStorage.legacyBaseDirectories = [legacy]

        let legacyDir = legacy
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx-community/Test-1B", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: legacyDir.appendingPathComponent("config.json"))
        try? Data().write(to: legacyDir.appendingPathComponent("model.safetensors"))

        let resolved = CHLocalMLXStorage.resolvedDirectory(forRepoID: "mlx-community/Test-1B")
        #expect(
            resolved.standardizedFileURL == legacyDir.standardizedFileURL,
            "2.5.3 must read from legacy App Group container so 2.5.0–2.5.2 downloads keep working"
        )
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("resolvedDirectory returns canonical (write target) when nothing is on disk")
    func resolvedReturnsCanonicalWhenAbsent() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        let originalLegacy = CHLocalMLXStorage.legacyBaseDirectories
        defer {
            CHLocalMLXStorage.baseDirectory = originalBase
            CHLocalMLXStorage.legacyBaseDirectories = originalLegacy
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHStorage253-\(UUID().uuidString)", isDirectory: true)
        CHLocalMLXStorage.baseDirectory = tmp.appendingPathComponent("canonical")
        CHLocalMLXStorage.legacyBaseDirectories = [tmp.appendingPathComponent("legacy")]

        let resolved = CHLocalMLXStorage.resolvedDirectory(forRepoID: "mlx-community/Nothing-Here")
        let canonical = CHLocalMLXStorage.localDirectory(forRepoID: "mlx-community/Nothing-Here")
        #expect(resolved.standardizedFileURL == canonical.standardizedFileURL)
    }

    @Test("isSnapshotPresent requires config.json + at least one .safetensors file")
    func snapshotPresenceHeuristic() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHStorage253-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(!CHLocalMLXStorage.isSnapshotPresent(at: tmp))

        try? Data("{}".utf8).write(to: tmp.appendingPathComponent("config.json"))
        #expect(!CHLocalMLXStorage.isSnapshotPresent(at: tmp))

        try? Data().write(to: tmp.appendingPathComponent("model.safetensors"))
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: tmp))
    }
}

// MARK: - 2.5.3 — verifyOnLaunch storage report

@MainActor
@Suite("CHLocalModelStore.verifyOnLaunch (2.5.3)", .serialized)
struct VerifyOnLaunchTests {

    @Test("CHLocalModelStore typealias resolves to LocalModelStore")
    func typealiasResolves() {
        let store: CHLocalModelStore = LocalModelStore.shared
        _ = store
    }

    @Test("verifyOnLaunch reports zero models on a fresh canonical directory")
    func zeroModelsOnFreshDir() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        let originalLegacy = CHLocalMLXStorage.legacyBaseDirectories
        defer {
            CHLocalMLXStorage.baseDirectory = originalBase
            CHLocalMLXStorage.legacyBaseDirectories = originalLegacy
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verifyOnLaunchTest-\(UUID().uuidString)", isDirectory: true)
        CHLocalMLXStorage.baseDirectory = tmp
        CHLocalMLXStorage.legacyBaseDirectories = []

        let report = CHLocalModelStore.verifyOnLaunch()
        #expect(report.installedModels.isEmpty)
        #expect(report.totalBytes == 0)
        #expect(report.summary.contains("0 models installed"))
    }

    @Test("verifyOnLaunch finds a model in legacy directory and flags isLegacyLocation")
    func findsLegacyModel() {
        let originalBase = CHLocalMLXStorage.baseDirectory
        let originalLegacy = CHLocalMLXStorage.legacyBaseDirectories
        defer {
            CHLocalMLXStorage.baseDirectory = originalBase
            CHLocalMLXStorage.legacyBaseDirectories = originalLegacy
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verifyOnLaunchTest-\(UUID().uuidString)", isDirectory: true)
        CHLocalMLXStorage.baseDirectory = tmp.appendingPathComponent("canonical")
        CHLocalMLXStorage.legacyBaseDirectories = [tmp.appendingPathComponent("legacy")]

        let qwen = LocalModelCatalog.qwen2_5_3B
        let repoID = CHLocalMLXRepoID.from(qwen.downloadURL)!
        let legacyDir = tmp.appendingPathComponent("legacy")
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: legacyDir.appendingPathComponent("config.json"))
        try? Data(repeating: 0, count: 1024).write(to: legacyDir.appendingPathComponent("model.safetensors"))

        let report = CHLocalModelStore.verifyOnLaunch()
        let qwenEntry = report.installedModels.first { $0.id == qwen.id }
        #expect(qwenEntry != nil, "Qwen 2.5 3B planted in legacy dir should be detected")
        #expect(qwenEntry?.isLegacyLocation == true, "Legacy-located models must be flagged as such")
        #expect(qwenEntry?.sizeBytes == Int64(1024 + 2)) // safetensors + config.json ("{}" = 2 bytes)

        try? FileManager.default.removeItem(at: tmp)
    }
}
