# Theme System Migration Guide

**Goal: every screen should feel like the ThemePickerView.**

The `ThemePickerView` is the reference design. It uses `theme.background` for the
full-screen root, renders cards with `theme.card` fill + `theme.divider` border +
drop shadow, and writes all text through `theme.textPrimary / textSecondary / textTertiary`.
The 5 view modifiers below encapsulate those patterns so adoption is one line per screen.

---

## What Changed

CHSharedKit now ships a complete `Theme` / `ResolvedTheme` system replacing the
earlier single-tint approach. Every `Theme` defines 15 color tokens, all available as
plain `Color` values on `ResolvedTheme` via `@Environment(\.theme)`.

The `ThemeManager` injects the active theme via `.themed(themeManager)` at the app
root. From that point every descendant view reads `@Environment(\.theme) private var theme`
and accesses tokens directly.

---

## Color Token Reference

| Token | Type | Use for |
|-------|------|---------|
| `theme.accent` | `Color` | Primary interactive color — buttons, links, selected state ring, tint |
| `theme.accentSecondary` | `Color` | Secondary highlights, gradient partner, softer emphasis |
| `theme.background` | `Color` | Root screen background (replaces `Color(.systemGroupedBackground)`) |
| `theme.backgroundElevated` | `Color` | Tab bar, nav bar, modal sheet background |
| `theme.card` | `Color` | Card/row background inside a List or standalone card (replaces `Color(.secondarySystemGroupedBackground)`) |
| `theme.cardElevated` | `Color` | Elevated card variant — action sheets, popovers, picker cards |
| `theme.textPrimary` | `Color` | Primary text (replaces `.primary` / `Color(.label)`) |
| `theme.textSecondary` | `Color` | Secondary / caption text (replaces `.secondary` / `Color(.secondaryLabel)`) |
| `theme.textTertiary` | `Color` | Placeholder, disabled, very muted labels |
| `theme.divider` | `Color` | Separator lines, card borders (replaces `Color(.separator)`) |
| `theme.success` | `Color` | Positive state indicators |
| `theme.warning` | `Color` | Warning / caution indicators |
| `theme.error` | `Color` | Error / destructive state indicators |
| `theme.gradientStart` | `Color` | Gradient leading color (card preview areas, hero banners) |
| `theme.gradientEnd` | `Color` | Gradient trailing color |
| `theme.gradient` | `LinearGradient` | Convenience `topLeading → bottomTrailing` gradient |

---

## Setup at App Root (required once per app)

```swift
@main struct MyApp: App {
    @StateObject private var themeManager = ThemeManager.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .themed(themeManager)   // ← injects theme + sets global tint
        }
    }
}
```

After this, every descendant reads the theme with:

```swift
@Environment(\.theme) private var theme
```

---

## View Modifier Reference

Five modifiers are provided in `ThemeViewModifiers.swift`. Prefer these over raw
property access for consistency.

### `.themedScreen()`

Apply to the **outermost view of every screen** (NavigationStack root, sheet root,
tab content root). Sets `theme.background` extending behind safe-area insets —
exactly as `ThemePickerView` does.

```swift
// BEFORE
var body: some View {
    ScrollView { … }
        .background(Color(.systemGroupedBackground))
}

// AFTER
var body: some View {
    ScrollView { … }
        .themedScreen()
}
```

### `.themedCard(cornerRadius:elevated:)`

Wrap any card VStack/HStack. Applies `theme.card` fill, `theme.divider` border,
and a drop shadow — matching the aesthetic of each card in `ThemePickerView`.

```swift
// BEFORE
VStack { … }
    .background(Color(.secondarySystemGroupedBackground))
    .cornerRadius(14)

// AFTER
VStack { … }
    .themedCard()

// Elevated variant (modal/popover surface):
VStack { … }
    .themedCard(elevated: true)
```

### `.themedListBackground()`

