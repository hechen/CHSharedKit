# Portfolio chat UI (CHSharedKit 2.7.0+)

Three pieces apps share:

1. `CHAIChatBubble` — markdown-rendered chat message bubble
2. `CHAIChatScrollView` — smart auto-scroll container
3. `CHAIContextProvider` — domain-context injection into every AI request

Plus a localized IAP unlock banner refresh (2.7.0): value-prop bullets +
"Loading…" → "Unlock" fallback after 1 s.

## Quick start — wire context into your app

```swift
import CHSharedKit

struct LiftCoachContextProvider: CHAIContextProvider {
    func buildContext() async -> String {
        let workouts = await WorkoutsRepository.shared.recentSummary(days: 7)
        let hrv = await HealthMetricsRepository.shared.hrvSummary()
        return """
        Recent training summary (last 7 days):
        - Workouts: \(workouts.count) sessions, \(workouts.totalVolumeKg) kg total volume
        - Top lifts: \(workouts.prList.joined(separator: ", "))
        - HRV avg: \(hrv.average) ms (baseline \(hrv.baseline))
        - Sleep avg: \(hrv.sleepAverage) hrs
        """
    }
}

@main
struct LiftCoachApp: App {
    init() {
        CHAIManager.shared.contextProvider = LiftCoachContextProvider()
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

That's it. Every `CHAIManager.send(...)` / `stream(...)` / `sendWithVision(...)`
call automatically prepends `buildContext()` output + the anti-disclaimer
suffix to the system prompt. Apps don't thread context through every call
site.

### Per-app context shapes

The kit is opinionated on format (plain text, not JSON — small LLMs
tokenize JSON poorly and often parse it as code instead of data) but
agnostic on content. Recommended shape per app:

| App | What to put in context |
|---|---|
| **LiftCoach** | Recent workouts, PRs, training plan progress, HRV/readiness |
| **TrainInsight** | Sleep, HRV, readiness scores, recent workouts, recovery trend |
| **EatWisely** | Today's nutrition (cal/macros), recent meal pattern, dietary flags |
| **Closet** | Wardrobe summary (count by category), recent wears, favorite items |
| **SpendWisely** | Active budgets, recent transactions, subscriptions, spending trend |
| **Distill** | Recently-read articles, reading patterns, tag affinities |

Keep the snapshot tight (≤ ~500 tokens). Long contexts blow out the small-LLM
window and slow generation.

## Chat UI

```swift
import CHSharedKit
import CHLocalLLM
import SwiftUI

struct YourChatView: View {
    @State private var messages: [YourMessage] = []
    @State private var draft: String = ""

    var body: some View {
        VStack {
            CHAIChatScrollView(messages: messages)
            HStack {
                TextField("Ask…", text: $draft)
                Button("Send", action: send)
            }.padding()
        }
    }

    func send() {
        let userMsg = YourMessage(id: UUID(), role: .user, content: draft, timestamp: Date())
        messages.append(userMsg)
        let prompt = draft
        draft = ""

        var assistantMsg = YourMessage(id: UUID(), role: .assistant, content: "", timestamp: Date())
        messages.append(assistantMsg)
        let assistantIdx = messages.count - 1

        Task {
            do {
                let stream = try await CHAIManager.shared.stream(prompt: prompt)
                var buffer = ""
                for try await chunk in stream {
                    buffer += chunk
                    messages[assistantIdx] = YourMessage(
                        id: assistantMsg.id,
                        role: .assistant,
                        content: buffer,
                        timestamp: assistantMsg.timestamp
                    )
                }
            } catch let CHAIError.providerLocked(name) {
                messages[assistantIdx] = YourMessage(
                    id: assistantMsg.id,
                    role: .error,
                    content: "\(name) requires a one-time purchase. Open Settings → AI Provider to unlock.",
                    timestamp: Date()
                )
            } catch {
                messages[assistantIdx] = YourMessage(
                    id: assistantMsg.id,
                    role: .error,
                    content: error.localizedDescription,
                    timestamp: Date()
                )
            }
        }
    }
}

