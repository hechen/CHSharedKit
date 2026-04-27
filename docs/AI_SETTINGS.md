# AI Provider settings — three integration patterns (CHSharedKit 2.7.1+)

The kit ships three views for the AI Provider settings surface. Pick based
on how you present them.

## Pattern A: Push from your app's NavigationStack (most common)

Use `CHAIProviderPickerView`. It sets `.navigationTitle("AI Provider")` and
relies on the caller's `NavigationStack` for the nav bar.

```swift
NavigationStack {
    List {
        NavigationLink {
            CHAIProviderPickerView(appIdentifier: .yourapp)
        } label: {
            Label("AI Provider", systemImage: "sparkles")
        }
    }
}
```

**Do NOT wrap `CHAIProviderPickerView` in another `NavigationStack` here.**
That's the source of the double-nav-bar bug Chen reported in SpendWisely:

```swift
// ❌ Wrong — causes double nav bar
NavigationLink {
    NavigationStack {                              // ← extra wrap
        CHAIProviderPickerView(appIdentifier: .x)
    }
}

// ✅ Correct
NavigationLink {
    CHAIProviderPickerView(appIdentifier: .x)
}
```

## Pattern B: Modal sheet presentation

Use `CHAISettingsSheet` (new in 2.7.1). It wraps the picker in its own
`NavigationStack` + a top-trailing Done button that dismisses the sheet.

```swift
.sheet(isPresented: $showAISettings) {
    CHAISettingsSheet(appIdentifier: .yourapp)
}
```

**Do NOT hand-roll your own NavigationStack wrap inside a `.sheet { ... }`
calling `CHAIProviderPickerView`** — `CHAISettingsSheet` exists exactly so
you don't have to. Hand-rolling is the same bug class as Pattern A's
double-wrap.

```swift
// ❌ Wrong — same double-nav-bar bug, different presentation
.sheet(isPresented: $show) {
    NavigationStack {                                 // ← hand-rolled
        CHAIProviderPickerView(appIdentifier: .x)
    }
}

// ✅ Correct
.sheet(isPresented: $show) {
    CHAISettingsSheet(appIdentifier: .x)
}
```

`CHAISettingsSheet` accepts an optional `onDismiss` callback if you need
to react to Done:

```swift
CHAISettingsSheet(appIdentifier: .yourapp, onDismiss: {
    refreshActiveProvider()
})
```

## Pattern C: Embed inside an existing settings `List`

Use `CHAISettingsContent` directly when you want the AI Provider rows to
appear as one section inside a larger settings view (alongside your app's
other sections):

```swift
NavigationStack {
    List {
        Section("Account") { … }
        CHAISettingsContent(appIdentifier: .yourapp)
        Section("About") { … }
    }
    .navigationTitle("Settings")
}
```

`CHAISettingsContent` returns plain `Section { ... }` content with no
NavigationStack and no `.navigationTitle` — it composes naturally inside
the caller's List + nav stack.

## Decision matrix

| You want… | Use |
|---|---|
| A pushed AI Provider screen with its own title bar | `CHAIProviderPickerView` |
| A modal sheet with Done button + own title bar | `CHAISettingsSheet` |
| AI Provider rows inside your existing settings List | `CHAISettingsContent` |

## Migration from 2.6.x / 2.7.0

If you previously hand-rolled a sheet:

```swift
// Before (still works but susceptible to double-nav-bar if mixed with push):
.sheet(isPresented: $show) {
    NavigationStack {
        CHAIProviderPickerView(appIdentifier: .x)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { show = false }
                }
            }
    }
}

// After (2.7.1+):
.sheet(isPresented: $show) {
    CHAISettingsSheet(appIdentifier: .x)
}
```

The kit's `CHAISettingsSheet` does exactly what your hand-rolled wrap did,
so the swap is a wash visually. The win is that future kit-side picker
chrome (back-button gestures, large-title dropdown, etc.) ships in one
place.
