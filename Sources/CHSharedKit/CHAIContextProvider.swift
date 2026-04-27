import Foundation

// MARK: - CHAIContextProvider
//
// 2.7.0: portfolio-wide hook for injecting domain-specific user data into
// every AI request. Each consumer app implements its own `buildContext()`
// returning a plain-text snapshot of the user's relevant state — workouts,
// nutrition, wardrobe, transactions, articles, etc.
//
// `CHAIManager.send` / `stream` / `sendWithVision` automatically prepend the
// context provider's output to the system prompt before dispatching to the
// active provider. Apps don't have to thread context through every call site.
//
// **Plain-text format, not JSON.** Smaller LLMs (Qwen 2.5 3B etc) struggle
// with deeply-structured JSON in the prompt — they often parse it as code
// rather than data. A natural-language summary ("Last 7 days: 3 workouts,
// avg HRV 58, sleep 7h12m") tokenizes more efficiently and reads better.

public protocol CHAIContextProvider: Sendable {
    /// Plain-text snapshot of the user's data relevant to this chat session.
    /// Called automatically before every `send`/`stream`/`sendWithVision`.
    /// Async so implementations can hit HealthKit, SwiftData, Core Data, etc.
    /// without blocking the call site.
    ///
    /// Tip: keep the output tight (a few hundred tokens at most). Long
    /// contexts blow out the window for small models and slow down
    /// generation. Summarize aggressively.
    func buildContext() async -> String
}

// MARK: - Default anti-disclaimer suffix
//
// Small instruction-tuned LLMs default to "I don't have access to your data"
// or "As an AI, I cannot see your personal information" disclaimers even
// when the data IS provided. The kit appends a fixed counter-instruction
// when a context provider is registered so the model treats the inline
// data as authoritative.

public enum CHAIContextSystemPrompt {
    /// Suffix appended to the system prompt by `CHAIManager` when a
    /// context provider returns non-empty content. Public + mutable so
    /// consumer apps can override the wording for their voice.
    nonisolated(unsafe) public static var antiDisclaimerInstruction: String =
        "User data is provided below. Use it to answer their questions with specifics. Never disclaim 'I don't have access to your data' — the data IS provided."
}
