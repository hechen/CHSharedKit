import SwiftUI

/// Grid of theme cards. Tap to apply with animation. Drop into a settings
/// screen or present as a sheet.
public struct ThemePickerView: View {
    @ObservedObject private var manager: ThemeManager
    @Environment(\.theme) private var currentTheme
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    public init(manager: ThemeManager = .shared) {
        self.manager = manager
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Themes")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Text("Pick a palette — it syncs across all your devices and apps.")
                    .font(.subheadline)
                    .foregroundStyle(currentTheme.textSecondary)
                    .padding(.horizontal, 20)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ThemePalette.all) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: manager.theme.id == theme.id,
                            colorScheme: colorScheme
                        ) {
                            manager.apply(theme)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(currentTheme.background.ignoresSafeArea())
    }
}

// MARK: - Card

private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    private var variant: Theme.Variant {
        theme.variant(for: colorScheme)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Preview area — gradient + swatch row
                ZStack {
                    LinearGradient(
                        colors: [variant.gradientStart, variant.gradientEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    VStack(spacing: 10) {
                        Image(systemName: theme.iconName)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.20), radius: 4, y: 1)

                        HStack(spacing: 6) {
                            Swatch(color: variant.accent)
                            Swatch(color: variant.background)
                            Swatch(color: variant.card)
                            Swatch(color: variant.textPrimary)
                        }
                    }
                }
                .frame(height: 110)

                // Label
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(theme.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(variant.textPrimary)
                        Spacer(minLength: 4)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(variant.accent)
                        }
                    }
                    Text(theme.tagline)
                        .font(.caption)
                        .foregroundStyle(variant.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(variant.card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? variant.accent : Color.black.opacity(0.06),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08),
                    radius: isSelected ? 12 : 6,
                    x: 0, y: isSelected ? 6 : 3)
            .scaleEffect(isSelected ? 1.0 : 1.0)
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
