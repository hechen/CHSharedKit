import Combine
import Foundation
import Testing
@testable import CHSharedKit

// MARK: - 2.18.0 — Locked provider falls back to Apple Intelligence
//
// Chen's report: a user unlocked OpenAI, saved a key, then refunded. The
// picker showed "OpenAI (Locked)" and every AI feature failed, because the
// stored choice kept resolving to the locked provider. A locked choice now
// resolves like a disabled one: Apple Intelligence when available, then an
// unlocked provider, never another locked one. The stored choice and key stay
// untouched, so a restore resumes the user's provider.

/// Records which provider a request reached.
///
/// Main-actor isolated on purpose: a request dispatched from the main actor
/// then completes without suspending, so the fixture's temporary state on
/// the shared manager is never visible to suites running in parallel.
@MainActor
private final class RecordingProvider: CHAIProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportsVision: Bool
    private(set) var requests: [String] = []

    init(id: String, displayName: String, supportsVision: Bool) {
        self.id = id
        self.displayName = displayName
        self.supportsVision = supportsVision
    }

    func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        requests.append(prompt)
        return "\(id) answered"
    }

    func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        guard supportsVision else { throw CHAIError.visionNotSupported }
        requests.append("image: \(prompt)")
        return "\(id) saw"
    }

    /// Records at dispatch; the stream itself is not needed to prove routing.
    func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        requests.append(prompt)
        return AsyncThrowingStream { $0.finish() }
    }

    func validate() async throws -> Bool { true }
}

@MainActor
@Suite("Locked provider falls back to Apple Intelligence (2.18.0)", .serialized)
struct CHAILockedProviderFallbackTests {

    static let paidID = "test-paid-provider"
    static let secondPaidID = "test-second-paid-provider"
    static let freeID = "test-free-provider"
    static let featureID = "test.locked-fallback.feature"
    static let apple = CHAppleIntelligenceProvider.providerID

    fileprivate struct Fixture {
        let manager: CHAIManager
        let gate: MockIAPGate
        let apple: RecordingProvider
        let paid: RecordingProvider
        let secondPaid: RecordingProvider
        let free: RecordingProvider
    }

    /// Isolates the shared manager: only Apple Intelligence (a recording
    /// stand-in, text-only like the real one) and three test providers stay
    /// enabled, `paid` and `secondPaid` are gated, and a locked mock gate is
    /// registered. Everything is restored afterwards.
    private func withFixture(
        appleAvailable: Bool,
        _ body: (Fixture) async throws -> Void
    ) async rethrows {
        let manager = CHAIManager.shared
        let priorActive = manager.activeProviderID
        let priorGated = manager.gatedProviderIDs
        let priorDisabled = manager.disabledProviderIDs
        let priorFilter = manager.availableProvidersFilter
        let priorGate = CHIAPGateRegistry.shared
        let priorAvailability = manager.appleIntelligenceAvailabilityOverride
        let priorContext = manager.contextProvider
        let overrideKey = CHAIFeatureProviderResolver.providerOverrideKey(featureID: Self.featureID)

        let fixture = Fixture(
            manager: manager,
            gate: MockIAPGate(),
            apple: RecordingProvider(id: Self.apple, displayName: "Apple Intelligence", supportsVision: false),
            paid: RecordingProvider(id: Self.paidID, displayName: "Test Paid", supportsVision: true),
            secondPaid: RecordingProvider(id: Self.secondPaidID, displayName: "Second Paid", supportsVision: true),
            free: RecordingProvider(id: Self.freeID, displayName: "Test Free", supportsVision: true)
        )
        let builtInApple = manager._swapProviderForTesting(fixture.apple)
        defer {
            for id in [Self.paidID, Self.secondPaidID, Self.freeID] { manager.unregisterProvider(id) }
            if let builtInApple { manager._swapProviderForTesting(builtInApple) }
            manager.activeProviderID = priorActive
            manager.gatedProviderIDs = priorGated
            manager.disabledProviderIDs = priorDisabled
            manager.availableProvidersFilter = priorFilter
            manager.appleIntelligenceAvailabilityOverride = priorAvailability
            manager.contextProvider = priorContext
            CHIAPGateRegistry.shared = priorGate
            UserDefaults.standard.removeObject(forKey: overrideKey)
        }

        for provider in [fixture.paid, fixture.secondPaid, fixture.free] {
            manager.registerProvider(provider)
        }
        let kept: Set<String> = [Self.apple, Self.paidID, Self.secondPaidID, Self.freeID]
        manager.disabledProviderIDs = Set(manager.allProviders.map(\.id)).subtracting(kept)
        manager.availableProvidersFilter = .all
        manager.appleIntelligenceAvailabilityOverride = appleAvailable
        manager.contextProvider = nil
        manager.gatedProviderIDs = [Self.paidID, Self.secondPaidID]
        CHIAPGateRegistry.shared = fixture.gate
        UserDefaults.standard.removeObject(forKey: overrideKey)

        try await body(fixture)
    }

