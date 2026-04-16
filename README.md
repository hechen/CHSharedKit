# CHSharedKit

Shared Swift package providing the theme system, AI provider infrastructure, on-device LLM support, logging, and backup utilities used across all of Chen's iOS apps.

**Apps:** Closet · EatWisely · GymLog · SpendWisely · Distill · TrainInsight

---

## Requirements

| | Version |
|---|---|
| Swift | 6.0+ |
| iOS | 18.0+ |
| macOS | 15.0+ |
| Xcode | 16.0+ |

---

## Installation

**XcodeGen (`project.yml`):**

```yaml
packages:
  CHSharedKit:
    url: https://github.com/hechen/CHSharedKit
    from: "2.0.0"

targets:
  MyApp:
    dependencies:
      - package: CHSharedKit
        product: CHSharedKit
      # Optionally, for on-device LLM:
      - package: CHSharedKit
        product: CHLocalLLM
```

**Package.swift:**

```swift
.package(url: "https://github.com/hechen/CHSharedKit", from: "2.0.0")
```

---

## Modules

- [Theme System](#theme-system) — 11 pre-designed palettes, iCloud sync, alternate icons
- [Themed View Modifiers](#themed-view-modifiers) — screen, nav bar, list, tab bar
- [AI Provider System](#ai-provider-system) — OpenAI, Claude, Apple Intelligence, custom endpoints
- [On-Device LLM (CHLocalLLM)](#on-device-llm) — GGUF model download and inference via llama.cpp
- [Logging](#logging) — structured in-memory logger with SwiftUI viewer
- [Backup & Storage](#backup--storage) — iCloud Drive-aware backup utilities

---

## Theme System

A shared palette system synced via `NSUbiquitousKeyValueStore`. Picking a theme in one app applies it across all apps on the next launch.

### Setup

```swift
import CHSharedKit

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .themed(ThemeManager.shared)  // injects theme, sets tint, syncs tab bar
        }
    }
}
```

### Reading the theme

```swift
struct MyView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Hello")
            .foregroundStyle(theme.textPrimary)
            .background(theme.background)
    }
}
```

### Changing the theme

```swift
ThemeManager.shared.apply(themeId: "midnight")
ThemeManager.shared.apply(ThemePalette.ocean)
```

### Theme picker

```swift
ThemePickerView()  // grid picker, drop-in settings screen
```

### Available themes

| ID | Name | Description | Accent |
|---|---|---|---|
| `default` | Default | System look — crisp and familiar | Blue |
| `midnight` | Midnight | Pure OLED black with vibrant purple/cyan | Purple |
| `ocean` | Ocean | Deep blue depths with cyan tide accents | Cyan |
| `sunset` | Sunset | Warm orange-pink horizon | Coral |
| `forest` | Forest | Deep moss greens with earthy sage | Green |
| `paper` | Paper | Warm cream with sepia ink | Sepia |
| `aurora` | Aurora | Northern lights — purple to teal | Magenta |
| `monochrome` | Monochrome | Pure grayscale | White |
| `editorial` | Editorial | Airy neutrals like a magazine spread | Stone |
| `boutique` | Boutique | Bright retail polish with blush tones | Pink |

Themes that set `associatedIconName` (Midnight, Ocean, Sunset, Forest, Paper, Aurora, Monochrome) automatically swap the app icon when selected. Register the corresponding `CFBundleAlternateIcons` entries in the host app (e.g. `AppIcon-Midnight`).

---

## Themed View Modifiers

```swift
// Fill screen with theme.background (ignores safe area)
ContentView()
    .themedScreen()

// Style a List or Form background
List { ... }
    .themedListBackground()

// Configure navigation bar colors + color scheme
NavigationStack { ... }
    .themedNavigationBar()

// Tint tab bar to theme.backgroundElevated
TabView { ... }
    .themedTabBar()

// Themed card surface
VStack { ... }
    .themedCard(cornerRadius: 12, elevated: true)
```

---

## AI Provider System

Plug-in AI architecture. All providers conform to `CHAIProvider` and can be swapped at runtime.

### Setup

```swift
import CHSharedKit

// At app startup — registers Apple Intelligence, OpenAI, Claude, and custom endpoint
CHAIManager.shared.registerBuiltInProviders()
```

### Sending requests

```swift
let response = try await CHAIManager.shared.send(
    prompt: "Summarize this article",
    systemPrompt: "You are a concise summarizer."
)

// Vision request
let response = try await CHAIManager.shared.sendWithVision(
    prompt: "What's in this image?",
    imageData: jpegData
)
```

### Settings & usage UI

```swift
// Drop-in settings screen (provider picker, API key fields, test connection)
CHAISettingsView()

// Usage dashboard (requests, tokens, estimated cost)
CHAIUsageView()
```

### Built-in providers

| Provider | Default Model | Vision | Notes |
|---|---|---|---|
| `CHOpenAIProvider` | `gpt-4o` | Yes | Also: gpt-4o-mini, GPT-4.1, o4-mini |
| `CHClaudeProvider` | `claude-sonnet-4-20250514` | Yes | Also: Opus 4, Haiku 3.5 |
| `CHAppleIntelligenceProvider` | System default | — | iOS 26+, free, on-device |
| `CHCustomEndpointProvider` | `llava` | — | Ollama, vLLM, LMStudio; OpenAI-compatible |

### BYOK — storing API keys

Keys are stored in the system Keychain:

```swift
CHAIKeychain.save(apiKey: "sk-...", service: CHOpenAIProvider.keychainService)
let key = CHAIKeychain.load(service: CHOpenAIProvider.keychainService)
```

### Custom provider

```swift
struct MyProvider: CHAIProvider {
    let id = "myprovider"
    let displayName = "My Backend"
    let supportsVision = false

    func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        // call your API
    }

    func validate() async throws -> Bool { true }
}

CHAIManager.shared.registerProvider(MyProvider())
```

### Usage tracking

`CHAIUsageTracker` captures every request automatically. Access via:

```swift
let tracker = CHAIUsageTracker.shared
print(tracker.totalRequests)
print(tracker.thisMonthCost)   // estimated USD
print(tracker.requestHistory)  // [CHAIRequestLog]
```

---

## On-Device LLM

`CHLocalLLM` is a separate library product. Import it only in targets that need on-device inference (llama.cpp via [LLM.swift](https://github.com/eastriverlee/LLM.swift)).

```swift
import CHLocalLLM
```

### Download & activate a model

```swift
let store = LocalModelStore.shared
store.appGroupID = "group.app.chen.sharedllm"
store.appIdentifier = .gymlog

// Download the recommended model
let model = LocalModelCatalog.defaultModel
await store.downloadModel(model)

// Set as active provider (registers with CHAIManager automatically)
await store.setActiveModel(model.id)
```

### Observe download state

```swift
switch store.downloadState {
case .idle:            break
case .downloading(let progress, _, _): progressBar(progress)
case .installing:      spinner()
case .installed:       checkmark()
case .failed(let msg): errorView(msg)
case .paused:          resumeButton()
}
```

### Model picker UI

```swift
ModelPickerView()  // shows curated catalog with per-app recommendations
```

### Curated model catalog

| Model | Size | License |
|---|---|---|
| Qwen 2.5 0.5B (Q4_K_M) | ~400 MB | Apache 2.0 |
| Qwen 2.5 1.5B (Q4_K_M) | ~900 MB | Apache 2.0 |
| Qwen 2.5 3B (Q4_K_M) | ~1.9 GB | Apache 2.0 |
| Llama 3.2 1B (Q4_K_M) | ~770 MB | Llama Community |
| Llama 3.2 3B (Q4_K_M) | ~1.9 GB | Llama Community |
| Phi-3 Mini 4K (Q4) | ~2.3 GB | MIT |
| Phi-3.5 Mini (Q4_K_M) | ~2.2 GB | MIT |
| Gemma 2 2B (Q4_K_M) | ~1.6 GB | Gemma ToU |
| SmolLM2 1.7B (Q4_K_M) | ~1.0 GB | Apache 2.0 |
| DeepSeek-R1 1.5B (Q4_K_M) | ~1.0 GB | MIT |

Models are stored in an App Group container so they can be shared across apps.

---

## Logging

```swift
import CHSharedKit

let log = CHLogger.shared
log.debug("Cache hit", category: "Storage")
log.info("Sync started", category: "iCloud")
log.warning("Rate limit approaching", category: "AI")
log.error("Request failed", category: "AI", details: error.localizedDescription)
```

Persists the last 500 entries to `Documents/clawd-logs.json`. Max 2000 in-memory entries.

```swift
// Drop-in log viewer with search and level filtering
CHLogViewerView()

// Hidden dev menu revealed after N taps
someView
    .chDeveloperMenu(tapCount: $taps, visible: $showMenu, threshold: 5) {
        DevMenuContent()
    }
```

---

## Backup & Storage

iCloud Drive-aware backup utilities. Falls back to local Documents if iCloud is unavailable.

```swift
import CHSharedKit

// Export
let payload = try JSONEncoder().encode(myAppData)
try CHBackupStorage.write(
    payload: payload,
    iCloudContainerId: "iCloud.app.chen.myapp",
    fallbackFolderName: "MyAppBackups",
    appVersion: "2.1"
)

// List available backups
let backups = CHBackupStorage.list(
    iCloudContainerId: "iCloud.app.chen.myapp",
    fallbackFolderName: "MyAppBackups"
)

// Decode
let backup = try JSONDecoder().decode(CHBackupFile.self, from: backupData)
let myAppData = try JSONDecoder().decode(MyAppData.self, from: backup.payload)
```

---

## License

Private — for use in Chen's personal projects only.

## Author

Chen He — [github.com/hechen](https://github.com/hechen)
