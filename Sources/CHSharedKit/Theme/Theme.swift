import SwiftUI

// MARK: - ThemeColor

/// A color that carries both a light-mode and dark-mode variant. Stored as
/// raw sRGB components so the whole `Theme` graph is `Codable` (SwiftUI's
/// `Color` is not).
public struct ThemeColor: Sendable, Equatable, Codable, Hashable {

    /// sRGB component triplet with alpha.
    public struct RGBA: Sendable, Equatable, Codable, Hashable {
        public var r: Double
        public var g: Double
        public var b: Double
        public var a: Double

        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        public var color: Color {
            Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
    }

    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    /// Convenience: build from `(r, g, b)` tuples in 0…1 sRGB space.
    public init(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) {
        self.light = .init(light.0, light.1, light.2)
        self.dark = .init(dark.0, dark.1, dark.2)
    }

    /// Resolve to a SwiftUI `Color` for the given color scheme.
    public func color(for scheme: ColorScheme) -> Color {
        scheme == .dark ? dark.color : light.color
    }
}

// MARK: - Theme

/// A complete visual theme. Every color token is a `ThemeColor` so the whole
/// theme is `Codable` and round-trips through KVS / disk without loss.
public struct Theme: Identifiable, Sendable, Equatable, Codable, Hashable {

    /// Stable identifier persisted in iCloud KVS. Lowercase, no spaces.
    public let id: String

    /// Display name shown in pickers ("Midnight", "Ocean", …).
    public let name: String

    /// One-line description shown beneath the name in the picker.
    public let description: String

    /// SF Symbol used to represent the theme in the picker grid.
    public let symbol: String

    /// Bundle name of the alternate app icon to set when this theme is
    /// applied. `nil` means "primary AppIcon — use `setAlternateIconName(nil)`".
    public let associatedIconName: String?

    public let accent: ThemeColor
    public let accentSecondary: ThemeColor
    public let background: ThemeColor
    public let backgroundElevated: ThemeColor
    public let card: ThemeColor
    public let cardElevated: ThemeColor
    public let textPrimary: ThemeColor
    public let textSecondary: ThemeColor
    public let textTertiary: ThemeColor
    public let divider: ThemeColor
    public let success: ThemeColor
    public let warning: ThemeColor
    public let error: ThemeColor
    public let gradientStart: ThemeColor
    public let gradientEnd: ThemeColor

    public init(
        id: String,
        name: String,
        description: String,
        symbol: String,
        associatedIconName: String?,
        accent: ThemeColor,
        accentSecondary: ThemeColor,
        background: ThemeColor,
        backgroundElevated: ThemeColor,
        card: ThemeColor,
        cardElevated: ThemeColor,
        textPrimary: ThemeColor,
        textSecondary: ThemeColor,
        textTertiary: ThemeColor,
        divider: ThemeColor,
        success: ThemeColor,
        warning: ThemeColor,
        error: ThemeColor,
        gradientStart: ThemeColor,
        gradientEnd: ThemeColor
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.symbol = symbol
        self.associatedIconName = associatedIconName
        self.accent = accent
        self.accentSecondary = accentSecondary
        self.background = background
        self.backgroundElevated = backgroundElevated
        self.card = card
        self.cardElevated = cardElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.divider = divider
        self.success = success
        self.warning = warning
        self.error = error
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
    }
}

// MARK: - ResolvedTheme

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

    public var id: String { theme.id }
    public var name: String { theme.name }
    public var description: String { theme.description }
    public var symbol: String { theme.symbol }
    public var associatedIconName: String? { theme.associatedIconName }

    public var accent: Color { theme.accent.color(for: colorScheme) }
    public var accentSecondary: Color { theme.accentSecondary.color(for: colorScheme) }
    public var background: Color { theme.background.color(for: colorScheme) }
    public var backgroundElevated: Color { theme.backgroundElevated.color(for: colorScheme) }
    public var card: Color { theme.card.color(for: colorScheme) }
    public var cardElevated: Color { theme.cardElevated.color(for: colorScheme) }
    public var textPrimary: Color { theme.textPrimary.color(for: colorScheme) }
    public var textSecondary: Color { theme.textSecondary.color(for: colorScheme) }
    public var textTertiary: Color { theme.textTertiary.color(for: colorScheme) }
    public var divider: Color { theme.divider.color(for: colorScheme) }
    public var success: Color { theme.success.color(for: colorScheme) }
    public var warning: Color { theme.warning.color(for: colorScheme) }
    public var error: Color { theme.error.color(for: colorScheme) }
    public var gradientStart: Color { theme.gradientStart.color(for: colorScheme) }
    public var gradientEnd: Color { theme.gradientEnd.color(for: colorScheme) }

    /// Convenience: linear gradient between gradientStart → gradientEnd.
    public var gradient: LinearGradient {
        LinearGradient(
            colors: [gradientStart, gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = ResolvedTheme(
        theme: Theme.default,
        colorScheme: .light
    )
}

public extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
