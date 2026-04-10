import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Central theme controller. Persists the user's choice in
/// `NSUbiquitousKeyValueStore` so it syncs across devices, observes external
/// KVS changes, and (on iOS) flips the alternate app icon when the theme
/// changes.
///
/// Inject once at the app root:
///
///     @main struct MyApp: App {
///         @StateObject private var themeManager = ThemeManager.shared
///         var body: some Scene {
///             WindowGroup {
///                 ContentView()
///                     .environmentObject(themeManager)
///                     .themed(themeManager) // sets @Environment(\.theme)
///             }
///         }
///     }
@MainActor
public final class ThemeManager: ObservableObject {

    /// iCloud KVS key. Shared across all CHSharedKit-using apps so the
    /// user's theme preference travels with them.
    public static let kvsKey = "chs.theme.id"

    /// Process-wide singleton. Apps may construct their own instance for
    /// tests, but production code should always use `.shared`.
    public static let shared = ThemeManager()

    @Published public private(set) var theme: Theme

    private let cloud = NSUbiquitousKeyValueStore.default

    public init() {
        // Prefer iCloud over UserDefaults so a fresh device picks up the
        // user's existing choice immediately.
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: Self.kvsKey)
            ?? UserDefaults.standard.string(forKey: Self.kvsKey)
        self.theme = ThemePalette.theme(for: raw)

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
        guard next.id != theme.id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.theme = next
            }
        } else {
            self.theme = next
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

    @objc private func externalKVSChange(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              keys.contains(Self.kvsKey) else { return }
        Task { @MainActor in
            let raw = self.cloud.string(forKey: Self.kvsKey)
            let next = ThemePalette.theme(for: raw)
            if next.id != self.theme.id {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.theme = next
                }
                self.updateAlternateIcon(for: next)
            }
        }
    }

    /// Resolve the current theme against a color scheme.
    public func resolved(for colorScheme: ColorScheme) -> ResolvedTheme {
        ResolvedTheme(theme: theme, colorScheme: colorScheme)
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
        let resolved = ResolvedTheme(theme: manager.theme, colorScheme: colorScheme)
        content
            .environment(\.theme, resolved)
            .tint(resolved.accent)
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
