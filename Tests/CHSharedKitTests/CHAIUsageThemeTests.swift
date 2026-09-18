import Foundation
import Testing

@Suite("CHAIUsageView theme contract")
struct CHAIUsageThemeTests {
    @Test("Usage and pricing views use semantic theme tokens")
    func usageViewsAvoidFixedSystemPalette() throws {
        let source = try String(contentsOf: usageSourceURL(), encoding: .utf8)

        let forbiddenFragments = [
            "color: .blue",
            "color: .green",
            "color: .purple",
            "color: .orange",
            "color: .primary",
            ".foregroundStyle(.green)",
            ".foregroundStyle(.orange)",
            ".foregroundStyle(.secondary)",
            ".foregroundStyle(.tertiary)"
        ]

        for fragment in forbiddenFragments {
            #expect(
                !source.contains(fragment),
                "CHAIUsageView must use ResolvedTheme semantics instead of \(fragment)"
            )
        }

        #expect(source.contains("@Environment(\\.theme)"))
        #expect(source.contains(".tint(theme.accent)"))
        #expect(source.contains(".themedListBackground()"))
        #expect(source.contains(".themedNavigationBar()"))
    }

    private func usageSourceURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        for _ in 0..<8 {
            if fileManager.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(
                    "Sources/CHSharedKit/CHAIUsageView.swift"
                )
            }
            directory = directory.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CHSharedKit/CHAIUsageView.swift")
    }
}
