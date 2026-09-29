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

    /// 2.19.16 — a fixed white label vanished on pale dark-mode accents
    /// (Closet House dark: white on coral is about 2.3:1).
    @Test("The Unlock label reads on the accent in both schemes")
    func readableUnlockLabel() {
        let houseLight = Color(red: 0.56, green: 0.22, blue: 0.17)
        let houseDark = Color(red: 0.91, green: 0.58, blue: 0.48)
        let galleryDark = Color(red: 0.90, green: 0.89, blue: 0.87)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: houseLight, in: .light) == .white)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: houseDark, in: .dark) == .black)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: galleryDark, in: .dark) == .black)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: .black, in: .dark) == .white)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: .white, in: .light) == .black)
        // Contrast decides, not the default banner's look: dark-mode system
        // indigo (109, 124, 255) gives white 3.5:1 and black 6.0:1. The
        // default banner never takes this path; only a host accent does.
        #expect(CHAIProviderUnlockBanner.readableLabel(on: .indigo, in: .light) == .white)
        #expect(CHAIProviderUnlockBanner.readableLabel(on: .indigo, in: .dark) == .black)
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

    /// 2.19.16 — the locked rows' lock and "Locked — purchase required"
    /// stayed indigo beside a cordovan banner. Provider identity colors
    /// (the on-device chip and its Private badge) are not purchase chrome.
    @Test("Locked provider rows use the banner's accent")
    func lockedRowsFollowAccent() throws {
        let source = try String(
            contentsOf: sourceURL("Sources/CHLocalLLM/CHAISettingsContent.swift"),
            encoding: .utf8
        )
        #expect(!source.contains(".foregroundStyle(.indigo)"))
        #expect(source.contains("CHAIProviderUnlockBanner.resolvedAccent(hostAccent)"))
    }

    private func bannerSourceURL() -> URL {
        sourceURL("Sources/CHLocalLLM/CHAIProviderUnlockBanner.swift")
    }

    private func sourceURL(_ relative: String) -> URL {
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
