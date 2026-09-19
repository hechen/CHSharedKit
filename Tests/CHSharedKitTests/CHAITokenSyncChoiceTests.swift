import XCTest
@testable import CHSharedKit

/// 2.10.0 — apps may now let the user decide whether an AI key follows them
/// through iCloud Keychain. The default is unchanged, so apps that never ask
/// keep syncing exactly as before.
@MainActor
final class CHAITokenSyncChoiceTests: XCTestCase {

    private let provider = "openai"
    private var backing: CHAITokenStore.TestBacking!

    override func setUp() {
        super.setUp()
        backing = CHAITokenStore.TestBacking()
        CHAITokenStore._testOverride = backing
    }

    override func tearDown() {
        CHAITokenStore.defaultSynchronizable = true
        CHAITokenStore._testOverride = nil
        backing = nil
        super.tearDown()
    }

    func testDefaultIsStillSynced() {
        CHAITokenStore.setToken("sk-synced", for: provider)
        XCTAssertEqual(CHAITokenStore.token(for: provider), "sk-synced")
        // A caller that never opts out must not see a device-only value.
        XCTAssertNil(CHAITokenStore.token(for: provider, synchronizable: false))
    }

    func testDeviceOnlyTokenStaysOutOfTheSyncedTier() {
        CHAITokenStore.setToken("sk-local", for: provider, synchronizable: false)
        XCTAssertEqual(CHAITokenStore.token(for: provider, synchronizable: false), "sk-local")
        XCTAssertNil(
            CHAITokenStore.token(for: provider),
            "a device-only key must never appear in the synced tier"
        )
    }

    func testTurningSyncOffMovesTheKeyAndClearsICloud() {
        CHAITokenStore.setToken("sk-moves", for: provider)
        XCTAssertTrue(CHAITokenStore.setSynchronizable(false, for: provider))

        XCTAssertEqual(CHAITokenStore.token(for: provider, synchronizable: false), "sk-moves")
        XCTAssertNil(
            CHAITokenStore.token(for: provider),
            "the iCloud copy must be removed, or the toggle is lying"
        )
    }

    func testTurningSyncOnMovesTheKeyBack() {
        CHAITokenStore.setToken("sk-returns", for: provider, synchronizable: false)
        XCTAssertTrue(CHAITokenStore.setSynchronizable(true, for: provider))

        XCTAssertEqual(CHAITokenStore.token(for: provider), "sk-returns")
        XCTAssertNil(CHAITokenStore.token(for: provider, synchronizable: false))
    }

    func testMovingWithNothingStoredIsHarmless() {
        XCTAssertFalse(CHAITokenStore.setSynchronizable(false, for: provider))
        XCTAssertFalse(CHAITokenStore.setSynchronizable(true, for: provider))
        XCTAssertNil(CHAITokenStore.token(for: provider))
        XCTAssertNil(CHAITokenStore.token(for: provider, synchronizable: false))
    }

    func testDeleteClearsBothTiers() {
        CHAITokenStore.setToken("sk-a", for: provider)
        CHAITokenStore.setToken("sk-b", for: provider, synchronizable: false)
        CHAITokenStore.deleteToken(for: provider)
        XCTAssertNil(CHAITokenStore.token(for: provider))
        XCTAssertNil(CHAITokenStore.token(for: provider, synchronizable: false))
    }

    /// The kit's own provider picker calls setToken with no argument, so
    /// the host's choice has to reach it through the default.
    func testHostDefaultRedirectsCallersThatDoNotAsk() {
        CHAITokenStore.defaultSynchronizable = false
        CHAITokenStore.setToken("sk-picker", for: provider)
        XCTAssertEqual(CHAITokenStore.token(for: provider, synchronizable: false), "sk-picker")

        CHAITokenStore.defaultSynchronizable = true
        XCTAssertNil(
            CHAITokenStore.token(for: provider),
            "the key written while the host wanted device-only must not be in iCloud"
        )
    }

    func testProvidersDoNotShareATier() {
        CHAITokenStore.setToken("sk-one", for: "openai", synchronizable: false)
        CHAITokenStore.setToken("sk-two", for: "anthropic", synchronizable: false)
        XCTAssertEqual(CHAITokenStore.token(for: "openai", synchronizable: false), "sk-one")
        XCTAssertEqual(CHAITokenStore.token(for: "anthropic", synchronizable: false), "sk-two")
    }
}
