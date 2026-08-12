import Foundation
import Testing
@testable import CHLocalLLM
@testable import CHSharedKit

@Suite("Privacy manifests")
struct PrivacyManifestTests {
    @Test("CHSharedKit manifest is bundled and declares its exact practices")
    func sharedKitManifest() throws {
        let manifest = try loadManifest(at: CHSharedKitPrivacyManifestResource.url)

        #expect(manifest.tracking == false)
        #expect(manifest.trackingDomains.isEmpty)
        #expect(manifest.accessedAPIReasons == [
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "DDA9.1"],
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]
        ])
        #expect(manifest.collectedData == [
            "NSPrivacyCollectedDataTypeOtherUserContent": CollectedData(
                linked: true,
                tracking: false,
                purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            ),
            "NSPrivacyCollectedDataTypePhotosorVideos": CollectedData(
                linked: true,
                tracking: false,
                purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        ])
    }

    @Test("CHLocalLLM manifest is bundled and remains local-only")
    func localLLMManifest() throws {
        let manifest = try loadManifest(at: CHLocalLLMPrivacyManifestResource.url)

        #expect(manifest.tracking == false)
        #expect(manifest.trackingDomains.isEmpty)
        #expect(manifest.accessedAPIReasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["1C8F.1", "CA92.1"]
        ])
        #expect(manifest.collectedData.isEmpty)
    }

    private func loadManifest(at url: URL?) throws -> ParsedManifest {
        let url = try #require(url)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let tracking = try #require(root["NSPrivacyTracking"] as? Bool)
        let trackingDomains = try #require(root["NSPrivacyTrackingDomains"] as? [String])
        let accessedAPIs = try #require(root["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let collectedData = try #require(root["NSPrivacyCollectedDataTypes"] as? [[String: Any]])

        var reasonsByCategory: [String: Set<String>] = [:]
        for entry in accessedAPIs {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            reasonsByCategory[category] = Set(reasons)
        }

        var dataByType: [String: CollectedData] = [:]
        for entry in collectedData {
            let type = try #require(entry["NSPrivacyCollectedDataType"] as? String)
            dataByType[type] = CollectedData(
                linked: try #require(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool),
                tracking: try #require(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool),
                purposes: Set(try #require(entry["NSPrivacyCollectedDataTypePurposes"] as? [String]))
            )
        }

        return ParsedManifest(
            tracking: tracking,
            trackingDomains: trackingDomains,
            accessedAPIReasons: reasonsByCategory,
            collectedData: dataByType
        )
    }
}

private struct ParsedManifest {
    let tracking: Bool
    let trackingDomains: [String]
    let accessedAPIReasons: [String: Set<String>]
    let collectedData: [String: CollectedData]
}

private struct CollectedData: Equatable {
    let linked: Bool
    let tracking: Bool
    let purposes: Set<String>
}