struct YourMessage: CHAIChatMessage {
    let id: UUID
    let role: CHAIChatRole
    let content: String
    let timestamp: Date
}
```

### What you get for free in `CHAIChatScrollView`

- **Smart auto-scroll** (iOS 18+ / macOS 15+ / visionOS 2+): tracks
  `isUserNearBottom` via `onScrollGeometryChange`. New message OR
  streaming chunk → scrolls to bottom only if user is currently within
  120 pt of the bottom. User-scrolled-up state shows a "↓ New messages"
  pill that taps to jump down.
- **Pre-iOS-18 fallback**: always-scroll-on-new-message, no pill. Acceptable
  degradation for the small slice of users still on the older OS.
- **Generic** over `Message: CHAIChatMessage` and `Bubble: View` — apps
  supply their own bubble OR use the convenience init that defaults to
  the kit's `CHAIChatBubble`.

### What you get in `CHAIChatBubble`

- **Markdown** for assistant messages via `MarkdownUI` (MIT). Streaming
  chunks render as plain `Text` during the 100 ms quiescence window, then
  swap to parsed Markdown once the stream pauses. Avoids reparsing the
  AST on every token.
- **Role-based chrome**: user → right-aligned + accent background + white
  text; assistant → left-aligned + neutral background + primary text;
  error → red-tinted with warning icon; system → monospaced + tertiary.
- **Long-press copy** via `.contextMenu`. iOS uses `UIPasteboard`, macOS
  `NSPasteboard`.
- **Relative timestamp** label below the bubble ("2m ago"). Optional via
  `showsTimestamp: Bool`.
- **Custom max-width fraction** — defaults to 0.85 so bubbles don't span
  the full container width.

## API surface (added in 2.7.0)

| Symbol | Where | Notes |
|---|---|---|
| `CHAIChatRole` | `CHSharedKit/CHAIChatMessage.swift` | `.user .assistant .system .error`, Codable, CaseIterable |
| `CHAIChatMessage` | `CHSharedKit/CHAIChatMessage.swift` | `Identifiable + Sendable`, `id: UUID`, `role`, `content`, `timestamp` |
| `CHAIContextProvider` | `CHSharedKit/CHAIContextProvider.swift` | `Sendable` protocol with `buildContext() async -> String` |
| `CHAIContextSystemPrompt.antiDisclaimerInstruction` | same | overridable default counter-instruction |
| `CHAIManager.contextProvider` | `CHSharedKit/CHAIManager.swift` | `@Published var contextProvider: (any CHAIContextProvider)?` |
| `CHAIManager.composedSystemPrompt(_:)` | same | inspect what the kit will send (debug aid) |
| `CHAIChatBubble<Message>` | `CHLocalLLM/CHAIChatBubble.swift` | generic bubble view |
| `CHAIChatScrollView<Message, Bubble>` | `CHLocalLLM/CHAIChatScrollView.swift` | generic scroll container |

### Banner refresh (2.7.0)

`CHAIProviderUnlockBanner` (rendered by `CHAISettingsContent` when gating
is active) now includes:

- **Value-prop bullets** between the subtitle and CTA buttons:
  - 🛡️ Private offline LLMs — no cloud, no rate limits
  - 🔑 Bring your own keys for cloud providers — you control the cost
- **"Loading…" → "Unlock" fallback** after 1 s of waiting on
  `CHIAPGate.unlockPriceLabel`. Tap still works — StoreKit's purchase
  sheet resolves the price there.
- **Subtle "•" indicator** after 5 s if the price still hasn't arrived,
  so the user knows the kit is still trying.
- All new copy localized for **en / zh-Hans / zh-Hant / ja**.

## Migration

Source-compatible. All new API is additive:
- Apps that don't set `CHAIManager.shared.contextProvider` get identical
  2.6.x behavior — the manager's `composedSystemPrompt(_:)` returns the
  caller's `systemPrompt` unchanged.
- Apps that don't use `CHAIChatBubble` / `CHAIChatScrollView` keep their
  existing chat UIs untouched.
- The MarkdownUI dep is only linked into `CHLocalLLM` (which already had
  multi-MB MLX deps) — apps that import `CHSharedKit` only don't pay the
  binary cost.

## Honest verification limits

- **Unit tests cover** the data-layer contracts: `composedSystemPrompt`
  composition, anti-disclaimer suffix, empty/no-context paths, role enum
  Codable round-trip, protocol satisfaction. **Suite is 97/97 green.**
- **Streaming + scroll behavior is structural-verified, not pixel-verified.**
  I can't drive a Sim through a token-by-token stream and watch the pill
  appear. Real test happens on the next consumer-app TF.
- **MarkdownUI rendering** isn't tested at runtime in `swift test` — it
  needs a UIKit/AppKit context. Compile-verified only.
