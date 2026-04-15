import SwiftUI

// MARK: - .themedScreen()

/// Applies `theme.background` as the full-screen root background.
/// Use this on the outermost view of every screen (NavigationStack root,
/// sheet root, TabView tab root).
///
/// Matches exactly how `ThemePickerView` renders its root:
/// ```swift
/// .background(currentTheme.background.ignoresSafeArea())
/// ```
///
/// **Usage:**
/// ```swift
/// struct FeedView: View {
///     @Environment(\.theme) private var theme
///     var body: some View {
///         List { … }
///             .themedScreen()
///     }
/// }
/// ```
private struct ThemedScreenModifier: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content.background(theme.background.ignoresSafeArea())
    }
}

public extension View {
    /// Fill the screen with `theme.background`, extending behind safe-area insets.
    func themedScreen() -> some View {
        modifier(ThemedScreenModifier())
    }
}

// MARK: - .themedCard()

/// Wraps content in a themed card: `theme.card` fill, `cornerRadius` (default 16),
/// a subtle border (`theme.divider`), and a shadow. This recreates the look of
/// each card in `ThemePickerView` — the reference for the cross-app aesthetic.
///
/// **Usage:**
/// ```swift
/// VStack { … }
///     .themedCard()
///
/// // Elevated variant (slightly lighter card surface):
/// VStack { … }
///     .themedCard(elevated: true)
/// ```
private struct ThemedCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat
    var elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(elevated ? theme.cardElevated : theme.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(0.08),
                radius: elevated ? 8 : 4,
                x: 0,
                y: elevated ? 4 : 2
            )
    }
}

public extension View {
    /// Style content as a themed card matching the ThemePickerView card aesthetic.
    func themedCard(cornerRadius: CGFloat = 16, elevated: Bool = false) -> some View {
        modifier(ThemedCardModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

// MARK: - .themedListBackground()

/// Sets `theme.background` on a `List` or `Form`. SwiftUI Lists don't
/// respond to `.background()` directly — this applies `.scrollContentBackground(.hidden)`
/// and fills with the theme color.
///
/// **Usage:**
/// ```swift
/// List { … }
///     .themedListBackground()
/// ```
private struct ThemedListBackgroundModifier: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
    }
}

public extension View {
    /// Apply `theme.background` to a List or Form (handles `.scrollContentBackground`).
    func themedListBackground() -> some View {
        modifier(ThemedListBackgroundModifier())
    }
}

// MARK: - .themedNavigationBar()

/// Configures the navigation bar background and title colors to match the
/// active theme. Call once at the root of a `NavigationStack`.
///
/// **Why luminance-based toolbarColorScheme instead of UIKit appearance proxy:**
/// The UIKit `UINavigationBar.appearance()` proxy is set globally and can be
/// overridden by SwiftUI's internal NavigationStack rendering on tab switches
/// and navigation transitions. Worse, it only applies to bars that exist when
/// `.onAppear` fires — newly-created bars (e.g. after a tab switch) inherit
/// SwiftUI defaults that may not match.
///
/// The correct SwiftUI-native approach: compute whether `theme.background` is
/// perceptually dark (luminance < 0.5) and drive `.toolbarColorScheme(.dark)`
/// or `.toolbarColorScheme(.light)` accordingly. SwiftUI manages title text
/// contrast automatically from there. This is reactive: when the theme changes,
/// the modifier updates without any UIKit side effects.
///
/// **Usage:**
/// ```swift
/// NavigationStack {
///     FeedView()
///         .themedNavigationBar()
/// }
/// ```
private struct ThemedNavigationBarModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(isDarkBackground ? .dark : .light, for: .navigationBar)
        #else
        content
        #endif
    }

    #if os(iOS)
    /// Returns true when `theme.background` has a perceptual luminance below 0.5.
    /// Uses the ITU-R BT.601 luma formula matching human brightness perception.
    private var isDarkBackground: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(theme.background).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
    #endif
}

public extension View {
    /// Style the navigation bar to match the active theme.
    ///
    /// Sets `theme.background` as the nav bar fill and automatically picks
    /// `.dark` or `.light` color scheme based on background luminance so
    /// titles (including large titles) always contrast correctly regardless
    /// of which theme or system appearance is active.
    func themedNavigationBar() -> some View {
        modifier(ThemedNavigationBarModifier())
    }
}

// MARK: - .themedTabBar()

/// Tints the tab bar background to `theme.backgroundElevated`.
private struct ThemedTabBarModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(theme.backgroundElevated, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        #else
        content
        #endif
    }
}

public extension View {
    /// Style the tab bar to match the active theme.
    func themedTabBar() -> some View {
        modifier(ThemedTabBarModifier())
    }
}
