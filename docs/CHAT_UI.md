# Chat views and app context

CHSharedKit defines the message and context contracts. The optional CHLocalLLM product provides `CHAIChatBubble` and `CHAIChatScrollView`, using MarkdownUI for assistant message rendering. The host owns conversation storage, request lifecycle, cancellation, and UI state.

## Context injection

Implement `CHAIContextProvider` to supply a concise, relevant plain-text snapshot. This example uses app-owned text without assuming a particular data store:

```swift
import CHSharedKit

struct DocumentContext: CHAIContextProvider {
    let summary: String

    func buildContext() async -> String {
        "Current document summary: \(summary)"
    }
}

@MainActor
func configureContext(summary: String) {
    CHAIManager.shared.contextProvider = DocumentContext(summary: summary)
}
```

`send`, `stream`, and `sendWithVision` compose the context with the supplied system prompt. The package also appends `CHAIContextSystemPrompt.antiDisclaimerInstruction`, which tells the model to use the supplied context. Inspect `composedSystemPrompt(_:)` when integrating this behavior. Without a context provider, the caller's system prompt is unchanged.

Keep context within the model's context budget and include only data appropriate for the selected provider. Cloud-provider requests include this text; the host must obtain applicable consent and avoid sending unrelated personal data.

## Message model and scroll view

```swift
import CHSharedKit
import CHLocalLLM
import Foundation
import SwiftUI

struct ChatMessage: CHAIChatMessage {
    let id: UUID
    let role: CHAIChatRole
    let content: String
    let timestamp: Date
}

struct ConversationView: View {
    let messages: [ChatMessage]

    var body: some View {
        CHAIChatScrollView(messages: messages)
    }
}
```

Roles are `.user`, `.assistant`, `.system`, and `.error`. Hosts can update a message's content as streaming chunks arrive while preserving its identity, or supply a custom bubble through the generic scroll-view initializer.

The default bubble supports Markdown for assistant replies, context-menu copying, optional relative timestamps, and configurable maximum width. Streaming content temporarily renders as plain text before Markdown parsing resumes after the update pause.

On iOS 18, macOS 15, and visionOS 2 or later, scroll geometry determines whether the user is near the bottom. New content follows only when the user is near the bottom; otherwise a New Messages control offers a jump. Older systems use the fallback scroll behavior. Validate this interaction with your actual composer, keyboard, window size, and message update cadence.

## API boundaries

| Symbol | Product | Role |
|---|---|---|
| `CHAIChatRole` | `CHSharedKit` | Codable message roles. |
| `CHAIChatMessage` | `CHSharedKit` | Identifiable, Sendable message contract with UUID, role, content, and timestamp. |
| `CHAIContextProvider` | `CHSharedKit` | Async, Sendable context source. |
| `CHAIManager.contextProvider` | `CHSharedKit` | Optional context injection for managed requests. |
| `CHAIChatBubble` | `CHLocalLLM` | Default Markdown message view. |
| `CHAIChatScrollView` | `CHLocalLLM` | Generic conversation scroll container. |

The chat UI resides in `CHLocalLLM`, so using those views links that product's dependencies even when your conversation uses a cloud provider. Core request routing and message contracts can be used independently.

## Validation

Package tests cover context composition and message contracts. Markdown rendering, live streaming, scroll position, copy actions, accessibility, and keyboard interaction require native UI validation in the host. Historical test counts are not a guarantee for a different toolchain or consumer app.
