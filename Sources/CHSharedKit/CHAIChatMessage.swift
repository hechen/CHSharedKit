import Foundation

// MARK: - CHAIChatRole
//
// Speaker / origin of a chat message. Drives bubble alignment, color, and
// role indicator chrome inside ``CHAIChatBubble``. Apps that store their own
// `Message` model just map their role enum onto this.

public enum CHAIChatRole: String, Sendable, Codable, CaseIterable {
    /// User-authored message — typically right-aligned, accent background.
    case user
    /// Model-generated response — typically left-aligned, neutral background,
    /// markdown-rendered.
    case assistant
    /// System / instruction message — usually hidden in the UI but kept in
    /// the message log for replay and debugging.
    case system
    /// Error-state message — left-aligned with a red accent. Used to surface
    /// `CHAIError.providerLocked`, `.networkError`, etc. to the user without
    /// derailing the whole chat.
    case error
}

// MARK: - CHAIChatMessage
//
// Minimal contract apps' message types satisfy so the kit's `CHAIChatBubble`
// and `CHAIChatScrollView` can render them. Apps own the rest of the model
// (persistence, attachments, tool calls, etc.) — this is just the shared
// surface.

public protocol CHAIChatMessage: Identifiable, Sendable {
    /// Stable identifier — used for ForEach in the scroll view AND for
    /// scroll-to-message anchors.
    var id: UUID { get }

    /// Speaker. Drives bubble alignment + color.
    var role: CHAIChatRole { get }

    /// Body text. Markdown is rendered when role == .assistant. Plain text
    /// otherwise.
    var content: String { get }

    /// When the message was created. Surfaced as a tiny timestamp label
    /// under the bubble (relative for recent, absolute for older).
    var timestamp: Date { get }
}
