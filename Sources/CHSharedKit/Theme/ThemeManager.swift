import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Central theme controller. Persists the user's choice in
/// `NSUbiquitousKeyValueStore` so it syncs across devices and apps, observes
/// external KVS changes, and (on iOS) flips the alternate app icon when the
/// theme changes.
///
/// Inject once at the app root:
///
///     @main struct MyApp: App {
///         @StateObject private var themeManager = ThemeManager.shared
///         var body: some Scene {
///             WindowGroup {
///                 ContentView()
///                     .environmentObject(themeManager)
///                     .themed(themeManager)
///             }
///         }
///     }
@MainActor
public final class ThemeManager: ObservableObject {

    /// iCloud KVS key. Shared across all CHSharedKit-using apps so the
    /// user's theme preference travels with them.
    nonisolated public static let kvsKey = "chs.theme.id"

    /// Process-wide singleton. Apps may construct their own instance for
    /// tests, but production code should always use `.shared`.
    public static let shared = ThemeManager()

    @Published public private(set) var currentTheme: Theme

    private let cloud = NSUbiquitousKeyValueStore.default

    public init() {
        // Prefer iCloud over UserDefaults so a fresh device picks up the
        // user's existing choice immediately.
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: Self.kvsKey)
            ?? UserDefaults.standard.string(forKey: Self.kvsKey)
        self.currentTheme = ThemePalette.theme(for: raw)

        cloud.synchronize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalKVSChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Apply a theme by id. Persists to KVS, swaps alternate icon, fires
    /// `objectWillChange` so SwiftUI redraws.
    public func apply(themeId: String, animated: Bool = true) {
        let next = ThemePalette.theme(for: themeId)
        guard next.id != currentTheme.id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.currentTheme = next
            }
        } else {
            self.currentTheme = next
        }
        persist(next.id)
        updateAlternateIcon(for: next)
    }

    /// Convenience overload for `Theme` instances.
    public func apply(_ theme: Theme, animated: Bool = true) {
        apply(themeId: theme.id, animated: animated)
    }

    private func persist(_ id: String) {
        cloud.set(id, forKey: Self.kvsKey)
        cloud.synchronize()
        UserDefaults.standard.set(id, forKey: Self.kvsKey)
    }

    @objc nonisolated private func externalKVSChange(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              keys.contains(Self.kvsKey) else { return }
        Task { @MainActor in
            let raw = self.cloud.string(forKey: Self.kvsKey)
            let next = ThemePalette.theme(for: raw)
            if next.id != self.currentTheme.id {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.currentTheme = next
                }
                self.updateAlternateIcon(for: next)
            }
        }
    }

    /// Resolve the current theme against a color scheme.
    public func resolved(for colorScheme: ColorScheme) -> ResolvedTheme {
        ResolvedTheme(theme: currentTheme, colorScheme: colorScheme)
    }

    // MARK: - Alternate icon

    private func updateAlternateIcon(for theme: Theme) {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let target = theme.associatedIconName
        if app.alternateIconName == target { return }
        app.setAlternateIconName(target) { error in
            if let error {
                // Logged but not surfaced — alternate icons can fail when the
                // bundle's CFBundleAlternateIcons doesn't include the name.
                // Themes still work; only the icon swap is missing.
                #if DEBUG
                print("[ThemeManager] setAlternateIconName(\(target ?? "nil")) failed: \(error.localizedDescription)")
                #endif
            }
        }
        #endif
    }
}

// MARK: - View modifier

private struct ThemedModifier: ViewModifier {
    @ObservedObject var manager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let resolved = ResolvedTheme(theme: manager.currentTheme, colorScheme: colorScheme)
        content
            .environment(\.theme, resolved)
            .tint(resolved.accent)
            .onAppear { syncTabBar(resolved) }
            .onChange(of: manager.currentTheme.id) { _, _ in syncTabBar(resolved) }
            .onChange(of: colorScheme) { _, _ in syncTabBar(resolved) }
    }

    private func syncTabBar(_ resolved: ResolvedTheme) {
        #if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
        applyTabBarAppearance(UIColor(resolved.accent))
        #endif
    }
}

public extension View {
    /// Inject the active `ResolvedTheme` into the environment and set the
    /// global SwiftUI tint to the theme's accent color. Apply once at the
    /// app root.
    func themed(_ manager: ThemeManager) -> some View {
        modifier(ThemedModifier(manager: manager))
    }
}

// MARK: - Tab bar appearance

/// Configures `UITabBarAppearance` so only the selected tab uses the accent
/// color. Without this, `.tint()` at the root makes ALL tab items render in
/// the accent color, losing the selected/unselected distinction.
///
/// Sets `standardAppearance` AND `scrollEdgeAppearance` (the iOS 15 scroll-
/// edge variant that otherwise falls back to defaults and causes the bug to
/// reappear when the user scrolls).  Also refreshes any tab bars already
/// on screen so a runtime theme change is immediately visible.
#if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
private func applyTabBarAppearance(_ selected: UIColor) {
    let unselected = UIColor.secondaryLabel

    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()

    for layout in [appearance.stackedLayoutAppearance,
                   appearance.inlineLayoutAppearance,
                   appearance.compactInlineLayoutAppearance] {
        layout.normal.iconColor = unselected
        layout.normal.titleTextAttributes = [.foregroundColor: unselected]
        layout.selected.iconColor = selected
        layout.selected.titleTextAttributes = [.foregroundColor: selected]
    }

    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance

    // Push updated appearance to tab bars already on screen (appearance proxies
    // only affect future instances; live instances need an explicit refresh).
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
            refreshTabBarsInView(window)
        }
    }
}

private func refreshTabBarsInView(_ view: UIView) {
    if let tabBar = view as? UITabBar {
        tabBar.standardAppearance = UITabBar.appearance().standardAppearance
        if let scrollEdge = UITabBar.appearance().scrollEdgeAppearance {
            tabBar.scrollEdgeAppearance = scrollEdge
        }
    }
    for subview in view.subviews {
        refreshTabBarsInView(subview)
    }
}
#endif
