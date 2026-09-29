import Foundation
import SwiftUI
import Testing
@testable import CHLocalLLM

/// 2.19.17 — Closet sells Closet Pro (item limit plus cloud AI) on its own
/// screen, yet the picker still showed the kit's AI-only unlock banner and,
/// once owned, its ownership card. A host that sells the unlock itself now
/// passes the action that opens its screen.
@Suite("Host-sold unlock")
struct CHAIHostUnlockTests {

    @Test("Without a host action the picker keeps its banner")
    func defaultIsKitBanner() {
        #expect(EnvironmentValues().chAIUnlockAction == nil)
    }

    @Test("The host action runs when invoked")
    @MainActor
    func actionRuns() {
        let counter = Counter()
        var environment = EnvironmentValues()
        environment.chAIUnlockAction = CHAIUnlockAction { counter.value += 1 }
        environment.chAIUnlockAction?()
        environment.chAIUnlockAction?()
        #expect(counter.value == 2)
    }

    @Test("The row names the locked providers and what unlocks them")
    func rowText() {
        let names = ["Claude", "Grok", "OpenAI"]
        #expect(CHAIHostUnlockRow.title(lockedProviderNames: names, productName: "Closet Pro")
            == names.formatted(.list(type: .and)))
        #expect(CHAIHostUnlockRow.subtitle(lockedProviderNames: names, productName: "Closet Pro")
            == String(localized: "Included with \("Closet Pro")", bundle: .module))
    }

    @Test("Without provider names the row still says what unlocks them")
    func rowTextWithoutNames() {
        #expect(CHAIHostUnlockRow.title(lockedProviderNames: [], productName: "Closet Pro")
            == String(localized: "Included with \("Closet Pro")", bundle: .module))
        #expect(CHAIHostUnlockRow.subtitle(lockedProviderNames: [], productName: "Closet Pro") == nil)
        #expect(CHAIHostUnlockRow.title(lockedProviderNames: [], productName: nil)
            == String(localized: "Requires a purchase", bundle: .module))
    }

    @Test("Every locked-row tap goes through the host action when there is one")
    func lockedTapsRouteThroughOneFunction() throws {
        let source = try String(
            contentsOf: sourceURL("Sources/CHLocalLLM/CHAISettingsContent.swift"),
            encoding: .utf8
        )
        let increments = source
            .split(separator: "\n")
            .filter { $0.contains("pulseTrigger += 1") }
        #expect(increments.count == 1, "Only pointToUnlock() may pulse the banner: \(increments)")
        #expect(source.contains("if let hostUnlock {\n            hostUnlock()"))
        // The host branch is checked before any banner or ownership card.
        let host = try #require(source.range(of: "if offersCloudProviders, let hostUnlock {"))
        let banner = try #require(source.range(of: "CHAIProviderUnlockBanner("))
        let card = try #require(source.range(of: "CHAIProviderOwnershipCard("))
        #expect(host.lowerBound < banner.lowerBound)
        #expect(host.lowerBound < card.lowerBound)
    }

    @Test("The new strings are translated in every kit language")
    func stringsTranslated() throws {
        let data = try Data(contentsOf: sourceURL("Sources/CHLocalLLM/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let languages = ["en", "de", "es", "fr", "it", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant"]
        for key in ["Included with %@", "Requires a purchase", "Learn More"] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) missing")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in languages {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["state"] as? String == "translated", "\(key) not translated to \(language)")
            }
        }
    }

    @MainActor
    private final class Counter: Sendable {
        var value = 0
    }

    private func sourceURL(_ relative: String) -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(relative)
            }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent(relative)
    }
}
