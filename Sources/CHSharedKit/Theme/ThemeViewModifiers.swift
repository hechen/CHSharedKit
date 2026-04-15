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
/// **Why UINavigationBarAppearance instead of `.toolbarColorScheme`:**
/// `.toolbarColorScheme` mirrors the *system* color scheme, not the
/// *theme's* background brightness. If the user picks a dark-background
/// theme while the system is in light mode, `.toolbarColorScheme(.light)`
/// would render dark title text on a dark background — invisible.
/// It also doesn't reliably control large-title text color on all iOS
/// versions. Instead we drive `UINavigationBarAppearance` directly with
/// explicit text attributes keyed to `UIColor.label` (which adapts to
/// light/dark automatically) so titles always contrast against the
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
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { applyNavBarAppearance(theme.background) }
            .onChange(of: theme.background) { _, bg in applyNavBarAppearance(bg) }
        #else
        content
        #endif
    }

    #if os(iOS)
    private func applyNavBarAppearance(_ background: Color) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label,
        ]
        let uiBg = UIColor(background)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = uiBg
        appearance.titleTextAttributes = titleAttrs
        appearance.largeTitleTextAttributes = titleAttrs

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactScrollEdgeAppearance = appearance

        // Refresh any live navigation bars
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                refreshNavBarsInView(window)
            }
        }
    }

    private func refreshNavBarsInView(_ view: UIView) {
        if let navBar = view as? UINavigationBar {
            navBar.standardAppearance = UINavigationBar.appearance().standardAppearance
            navBar.compactAppearance = UINavigationBar.appearance().compactAppearance
            if let se = UINavigationBar.appearance().scrollEdgeAppearance {
                navBar.scrollEdgeAppearance = se
            }
            if let cse = UINavigationBar.appearance().compactScrollEdgeAppearance {
                navBar.compactScrollEdgeAppearance = cse
            }
        }
        for subview in view.subviews { refreshNavBarsInView(subview) }
    }
    #endif
}

public extension View {
    /// Style the navigation bar to match the active theme.
    ///
    /// Applies `theme.background` as the nav bar fill and explicitly sets
    /// title text to `UIColor.label` so large titles are always visible
    /// regardless of which theme or system color scheme is active.
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
