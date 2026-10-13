# CHSharedKit

Reusable Swift components for Apple-platform apps, maintained by [Chen He](https://github.com/hechen). The package contains backup and settings utilities, a theme system, AI provider interfaces, optional on-device inference, and order-import helpers. Each host app owns its data model, navigation, feature workflows, purchases, and branding.

## Products

| Product | Contents |
|---|---|
| `CHSharedKit` | Themes and SwiftUI settings components; backup storage; synchronized preferences and Keychain helpers; logging; AI providers, request routing, usage tracking, and purchase-gating interfaces. |
| `CHLocalLLM` | MLX model downloads and inference, model selection UI, and Markdown chat views. Depends on `CHSharedKit`. |
| `CHOrderImport` | Amazon order-page reading, CSV parsing, duplicate detection, and review drafts. Uses Foundation, CryptoKit, and WebKit; independent of the other two targets. |

Select only the products your app uses. MLX, Hugging Face libraries, and MarkdownUI are dependencies of the `CHLocalLLM` target. Swift Package Manager may still resolve the package's full dependency graph.

## Requirements

[Package.swift](Package.swift) declares Swift tools **6.1** and these deployment minimums:

- iOS / iPadOS 17
- macOS 14
- visionOS 1

Individual features have additional requirements. Apple Intelligence needs a supported OS and device; its integration uses Foundation Models on OS 26 or later. MLX inference needs compatible Apple Silicon hardware and enough memory for the selected model. Mac Catalyst is explicitly excluded from local MLX inference. A deployment minimum is not a claim that every feature has been tested on every device; see [platform notes](docs/MACOS_SUPPORT.md).

## Installation

Add `https://github.com/hechen/CHSharedKit` using Xcode's package dependency editor, select the release tag you intend to use, and link the appropriate library product to your target.

For Swift Package Manager:

```swift
// In Package.dependencies:
.package(url: "https://github.com/hechen/CHSharedKit", from: "2.19.20")

// In your target's dependencies:
.product(name: "CHSharedKit", package: "CHSharedKit")
```

The examples below are integration fragments. App-owned types such as `ContentView` and data models belong to your app.

## Back up app-owned data

`CHBackupFile` wraps an opaque payload with a version and export date. The host defines serialization and restore behavior. Pass your own entitled iCloud container to use iCloud Drive, or `nil` for local Documents storage.

```swift
import CHSharedKit
import Foundation

let payload = try JSONEncoder().encode(["example": "Saved by the host app"])
let backup = CHBackupFile(appVersion: "1.0", payload: payload)
let data = try JSONEncoder().encode(backup)
let url = try CHBackupStorage.write(
    fileExtension: "json",
    appName: "MyApp",
    data: data,
    iCloudContainerId: nil,
    fallbackFolderName: "MyAppBackups"
)

let backups = CHBackupStorage.list(
    fileExtension: "json",
    iCloudContainerId: nil,
    fallbackFolderName: "MyAppBackups"
)
```

`CHBackupSettingsView`, `CHBackupListView`, and `CHAutoBackupCoordinator` provide optional integration points. Review backup contents, error handling, and restore validation in the host app.

## Themes and settings

```swift
import CHSharedKit
import SwiftUI

struct ExampleView: View {
    var body: some View {
        Text("Hello")
            .themedScreen()
            .themed(ThemeManager.shared)
    }
}
```

Descendant views read `@Environment(\.theme)` for semantic colors. `ThemePickerView` selects a palette; `ThemePalette.useAppThemes(_:)` lets a host supply its own themes before initializing `ThemeManager.shared`. See the [theme integration guide](Sources/CHSharedKit/Theme/THEME_MIGRATION.md) for tokens and modifiers.

Theme preferences use `NSUbiquitousKeyValueStore` and a local fallback. Cross-device or cross-app synchronization depends on the host's entitlements and shared store configuration. Set the `CHThemeCloudSyncEnabledDefaultsKey` Info.plist entry to a UserDefaults Boolean key to gate theme sync with a per-device setting. Alternate icons require the host's own registered assets.

`CHSettingsRow` supplies a reusable settings row. `CHSettingsSheet` owns navigation, dismissal, and modal sizing; use it at a sheet boundary:

```swift
.sheet(isPresented: $showSettings) {
    CHSettingsSheet("Settings") {
        MySettingsContent()
    }
}
```

## AI providers

`CHAIProvider` defines text, vision, and streaming interfaces. `CHAIManager` handles registration, routing, optional per-feature overrides, and purchase gates. Built-in implementations include OpenAI, Anthropic Claude, Apple Intelligence, and custom endpoints; catalog entries can add OpenAI-compatible cloud providers.

```swift
import CHSharedKit

@MainActor
func summarize(_ text: String) async throws -> String {
    return try await CHAIManager.shared.send(
        prompt: text,
        systemPrompt: "Summarize the supplied text."
    )
}
```

The shared manager registers built-in providers during initialization. Configure an available provider before sending requests. `CHAISettingsView` is available in the core product. Cloud calls require the user's provider credentials and may incur that provider's charges. The host decides which providers are enabled and obtains any required consent before sending data.

The bundled cloud catalog has a cache and a configurable remote source; the default is the public [AI model catalog](https://github.com/hechen/ai-model-catalog). Catalog pricing is metadata for estimates, not a billing statement.

Optional integration guides:

- [AI settings presentation](docs/AI_SETTINGS.md)
- [Purchase gating and host responsibilities](docs/IAP_GATING.md)
- [Chat views and context injection](docs/CHAT_UI.md)
- [Offline model catalog and installation](docs/OFFLINE_MODEL_CATALOG.md)
- [Order import](docs/ORDER_IMPORT.md)

`CHLocalLLM` uses Apple's MLX libraries with Hugging Face model repositories. Model weights are downloaded separately and remain subject to their own licenses. Its existing `AppIdentifier` enum contains named profiles for the original consuming apps; those cases are retained for compatibility, and it does not currently accept arbitrary app identifiers. Generic core APIs do not require that enum.

## Privacy and integration boundaries

`CHSharedKit` and `CHLocalLLM` bundle target-owned privacy manifests. Inspect their [core](Sources/CHSharedKit/Resources/PrivacyInfo.xcprivacy) and [local model](Sources/CHLocalLLM/Resources/PrivacyInfo.xcprivacy) declarations together with your final app bundle. Hosts are responsible for their own data disclosures, entitlements, user consent, and the behavior of configured endpoints.

Provider keys use Keychain helpers. The host controls access groups; installing the SDK alone does not grant access to another app's data. Model inference runs locally, while catalog refreshes and model downloads use the network. Cloud inference sends the supplied request to the selected provider.

## Development

Run package tests on a compatible Apple-platform development machine:

```sh
swift test
```

Tests cover package contracts and synthetic fixtures. Native UI presentation, real-device synchronization, model execution, and purchases need separate host-app validation. The tools under `Tools/` run local model smoke/conformance checks and may download model weights; inspect their arguments and storage requirements before running them. [Optional validation scripts](Scripts/README.md) are available for host projects.

## License

[MIT](LICENSE), copyright 2026 Chen He. Dependencies and downloaded models retain their respective licenses.
