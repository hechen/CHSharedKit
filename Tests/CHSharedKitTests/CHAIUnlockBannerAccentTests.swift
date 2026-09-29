import Foundation
import SwiftUI
import Testing
@testable import CHLocalLLM

/// 2.19.15 — the unlock banner hard-coded indigo, so in an app with its own
/// accent (Closet's cordovan) it was the one purple card on the screen.
/// Hosts now pass their accent; apps that don't keep indigo.
@Suite("Unlock banner accent")
struct CHAIUnlockBannerAccentTests {

    @Test("Without a host accent the banner stays indigo")
    func defaultIsIndigo() {
        #expect(EnvironmentValues().chAIAccentColor == nil)
        #expect(CHAIProviderUnlockBanner.resolvedAccent(nil) == .indigo)
    }

    @Test("A host accent replaces indigo")
    func hostAccentWins() {
        let cordovan = Color(red: 0.49, green: 0.16, blue: 0.14)
        #expect(CHAIProviderUnlockBanner.resolvedAccent(cordovan) == cordovan)

        var environment = EnvironmentValues()
        environment.chAIAccentColor = cordovan
        #expect(environment.chAIAccentColor == cordovan)
    }

    @Test("Indigo appears only as the fallback, not in the banner's views")
    func noOtherIndigoLiterals() throws {
        let source = try String(contentsOf: bannerSourceURL(), encoding: .utf8)
        let indigoLines = source
            .split(separator: "\n")
            .filter { $0.contains(".indigo") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(indigoLines.count == 1, "Only resolvedAccent may name indigo: \(indigoLines)")
        #expect(indigoLines.first?.contains("hostAccent ?? .indigo") == true)
    }

    private func bannerSourceURL() -> URL {
        let relative = "Sources/CHLocalLLM/CHAIProviderUnlockBanner.swift"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(relative)
            }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
