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
/// **Large title behavior:**
/// `.toolbarBackground(.visible)` is intentionally NOT applied here. Forcing
/// visibility makes SwiftUI set `scrollEdgeAppearance = standardAppearance`,
/// which prevents the nav bar from ever entering large-title mode (iOS needs
/// a transparent scroll-edge appearance to expand the large title). Without
/// `.visible`, the themed background appears naturally when content scrolls
/// away from the top — matching standard iOS behavior.
///
/// **Color scheme:**
/// `UIColor(color).getRed(...)` silently returns 0 for SwiftUI dynamic colors
/// (which have no resolved value without a trait collection). We resolve in the
/// `.light` trait collection to determine the theme's intrinsic luminance, then
/// apply `.toolbarColorScheme` so inline titles contrast correctly against the
/// themed background.
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
            // NOTE: .toolbarBackground(.visible) is deliberately absent.
            // Forcing visibility sets scrollEdgeAppearance = standardAppearance,
            // which prevents large titles from expanding when scrolled to top.
            .toolbarColorScheme(isDarkBackground ? .dark : .light, for: .navigationBar)
        #else
        content
        #endif
    }

    #if os(iOS)
    /// Returns true when `theme.background` is perceptually dark (luma < 0.5).
    /// Resolves in .light trait collection so dynamic colors return a real value
    /// instead of the silent-zero the default resolution path returns.
    private var isDarkBackground: Bool {
        let resolved = UIColor(theme.background)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
    #endif
}

public extension View {
    /// Style the navigation bar to match the active theme.
    ///
    /// Sets `theme.background` as the nav bar fill (visible when scrolled) and
    /// applies the correct color scheme for inline title contrast. Large titles
    /// work correctly because the scroll-edge appearance remains transparent.
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
