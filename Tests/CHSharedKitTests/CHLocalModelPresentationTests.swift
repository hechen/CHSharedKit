import Foundation
import Testing
import CHSharedKit
@testable import CHLocalLLM

/// 2.19.13 — the model picker speaks the app's language.
@Suite("Local model presentation")
struct CHLocalModelPresentationTests {
    private func model(replyLanguages: [String]?, liftcoach verification: String = "unverified") throws -> LocalModelInfo {
        let base = try #require(LocalModelCatalog.all.first { $0.id == "qwen3-1.7b-q4" })
        let release = try #require(base.release)
        var recommendations = release.recommendations
        recommendations["liftcoach"] = .init(score: 9, reason: "Workout summaries and coaching answers.",
                                             verification: verification, evidence: verification == "passed" ? "run" : nil)
        return LocalModelInfo(
            id: base.id, displayName: base.displayName, description: base.description, sizeBytes: base.sizeBytes,
            quantization: base.quantization, downloadURL: base.downloadURL, minRAM_GB: base.minRAM_GB,
            license: base.license, quality: base.quality, chatTemplate: base.chatTemplate,
            languages: base.languages, strengths: ["Fast"],
            release: LocalModelRelease(
                repoID: release.repoID, revision: release.revision, runtime: release.runtime,
                modelType: release.modelType, minimumRuntimeVersion: release.minimumRuntimeVersion,
                status: release.status, files: release.files, recommendations: recommendations
            ),
            replyLanguages: replyLanguages
        )
    }

    @Test("Measured reply languages match app languages, keeping Chinese scripts apart")
    func speaksLanguage() throws {
        let measured = try model(replyLanguages: ["en", "zh-Hans", "pt-BR", "de"])
        #expect(measured.speaksLanguage("zh-Hans"))
        #expect(!measured.speaksLanguage("zh-Hant"))
        #expect(measured.speaksLanguage("pt-PT"))
        #expect(measured.speaksLanguage("de-CH"))
        #expect(!measured.speaksLanguage("ja"))
        #expect(try !model(replyLanguages: nil).speaksLanguage("de"))
    }

    @Test("English apps see the catalog prose; other apps see translated facts")
    func proseByLanguage() throws {
        let measured = try model(replyLanguages: ["en", "zh-Hans"], liftcoach: "passed")
        #expect(CHLocalModelPresentation.strengths(for: measured, language: "en") == ["Fast"])
        #expect(CHLocalModelPresentation.strengths(for: measured, language: "zh-Hans").isEmpty)
        #expect(!CHLocalModelPresentation.speaksAppLanguage(measured, language: "en"))
        #expect(CHLocalModelPresentation.speaksAppLanguage(measured, language: "zh-Hans"))
        #expect(CHLocalModelPresentation.hint(for: measured, app: .liftcoach, language: "en") == "Workout summaries and coaching answers.")
        #expect(CHLocalModelPresentation.hint(for: measured, app: .liftcoach, language: "zh-Hans") != nil)
        let unverified = try model(replyLanguages: ["en"])
        #expect(CHLocalModelPresentation.hint(for: unverified, app: .liftcoach, language: "de") == nil)
    }

    @Test("The bundled catalog is revision 3 with plain copy and measured languages")
    func bundledRevision() throws {
        let models = LocalModelCatalog.all
        let qwen3 = try #require(models.first { $0.id == "qwen3-1.7b-q4" })
        #expect(qwen3.replyLanguages?.contains("zh-Hans") == true)
        #expect(qwen3.release?.recommendations["liftcoach"]?.verification == "passed")
        for model in models {
            let copy = ([model.description] + model.strengths + (model.release?.recommendations.values.map(\.reason) ?? []))
                .joined(separator: " ").lowercased()
            #expect(!copy.contains("unverified"), "\(model.id) still shows evaluation notes")
            #expect(!copy.contains("candidate"), "\(model.id) still shows evaluation notes")
        }
    }
}
