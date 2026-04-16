import SwiftUI

/// Pre-designed themes shipped with CHSharedKit. All apps see the same
/// palette so users can carry their preferred theme across apps via iCloud KVS.
public enum ThemePalette {

    /// All themes in display order.
    public static let all: [Theme] = [
        .default,
        .editorial,
        .boutique,
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

// Tiny helper for terser palette literals.
private func tc(
    _ light: (Double, Double, Double),
    _ dark: (Double, Double, Double)
) -> ThemeColor {
    ThemeColor(light: light, dark: dark)
}

// MARK: - Themes

public extension Theme {

    // ---------- Editorial — airy fashion spread, soft stone ----------
    static let editorial = Theme(
        id: "editorial",
        name: "Editorial",
        description: "Airy neutrals with soft contrast, like a magazine spread.",
        symbol: "square.stack.3d.up.fill",
        associatedIconName: nil,
        accent:             tc((0.24, 0.24, 0.28), (0.90, 0.88, 0.84)),
        accentSecondary:    tc((0.58, 0.56, 0.52), (0.72, 0.70, 0.66)),
        background:         tc((0.97, 0.96, 0.95), (0.09, 0.09, 0.10)),
        backgroundElevated: tc((0.99, 0.985, 0.975), (0.12, 0.12, 0.13)),
        card:               tc((1.00, 0.995, 0.99), (0.14, 0.14, 0.16)),
        cardElevated:       tc((0.985, 0.98, 0.97), (0.18, 0.18, 0.20)),
        textPrimary:        tc((0.12, 0.12, 0.13), (0.96, 0.95, 0.93)),
        textSecondary:      tc((0.42, 0.41, 0.40), (0.72, 0.70, 0.68)),
        textTertiary:       tc((0.65, 0.63, 0.60), (0.48, 0.47, 0.45)),
        divider:            tc((0.90, 0.88, 0.85), (0.24, 0.24, 0.26)),
        success:            tc((0.28, 0.62, 0.46), (0.44, 0.82, 0.60)),
        warning:            tc((0.84, 0.60, 0.24), (0.96, 0.78, 0.38)),
        error:              tc((0.78, 0.30, 0.30), (0.94, 0.48, 0.48)),
        gradientStart:      tc((0.92, 0.90, 0.87), (0.30, 0.29, 0.30)),
        gradientEnd:        tc((0.74, 0.72, 0.68), (0.15, 0.15, 0.17))
    )

    // ---------- Boutique — bright boutique retail, blush + sand ----------
    static let boutique = Theme(
        id: "boutique",
        name: "Boutique",
        description: "Bright retail polish with blush, sand, and soft cocoa.",
        symbol: "bag.fill",
        associatedIconName: nil,
        accent:             tc((0.82, 0.47, 0.54), (1.00, 0.68, 0.74)),
        accentSecondary:    tc((0.86, 0.70, 0.58), (0.96, 0.82, 0.68)),
        background:         tc((0.995, 0.975, 0.97), (0.11, 0.09, 0.10)),
        backgroundElevated: tc((1.00, 0.99, 0.985), (0.15, 0.13, 0.14)),
        card:               tc((1.00, 1.00, 0.995), (0.18, 0.15, 0.17)),
        cardElevated:       tc((0.99, 0.96, 0.95), (0.22, 0.18, 0.20)),
        textPrimary:        tc((0.20, 0.14, 0.16), (0.98, 0.94, 0.95)),
        textSecondary:      tc((0.50, 0.38, 0.40), (0.76, 0.66, 0.68)),
        textTertiary:       tc((0.68, 0.56, 0.57), (0.52, 0.44, 0.46)),
        divider:            tc((0.94, 0.86, 0.86), (0.30, 0.24, 0.27)),
        success:            tc((0.28, 0.68, 0.50), (0.44, 0.88, 0.66)),
        warning:            tc((0.90, 0.62, 0.20), (1.00, 0.80, 0.36)),
        error:              tc((0.82, 0.28, 0.34), (0.98, 0.46, 0.54)),
        gradientStart:      tc((0.98, 0.84, 0.86), (0.48, 0.24, 0.34)),
        gradientEnd:        tc((0.92, 0.76, 0.64), (0.24, 0.16, 0.18))
    )

    // ---------- Default — crisp blue, system look ----------
    static let `default` = Theme(
        id: "default",
        name: "Default",
        description: "Crisp & familiar — the system look you know.",
        symbol: "circle.lefthalf.filled",
        associatedIconName: nil,
        accent:             tc((0.10, 0.45, 0.95), (0.40, 0.66, 1.00)),
        accentSecondary:    tc((0.30, 0.62, 1.00), (0.60, 0.80, 1.00)),
        background:         tc((0.97, 0.97, 0.98), (0.06, 0.06, 0.08)),
        backgroundElevated: tc((1.00, 1.00, 1.00), (0.10, 0.10, 0.12)),
        card:               tc((1.00, 1.00, 1.00), (0.12, 0.12, 0.14)),
        cardElevated:       tc((0.99, 0.99, 1.00), (0.16, 0.16, 0.19)),
        textPrimary:        tc((0.08, 0.08, 0.10), (0.97, 0.97, 0.98)),
        textSecondary:      tc((0.42, 0.42, 0.46), (0.65, 0.65, 0.70)),
        textTertiary:       tc((0.60, 0.60, 0.64), (0.45, 0.45, 0.50)),
        divider:            tc((0.88, 0.88, 0.90), (0.22, 0.22, 0.25)),
        success:            tc((0.18, 0.70, 0.40), (0.36, 0.85, 0.55)),
        warning:            tc((0.96, 0.65, 0.14), (1.00, 0.78, 0.30)),
        error:              tc((0.93, 0.27, 0.30), (1.00, 0.45, 0.45)),
        gradientStart:      tc((0.30, 0.55, 0.98), (0.20, 0.45, 0.95)),
        gradientEnd:        tc((0.10, 0.35, 0.85), (0.05, 0.20, 0.55))
    )

    // ---------- Midnight — pure black OLED, vibrant purple/cyan ----------
    static let midnight = Theme(
        id: "midnight",
        name: "Midnight",
        description: "Pure black OLED with vibrant purple and cyan accents.",
        symbol: "moon.stars.fill",
        associatedIconName: "AppIcon-Midnight",
        accent:             tc((0.46, 0.24, 0.92), (0.66, 0.46, 1.00)),
        accentSecondary:    tc((0.10, 0.72, 0.92), (0.30, 0.85, 1.00)),
        background:         tc((0.96, 0.96, 0.99), (0.00, 0.00, 0.00)),
        backgroundElevated: tc((1.00, 1.00, 1.00), (0.04, 0.04, 0.07)),
        card:               tc((1.00, 1.00, 1.00), (0.07, 0.06, 0.12)),
        cardElevated:       tc((0.99, 0.99, 1.00), (0.11, 0.09, 0.18)),
        textPrimary:        tc((0.08, 0.06, 0.16), (0.96, 0.94, 1.00)),
        textSecondary:      tc((0.40, 0.36, 0.50), (0.66, 0.60, 0.80)),
        textTertiary:       tc((0.60, 0.56, 0.68), (0.42, 0.38, 0.52)),
        divider:            tc((0.86, 0.84, 0.92), (0.16, 0.13, 0.24)),
        success:            tc((0.20, 0.70, 0.55), (0.34, 0.92, 0.66)),
        warning:            tc((0.95, 0.60, 0.20), (1.00, 0.78, 0.34)),
        error:              tc((0.92, 0.25, 0.45), (1.00, 0.45, 0.62)),
        gradientStart:      tc((0.46, 0.22, 0.92), (0.56, 0.26, 1.00)),
        gradientEnd:        tc((0.10, 0.66, 0.92), (0.10, 0.78, 1.00))
    )

    // ---------- Ocean — deep blue gradients, navy, cyan ----------
    static let ocean = Theme(
        id: "ocean",
        name: "Ocean",
        description: "Deep blue depths with cyan tide accents.",
        symbol: "water.waves",
        associatedIconName: "AppIcon-Ocean",
        accent:             tc((0.04, 0.50, 0.78), (0.30, 0.78, 1.00)),
        accentSecondary:    tc((0.10, 0.66, 0.82), (0.20, 0.92, 0.98)),
        background:         tc((0.94, 0.97, 1.00), (0.02, 0.06, 0.12)),
        backgroundElevated: tc((1.00, 1.00, 1.00), (0.04, 0.10, 0.18)),
        card:               tc((1.00, 1.00, 1.00), (0.06, 0.14, 0.22)),
        cardElevated:       tc((0.97, 0.99, 1.00), (0.09, 0.18, 0.28)),
        textPrimary:        tc((0.04, 0.12, 0.22), (0.92, 0.98, 1.00)),
        textSecondary:      tc((0.30, 0.44, 0.54), (0.58, 0.76, 0.90)),
        textTertiary:       tc((0.50, 0.62, 0.72), (0.36, 0.50, 0.66)),
        divider:            tc((0.80, 0.90, 0.96), (0.12, 0.22, 0.32)),
        success:            tc((0.16, 0.72, 0.50), (0.36, 0.88, 0.65)),
        warning:            tc((0.96, 0.66, 0.18), (1.00, 0.78, 0.32)),
        error:              tc((0.94, 0.30, 0.36), (1.00, 0.46, 0.50)),
        gradientStart:      tc((0.20, 0.72, 0.92), (0.10, 0.62, 0.92)),
        gradientEnd:        tc((0.02, 0.22, 0.55), (0.02, 0.10, 0.35))
    )

    // ---------- Sunset — warm orange-pink, cream, coral ----------
    static let sunset = Theme(
        id: "sunset",
        name: "Sunset",
        description: "Warm orange-pink horizon with coral accents.",
        symbol: "sun.horizon.fill",
        associatedIconName: "AppIcon-Sunset",
        accent:             tc((0.92, 0.36, 0.34), (1.00, 0.56, 0.46)),
        accentSecondary:    tc((0.96, 0.56, 0.30), (1.00, 0.72, 0.40)),
        background:         tc((1.00, 0.97, 0.93), (0.10, 0.05, 0.05)),
        backgroundElevated: tc((1.00, 0.99, 0.96), (0.16, 0.09, 0.08)),
        card:               tc((1.00, 1.00, 0.99), (0.20, 0.11, 0.10)),
        cardElevated:       tc((1.00, 0.97, 0.92), (0.24, 0.14, 0.13)),
        textPrimary:        tc((0.20, 0.08, 0.04), (1.00, 0.96, 0.92)),
        textSecondary:      tc((0.50, 0.34, 0.28), (0.80, 0.64, 0.56)),
        textTertiary:       tc((0.66, 0.52, 0.46), (0.55, 0.42, 0.36)),
        divider:            tc((0.96, 0.86, 0.78), (0.30, 0.18, 0.16)),
        success:            tc((0.32, 0.72, 0.45), (0.45, 0.85, 0.55)),
        warning:            tc((0.96, 0.66, 0.18), (1.00, 0.78, 0.34)),
        error:              tc((0.90, 0.20, 0.30), (1.00, 0.40, 0.45)),
        gradientStart:      tc((1.00, 0.62, 0.34), (1.00, 0.50, 0.32)),
        gradientEnd:        tc((0.92, 0.28, 0.42), (0.66, 0.14, 0.30))
    )

    // ---------- Forest — deep green, sage, earthy ----------
    static let forest = Theme(
        id: "forest",
        name: "Forest",
        description: "Deep moss greens with earthy sage accents.",
        symbol: "leaf.fill",
        associatedIconName: "AppIcon-Forest",
        accent:             tc((0.20, 0.52, 0.30), (0.50, 0.85, 0.55)),
        accentSecondary:    tc((0.46, 0.66, 0.30), (0.70, 0.90, 0.50)),
        background:         tc((0.96, 0.98, 0.94), (0.04, 0.08, 0.05)),
        backgroundElevated: tc((1.00, 1.00, 0.98), (0.07, 0.12, 0.08)),
        card:               tc((1.00, 1.00, 1.00), (0.09, 0.14, 0.10)),
        cardElevated:       tc((0.97, 0.99, 0.95), (0.12, 0.18, 0.13)),
        textPrimary:        tc((0.07, 0.16, 0.10), (0.94, 0.99, 0.92)),
        textSecondary:      tc((0.34, 0.46, 0.36), (0.60, 0.78, 0.62)),
        textTertiary:       tc((0.52, 0.64, 0.54), (0.40, 0.54, 0.42)),
        divider:            tc((0.86, 0.92, 0.84), (0.14, 0.22, 0.16)),
        success:            tc((0.18, 0.68, 0.34), (0.38, 0.85, 0.50)),
        warning:            tc((0.92, 0.66, 0.18), (1.00, 0.78, 0.34)),
        error:              tc((0.86, 0.32, 0.32), (0.98, 0.45, 0.45)),
        gradientStart:      tc((0.40, 0.72, 0.42), (0.22, 0.55, 0.32)),
        gradientEnd:        tc((0.10, 0.34, 0.18), (0.04, 0.18, 0.08))
    )

    // ---------- Paper — warm cream, sepia, book-like ----------
    static let paper = Theme(
        id: "paper",
        name: "Paper",
        description: "Warm cream with sepia ink — like a well-worn book.",
        symbol: "book.fill",
        associatedIconName: "AppIcon-Paper",
        accent:             tc((0.42, 0.30, 0.18), (0.92, 0.84, 0.66)),
        accentSecondary:    tc((0.62, 0.46, 0.26), (0.78, 0.66, 0.46)),
        background:         tc((0.98, 0.95, 0.88), (0.10, 0.08, 0.06)),
        backgroundElevated: tc((1.00, 0.98, 0.92), (0.14, 0.11, 0.08)),
        card:               tc((1.00, 0.99, 0.94), (0.16, 0.13, 0.10)),
        cardElevated:       tc((1.00, 0.97, 0.90), (0.20, 0.16, 0.12)),
        textPrimary:        tc((0.16, 0.12, 0.06), (0.98, 0.95, 0.86)),
        textSecondary:      tc((0.46, 0.40, 0.28), (0.74, 0.66, 0.52)),
        textTertiary:       tc((0.62, 0.56, 0.42), (0.50, 0.44, 0.32)),
        divider:            tc((0.92, 0.86, 0.74), (0.26, 0.22, 0.16)),
        success:            tc((0.32, 0.62, 0.36), (0.46, 0.82, 0.50)),
        warning:            tc((0.85, 0.58, 0.18), (1.00, 0.80, 0.40)),
        error:              tc((0.78, 0.28, 0.20), (0.98, 0.45, 0.40)),
        gradientStart:      tc((0.96, 0.90, 0.74), (0.42, 0.32, 0.20)),
        gradientEnd:        tc((0.78, 0.62, 0.40), (0.16, 0.10, 0.04))
    )

    // ---------- Aurora — purple-teal gradient, neon, rich blacks ----------
    static let aurora = Theme(
        id: "aurora",
        name: "Aurora",
        description: "Northern lights — purple to teal across rich blacks.",
        symbol: "sparkles",
        associatedIconName: "AppIcon-Aurora",
        accent:             tc((0.62, 0.18, 0.78), (0.96, 0.42, 0.92)),
        accentSecondary:    tc((0.16, 0.74, 0.74), (0.30, 0.96, 0.86)),
        background:         tc((0.97, 0.95, 0.99), (0.03, 0.02, 0.08)),
        backgroundElevated: tc((1.00, 1.00, 1.00), (0.06, 0.04, 0.12)),
        card:               tc((1.00, 1.00, 1.00), (0.09, 0.07, 0.16)),
        cardElevated:       tc((0.98, 0.96, 1.00), (0.13, 0.10, 0.22)),
        textPrimary:        tc((0.10, 0.06, 0.16), (0.98, 0.96, 1.00)),
        textSecondary:      tc((0.42, 0.36, 0.50), (0.68, 0.62, 0.80)),
        textTertiary:       tc((0.62, 0.56, 0.68), (0.42, 0.38, 0.55)),
        divider:            tc((0.90, 0.86, 0.94), (0.18, 0.14, 0.30)),
        success:            tc((0.18, 0.78, 0.62), (0.36, 0.96, 0.72)),
        warning:            tc((0.96, 0.62, 0.20), (1.00, 0.78, 0.34)),
        error:              tc((0.94, 0.22, 0.50), (1.00, 0.40, 0.62)),
        gradientStart:      tc((0.96, 0.30, 0.62), (0.96, 0.20, 0.78)),
        gradientEnd:        tc((0.10, 0.66, 0.86), (0.10, 0.86, 0.96))
    )

    // ---------- Monochrome — grayscale, charcoal, white accents ----------
    static let monochrome = Theme(
        id: "monochrome",
        name: "Monochrome",
        description: "Pure grayscale — charcoal canvas, white accents.",
        symbol: "circle.fill",
        associatedIconName: "AppIcon-Monochrome",
        accent:             tc((0.10, 0.10, 0.10), (0.98, 0.98, 0.98)),
        accentSecondary:    tc((0.32, 0.32, 0.32), (0.78, 0.78, 0.78)),
        background:         tc((0.96, 0.96, 0.96), (0.02, 0.02, 0.02)),
        backgroundElevated: tc((1.00, 1.00, 1.00), (0.06, 0.06, 0.06)),
        card:               tc((1.00, 1.00, 1.00), (0.10, 0.10, 0.10)),
        cardElevated:       tc((0.98, 0.98, 0.98), (0.14, 0.14, 0.14)),
        textPrimary:        tc((0.06, 0.06, 0.06), (0.98, 0.98, 0.98)),
        textSecondary:      tc((0.42, 0.42, 0.42), (0.70, 0.70, 0.70)),
        textTertiary:       tc((0.60, 0.60, 0.60), (0.45, 0.45, 0.45)),
        divider:            tc((0.86, 0.86, 0.86), (0.22, 0.22, 0.22)),
        success:            tc((0.30, 0.30, 0.30), (0.85, 0.85, 0.85)),
        warning:            tc((0.45, 0.45, 0.45), (0.65, 0.65, 0.65)),
        error:              tc((0.20, 0.20, 0.20), (0.95, 0.95, 0.95)),
        gradientStart:      tc((0.65, 0.65, 0.65), (0.40, 0.40, 0.40)),
        gradientEnd:        tc((0.18, 0.18, 0.18), (0.05, 0.05, 0.05))
    )
}
