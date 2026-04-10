import SwiftUI

/// A complete visual theme. Tokens map directly to SwiftUI `Color` so callers
/// can write `theme.background` instead of duct-taping their own palette.
///
/// Each `Theme` carries both a light and dark variant; the active variant is
/// chosen by `ThemeManager` from the current `ColorScheme`.
public struct Theme: Identifiable, Sendable, Equatable {

    /// One half of a `Theme` (light or dark). Holds the actual `Color` tokens.
    public struct Variant: Sendable, Equatable {
        public var accent: Color
        public var background: Color
        public var card: Color
        public var textPrimary: Color
        public var textSecondary: Color
        public var divider: Color
        public var success: Color
        public var warning: Color
        public var error: Color
        public var gradientStart: Color
        public var gradientEnd: Color

        public init(
            accent: Color,
            background: Color,
            card: Color,
            textPrimary: Color,
            textSecondary: Color,
            divider: Color,
            success: Color,
            warning: Color,
            error: Color,
            gradientStart: Color,
            gradientEnd: Color
        ) {
            self.accent = accent
            self.background = background
            self.card = card
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.divider = divider
            self.success = success
            self.warning = warning
            self.error = error
            self.gradientStart = gradientStart
            self.gradientEnd = gradientEnd
        }
    }

    /// Stable identifier persisted in iCloud KVS. Lowercase, no spaces.
    public let id: String

    /// Display name shown in pickers ("Midnight", "Ocean", …).
    public let name: String

    /// Short marketing-style tagline shown beneath the name in the picker.
    public let tagline: String

    /// SF Symbol used to represent the theme in the picker grid.
    public let iconName: String

    /// Bundle name of the alternate app icon to set when this theme is
    /// applied. `nil` means "primary AppIcon — use `setAlternateIconName(nil)`".
    public let associatedIconName: String?

    public let light: Variant
    public let dark: Variant

    public init(
        id: String,
        name: String,
        tagline: String,
        iconName: String,
        associatedIconName: String?,
        light: Variant,
        dark: Variant
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.iconName = iconName
        self.associatedIconName = associatedIconName
        self.light = light
        self.dark = dark
    }

    /// Resolve the variant to use for a given color scheme.
    public func variant(for colorScheme: ColorScheme) -> Variant {
        colorScheme == .dark ? dark : light
    }
}

// MARK: - Resolved theme (variant + colorScheme)

/// A `Theme` resolved against the current color scheme. Views read this
/// through `@Environment(\.theme)` and access tokens directly:
///
///     @Environment(\.theme) private var theme
///     // …
///     .background(theme.background)
///     .foregroundStyle(theme.textPrimary)
public struct ResolvedTheme: Sendable, Equatable {
    public let theme: Theme
    public let colorScheme: ColorScheme

    public init(theme: Theme, colorScheme: ColorScheme) {
        self.theme = theme
        self.colorScheme = colorScheme
    }

    private var v: Theme.Variant { theme.variant(for: colorScheme) }

    public var id: String { theme.id }
    public var name: String { theme.name }
    public var iconName: String { theme.iconName }
    public var associatedIconName: String? { theme.associatedIconName }

    public var accent: Color { v.accent }
    public var background: Color { v.background }
    public var card: Color { v.card }
    public var textPrimary: Color { v.textPrimary }
    public var textSecondary: Color { v.textSecondary }
    public var divider: Color { v.divider }
    public var success: Color { v.success }
    public var warning: Color { v.warning }
    public var error: Color { v.error }
    public var gradientStart: Color { v.gradientStart }
    public var gradientEnd: Color { v.gradientEnd }

    /// Convenience: linear gradient between gradientStart → gradientEnd.
    public var gradient: LinearGradient {
        LinearGradient(
            colors: [v.gradientStart, v.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = ResolvedTheme(
        theme: .default,
        colorScheme: .light
    )
}

public extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
