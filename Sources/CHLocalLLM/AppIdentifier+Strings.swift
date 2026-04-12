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
            return "Download a small AI model once. After that, Distill summarizes articles with no API key, no account, and no network connection required."
        case .closet:
            return "Download a small AI model once. After that, Closet categorizes items and suggests outfits with no API key, no account, and no network connection required."
        case .spendwisely:
            return "Download a small AI model once. After that, SpendWisely categorizes transactions and analyzes your spending with no API key, no account, and no network connection required."
        case .eatwisely:
            return "Download a small AI model once. After that, EatWisely generates nutrition insights with no API key, no account, and no network connection required."
        case .traininsight:
            return "Download a small AI model once. After that, TrainInsight generates readiness advice with no API key, no account, and no network connection required."
        case .gymlog:
            return "Download a small AI model once. After that, GymLog suggests workouts, gives form tips, detects plateaus, and writes your weekly training summaries with no API key, no account, and no network connection required."
        }
    }

    /// Default title for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionTitle: String { "On-device AI ready" }

    /// Default body for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionBody: String {
        switch self {
        case .distill:
            return "Distill can now summarize articles without a network."
        case .closet:
            return "Closet can now categorize items, detect brands, and suggest outfits privately on your device."
        case .spendwisely:
            return "SpendWisely now categorizes transactions and generates insights privately. Your financial data never leaves this iPhone."
        case .eatwisely:
            return "AI Quick Add and daily insights now run on your iPhone. Photo meal scanning still uses cloud AI."
        case .traininsight:
            return "TrainInsight can now generate your daily readiness advice privately on your iPhone."
        case .gymlog:
            return "GymLog can now suggest workouts, detect plateaus, and write training summaries privately on your device. Your workout data never leaves this iPhone."
        }
    }

    /// Per-app notification request identifier so multiple CHLocalLLM apps
    /// installed side-by-side do not collide on the same UN request id.
    var downloadCompletionNotificationIdentifier: String {
        "app.chen.\(rawValue).llm.ready"
    }
}
