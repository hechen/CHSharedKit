# CHSharedKit macOS support matrix

Honest accounting of what works on macOS, what's iOS-shaped but renders, and
what's intentionally iOS-only. As of **2.5.2** (2026-04-26).

## Platform requirements

| Platform | Minimum | Notes |
|---|---|---|
| iOS / iPadOS | 17.0 | Full support, all features |
| macOS native | 14.0 (Apple Silicon) | Full support for AI provider + on-device MLX |
| visionOS | 1.0 | Full support |
| Mac Catalyst | — | **Not supported.** MLX requires Metal-capable Apple Silicon GPU; Catalyst targets a slightly different runtime. `CHAIError.unsupportedPlatform` is thrown by the on-device providers. Cloud providers (OpenAI, Claude) work fine over Catalyst since they're plain HTTP. |
| macOS Intel | — | Untested. MLX upstream targets Apple Silicon; Intel Macs likely fail at MLX kernel load. Cloud providers work. |

## On-device AI (`CHLocalLLMProvider` / `CHLocalVLMProvider`)

| Where | Status |
|---|---|
| iOS / iPadOS Apple Silicon | ✅ Full — model download via HuggingFace, MLX inference, streaming |
| macOS Apple Silicon | ✅ Full — same as iOS, native macOS picker (`ModelPickerView+macOS.swift`) |
| visionOS | ✅ Full |
| macOS Intel | ❌ MLX requires Apple Silicon Metal |
| Catalyst | ❌ Throws `.unsupportedPlatform` at load (`CHLocalMLXPlatform.requireSupported()`) |

The on-device path is symmetrical between iOS and macOS — same catalog, same
download directory layout (`<App Support>/CHSharedKit/models/<repo>/`), same
`HubApi`-based downloads, same `MLXLLM.LLMModelFactory.shared.loadContainer`
inference path. Only the picker UI differs (iOS uses a `List`-based custom
layout, macOS uses a native `Form(.grouped)`).

## Cloud providers (OpenAI, Claude, custom OpenAI-compatible)

All cloud providers are plain HTTP and work everywhere CHSharedKit builds —
iOS, iPadOS, macOS native, Catalyst, visionOS. They're not gated by
`#if os(iOS)`. If a consumer app's UI claims otherwise (e.g.
`"Cloud providers... iOS-only"`), that's the consumer app's wrapper code,
not the kit.

## View-by-view macOS readiness

| View | iOS | macOS native | Notes |
|---|---|---|---|
| `CHAISettingsContent` | ✅ | ✅ | Common code; iOS-only modifiers wrapped in `#if os(iOS)` (keyboard toolbar, haptics, `.keyboardType`, `.textInputAutocapitalization`) |
| `CHAIProviderPickerView` | ✅ | ✅ | List + content; `.navigationBarTitleDisplayMode(.inline)` is iOS-only-wrapped |
| `CHAIActiveProviderLabelView` | ✅ | ✅ | No platform-specific code |
| `CHAISettingsView` | ✅ | ✅ | Has 6 iOS guards for keyboard / UIKit haptics, all wrapped |
| `CHAIUsageView` | ✅ | ✅ | 2 iOS guards (haptics) |
| `ModelPickerView` (iOS) | ✅ | — | Whole file `#if os(iOS)`; macOS uses sibling file |
| `ModelPickerView+macOS.swift` | — | ✅ | Whole file `#if os(macOS)`; native Form-based layout, native sheets for license + pre-download confirm |
| `OnDeviceLLMOnboardingView` | ✅ | ⚠️ | Currently iOS-only (`#if os(iOS)`); macOS path skips onboarding and goes straight to picker. Acceptable for 2.5.2; native macOS onboarding is a follow-up |
| `LocalModelDownloadView` | ✅ | ✅ | Plain SwiftUI |
| `CHBackupSettingsView` | ✅ | ✅ | No platform guards |
| `CHBackupListView` | ✅ | ✅ | 3 iOS guards (swipe gestures, share sheet) — all wrapped properly |
| `CHLogViewerView` | ✅ | ✅ | UIKit imports for share sheet wrapped |
| `CHDeveloperMenuModifier` | ✅ | ✅ | Pure SwiftUI |
| `Theme/ThemePickerView` | ✅ | ✅ | 1 iOS guard (haptics) |
| `Theme/Theme*` | ✅ | ✅ | Cross-platform |

## Known macOS layout polish gaps (2.5.2)

These render and are functional on macOS but aren't yet peak-native:

- **`CHAISettingsContent`** still uses iOS-shaped `Section { ... }` rows
  inside a `List` rather than `.formStyle(.grouped)`. Renders correctly in
  a macOS `List` but doesn't feel as native as the macOS picker.
  Consumer apps can wrap it in their own `Form(.grouped)` for a more
  native feel.
- **`MacAddCustomModelSheet`** in the macOS picker still has GGUF-era URL
  validation (requires `.gguf` suffix, fetches `Content-Length`). This
  doesn't crash, but the validation rejects MLX repo URLs.
  **Custom MLX model addition on macOS is not yet wired up** —
  catalog models work fine. Tracked for a follow-up.
- **`OnDeviceLLMOnboardingView`** is iOS-only. macOS users currently see
  the model picker without an onboarding step.

## Consumer app integration for macOS

Apps that want the kit's AI panel on macOS:

```swift
struct YourMacAISettingsView: View {
    var body: some View {
        // Same call as iOS — kit picks the right platform variant internally.
        CHAIProviderPickerView(appIdentifier: .yourApp)
    }
}
```

Do **not** wrap with `#if os(iOS)` placeholder fallback. Pre-2.5.0 fallback
text ("On-device AI unavailable on Mac" etc.) is now stale and incorrect —
delete it.

## Catalyst gotcha

If your app supports Catalyst (`SUPPORTS_MACCATALYST = YES`), you must
guard on-device-AI UI behind `CHLocalMLXPlatform.isSupported` so the row
doesn't appear for Catalyst users (where it would throw). The kit's
provider validation already returns `false` on Catalyst, but UI gating is
the consumer app's responsibility.
