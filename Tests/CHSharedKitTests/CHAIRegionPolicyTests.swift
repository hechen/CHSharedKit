import XCTest
@testable import CHSharedKit

/// Where AI can be offered: by storefront and Apple Intelligence availability.
final class CHAIRegionPolicyTests: XCTestCase {
    func testOpenStorefrontsKeepEverything() {
        XCTAssertEqual(CHAIRegionPolicy.mode(storefront: "USA", restricted: ["CHN"], appleIntelligenceAvailable: false), .full)
        XCTAssertEqual(CHAIRegionPolicy.mode(storefront: "can", restricted: ["CHN"], appleIntelligenceAvailable: true), .full)
        // No account yet: nothing is hidden.
        XCTAssertEqual(CHAIRegionPolicy.mode(storefront: nil, restricted: ["CHN"], appleIntelligenceAvailable: false), .full)
    }

    func testARestrictedStorefrontHidesCloudAIAndOpensUpWithAppleIntelligence() {
        XCTAssertEqual(CHAIRegionPolicy.mode(storefront: "CHN", restricted: ["CHN"], appleIntelligenceAvailable: false), .off)
        XCTAssertEqual(CHAIRegionPolicy.mode(storefront: "chn", restricted: ["CHN"], appleIntelligenceAvailable: true), .appleIntelligenceOnly)
    }

    @MainActor
    func testTheProviderFilterOnlyEverRemovesCloudProviders() {
        let policy = CHAIRegionPolicy.shared
        policy.appleIntelligenceAvailability = { true }
        policy.baseProviderFilter = .all
        policy.storefrontOverride = "CHN"
        XCTAssertEqual(policy.mode, .appleIntelligenceOnly)
        XCTAssertEqual(policy.providerFilter, .onDeviceOnly)
        XCTAssertFalse(policy.allowsCloudProviders)
        XCTAssertTrue(policy.showsAIFeatures)

        policy.appleIntelligenceAvailability = { false }
        XCTAssertEqual(policy.mode, .off)
        XCTAssertFalse(policy.showsAIFeatures)

        // The Apple Intelligence override wins over the real state, and
        // clearing it returns to the real state.
        policy.appleIntelligenceOverride = true
        XCTAssertEqual(policy.mode, .appleIntelligenceOnly)
        policy.appleIntelligenceOverride = false
        XCTAssertEqual(policy.mode, .off)
        XCTAssertEqual(CHAIRegionPolicy.currentMode, .off, "The nonisolated snapshot follows apply()")
        XCTAssertFalse(CHAIRegionPolicy.currentlyShowsAIFeatures)
        policy.appleIntelligenceOverride = nil
        XCTAssertEqual(policy.mode, .off)
        XCTAssertNil(UserDefaults.standard.object(forKey: CHAIRegionPolicy.appleIntelligenceOverrideKey))

        policy.storefrontOverride = nil
        policy.baseProviderFilter = .onDeviceOnly
        XCTAssertEqual(policy.mode, .full)
        XCTAssertTrue(CHAIRegionPolicy.currentlyShowsAIFeatures)
        XCTAssertEqual(policy.providerFilter, .onDeviceOnly, "An on-device-only app stays on-device-only")
        policy.baseProviderFilter = .all
    }
}
