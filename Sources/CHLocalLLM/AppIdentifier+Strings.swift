import Foundation

// MARK: - App-specific copy for CHLocalLLM UI and notifications
//
// Each consuming app identifies itself with an ``AppIdentifier`` so the
// download flow, onboarding card, and completion notification can render
// text that matches that app's use case instead of hard-coding a single
// app's wording.

public extension AppIdentifier {

    /// Body paragraph shown under "On-Device AI" on the onboarding card.
    /// Replaces what used to be a hard-coded "Distill summarizes articles…" line.
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
        }
    }

    /// Default title for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionTitle: String { "On-Device AI Ready" }

    /// Default body for the local notification fired when a model finishes downloading.
    var defaultDownloadCompletionBody: String {
        switch self {
        case .distill:
            return "Distill can now summarize articles offline."
        case .closet:
            return "Closet can now categorize items privately on your device."
        case .spendwisely:
            return "SpendWisely can now categorize transactions privately on your device."
        case .eatwisely:
            return "EatWisely can now generate nutrition insights privately on your device."
        }
    }

    /// Per-app notification request identifier so multiple CHLocalLLM apps
    /// installed side-by-side do not collide on the same UN request id.
    var downloadCompletionNotificationIdentifier: String {
        "app.chen.\(rawValue).llm.ready"
    }
}
