import SwiftUI

/// Pre-designed themes shipped with CHSharedKit. All apps see the same
/// palette so users can carry their preferred theme across apps via iCloud KVS.
public enum ThemePalette {

    /// All themes in display order.
    public static let all: [Theme] = [
        .default,
        .midnight,
        .ocean,
        .sunset,
        .forest,
        .paper,
        .aurora,
        .monochrome
    ]

    /// Look up a theme by id. Falls back to `.default` if unknown so a
    /// removed theme can never leave the app in a broken state.
    public static func theme(for id: String?) -> Theme {
        guard let id else { return .default }
        return all.first(where: { $0.id == id }) ?? .default
    }
}

// MARK: - Themes

public extension Theme {

    // ---- Default (warm blue) ----
    static let `default` = Theme(
        id: "default",
        name: "Default",
        tagline: "Crisp & familiar",
        iconName: "circle.lefthalf.filled",
        associatedIconName: nil,
        light: .init(
            accent:        Color(red: 0.10, green: 0.45, blue: 0.95),
            background:    Color(red: 0.97, green: 0.97, blue: 0.98),
            card:          .white,
            textPrimary:   Color(red: 0.08, green: 0.08, blue: 0.10),
            textSecondary: Color(red: 0.42, green: 0.42, blue: 0.46),
            divider:       Color(red: 0.88, green: 0.88, blue: 0.90),
            success:       Color(red: 0.18, green: 0.70, blue: 0.40),
            warning:       Color(red: 0.96, green: 0.65, blue: 0.14),
            error:         Color(red: 0.93, green: 0.27, blue: 0.30),
            gradientStart: Color(red: 0.30, green: 0.55, blue: 0.98),
            gradientEnd:   Color(red: 0.10, green: 0.35, blue: 0.85)
        ),
        dark: .init(
            accent:        Color(red: 0.40, green: 0.66, blue: 1.00),
            background:    Color(red: 0.06, green: 0.06, blue: 0.08),
            card:          Color(red: 0.12, green: 0.12, blue: 0.14),
            textPrimary:   Color(red: 0.97, green: 0.97, blue: 0.98),
            textSecondary: Color(red: 0.65, green: 0.65, blue: 0.70),
            divider:       Color(red: 0.22, green: 0.22, blue: 0.25),
            success:       Color(red: 0.36, green: 0.85, blue: 0.55),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.30),
            error:         Color(red: 1.00, green: 0.45, blue: 0.45),
            gradientStart: Color(red: 0.20, green: 0.45, blue: 0.95),
            gradientEnd:   Color(red: 0.05, green: 0.20, blue: 0.55)
        )
    )

    // ---- Midnight (deep purple/indigo) ----
    static let midnight = Theme(
        id: "midnight",
        name: "Midnight",
        tagline: "Deep indigo nights",
        iconName: "moon.stars.fill",
        associatedIconName: "AppIcon-Midnight",
        light: .init(
            accent:        Color(red: 0.36, green: 0.20, blue: 0.78),
            background:    Color(red: 0.96, green: 0.96, blue: 0.99),
            card:          .white,
            textPrimary:   Color(red: 0.08, green: 0.06, blue: 0.16),
            textSecondary: Color(red: 0.40, green: 0.36, blue: 0.50),
            divider:       Color(red: 0.86, green: 0.84, blue: 0.92),
            success:       Color(red: 0.20, green: 0.70, blue: 0.55),
            warning:       Color(red: 0.95, green: 0.60, blue: 0.20),
            error:         Color(red: 0.92, green: 0.25, blue: 0.45),
            gradientStart: Color(red: 0.42, green: 0.22, blue: 0.85),
            gradientEnd:   Color(red: 0.16, green: 0.08, blue: 0.45)
        ),
        dark: .init(
            accent:        Color(red: 0.62, green: 0.45, blue: 1.00),
            background:    Color(red: 0.05, green: 0.04, blue: 0.10),
            card:          Color(red: 0.11, green: 0.09, blue: 0.18),
            textPrimary:   Color(red: 0.95, green: 0.94, blue: 1.00),
            textSecondary: Color(red: 0.62, green: 0.58, blue: 0.74),
            divider:       Color(red: 0.20, green: 0.17, blue: 0.30),
            success:       Color(red: 0.34, green: 0.85, blue: 0.66),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.34),
            error:         Color(red: 1.00, green: 0.45, blue: 0.58),
            gradientStart: Color(red: 0.36, green: 0.18, blue: 0.78),
            gradientEnd:   Color(red: 0.08, green: 0.04, blue: 0.32)
        )
    )

    // ---- Ocean (teal/cyan) ----
    static let ocean = Theme(
        id: "ocean",
        name: "Ocean",
        tagline: "Tide & turquoise",
        iconName: "water.waves",
        associatedIconName: "AppIcon-Ocean",
        light: .init(
            accent:        Color(red: 0.04, green: 0.55, blue: 0.62),
            background:    Color(red: 0.95, green: 0.98, blue: 0.99),
            card:          .white,
            textPrimary:   Color(red: 0.05, green: 0.16, blue: 0.20),
            textSecondary: Color(red: 0.32, green: 0.46, blue: 0.50),
            divider:       Color(red: 0.82, green: 0.92, blue: 0.94),
            success:       Color(red: 0.16, green: 0.72, blue: 0.50),
            warning:       Color(red: 0.96, green: 0.66, blue: 0.18),
            error:         Color(red: 0.94, green: 0.30, blue: 0.36),
            gradientStart: Color(red: 0.20, green: 0.72, blue: 0.78),
            gradientEnd:   Color(red: 0.04, green: 0.42, blue: 0.55)
        ),
        dark: .init(
            accent:        Color(red: 0.30, green: 0.85, blue: 0.90),
            background:    Color(red: 0.02, green: 0.08, blue: 0.10),
            card:          Color(red: 0.06, green: 0.14, blue: 0.16),
            textPrimary:   Color(red: 0.94, green: 0.99, blue: 1.00),
            textSecondary: Color(red: 0.55, green: 0.75, blue: 0.78),
            divider:       Color(red: 0.14, green: 0.24, blue: 0.27),
            success:       Color(red: 0.36, green: 0.88, blue: 0.65),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.32),
            error:         Color(red: 1.00, green: 0.46, blue: 0.50),
            gradientStart: Color(red: 0.10, green: 0.55, blue: 0.65),
            gradientEnd:   Color(red: 0.02, green: 0.20, blue: 0.30)
        )
    )

    // ---- Sunset (warm orange/pink) ----
    static let sunset = Theme(
        id: "sunset",
        name: "Sunset",
        tagline: "Golden hour glow",
        iconName: "sun.horizon.fill",
        associatedIconName: "AppIcon-Sunset",
        light: .init(
            accent:        Color(red: 0.92, green: 0.42, blue: 0.30),
            background:    Color(red: 1.00, green: 0.97, blue: 0.95),
            card:          .white,
            textPrimary:   Color(red: 0.20, green: 0.10, blue: 0.05),
            textSecondary: Color(red: 0.50, green: 0.36, blue: 0.30),
            divider:       Color(red: 0.96, green: 0.88, blue: 0.82),
            success:       Color(red: 0.32, green: 0.72, blue: 0.45),
            warning:       Color(red: 0.96, green: 0.66, blue: 0.18),
            error:         Color(red: 0.90, green: 0.20, blue: 0.30),
            gradientStart: Color(red: 1.00, green: 0.62, blue: 0.34),
            gradientEnd:   Color(red: 0.92, green: 0.28, blue: 0.42)
        ),
        dark: .init(
            accent:        Color(red: 1.00, green: 0.58, blue: 0.40),
            background:    Color(red: 0.10, green: 0.05, blue: 0.05),
            card:          Color(red: 0.18, green: 0.10, blue: 0.10),
            textPrimary:   Color(red: 1.00, green: 0.96, blue: 0.92),
            textSecondary: Color(red: 0.78, green: 0.62, blue: 0.55),
            divider:       Color(red: 0.30, green: 0.18, blue: 0.18),
            success:       Color(red: 0.45, green: 0.85, blue: 0.55),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.34),
            error:         Color(red: 1.00, green: 0.40, blue: 0.45),
            gradientStart: Color(red: 0.95, green: 0.45, blue: 0.30),
            gradientEnd:   Color(red: 0.55, green: 0.10, blue: 0.20)
        )
    )

    // ---- Forest (sage green) ----
    static let forest = Theme(
        id: "forest",
        name: "Forest",
        tagline: "Sage & moss",
        iconName: "leaf.fill",
        associatedIconName: "AppIcon-Forest",
        light: .init(
            accent:        Color(red: 0.20, green: 0.52, blue: 0.30),
            background:    Color(red: 0.96, green: 0.98, blue: 0.95),
            card:          .white,
            textPrimary:   Color(red: 0.07, green: 0.16, blue: 0.10),
            textSecondary: Color(red: 0.34, green: 0.44, blue: 0.36),
            divider:       Color(red: 0.86, green: 0.92, blue: 0.85),
            success:       Color(red: 0.18, green: 0.68, blue: 0.34),
            warning:       Color(red: 0.92, green: 0.66, blue: 0.18),
            error:         Color(red: 0.86, green: 0.32, blue: 0.32),
            gradientStart: Color(red: 0.40, green: 0.72, blue: 0.42),
            gradientEnd:   Color(red: 0.12, green: 0.40, blue: 0.20)
        ),
        dark: .init(
            accent:        Color(red: 0.50, green: 0.85, blue: 0.55),
            background:    Color(red: 0.04, green: 0.08, blue: 0.05),
            card:          Color(red: 0.09, green: 0.14, blue: 0.10),
            textPrimary:   Color(red: 0.95, green: 0.99, blue: 0.94),
            textSecondary: Color(red: 0.58, green: 0.74, blue: 0.60),
            divider:       Color(red: 0.16, green: 0.24, blue: 0.18),
            success:       Color(red: 0.38, green: 0.85, blue: 0.50),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.34),
            error:         Color(red: 0.98, green: 0.45, blue: 0.45),
            gradientStart: Color(red: 0.22, green: 0.55, blue: 0.32),
            gradientEnd:   Color(red: 0.04, green: 0.20, blue: 0.10)
        )
    )

    // ---- Paper (warm beige/cream) ----
    static let paper = Theme(
        id: "paper",
        name: "Paper",
        tagline: "Linen & ink",
        iconName: "doc.text.fill",
        associatedIconName: "AppIcon-Paper",
        light: .init(
            accent:        Color(red: 0.36, green: 0.28, blue: 0.18),
            background:    Color(red: 0.98, green: 0.96, blue: 0.92),
            card:          Color(red: 1.00, green: 0.99, blue: 0.96),
            textPrimary:   Color(red: 0.16, green: 0.12, blue: 0.08),
            textSecondary: Color(red: 0.46, green: 0.40, blue: 0.30),
            divider:       Color(red: 0.92, green: 0.88, blue: 0.78),
            success:       Color(red: 0.32, green: 0.62, blue: 0.36),
            warning:       Color(red: 0.85, green: 0.58, blue: 0.18),
            error:         Color(red: 0.78, green: 0.28, blue: 0.20),
            gradientStart: Color(red: 0.96, green: 0.90, blue: 0.78),
            gradientEnd:   Color(red: 0.78, green: 0.66, blue: 0.46)
        ),
        dark: .init(
            accent:        Color(red: 0.86, green: 0.78, blue: 0.62),
            background:    Color(red: 0.10, green: 0.08, blue: 0.06),
            card:          Color(red: 0.16, green: 0.13, blue: 0.10),
            textPrimary:   Color(red: 0.98, green: 0.95, blue: 0.88),
            textSecondary: Color(red: 0.72, green: 0.66, blue: 0.54),
            divider:       Color(red: 0.26, green: 0.22, blue: 0.16),
            success:       Color(red: 0.46, green: 0.82, blue: 0.50),
            warning:       Color(red: 1.00, green: 0.80, blue: 0.40),
            error:         Color(red: 0.98, green: 0.45, blue: 0.40),
            gradientStart: Color(red: 0.36, green: 0.28, blue: 0.18),
            gradientEnd:   Color(red: 0.12, green: 0.08, blue: 0.04)
        )
    )

    // ---- Aurora (vibrant pink/violet/teal) ----
    static let aurora = Theme(
        id: "aurora",
        name: "Aurora",
        tagline: "Northern lights",
        iconName: "sparkles",
        associatedIconName: "AppIcon-Aurora",
        light: .init(
            accent:        Color(red: 0.62, green: 0.18, blue: 0.78),
            background:    Color(red: 0.97, green: 0.96, blue: 0.99),
            card:          .white,
            textPrimary:   Color(red: 0.10, green: 0.06, blue: 0.16),
            textSecondary: Color(red: 0.42, green: 0.36, blue: 0.50),
            divider:       Color(red: 0.90, green: 0.86, blue: 0.94),
            success:       Color(red: 0.18, green: 0.78, blue: 0.62),
            warning:       Color(red: 0.96, green: 0.62, blue: 0.20),
            error:         Color(red: 0.94, green: 0.22, blue: 0.50),
            gradientStart: Color(red: 0.96, green: 0.30, blue: 0.62),
            gradientEnd:   Color(red: 0.20, green: 0.40, blue: 0.96)
        ),
        dark: .init(
            accent:        Color(red: 0.96, green: 0.42, blue: 0.86),
            background:    Color(red: 0.04, green: 0.04, blue: 0.10),
            card:          Color(red: 0.10, green: 0.08, blue: 0.18),
            textPrimary:   Color(red: 0.98, green: 0.96, blue: 1.00),
            textSecondary: Color(red: 0.66, green: 0.60, blue: 0.78),
            divider:       Color(red: 0.20, green: 0.16, blue: 0.30),
            success:       Color(red: 0.36, green: 0.96, blue: 0.72),
            warning:       Color(red: 1.00, green: 0.78, blue: 0.34),
            error:         Color(red: 1.00, green: 0.40, blue: 0.62),
            gradientStart: Color(red: 0.96, green: 0.30, blue: 0.62),
            gradientEnd:   Color(red: 0.10, green: 0.20, blue: 0.86)
        )
    )

    // ---- Monochrome (pure grayscale) ----
    static let monochrome = Theme(
        id: "monochrome",
        name: "Monochrome",
        tagline: "Pure grayscale",
        iconName: "circle.fill",
        associatedIconName: "AppIcon-Monochrome",
        light: .init(
            accent:        Color(red: 0.10, green: 0.10, blue: 0.10),
            background:    Color(red: 0.96, green: 0.96, blue: 0.96),
            card:          .white,
            textPrimary:   Color(red: 0.06, green: 0.06, blue: 0.06),
            textSecondary: Color(red: 0.42, green: 0.42, blue: 0.42),
            divider:       Color(red: 0.86, green: 0.86, blue: 0.86),
            success:       Color(red: 0.30, green: 0.30, blue: 0.30),
            warning:       Color(red: 0.55, green: 0.55, blue: 0.55),
            error:         Color(red: 0.20, green: 0.20, blue: 0.20),
            gradientStart: Color(red: 0.65, green: 0.65, blue: 0.65),
            gradientEnd:   Color(red: 0.18, green: 0.18, blue: 0.18)
        ),
        dark: .init(
            accent:        Color(red: 0.95, green: 0.95, blue: 0.95),
            background:    Color(red: 0.02, green: 0.02, blue: 0.02),
            card:          Color(red: 0.10, green: 0.10, blue: 0.10),
            textPrimary:   Color(red: 0.98, green: 0.98, blue: 0.98),
            textSecondary: Color(red: 0.65, green: 0.65, blue: 0.65),
            divider:       Color(red: 0.22, green: 0.22, blue: 0.22),
            success:       Color(red: 0.85, green: 0.85, blue: 0.85),
            warning:       Color(red: 0.65, green: 0.65, blue: 0.65),
            error:         Color(red: 0.95, green: 0.95, blue: 0.95),
            gradientStart: Color(red: 0.40, green: 0.40, blue: 0.40),
            gradientEnd:   Color(red: 0.05, green: 0.05, blue: 0.05)
        )
    )
}
