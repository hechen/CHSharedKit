import SwiftUI
import Testing
@testable import CHSharedKit
@testable import CHLocalLLM

@Suite("CHSettingsSheet presentation contract")
struct CHSettingsSheetContractTests {
    @Test("macOS settings geometry is pinned fleet-wide")
    func standardMacOSGeometry() {
        #expect(CHSettingsPresentationLayout.macOSWidth == 560)
        #expect(CHSettingsPresentationLayout.macOSHeight == 600)
    }

    @MainActor
    @Test("generic settings sheet renders with the non-default theme")
    func themedSheetRenders() {
        let theme = ResolvedTheme(theme: .editorial, colorScheme: .light)
        let sheet = CHSettingsSheet("Test Settings") {
            Text("Content")
        }
        .environment(\.theme, theme)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1

        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced nil cgImage")
            return
        }

        #if os(macOS)
        #expect(image.width == Int(CHSettingsPresentationLayout.macOSWidth))
        #expect(image.height == Int(CHSettingsPresentationLayout.macOSHeight))
        #else
        #expect(image.width > 0)
        #expect(image.height > 0)
        #endif
    }

    @MainActor
    @Test("AI convenience sheets remain constructible")
    func aiConvenienceSheetsCompile() {
        _ = CHAISettingsSheet(appIdentifier: .closet)
        _ = CHAIFeaturesSettingsSheet(appName: "Closet")
        _ = CHAIUsageSheet()
    }

    @Test("shared shell explicitly owns themed macOS footer chrome")
    func themedFooterContract() throws {
        let source = try String(contentsOf: settingsSheetSourceURL(), encoding: .utf8)

        #expect(source.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(source.contains(".background(theme.backgroundElevated)"))
        #expect(source.contains(".fill(theme.divider)"))
        #expect(source.contains(".chSettingsPresentation(sizing: .standardSheet)"))
        #expect(source.contains("sizing: CHSettingsPresentationSizing = .adaptive"))
    }

    @Test("AI feature rows use the shared leading-label geometry")
    func aiFeatureRowAlignmentContract() throws {
        let source = try String(contentsOf: aiFeaturesSourceURL(), encoding: .utf8)

        #expect(source.contains("CHSettingsRow.value("))
        #expect(source.contains("icon: \"sparkles\""))
        #expect(source.contains("title: \"Default Provider\""))
        #expect(!source.contains("HStack {\n                        Text(\"Default Provider\")"))
    }

    private func settingsSheetSourceURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        for _ in 0..<8 {
            if fileManager.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(
                    "Sources/CHSharedKit/CHSettingsSheet.swift"
                )
            }
            directory = directory.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CHSharedKit/CHSettingsSheet.swift")
    }

    private func aiFeaturesSourceURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        for _ in 0..<8 {
            if fileManager.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(
                    "Sources/CHSharedKit/CHAIFeaturesSettingsContent.swift"
                )
            }
            directory = directory.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CHSharedKit/CHAIFeaturesSettingsContent.swift")
    }
}
