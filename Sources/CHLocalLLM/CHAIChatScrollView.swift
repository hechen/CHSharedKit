import SwiftUI
import CHSharedKit

// MARK: - CHAIChatScrollView
//
// 2.7.0: scrolling chat container with smart auto-scroll.
//
// Behavior:
//   • New message OR streaming chunk → auto-scroll to bottom *only if* the
//     user is currently near the bottom (within `nearBottomThreshold` pts).
//     This stops the scroll from yanking down when the user is reading
//     earlier history.
//   • User-scrolled-up state surfaces a "↓ New messages" pill that taps to
//     jump to the bottom. iOS 18+ only — uses `onScrollGeometryChange` for
//     the near-bottom detection. On iOS 17 / pre-18 macOS the view falls
//     back to "always scroll on new message" (no pill).
//   • Generic over `Message: CHAIChatMessage` and `Bubble: View` so apps
//     supply their own bubble renderer or use the kit-default `CHAIChatBubble`
//     via the convenience init.
//
// Apps drive content with a binding (or @Observable wrapper) and the view
// observes via `@Binding` semantics — re-renders on every messages change.

public struct CHAIChatScrollView<Message: CHAIChatMessage, Bubble: View>: View {
    public let messages: [Message]
    public let bubble: (Message) -> Bubble

    /// Pixels from the bottom edge before "near bottom" flips false. Tuned
    /// to ~120 pt so a user scrolled-up by one bubble height still gets
    /// the pill (rather than auto-scroll).
    public let nearBottomThreshold: CGFloat

    public init(
        messages: [Message],
        nearBottomThreshold: CGFloat = 120,
        @ViewBuilder bubble: @escaping (Message) -> Bubble
    ) {
        self.messages = messages
        self.nearBottomThreshold = nearBottomThreshold
        self.bubble = bubble
    }

    @State private var isUserNearBottom: Bool = true
    @State private var hasUnreadBelow: Bool = false

    public var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                scrollContent(proxy: proxy)
                if hasUnreadBelow {
                    newMessagesPill {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                            hasUnreadBelow = false
                            isUserNearBottom = true
                        }
                    }
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onChange(of: messages.last?.id) { _, newID in
                guard let newID else { return }
                if isUserNearBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                } else {
                    hasUnreadBelow = true
                }
            }
            .onChange(of: messages.last?.content) { _, _ in
                // Streaming chunk landed on the existing last message —
                // same id, growing content. Re-trail if near bottom.
                if isUserNearBottom, let lastID = messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        let core = ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { msg in
                    bubble(msg).id(msg.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
            core.onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distanceFromBottom < nearBottomThreshold
            } action: { _, near in
                isUserNearBottom = near
                if near { hasUnreadBelow = false }
            }
        } else {
            // iOS 17 / macOS 14 fallback: no scroll-position introspection
            // API. Treat as always-near-bottom — auto-scroll on every new
            // message; pill never appears. Acceptable degradation for the
            // small slice of users still on the older OS.
            core
                .onAppear { isUserNearBottom = true }
        }
    }

    @ViewBuilder
    private func newMessagesPill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text(Self.localizedNewMessages)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// Localized "↓ New messages" copy. Same locale-keyed pattern as the
    /// IAP banner — no .xcstrings catalog yet.
    private static var localizedNewMessages: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh":
            let script = Locale.current.language.script?.identifier
            return script == "Hant" ? "新訊息" : "新消息"
        case "ja": return "新着メッセージ"
        default: return "New messages"
        }
    }
}

// MARK: - Convenience init using CHAIChatBubble as the default bubble renderer

public extension CHAIChatScrollView where Bubble == CHAIChatBubble<Message> {
    /// Convenience initializer that uses the kit's default ``CHAIChatBubble``
    /// for every message. Apps that want a custom bubble pass their own
    /// `@ViewBuilder` to the designated init instead.
    init(messages: [Message], nearBottomThreshold: CGFloat = 120) {
        self.init(messages: messages, nearBottomThreshold: nearBottomThreshold) { msg in
            CHAIChatBubble(message: msg)
        }
    }
}
