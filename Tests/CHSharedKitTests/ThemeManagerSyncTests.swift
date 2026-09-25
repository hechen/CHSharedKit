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

// App palettes are process-wide, so these run inside the serialized suite
// above rather than in parallel with it.
extension ThemeManagerSyncTests {
    private func appTheme(_ id: String, name: String) -> Theme {
        let base = Theme.editorial
        return Theme(
            id: id, name: name, description: "", symbol: base.symbol,
            associatedIconName: nil,
            accent: base.accent, accentSecondary: base.accentSecondary,
            background: base.background, backgroundElevated: base.backgroundElevated,
            card: base.card, cardElevated: base.cardElevated,
            textPrimary: base.textPrimary, textSecondary: base.textSecondary,
            textTertiary: base.textTertiary, divider: base.divider,
            success: base.success, warning: base.warning, error: base.error,
            gradientStart: base.gradientStart, gradientEnd: base.gradientEnd
        )
    }

    @Test("App themes replace the shared palette and the first is the fallback")
    func appThemesReplacePalette() {
        defer { ThemePalette.useSharedThemes() }
        ThemePalette.useAppThemes([appTheme("default", name: "House"), appTheme("midnight", name: "Noir")])

        #expect(ThemePalette.all.map(\.id) == ["default", "midnight"])
        #expect(ThemePalette.theme(for: "midnight").name == "Noir")
        #expect(ThemePalette.theme(for: "default").name == "House")
        #expect(ThemePalette.theme(for: "ocean").name == "House")
        #expect(ThemePalette.theme(for: nil).name == "House")
    }

    @Test("A manager resolves stored ids through the app palette")
    func managerUsesAppThemes() throws {
        defer { ThemePalette.useSharedThemes() }
        ThemePalette.useAppThemes([appTheme("default", name: "House"), appTheme("midnight", name: "Noir")])
        let defaults = try #require(UserDefaults(suiteName: "AppThemePaletteTests.\(UUID().uuidString)"))
        defaults.set("aurora", forKey: ThemeManager.kvsKey)

        let manager = ThemeManager(
            cloud: FakeThemeKeyValueStore(values: [:]),
            localDefaults: defaults,
            isCloudSyncEnabled: { false }
        )
        #expect(manager.currentTheme.name == "House")
        manager.apply(themeId: "midnight", animated: false)
        #expect(manager.currentTheme.name == "Noir")
    }

    @Test("Without app themes the shared palette is unchanged")
    func sharedPaletteByDefault() {
        ThemePalette.useSharedThemes()
        #expect(ThemePalette.all == ThemePalette.shared)
        #expect(ThemePalette.theme(for: "unknown").id == "default")
    }
}
