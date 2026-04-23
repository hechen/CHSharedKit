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
