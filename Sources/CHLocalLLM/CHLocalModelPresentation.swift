import Foundation

// MARK: - CHLocalModelPresentation
//
// 2.19.13: what the model picker shows in the host app's language. The
// catalog's description, strengths and per-app reasons are English prose
// (catalog revision 3 made them plain English). Apps ship many more
// languages than any catalog could, so only English-language apps show that
// prose; every app shows translated facts: the quality tier, the language
// count, "Speaks your language" (measured, catalog `replyLanguages`) and
// "Tested in <app>" (a passed evaluation). The description stays visible:
// it is maker, model, size and quantization.

enum CHLocalModelPresentation {
    /// The host app's current language, e.g. `zh-Hans`.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static func showsCatalogProse(language: String = appLanguage) -> Bool {
        Locale.Language(identifier: language).languageCode?.identifier == "en"
    }

    static func strengths(for model: LocalModelInfo, language: String = appLanguage) -> [String] {
        showsCatalogProse(language: language) ? model.strengths : []
    }

    /// Only worth saying outside English, where it is the point.
    static func speaksAppLanguage(_ model: LocalModelInfo, language: String = appLanguage) -> Bool {
        !showsCatalogProse(language: language) && model.speaksLanguage(language)
    }

    static func recommendationKey(for app: AppIdentifier) -> String {
        app == .gymlog ? "liftcoach" : app.rawValue
    }

    /// The line under a model: the app's reason in English, otherwise
    /// "Tested in <app>" when the evaluation passed, otherwise nothing.
    static func hint(for model: LocalModelInfo, app: AppIdentifier, language: String = appLanguage) -> String? {
        guard !model.isCustom else { return nil }
        guard let release = model.release else {
            return String(localized: "Not yet evaluated for \(app.displayName)", bundle: .module)
        }
        if showsCatalogProse(language: language) { return model.taskHint(for: app) }
        if release.recommendations[recommendationKey(for: app)]?.verification == "passed" {
            return String(localized: "Tested in \(app.displayName)", bundle: .module)
        }
        return nil
    }
}
