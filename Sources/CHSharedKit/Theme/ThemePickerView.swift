import SwiftUI

/// Grid of theme cards. Tap a card to apply that theme via `ThemeManager` —
/// the active theme is highlighted with an accent-colored checkmark and the
/// colors (and app icon) swap immediately and animate.
public struct ThemePickerView: View {

    @ObservedObject private var manager: ThemeManager
    @Environment(\.theme) private var currentTheme
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
    private let caption: LocalizedStringKey?

    /// - Parameter caption: the line above the grid, looked up in the app's
    ///   own strings. Nil uses the kit's localized default, which promises
    ///   cross-device sync; apps that keep the theme on the device should
    ///   pass their own.
    public init(
        manager: ThemeManager = .shared,
        caption: LocalizedStringKey? = nil
    ) {
        self.manager = manager
        self.caption = caption
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let caption {
                        Text(caption)
                    } else {
                        Text(String(localized: "Pick a palette — it syncs across all your devices and apps.", bundle: .module))
                    }
                }
                    .font(.subheadline)
                    .foregroundStyle(currentTheme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ThemePalette.all) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: manager.currentTheme.id == theme.id,
                            colorScheme: colorScheme,
                            highlight: currentTheme.accent
                        ) {
                            manager.apply(theme)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(theme.name)
                        .accessibilityHint(theme.description)
                        .accessibilityAddTraits(
                            manager.currentTheme.id == theme.id ? .isSelected : []
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(currentTheme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "Theme", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Card

private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let colorScheme: ColorScheme
    let highlight: Color
    let action: () -> Void

    private var resolved: ResolvedTheme {
        ResolvedTheme(theme: theme, colorScheme: colorScheme)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Preview area — gradient + symbol + swatch row
                ZStack {
                    resolved.gradient

                    VStack(spacing: 10) {
                        Image(systemName: theme.symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)

                        HStack(spacing: 6) {
                            Swatch(color: resolved.accent)
                            Swatch(color: resolved.accentSecondary)
                            Swatch(color: resolved.card)
                            Swatch(color: resolved.textPrimary)
                            Swatch(color: resolved.success)
                        }
                    }
                }
                .frame(height: 110)

                // Label
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(theme.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(resolved.textPrimary)
                        Spacer(minLength: 4)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white, highlight)
                        }
                    }
                    Text(theme.description)
                        .font(.caption)
                        .foregroundStyle(resolved.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(resolved.card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? highlight : Color.black.opacity(0.06),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .shadow(
                color: .black.opacity(isSelected ? 0.18 : 0.08),
                radius: isSelected ? 12 : 6,
                x: 0,
                y: isSelected ? 6 : 3
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct Swatch: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(
                Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
            )
    }
}
