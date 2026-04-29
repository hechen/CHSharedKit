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

    /// Re-applies the alternate icon for the current theme if it has drifted
    /// (e.g. after the OS resets it while the app is backgrounded). Call on
    /// `scenePhase == .active`.
    public func syncIconIfNeeded() {
        updateAlternateIcon(for: currentTheme)
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
        TabBarAppearanceCoordinator.shared.apply(UIColor(resolved.accent))
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

/// Coordinator that owns the `UITabBarAppearance` and re-applies it whenever
/// iOS would otherwise reset to defaults. Without re-application:
///
/// - Returning from a pushed `NavigationLink` can leave the live tab bar in a
///   transition state where `iconColor` resolves through `tintColor`
///   inheritance — every item renders in the accent color.
/// - iPad split-view / iPhone landscape pulls `compactAppearance`, which
///   wasn't set in 2.7.1, so the tab bar fell back to the system default
///   appearance and the same all-tinted symptom appeared.
/// - Scene re-activation (multi-window, app switcher) drops the proxy state
///   on some iOS 17/18 builds.
///
/// Strategy: cache the latest accent, set all three appearance variants
/// (`standardAppearance`, `scrollEdgeAppearance`, `compactAppearance`) on the
/// proxy AND on every live tab bar, and re-apply on scene activation,
/// foreground, and window-key changes.
#if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
@MainActor
final class TabBarAppearanceCoordinator {
    static let shared = TabBarAppearanceCoordinator()

    private var lastSelected: UIColor = .tintColor
    private var didRegisterObservers = false

    private init() {}

    /// Apply the appearance with the given selected (accent) color and arm
    /// the notification-driven re-applications.
    func apply(_ selected: UIColor) {
        lastSelected = selected
        registerObserversIfNeeded()
        configure(selected: selected)
    }

    private func registerObserversIfNeeded() {
        guard !didRegisterObservers else { return }
        didRegisterObservers = true
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIScene.didActivateNotification,
            UIApplication.willEnterForegroundNotification,
            UIWindow.didBecomeKeyNotification,
        ]
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyLast() }
            }
        }
    }

    private func reapplyLast() {
        configure(selected: lastSelected)
    }

    private func configure(selected: UIColor) {
        // Solid systemGray — semi-transparent .secondaryLabel can resolve
        // to tintColor during navigation transitions on iOS 17+.
        let unselected = UIColor.systemGray

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

        let proxy = UITabBar.appearance()
        proxy.standardAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        // 2.7.3: `compactAppearance` was removed from the iOS 26 SDK in
        // favour of unified appearance via `standardAppearance`. Setting
        // it via the Swift symbol no longer compiles when building
        // against iPhoneOS26.sdk; bridge through KVC so older runtimes
        // still receive the value while iOS 26 silently no-ops.
        if proxy.responds(to: NSSelectorFromString("setCompactAppearance:")) {
            proxy.setValue(appearance, forKey: "compactAppearance")
        }

        // Live tab bars need an explicit refresh; appearance proxies only
        // affect future instances. Refresh once now and once on the next
        // run loop tick to catch tab bars whose layout straddles a
        // transition (the "back from pushed view" case).
        refreshLiveTabBars(with: appearance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshLiveTabBars(with: appearance)
        }
    }

    private func refreshLiveTabBars(with appearance: UITabBarAppearance) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                refresh(view: window, with: appearance)
            }
        }
    }

    private func refresh(view: UIView, with appearance: UITabBarAppearance) {
        if let tabBar = view as? UITabBar {
            tabBar.standardAppearance = appearance
            tabBar.scrollEdgeAppearance = appearance
            // See note above re: iOS 26 SDK removing this symbol.
            if tabBar.responds(to: NSSelectorFromString("setCompactAppearance:")) {
                tabBar.setValue(appearance, forKey: "compactAppearance")
            }
        }
        for subview in view.subviews {
            refresh(view: subview, with: appearance)
        }
    }
}
#endif
