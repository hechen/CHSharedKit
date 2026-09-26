import SwiftUI
import CHSharedKit
import MarkdownUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - CHAIChatBubble
//
// 2.7.0: portfolio-shared chat-message bubble. Renders a single message with
// role-based alignment + chrome, markdown-rendered bodies for assistant
// messages (debounced re-parse during streaming), and a long-press copy
// gesture. Generic over `CHAIChatMessage` so apps' message types plug in.
//
// Streaming behavior: assistant messages re-parse markdown only after a
// 100 ms quiescence window — bursty token deltas don't thrash MarkdownUI
// (which builds an AST every render). The bubble shows the live raw text
// during the debounce window; the parsed-markdown view replaces it once
// the user stops typing for 100 ms or the content stops changing for 100 ms.

public struct CHAIChatBubble<Message: CHAIChatMessage>: View {
    public let message: Message

    /// Optional override for the maximum width of the bubble (relative to
    /// container). Defaults to 0.85 — leaves visual breathing room without
    /// cramping responses on iPhone or wasting space on iPad.
    public let maxWidthFraction: CGFloat

    /// When true, shows a small relative-time label under the bubble
    /// ("2m ago"). Default true.
    public let showsTimestamp: Bool

    public init(
        message: Message,
        maxWidthFraction: CGFloat = 0.85,
        showsTimestamp: Bool = true
    ) {
        self.message = message
        self.maxWidthFraction = maxWidthFraction
        self.showsTimestamp = showsTimestamp
    }

    @State private var debouncedContent: String = ""

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 0)
            }
            VStack(alignment: alignment, spacing: 4) {
                bubbleContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                if showsTimestamp {
                    Text(timestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity * maxWidthFraction, alignment: bubbleFrameAlignment)
            if message.role != .user {
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            Button {
                copyContent()
            } label: {
                Label(String(localized: "Copy", bundle: .module), systemImage: "doc.on.doc")
            }
        }
        .task(id: message.content) {
            // 100 ms quiescence debounce so streaming tokens don't thrash
            // MarkdownUI's AST builder. If the content keeps changing, this
            // task gets cancelled and re-spawned; the assignment only fires
            // once the stream pauses.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            debouncedContent = message.content
        }
        .onAppear {
            // Initial paint: skip the debounce so non-streaming bubbles
            // (already-saved messages, error rows) render immediately.
            if debouncedContent.isEmpty {
                debouncedContent = message.content
            }
        }
    }

    // MARK: Body content per role

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .assistant:
            // Markdown for AI replies. Use the debounced content so streaming
            // doesn't re-parse on every chunk.
            if debouncedContent != message.content {
                // Mid-stream — show the live raw text so the user sees tokens
                // arriving without waiting for the debounce.
                Text(message.content)
                    .textSelection(.enabled)
            } else {
                Markdown(debouncedContent)
                    .textSelection(.enabled)
            }
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout)
                Text(message.content)
                    .textSelection(.enabled)
            }
        case .system:
            Text(message.content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        case .user:
            Text(message.content)
                .textSelection(.enabled)
        }
    }

    // MARK: Layout helpers

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }
    private var bubbleFrameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            Color.accentColor
        case .assistant:
            Color(platformSecondaryBackground)
        case .error:
            Color.red.opacity(0.12)
        case .system:
            Color.secondary.opacity(0.08)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user:     return .white
        case .assistant: return .primary
        case .error:    return .red
        case .system:   return .secondary
        }
    }

    private var timestampLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: message.timestamp, relativeTo: Date())
    }

    // MARK: Copy

    private func copyContent() {
        #if canImport(UIKit)
        UIPasteboard.general.string = message.content
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
    }

    // MARK: Platform-specific neutral background
    //
    // `Color(.secondarySystemBackground)` is iOS-only (UIKit). On macOS we
    // map to AppKit's `controlBackgroundColor`. Wrapping in a small helper
    // keeps the platform conditional out of the layout body.
    #if canImport(UIKit)
    private var platformSecondaryBackground: UIColor { .secondarySystemBackground }
    #elseif canImport(AppKit)
    private var platformSecondaryBackground: NSColor { .controlBackgroundColor }
    #endif
}