Apply to any `List` or `Form`. Handles the SwiftUI `.scrollContentBackground(.hidden)`
requirement so the list background actually shows `theme.background`.

```swift
// BEFORE
List { … }
    // List ignores .background() — theme never shows

// AFTER
List { … }
    .themedListBackground()
```

### `.themedNavigationBar()`

Apply inside a `NavigationStack` or `NavigationView` root. Configures
`toolbarBackground` so the nav bar blends with `theme.background`.

```swift
NavigationStack {
    FeedView()
        .themedNavigationBar()
}
```

### `.themedTabBar()`

Apply to the root `TabView`. Tints the tab bar to `theme.backgroundElevated`.

```swift
TabView { … }
    .themedTabBar()
```

---

## Before / After Examples

### Root navigation screen

```swift
// BEFORE
struct ArticleListView: View {
    var body: some View {
        List(articles) { article in
            ArticleRow(article: article)
        }
        .navigationTitle("Articles")
    }
}

// AFTER
struct ArticleListView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        List(articles) { article in
            ArticleRow(article: article)
        }
        .navigationTitle("Articles")
        .themedListBackground()
        .themedNavigationBar()
    }
}
```

### Standalone card

```swift
// BEFORE
VStack(alignment: .leading, spacing: 8) {
    Text(title).font(.headline)
    Text(subtitle).font(.caption).foregroundStyle(.secondary)
}
.padding()
.background(Color(.secondarySystemGroupedBackground))
.cornerRadius(14)

// AFTER
struct ArticleCard: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(theme.textPrimary)
            Text(subtitle).font(.caption).foregroundStyle(theme.textSecondary)
        }
        .padding()
        .themedCard()
    }
}
```

### Full screen with scroll content

```swift
// BEFORE
struct SettingsView: View {
    var body: some View {
        Form { … }
    }
}

// AFTER
struct SettingsView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Form { … }
            .themedListBackground()
            .themedNavigationBar()
    }
}
```

### Accent / tint usage

```swift
// BEFORE — hardcoded
Button("Save") { … }
    .tint(.blue)

// AFTER — not needed: .themed() at app root already sets global tint to theme.accent
Button("Save") { … }
// or explicitly:
Button("Save") { … }
    .tint(theme.accent)
```

---

## Migration Checklist (per screen)

- [ ] Add `@Environment(\.theme) private var theme` if accessing tokens directly
- [ ] Replace root `.background(Color(.systemGroupedBackground))` → `.themedScreen()`
- [ ] Replace `List`/`Form` background → `.themedListBackground()`
- [ ] Replace `.background(Color(.secondarySystemGroupedBackground))` on cards → `.themedCard()`
- [ ] Replace `.foregroundStyle(.primary)` / `.foregroundStyle(Color(.label))` → `.foregroundStyle(theme.textPrimary)`
- [ ] Replace `.foregroundStyle(.secondary)` → `.foregroundStyle(theme.textSecondary)`
- [ ] Replace `Color(.separator)` / `Divider()` color → `theme.divider`
- [ ] Replace hardcoded `.tint(.blue)` → `.tint(theme.accent)` (or remove — root `.themed()` handles it)
- [ ] Add `.themedNavigationBar()` to each NavigationStack root
- [ ] Add `.themedTabBar()` to the root TabView (once per app)

---

## What NOT to change

- `Color.red`, `Color.green` for non-semantic UI (charts, category dots, sport-specific colors)
- SF Symbol colors driven by system tint — `.themed()` handles this globally
- `Color.white` / `Color.black` used deliberately for contrast on gradient areas

---

## Host synchronization

Theme preferences use `NSUbiquitousKeyValueStore` with a local fallback. Synchronization across devices or apps depends on the host entitlements and store configuration. The `CHThemeCloudSyncEnabledDefaultsKey` Info.plist entry can name a per-device Boolean setting that gates cloud access. Apps with custom palettes should configure them before `ThemeManager.shared` is initialized.
