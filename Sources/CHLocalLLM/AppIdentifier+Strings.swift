import Foundation

// MARK: - App-specific copy for CHLocalLLM UI and notifications
//
// Each consuming app identifies itself with an ``AppIdentifier`` so the
// download flow, onboarding card, and completion notification can render
// text that matches that app's use case instead of hard-coding a single
// app's wording.

public extension AppIdentifier {

    /// Body paragraph shown under "On-Device AI" on the onboarding card.
    var onboardingBlurb: String {
        switch self {
        case .distill:
            return String(localized: "Download a small AI model once. After that, Distill summarizes articles with no API key, no account, and no network connection required.", bundle: .module)
        case .closet:
            return String(localized: "Download a small AI model once. After that, Closet categorizes items and suggests outfits with no API key, no account, and no network connection required.", bundle: .module)
        case .spendwisely:
            return String(localized: "Download a small AI model once. After that, SpendWisely categorizes transactions and analyzes your spending with no API key, no account, and no network connection required.", bundle: .module)
        case .eatwisely:
            return String(localized: "Download a small AI model once. After that, EatWisely generates nutrition insights with no API key, no account, and no network connection required.", bundle: .module)
        case .traininsight:
            return String(localized: "Download a small AI model once. After that, TrainInsight generates readiness advice with no API key, no account, and no network connection required.", bundle: .module)
        case .liftcoach, .gymlog:
            return String(localized: "Download a small AI model once. After that, LiftCoach suggests workouts, gives form tips, detects plateaus, and writes your weekly training summaries with no API key, no account, and no network connection required.", bundle: .module)
        }
    }

    /// Default title for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionTitle: String { String(localized: "On-device AI ready", bundle: .module) }

    /// Default body for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionBody: String {
        switch self {
        case .distill:
            return String(localized: "Distill can now summarize articles without a network.", bundle: .module)
        case .closet:
            return String(localized: "Closet can now categorize items, detect brands, and suggest outfits privately on your device.", bundle: .module)
        case .spendwisely:
            return String(localized: "SpendWisely now categorizes transactions and generates insights privately. Your financial data never leaves this iPhone.", bundle: .module)
        case .eatwisely:
            return String(localized: "AI for Quick Add and daily insights now runs on your iPhone — no network needed. Photo meal scanning still uses cloud AI by default. To run photos on-device too, download the vision model in Settings → AI Provider → On-Device.", bundle: .module)
        case .traininsight:
            return String(localized: "TrainInsight can now generate your daily readiness advice privately on your iPhone.", bundle: .module)
        case .liftcoach, .gymlog:
            return String(localized: "LiftCoach can now suggest workouts, detect plateaus, and write training summaries privately on your device. Your workout data never leaves this iPhone.", bundle: .module)
        }
    }

    /// Per-app notification request identifier so multiple CHLocalLLM apps
    /// installed side-by-side do not collide on the same UN request id.
    var downloadCompletionNotificationIdentifier: String {
        "app.chen.\(rawValue).llm.ready"
    }
}
