import Foundation
import Testing
@testable import CHSharedKit

@MainActor
@Suite("ThemeManager settings-sync gate", .serialized)
struct ThemeManagerSyncTests {
    @Test("Disabled sync starts from local theme and never writes cloud")
    func disabledSyncStaysLocal() throws {
        let defaults = try makeDefaults()
        let cloud = FakeThemeKeyValueStore(values: [ThemeManager.kvsKey: "midnight"])
        defaults.set("editorial", forKey: ThemeManager.kvsKey)
        var enabled = false

        let manager = ThemeManager(
            cloud: cloud,
            localDefaults: defaults,
            isCloudSyncEnabled: { enabled }
        )

        #expect(manager.currentTheme.id == "editorial")
        #expect(cloud.synchronizeCallCount == 0)

        manager.apply(themeId: "ocean", animated: false)
        #expect(defaults.string(forKey: ThemeManager.kvsKey) == "ocean")
        #expect(cloud.values[ThemeManager.kvsKey] == "midnight")
        #expect(cloud.setCallCount == 0)

        enabled = true
        manager.cloudSyncDidEnable()
        #expect(manager.currentTheme.id == "midnight")
        #expect(defaults.string(forKey: ThemeManager.kvsKey) == "midnight")
        #expect(cloud.synchronizeCallCount == 1)
    }

    @Test("Enabled sync starts cloud-first and publishes later choices")
    func enabledSyncUsesCloud() throws {
        let defaults = try makeDefaults()
        let cloud = FakeThemeKeyValueStore(values: [ThemeManager.kvsKey: "boutique"])
        defaults.set("editorial", forKey: ThemeManager.kvsKey)

        let manager = ThemeManager(
            cloud: cloud,
            localDefaults: defaults,
            isCloudSyncEnabled: { true }
        )

        #expect(manager.currentTheme.id == "boutique")
        #expect(cloud.synchronizeCallCount == 1)

        manager.apply(themeId: "forest", animated: false)
        #expect(defaults.string(forKey: ThemeManager.kvsKey) == "forest")
        #expect(cloud.values[ThemeManager.kvsKey] == "forest")
        #expect(cloud.setCallCount == 1)
        #expect(cloud.synchronizeCallCount == 2)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ThemeManagerSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class FakeThemeKeyValueStore: ThemeKeyValueStore {
    var values: [String: String]
    private(set) var setCallCount = 0
    private(set) var synchronizeCallCount = 0

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        setCallCount += 1
        values[defaultName] = value as? String
    }

    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return true
    }
}
