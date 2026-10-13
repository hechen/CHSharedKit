# AI settings presentation

The core product's `CHAISettingsView` provides provider settings without linking `CHLocalLLM`. The richer picker, modal wrapper, and section content below belong to `CHLocalLLM` and include its downloadable-model integration.

Import `CHLocalLLM` to use these views. Their `appIdentifier` parameter is an existing `AppIdentifier` value supplied by the host. That enum currently contains the original named app profiles; `.yourapp` is not a supported case. See [platform notes](MACOS_SUPPORT.md) for feature requirements.

## Push within a navigation stack

Use `CHAIProviderPickerView` as a destination. It supplies its title and uses the caller's navigation stack.

```swift
import CHLocalLLM
import SwiftUI

struct ProviderDestination: View {
    let appIdentifier: AppIdentifier

    var body: some View {
        NavigationStack {
            CHAIProviderPickerView(appIdentifier: appIdentifier)
        }
    }
}
```

When pushing from an existing stack, pass the picker directly to `NavigationLink` rather than adding a second stack around the destination.

## Present a sheet

`CHAISettingsSheet` owns navigation, a Done action, semantic surfaces, and the standard macOS sheet size. Do not nest another navigation stack inside it.

```swift
.sheet(isPresented: $showAISettings) {
    CHAISettingsSheet(appIdentifier: appIdentifier, onDismiss: {
        refreshHostSettings()
    })
}
```

The `onDismiss` callback is optional.

## Embed sections in a host settings screen

`CHAISettingsContent` supplies sections without a navigation stack or title. Place it in your own `List` or `Form`:

```swift
Form {
    Section("Account") { AccountSettings() }
    CHAISettingsContent(appIdentifier: appIdentifier)
    Section("About") { AboutSettings() }
}
```

The picker uses a grouped `Form` on macOS. For custom sheets, `CHSettingsSheet` in the core product supplies the same modal boundary. `CHAIFeaturesSettingsSheet` and `CHAIUsageSheet` wrap the core feature-settings and usage screens.

## Host configuration

Built-in providers register when the manager initializes. Register any custom providers before use and set `CHAIManager.shared.disabledProviderIDs` or `availableProvidersFilter` to match your app's supported providers. Hiding downloadable models also requires omitting host-owned local-model initialization if your app should not initialize that storage. Apple Intelligence is a separate provider.

Provider credential sections use Keychain storage and show connection-test results inline. The host remains responsible for provider availability, disclosure, and purchase configuration. See [purchase gating](IAP_GATING.md) for `chAIAccentColor(_:)` and `chAIUnlockAction(_:)` customization.
