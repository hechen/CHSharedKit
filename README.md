# CHSharedKit

Shared Swift package providing the theme system, AI provider infrastructure, on-device LLM support, logging, and backup utilities used across all of Chen's iOS apps.

**Apps:** Closet · EatWisely · LiftCoach · SpendWisely · Distill · TrainInsight

Products: `CHSharedKit` (theme, AI providers, logging, backup, IAP gating), `CHLocalLLM` (on-device models), and `CHOrderImport` (Amazon order-page and order-CSV import with review drafts; see [docs/ORDER_IMPORT.md](docs/ORDER_IMPORT.md)).

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
- [Settings Sheet Presentation](#settings-sheet-presentation) — shared modal chrome and stable macOS geometry
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

## Settings Sheet Presentation

Use `CHSettingsSheet` at a modal boundary to keep settings sheets visually
consistent across apps. It owns the navigation stack, title, Done action,
semantic theme surfaces, and a stable 560×600 macOS window. Its content remains
adaptive on iOS and visionOS.

```swift
.sheet(isPresented: $showUsage) {
    CHSettingsSheet("AI Usage") {
        MyAppUsageView() // Custom content and data remain app-owned.
    }
}
```

Content-only views such as `CHAIProviderPickerView`, `CHAIUsageView`, and
`CHAIFeaturesSettingsContent` remain suitable for pushed navigation. Do not add
`CHSettingsSheet` around a view that is already inside a `NavigationStack` or a
native Settings scene.

For standard modal AI surfaces, use the convenience wrappers:

```swift
CHAISettingsSheet(appIdentifier: .closet) // CHLocalLLM product
CHAIFeaturesSettingsSheet(appName: "MyApp")
CHAIUsageSheet()
```

If a custom presentation root already owns its navigation and dismissal UI,
apply `.chSettingsPresentation()` to receive the same semantic surfaces
without adding another stack or changing its size. Use
`.chSettingsPresentation(sizing: .standardSheet)` only when that custom modal
root owns scrolling and should adopt the stable 560×600 macOS geometry.

---

## AI Provider System

Plug-in AI architecture. All providers conform to `CHAIProvider` and can be swapped at runtime.

### Setup

```swift
import CHSharedKit

// At app startup — registers Apple Intelligence, OpenAI, Claude, and custom endpoint
CHAIManager.shared.registerBuiltInProviders()

// Optional: refresh model names, defaults, retirements, and pricing now.
// CHAISettingsView also does this automatically when opened.
Task { await CHAICloudModelCatalog.shared.refreshIfNeeded() }

// Optional: disable a provider on this device without overwriting a
// cross-device active-provider preference.
CHAIManager.shared.disabledProviderIDs = [
    CHCustomEndpointProvider.providerID
]
```

As of 2.15.3, disabling `"on-device-llm"` also hides the downloadable-model
row, installed-model details, and download sheets in `CHAIProviderPickerView`
and `CHAISettingsContent`. These surfaces respect `availableProvidersFilter`
and do not initialize local model storage when local models are hidden. Apple
Intelligence remains a separate provider. Hosts that disable downloads should
also omit their own `LocalModelStore` startup and offline-catalog refreshes.
The manager preserves the saved provider choice and resolves its usual enabled
fallback; migrate that preference explicitly if the app must avoid a cloud
fallback for users who previously chose local models.
As of 2.15.4, the purchase banner also omits the offline-model benefit when
downloads are disabled and describes Apple Intelligence as included without
the optional unlock.

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
// Content-only settings screen for pushed navigation.
CHAISettingsView()

// Content-only usage dashboard for pushed navigation.
CHAIUsageView()

// Modal wrappers with shared title, Done action, theme, and macOS geometry.
CHAIUsageSheet()
CHSettingsSheet("My App Usage") { MyAppUsageView() }
```

### Built-in providers

| Provider | Default Model | Vision | Notes |
|---|---|---|---|
| `CHOpenAIProvider` | Catalog-defined | Yes | Remotely refreshed, bundled fallback |
| `CHClaudeProvider` | Catalog-defined | Yes | Remotely refreshed, bundled fallback |
| `CHAppleIntelligenceProvider` | System default | — | iOS 26+, free, on-device |
| `CHCustomEndpointProvider` | `llava` | — | Ollama, vLLM, LMStudio; OpenAI-compatible |

### Updating the cloud model catalog

The authoritative catalog lives in
[`hechen/ai-model-catalog`](https://github.com/hechen/ai-model-catalog).
Edit `cloud-model-catalog.json` there, increase the lexicographically sortable
`revision`, validate it, and push to `main`. Routine catalog updates require
neither a CHSharedKit release nor an app rebuild.

The default endpoint is
`https://raw.githubusercontent.com/hechen/ai-model-catalog/main/cloud-model-catalog.json`.
Clients load their last validated cached copy immediately, refresh the public
file with normal HTTP caching, and fall back to the package resource offline.
When preparing an SDK release, copy the canonical JSON into
`Sources/CHSharedKit/Resources/cloud-model-catalog.json` for the offline fallback.

Shipped apps using `https://hechen.github.io/apps/closet/cloud-model-catalog.json`
remain supported: the blog's Pages workflow generates that compatibility copy
from the catalog repository and checks hourly for changes. No app SDK bump is
required just to migrate hosting. New SDK releases use the direct URL above.

The schema validates unique provider/model IDs, recommendation and migration
targets, and nonnegative prices before replacing the active catalog. Add a
retired ID and its fallback in the manifest to move users away from a removed
API model without publishing a new package or app build.

### Immediate offline model picker presentation (2.15.2)

The on-device provider row and its lower Change Model / Download a Model section now present the picker from their own visible location. Scrolling the provider row offscreen no longer delays the lower action's sheet. The detail presenter stays mounted until dismissal when deleting the active model changes the selected provider.

### Offline model picker fixes (2.15.1)

Catalog refresh now preserves in-progress download controls, and selecting an installed model cancels any pending automatic switch. Failed custom entries can be removed, repository checks reject stale responses, and errors retain their actual cause. Installed license labels describe the installed revision. Deleting a model preserves its files if updating the installation registry fails.

### Remote offline model catalog (2.15.0)

CHLocalLLM model listings now refresh from the same public catalog repository as
cloud providers, with a bundled fallback and a validated cache. Installed model
revisions remain device-owned; changing listings never downloads weights or
switches the active provider. Explicit updates verify pinned files and run a
local smoke test before replacing the installed release. Recommendations require
an app-specific evaluation record. See [offline catalog integration and update
semantics](docs/OFFLINE_MODEL_CATALOG.md).

### Catalog-defined providers (2.14.0)

`CHAICatalogProvider` registers providers whose optional catalog `api` descriptor
uses `openai-chat-completions`. Shared pickers render their key and model settings
automatically. Grok is included as the first example. See the
[catalog format guide](https://github.com/hechen/ai-model-catalog#catalog-defined-providers-chsharedkit-2140)
for adding another provider without an SDK release.

Supported transport: HTTPS bearer authentication, text/image Chat Completions,
and SSE streaming. Unknown formats are skipped. Keys are scoped to provider and
endpoint; redirects are blocked. Host-registered providers take precedence.
Withdrawn providers fail closed, and on-device-only filters exclude dispatch as
well as picker rows. `gateAllExceptAppleIntelligence()` includes future providers
through `allProvidersGateID` (`*`); `effectiveGatedProviderIDs` expands that policy
for display. Explicit ID sets remain explicit.

Hosts with custom inference code must bridge `CHAICatalogProvider` into that code.
Hosts offering key-sync controls should include `CHAICatalogProvider.storedCredentialIDs`
when moving tokens between Keychain tiers. Shared credentials never cross apps.
One app release adopting this SDK is required; later compatible providers/models
arrive through a catalog refresh. New API protocols or capabilities still need
an SDK update.


### Which changes need an SDK update?

The catalog supports multiple providers, but runtime compatibility depends on
an implemented API adapter. CHSharedKit 2.14.0 supports these cases:

| Change | JSON only? | Requirement |
| --- | --- | --- |
| Add/update OpenAI or Claude models, prices, or retirement rules | Yes | The model must work with the existing built-in adapter. |
| Add a provider such as Grok using OpenAI-compatible Chat Completions | Yes | HTTPS, bearer API-key authentication, and the supported request/response format. |
| Add a provider using a native Anthropic Messages or another API format | No | Add a catalog runtime adapter to CHSharedKit first. Built-in Claude support does not make arbitrary Messages-compatible providers catalog-configurable. |
| Use OpenAI Responses, a different authentication scheme, or audio/tool-calling features | No | These are outside the current generic adapter and need SDK support. |

The generic adapter currently supports text, image input, and SSE text streaming;
each model must declare the capabilities it actually supports. An
“OpenAI-compatible” label alone is insufficient: the provider must support the
Chat Completions subset used by this adapter.

Each app must ship one update adopting SDK 2.14.0 and route requests through the
shared manager or an appropriate host bridge. After that, compatible additions
arrive on catalog refresh without another SDK or app release. Users still select
the provider and supply their own key. App capability filters, purchase gates,
and consent rules continue to apply; on-device-only apps do not expose cloud
providers.

When a new API adapter is implemented and shipped, later providers using that
supported format can also be added through JSON alone.

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
store.appIdentifier = .liftcoach

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

## Per-feature provider override (2.10.0)

Each AI-powered surface in an app (AI Stylist, Outfit Suggestions,
Smart Categorization, etc.) can now use a different provider than
the global "Active Provider." Run lightweight text features on
free Apple Intelligence; pin vision features to a paid OpenAI key;
route a specific feature to a Custom Endpoint for privacy.

### 1. Register features at app launch

```swift
import CHSharedKit

@main struct ClosetApp: App {
    init() {
        Task { @MainActor in
            CHAIFeatureRegistry.register([
                CHAIFeature(
                    id: "closet.ai_stylist",
                    displayName: "AI Stylist",
                    symbol: "sparkles",
                    tint: .blue,
                    requiredCapabilities: [.textInput],
                    footnote: "Personalized outfit recommendations from your wardrobe."
                ),
                CHAIFeature(
                    id: "closet.item_description",
                    displayName: "Item Description",
                    symbol: "photo",
                    tint: .purple,
                    requiredCapabilities: [.textInput, .visionInput],
                    footnote: "Auto-tags items from photos."
                ),
                // …
            ], appName: "Closet")
        }
    }
    var body: some Scene { … }
}
```

### 2. Route AI requests through the featureID

```swift
// Pre-2.10.0 — all features hit the global active provider:
let response = try await CHAIManager.shared.send(prompt: "Suggest an outfit")

// 2.10.0+ — feature-aware dispatch:
let response = try await CHAIManager.shared.send(
    prompt: "Suggest an outfit",
    featureID: "closet.ai_stylist"
)
```

`stream(prompt:featureID:)` and `sendWithVision(prompt:imageData:featureID:)`
have the same shape. When no override is set the resolver falls
back to the global active provider — existing behavior is preserved
for un-tagged calls.

### 3. Embed the settings UI

```swift
NavigationStack {
    CHAIFeaturesSettingsContent(appName: "Closet")
}
```

Renders one row per registered feature with a tappable detail page
that exposes: enabled toggle, provider override picker (filtered
by capability + isCloudOnly), model override picker, reset-to-
default button. Apps that need to inject extra sections (e.g.
Closet's "Show Suggested Questions" toggle) pass a
`displaySection:` closure.

### 4. Migrate legacy per-feature toggles (one-shot)

If your app already had its own enabled-toggle keys (e.g.
`"closet_ai_stylist_enabled"`), wire a one-shot migration in your
App init:

```swift
init() {
    CHAIModelMigration.migrateLegacyFeatureToggles(
        legacyKeyMap: [
            "closet_ai_stylist_enabled":       "closet.ai_stylist",
            "closet_item_description_enabled": "closet.item_description",
        ],
        appName: "Closet"
    )
}
```

The helper is idempotent — flagged by
`<appname>_feature_toggles_migrated_v_2_10_0` in
`UserDefaults.standard`. Subsequent launches are no-ops.

### Capability matrix

| Provider              | Text | Vision | Func calling | Streaming |
|-----------------------|:----:|:------:|:------------:|:---------:|
| OpenAI                | ✓    | ✓      | ✓            | ✓         |
| Claude (Anthropic)    | ✓    | ✓      | ✓            | ✓         |
| Custom Endpoint       | ✓    | ✓      | —            | —         |
| On-Device LLM (MLX)   | ✓    | —      | —            | ✓         |
| Apple Intelligence    | ✓    | —      | —            | —         |

A feature registered with `requiredCapabilities: [.visionInput]`
filters Apple Intelligence + On-Device LLM out of its picker
automatically. A feature registered with `isCloudOnly: true`
additionally filters out both on-device options regardless of
capability.

### Storage keys

The kit owns three UserDefaults key shapes — apps must not write
to these directly:

```
ch_ai_feature_provider_<featureID>
    → providerID String, "" or missing means "use active"
ch_ai_feature_model_<featureID>_<providerID>
    → modelID String, missing means "use provider's global model"
ch_ai_feature_enabled_<featureID>
    → Bool, default true
```

---

## Privacy manifests

Both library products bundle a target-owned `PrivacyInfo.xcprivacy` file:

- `CHSharedKit` declares app-private preferences (`CA92.1`), backup-file
  metadata and user-visible timestamps (`C617.1`, `DDA9.1`), and the
  prompt/image data its cloud AI providers can send to the configured provider.
- `CHLocalLLM` declares app-private and App Group preferences (`CA92.1`,
  `1C8F.1`). Its model inference remains on device, so the target declares no
  collected data.

Apps remain responsible for declaring any additional semantic data types they
place into an AI prompt (for example health, purchase, or financial data), the
purposes for which they use the response, and the retention practices of a
custom endpoint. A consuming app must also provide the required disclosure and
permission before sending personal data to a third-party AI provider.

## License

Private — for use in Chen's personal projects only.

## Author

Chen He — [github.com/hechen](https://github.com/hechen)