    // MARK: - Global selection

    @Test("Locked choice resolves to Apple Intelligence without changing the saved choice")
    func lockedChoiceUsesAppleIntelligence() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.paidID
            #expect(f.manager.isLocked(providerID: Self.paidID))

            #expect(f.manager.effectiveActiveProviderID == Self.apple)
            #expect(f.manager.activeProvider?.id == Self.apple)

            let answer = try await f.manager.send(prompt: "plan names")
            #expect(answer == "\(Self.apple) answered")
            _ = try await f.manager.stream(prompt: "coach")

            #expect(f.apple.requests == ["plan names", "coach"])
            #expect(f.paid.requests.isEmpty, "No request may reach a locked provider")
            #expect(f.manager.activeProviderID == Self.paidID)
            #expect(UserDefaults.standard.string(forKey: "clawd_ai_active_provider") == Self.paidID)
        }
    }

    @Test("Unlocking again resumes the saved provider automatically, and a second refund falls back again")
    func unlockResumesSavedChoice() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.paidID
            #expect(f.manager.effectiveActiveProviderID == Self.apple)

            f.gate.hasUnlockedProviders = true   // restore / re-purchase
            #expect(f.manager.effectiveActiveProviderID == Self.paidID)
            let restoredAnswer = try await f.manager.send(prompt: "after restore")
            #expect(restoredAnswer == "\(Self.paidID) answered")
            #expect(f.paid.requests == ["after restore"])

            f.gate.hasUnlockedProviders = false  // refunded again
            #expect(f.manager.effectiveActiveProviderID == Self.apple)
            let refundedAnswer = try await f.manager.send(prompt: "after refund")
            #expect(refundedAnswer == "\(Self.apple) answered")
            #expect(f.paid.requests == ["after restore"])
            #expect(f.manager.activeProviderID == Self.paidID)
        }
    }

    @Test("Without Apple Intelligence the fallback is an unlocked provider")
    func unlockedProviderFallbackWhenAppleUnavailable() async throws {
        try await withFixture(appleAvailable: false) { f in
            f.manager.activeProviderID = Self.paidID
            #expect(f.manager.effectiveActiveProviderID == Self.freeID)
            let answer = try await f.manager.send(prompt: "p")
            #expect(answer == "\(Self.freeID) answered")
            #expect(f.paid.requests.isEmpty)
        }
    }

    @Test("Never falls back to another locked provider; with nothing unlocked the locked error remains")
    func noUnlockedFallbackKeepsLockedError() async {
        await withFixture(appleAvailable: false) { f in
            f.manager.gatedProviderIDs = [Self.paidID, Self.secondPaidID, Self.freeID]
            f.manager.activeProviderID = Self.paidID

            #expect(f.manager.effectiveActiveProviderID == Self.paidID)
            #expect(f.manager.activeProviderLockedFallbackNotice == nil)
            do {
                _ = try await f.manager.send(prompt: "p")
                Issue.record("Expected providerLocked")
            } catch let CHAIError.providerLocked(name) {
                #expect(name == "Test Paid")
            } catch {
                Issue.record("Wrong error: \(error)")
            }
            #expect(f.paid.requests.isEmpty && f.secondPaid.requests.isEmpty && f.free.requests.isEmpty)
        }
    }

    @Test("Image requests use an unlocked vision provider, or report the lock rather than 'vision not supported'")
    func visionRequestsNeedVisionCapableFallback() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.paidID
            let sawMeal = try await f.manager.sendWithVision(prompt: "meal", imageData: Data([1]))
            #expect(sawMeal == "\(Self.freeID) saw")
            #expect(f.paid.requests.isEmpty)

            f.manager.gatedProviderIDs.insert(Self.freeID)
            do {
                _ = try await f.manager.sendWithVision(prompt: "meal", imageData: Data([1]))
                Issue.record("Expected providerLocked")
            } catch let CHAIError.providerLocked(name) {
                #expect(name == "Test Paid")
            } catch {
                Issue.record("Wrong error: \(error)")
            }
            #expect(f.paid.requests.isEmpty && f.apple.requests.isEmpty)
        }
    }

    // MARK: - Per-feature override

    @Test("A locked per-feature override falls back and resumes after unlock, without writing the global choice")
    func lockedFeatureOverrideFallsBack() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.apple
            CHAIFeatureProviderResolver.setProviderOverride(Self.paidID, for: Self.featureID)

            var globalWrites = 0
            let watch = f.manager.$activeProviderID.dropFirst().sink { _ in globalWrites += 1 }
            defer { watch.cancel() }

            #expect(CHAIFeatureProviderResolver.providerID(for: Self.featureID) == Self.apple)
            let lockedAnswer = try await f.manager.send(prompt: "feature", featureID: Self.featureID)
            #expect(lockedAnswer == "\(Self.apple) answered")
            _ = try await f.manager.stream(prompt: "feature stream", featureID: Self.featureID)
            #expect(f.apple.requests == ["feature", "feature stream"])
            let sawPhoto = try await f.manager.sendWithVision(prompt: "photo", imageData: Data([1]), featureID: Self.featureID)
            #expect(sawPhoto == "\(Self.freeID) saw")
            #expect(f.paid.requests.isEmpty)
            #expect(CHAIFeatureProviderResolver.storedOverride(for: Self.featureID) == Self.paidID)
            #expect(f.manager.lockedFallbackNotice(
                storedChoice: Self.paidID,
                resolvedProviderID: CHAIFeatureProviderResolver.providerID(for: Self.featureID)
            ) != nil)

            f.gate.hasUnlockedProviders = true
            #expect(CHAIFeatureProviderResolver.providerID(for: Self.featureID) == Self.paidID)
            let unlockedAnswer = try await f.manager.send(prompt: "unlocked", featureID: Self.featureID)
            #expect(unlockedAnswer == "\(Self.paidID) answered")
            #expect(globalWrites == 0, "Per-feature dispatch must not write the persisted global choice")
        }
    }

    @Test("A locked override whose global choice is also locked still reaches Apple Intelligence")
    func lockedOverrideAndLockedGlobal() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.secondPaidID
            CHAIFeatureProviderResolver.setProviderOverride(Self.paidID, for: Self.featureID)
            #expect(CHAIFeatureProviderResolver.providerID(for: Self.featureID) == Self.apple)
            let answer = try await f.manager.send(prompt: "f", featureID: Self.featureID)
            #expect(answer == "\(Self.apple) answered")
            #expect(f.paid.requests.isEmpty && f.secondPaid.requests.isEmpty)
        }
    }

    // MARK: - Not gated

    @Test("Without active gating nothing changes")
    func notGatedIsUnchanged() async throws {
        try await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.paidID
            CHAIFeatureProviderResolver.setProviderOverride(Self.paidID, for: Self.featureID)

            // Unlocked.
            f.gate.hasUnlockedProviders = true
            #expect(f.manager.effectiveActiveProviderID == Self.paidID)
            #expect(CHAIFeatureProviderResolver.providerID(for: Self.featureID) == Self.paidID)
            #expect(f.manager.activeProviderLockedFallbackNotice == nil)

            // No gate registered.
            f.gate.hasUnlockedProviders = false
            CHIAPGateRegistry.shared = nil
            #expect(f.manager.effectiveActiveProviderID == Self.paidID)

            // Gate registered but the provider is not in the gated set.
            CHIAPGateRegistry.shared = f.gate
            f.manager.gatedProviderIDs = []
            #expect(f.manager.effectiveActiveProviderID == Self.paidID)
            #expect(CHAIFeatureProviderResolver.providerID(for: Self.featureID) == Self.paidID)
            let answer = try await f.manager.send(prompt: "free")
            #expect(answer == "\(Self.paidID) answered")
            #expect(f.apple.requests.isEmpty)
        }
    }

    // MARK: - What the UI shows

    @Test("Labels name the provider in use and the notice names both")
    func uiShowsTheFallback() async {
        await withFixture(appleAvailable: true) { f in
            f.manager.activeProviderID = Self.paidID
            #expect(CHAIActiveProviderLabel.text(for: f.manager) == "Apple Intelligence")
            #expect(CHAIActiveProviderLabelView.label(for: f.manager) == "Apple Intelligence")

            let notice = f.manager.activeProviderLockedFallbackNotice
            #expect(notice?.contains("Test Paid") == true)
            #expect(notice?.contains("Apple Intelligence") == true)

            f.gate.hasUnlockedProviders = true
            #expect(f.manager.activeProviderLockedFallbackNotice == nil)
            #expect(CHAIActiveProviderLabel.text(for: f.manager) == "Test Paid")
        }
    }

    @Test("An entitlement flip on the registered gate re-renders manager observers")
    func gateChangesReachManagerObservers() async {
        await withFixture(appleAvailable: true) { f in
            var changes = 0
            let watch = f.manager.objectWillChange.sink { _ in changes += 1 }
            defer { watch.cancel() }

            f.gate.hasUnlockedProviders = true
            #expect(changes >= 1)

            // Replacing the gate moves the subscription to the new one.
            let replacement = MockIAPGate()
            CHIAPGateRegistry.shared = replacement
            changes = 0
            f.gate.hasUnlockedProviders = false
            #expect(changes == 0, "The old gate is no longer observed")
            replacement.hasUnlockedProviders = true
            #expect(changes >= 1)
        }
    }

    @Test("A gate publishing off the main thread is forwarded without a main-actor assertion")
    func offMainGatePublishIsSafe() async {
        let manager = CHAIManager.shared
        let gate = MockIAPGate()
        var changes = 0
        let watch = manager.objectWillChange.sink { _ in changes += 1 }
        defer { watch.cancel() }

        // Subscribe the manager directly and publish from a plain thread
        // while main waits, so no other suite observes the temporary gate.
        // StoreKit listeners publish off-main exactly like this.
        manager.observeIAPGate(gate)
        Self.unlockOnBackgroundThread(gate)
        manager.observeIAPGate(CHIAPGateRegistry.shared)
        changes = 0

        // The forwarded change was queued on main before this hop.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(changes >= 1)
    }

    /// Blocks the caller until a plain thread has flipped the entitlement.
    nonisolated private static func unlockOnBackgroundThread(_ gate: MockIAPGate) {
        let published = DispatchSemaphore(value: 0)
        Thread {
            gate.hasUnlockedProviders = true
            published.signal()
        }.start()
        published.wait()
    }
}
