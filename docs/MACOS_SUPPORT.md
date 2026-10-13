# Platform integration notes

The package manifest declares iOS 17, macOS 14, and visionOS 1 minimum deployment targets and Swift tools 6.1. Individual APIs, dependencies, and runtime features may require a newer OS or compatible hardware. These declarations are build requirements, not a device-test matrix.

## Local inference

`CHLocalLLM` uses MLX and Hugging Face model repositories. Local inference requires compatible Apple Silicon hardware, Metal, enough memory, and installed model files. `CHLocalMLXPlatform.isSupported` explicitly excludes Mac Catalyst; it is not a complete hardware or memory-capacity check. Validate the selected model on the actual target device. Intel inference is not supported by this integration.

Canonical model storage is in the host sandbox's `Application Support/CHSharedKit/` directory. Legacy App Group locations are read only as migration fallbacks. Pinned installs retain their own revision and manifest; see [offline model installation](OFFLINE_MODEL_CATALOG.md).

The macOS `ModelPickerView` uses native forms and accepts MLX repository entries. iOS has a separate picker implementation. `OnDeviceLLMOnboardingView` is currently iOS-only; hosts on other platforms must supply their own onboarding where needed.

## Cloud providers and Apple Intelligence

Cloud-provider transports use Foundation networking. Their availability also depends on credentials, connectivity, host filtering, purchase gates, and region policy. Apple Intelligence uses Foundation Models when available on OS 26 or later and a supported device; its availability must be checked at runtime.

## SwiftUI presentation

`CHAIProviderPickerView` uses a grouped `Form` on macOS and a `List` elsewhere. It expects an existing navigation stack. `CHAISettingsSheet` owns the modal stack and Done action; shared settings sheets use a 560 by 600 point macOS content size and adaptive layouts elsewhere. See [AI settings presentation](AI_SETTINGS.md).

Theme, backup, settings-row, and log-viewer components include platform-specific behavior. UIKit-only interactions such as alternate app icons do not apply to native macOS. Chat scrolling uses newer scroll-geometry APIs where available, with a fallback on older systems.

## Host validation

Build the exact products your app links for each shipping destination. Exercise sheets, menus, keyboard navigation, scrolling, and dismissal in a native host. Separately verify iCloud and Keychain entitlements, synchronization on signed-in devices, and any configured cloud or local inference path. A successful `swift test` run alone does not establish these runtime behaviors.
