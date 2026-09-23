import Testing
import Combine
import Foundation
@testable import CHSharedKit
@testable import CHLocalLLM

/// 2.16.0 — Restore used to report only failures, so a successful restore
/// that found nothing looked identical to a tap that did nothing. These pin
/// the outcome derivation the picker now shows.
@Suite("Restore outcome")
struct CHAIRestoreOutcomeTests {

    @Test("Locked before, unlocked after: the restore did something")
    func restoredWhenUnlockAppears() {
        #expect(CHAIRestoreOutcome.after(wasUnlocked: false, isUnlocked: true) == .restored)
    }

    @Test("Already unlocked: the restore confirms rather than restores")
    func confirmedWhenAlreadyOwned() {
        #expect(CHAIRestoreOutcome.after(wasUnlocked: true, isUnlocked: true) == .confirmed)
    }

    @Test("Still locked: say there was nothing, instead of staying silent")
    func nothingWhenStillLocked() {
        #expect(CHAIRestoreOutcome.after(wasUnlocked: false, isUnlocked: false) == .nothingToRestore)
    }

    /// A restore can only confirm entitlement, never remove it — that path
    /// is refund/revocation, which reaches the gate independently. If the
    /// unlock ever did vanish across a restore, "nothing to restore" is the
    /// honest reading, not a success.
    @Test("Unlock lost across a restore is not reported as success")
    func lostUnlockIsNotPositive() {
        let outcome = CHAIRestoreOutcome.after(wasUnlocked: true, isUnlocked: false)
        #expect(outcome == .nothingToRestore)
        #expect(!outcome.isPositive)
    }

    @Test("Every outcome has non-empty copy")
    func everyOutcomeHasCopy() {
        for outcome in [CHAIRestoreOutcome.restored, .confirmed, .nothingToRestore] {
            #expect(!outcome.message.isEmpty)
        }
    }

    @Test("Only the two successful outcomes read as good news")
    func positivity() {
        #expect(CHAIRestoreOutcome.restored.isPositive)
        #expect(CHAIRestoreOutcome.confirmed.isPositive)
        #expect(!CHAIRestoreOutcome.nothingToRestore.isPositive)
    }
}

@Suite("Ownership card")
struct CHAIOwnershipCardTests {

    @Test("A host product name leads the title")
    func productNameLeads() {
        let title = CHAIUnlockStrings.ownedTitle(productName: "AI Pro")
        #expect(title.hasPrefix("AI Pro"))
    }

    /// The kit is shared, so a host that supplies no name must not inherit
    /// another app's branding.
    @Test("No product name falls back to generic wording")
    func genericFallback() {
        let generic = CHAIUnlockStrings.ownedTitle(productName: nil)
        #expect(!generic.isEmpty)
        #expect(!generic.contains("AI Pro"))
        #expect(CHAIUnlockStrings.ownedTitle(productName: "") == generic)
    }

    @Test("Restore has a full label and an accessibility hint")
    func restoreIsLabelled() {
        #expect(!CHAIUnlockStrings.restorePurchases.isEmpty)
        #expect(!CHAIUnlockStrings.restoreHint.isEmpty)
    }

    /// The old Restore was a caption-size plain link that was hard to hit
    /// with a pointer. Mac `.regular` buttons are notably smaller than iOS.
    @Test("Purchase actions use a large control size on the Mac")
    func macControlSize() {
        #if os(macOS)
        #expect(CHAIUnlockStrings.actionControlSize == .large)
        #else
        #expect(CHAIUnlockStrings.actionControlSize == .regular)
        #endif
    }
}

@Suite("Gate product name")
@MainActor
struct CHIAPGateProductNameTests {

    final class MinimalGate: CHIAPGate {
        let objectWillChange = ObservableObjectPublisher()
        var hasUnlockedProviders = false
        var unlockPriceLabel: String? = nil
        func startPurchase() async throws {}
        func restorePurchases() async throws {}
    }

    final class NamedGate: CHIAPGate {
        let objectWillChange = ObservableObjectPublisher()
        var hasUnlockedProviders = true
        var unlockPriceLabel: String? = "$2.99"
        var unlockProductDisplayName: String? { "AI Pro" }
        func startPurchase() async throws {}
        func restorePurchases() async throws {}
    }

    /// Existing conformers across the portfolio do not implement the new
    /// requirement. They must keep compiling and read as unnamed.
    @Test("Conformers that predate 2.16.0 default to no name")
    func defaultIsNil() {
        let gate: any CHIAPGate = MinimalGate()
        #expect(gate.unlockProductDisplayName == nil)
    }

    /// A requirement with an extension default must dispatch dynamically;
    /// the picker reads the name through `any CHIAPGate`.
    @Test("A conformer's name survives existential dispatch")
    func namedDispatches() {
        let gate: any CHIAPGate = NamedGate()
        #expect(gate.unlockProductDisplayName == "AI Pro")
    }
}
