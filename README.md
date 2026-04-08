# CHSharedKit

A private Swift package providing shared infrastructure for Chen's iOS and macOS apps. Includes an AI provider system, structured logging, iCloud backup utilities, and developer tooling — all built for Swift 6 concurrency.

---

## Requirements

| Requirement | Version |
|---|---|
| Swift | 6.0+ |
| iOS | 18.0+ |
| macOS | 15.0+ |
| Xcode | 16.0+ |

---

## Installation

Add CHSharedKit as a Swift Package Manager dependency in your `project.yml` (XcodeGen):

```yaml
packages:
  CHSharedKit:
    url: https://github.com/hechen/CHSharedKit
    from: "1.0.0"
```

Then add it as a target dependency:

```yaml
targets:
  MyApp:
    dependencies:
      - package: CHSharedKit
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/hechen/CHSharedKit", from: "1.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "CHSharedKit", package: "CHSharedKit")
        ]
    )
]
```

---

## Modules

### AI Provider System

A plug-in AI provider architecture supporting multiple backends. All providers conform to `ClawdAIProvider` and can be swapped at runtime.

| Component | Description |
|---|---|
| `ClawdAIProvider` | Protocol defining the interface for all AI providers (text + vision) |
| `ClawdAIManager` | Central `@MainActor` singleton — handles provider selection, request dispatch, and error state |
| `ClawdOpenAIProvider` | OpenAI GPT provider (defaults to `gpt-4o`, supports vision) |
| `ClawdClaudeProvider` | Anthropic Claude provider (defaults to `claude-sonnet-4`, supports vision) |
| `ClawdCustomEndpointProvider` | OpenAI-compatible custom endpoints — Ollama, vLLM, LMStudio, etc. |
| `ClawdAISettingsView` | Drop-in SwiftUI settings UI for provider selection and API key configuration |
| `ClawdAIUsageTracker` | Tracks token usage and estimated costs per provider |
| `ClawdAIUsageView` | SwiftUI view displaying usage stats |

**Quick example:**

```swift
import CHSharedKit

// Configure once at app startup
ClawdOpenAIProvider.apiKey = "sk-..."
ClawdAIManager.shared.registerProvider(ClawdOpenAIProvider())

// Send a request
let response = try await ClawdAIManager.shared.send(
    prompt: "Summarize this article",
    systemPrompt: "You are a concise summarizer."
)
```

---

### Logging

Structured, in-memory logging with OSLog integration and a built-in SwiftUI viewer.

| Component | Description |
|---|---|
| `ClawdLogger` | Unified logger with log levels (debug, info, warning, error) and category tagging |
| `ClawdLogEntry` | Codable log entry struct |
| `ClawdLogViewerView` | SwiftUI log viewer with filtering by level and category |

```swift
import CHSharedKit

let log = ClawdLogger.shared
log.info("Sync started", category: "iCloud")
log.error("Request failed", category: "AI", details: error.localizedDescription)
```

---

### Backup & Restore

iCloud Drive-aware backup utilities for exporting and restoring app data.

| Component | Description |
|---|---|
| `ClawdBackupKit` | Core backup/restore logic with iCloud Drive and local Documents fallback |
| `ClawdBackupFile` | Codable container wrapping app payload with export date and app version |
| `ClawdBackupStorage` | Resolves the correct backup directory (iCloud or local) |
| `ClawdBackupSettingsView` | SwiftUI settings row for triggering export/import |
| `ClawdBackupListView` | SwiftUI list of available backup files with restore/delete actions |

```swift
import CHSharedKit

// Export
let payload = try JSONEncoder().encode(myAppData)
try ClawdBackupKit.export(
    payload: payload,
    iCloudContainerId: "iCloud.app.chen.myapp",
    appVersion: "2.1"
)

// Import
let backup = try ClawdBackupKit.latestBackup(iCloudContainerId: "iCloud.app.chen.myapp")
let myAppData = try JSONDecoder().decode(MyAppData.self, from: backup.payload)
```

---

### Developer Tools

Tooling for in-app debugging without shipping debug builds to users.

| Component | Description |
|---|---|
| `ClawdDeveloperMenu` | SwiftUI `ViewModifier` that reveals a hidden developer menu after N taps |
| `ClawdDeveloperMenuModifier` | Convenience modifier wrapper |

```swift
import CHSharedKit

// Reveal a dev menu after 5 taps on any view
.modifier(ClawdDeveloperMenu(
    tapCount: $tapCount,
    visible: $devMenuVisible,
    threshold: 5
) {
    DevMenuContent()
})
```

---

## License

Private — for use in Chen's personal projects only.

## Author

Chen — [github.com/hechen](https://github.com/hechen)
