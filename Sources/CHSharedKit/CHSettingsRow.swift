import SwiftUI

// MARK: - CHSettingsRow (2.9.1)
//
// ## Usage
//
// All Settings rows in consumer apps go through this primitive. The
// kit ships five variants — pick the one that matches your action
// shape. Dimensions are locked (see `CHSettingsLayout`); apps cannot
// override the icon-badge size, row height, or spacing.
//
// ```swift
// // Navigation
// NavigationLink { DetailView() } label: {
//     CHSettingsRow(icon: "paintbrush", title: "Theme")
// }
//
// // Toggle
// Toggle(isOn: $darkMode) {
//     CHSettingsRow(icon: "moon", title: "Dark Mode")
// }
//
// // Picker
// Picker(selection: $unit) {
//     Text("Imperial").tag(0)
//     Text("Metric").tag(1)
// } label: {
//     CHSettingsRow(icon: "ruler", title: "Units")
// }
//
// // Value (read-only)
// CHSettingsRow.value(icon: "bolt", title: "BMR", value: "1,850 kcal")
//
// // Action (Button)
// Button(role: .destructive) { delete() } label: {
//     CHSettingsRow(icon: "trash", iconColor: .red, title: "Delete Data")
// }
// ```
//
// ## What this primitive deliberately does NOT expose
//
// - No `.frame(...)` parameter — height is locked to 44/56pt.
// - No `.padding(...)` parameter — internal padding is fixed.
// - No icon-size override — badge is 30×30 with 7pt corner radius.
// - No spacing parameter — icon-to-label spacing is 12pt.
//
// Apps that "need" different spacing for a Settings row are signaling
// "this isn't a Settings row" — use a different primitive (or, if
// genuinely missing, raise a kit issue).

/// Standard Settings cell. Every consumer app's Settings UI goes
/// through this primitive — see module header for usage.
public struct CHSettingsRow: View {
    private let icon: String
    private let iconColor: Color?
    private let title: String
    private let subtitle: String?
    private let valueText: String?
    private let badgeCount: Int?

    /// Standard initializer — icon + title (+ optional subtitle).
    /// Wrap in `NavigationLink`, `Toggle`, `Picker`, or `Button` as
    /// appropriate to the action shape.
    public init(
        icon: String,
        iconColor: Color? = nil,
        title: String,
        subtitle: String? = nil,
        badgeCount: Int? = nil
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.valueText = nil
        self.badgeCount = badgeCount
    }

    /// Read-only value row — title on the left, value on the right.
    /// Use for fixed metrics like "BMR: 1,850 kcal" or "Last Backup:
    /// 2 hours ago". For interactive selection use `Picker` wrapping
    /// the standard initializer.
    public static func value(
        icon: String,
        iconColor: Color? = nil,
        title: String,
        value: String
    ) -> CHSettingsRow {
        CHSettingsRow(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: nil,
            badgeCount: nil,
            valueText: value
        )
    }

    private init(
        icon: String,
        iconColor: Color?,
        title: String,
        subtitle: String?,
        badgeCount: Int?,
        valueText: String?
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.valueText = valueText
        self.badgeCount = badgeCount
    }

    public var body: some View {
        HStack(spacing: CHSettingsLayout.iconToLabelSpacing) {
            CHSettingsIconBadge(symbol: icon, tint: iconColor)

            VStack(alignment: .leading, spacing: CHSettingsLayout.titleToSubtitleSpacing) {
                Text(title)
                    .font(.system(size: CHSettingsLayout.titleFontSize))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: CHSettingsLayout.subtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }

            if valueText != nil || badgeCount != nil {
                Spacer(minLength: CHSettingsLayout.labelToTrailingSpacing)
                if let valueText {
                    Text(valueText)
                        .font(.system(size: CHSettingsLayout.subtitleFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
        }
        .frame(
            minHeight: subtitle == nil
                ? CHSettingsLayout.minRowHeight
                : CHSettingsLayout.minRowHeightWithSubtitle,
            alignment: .center
        )
        // Internal padding is applied here. Consumers cannot turn it
        // off — it's part of the body, not a modifier. (List rows
        // also apply outer insets; the kit row only owns the
        // intrinsic-content-to-edge gap.)
        .padding(.vertical, CHSettingsLayout.verticalPadding)
        // Mark the row for the linter — opaque accessibility identifier
        // so Scripts/validate-settings-rows.swift can recognize "this
        // is the kit primitive, not a hand-roll."
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("CHSettingsRow")
    }
}

// MARK: - CHSettingsIconBadge
//
// Internal — apps cannot construct this directly. Bakes the badge
// dimensions and corner radius from `CHSettingsLayout`. Tinted by an
// optional caller-supplied color, otherwise falls back to a neutral
// gray that adapts to color scheme.

struct CHSettingsIconBadge: View {
    let symbol: String
    let tint: Color?

    var body: some View {
        let backgroundColor = tint ?? .gray
        let glyphColor: Color = .white

        ZStack {
            RoundedRectangle(cornerRadius: CHSettingsLayout.iconBadgeCornerRadius, style: .continuous)
                .fill(backgroundColor)
            Image(systemName: symbol)
                .font(.system(size: CHSettingsLayout.iconGlyphPointSize, weight: .medium))
                .foregroundStyle(glyphColor)
        }
        .frame(
            width: CHSettingsLayout.iconBadgeSize.width,
            height: CHSettingsLayout.iconBadgeSize.height
        )
    }
}

#Preview("Variants") {
    NavigationStack {
        List {
            Section("Standard") {
                CHSettingsRow(icon: "paintbrush", iconColor: .purple, title: "Theme")
                CHSettingsRow(icon: "moon", iconColor: .indigo, title: "Dark Mode")
                CHSettingsRow(
                    icon: "bell",
                    iconColor: .orange,
                    title: "Notifications",
                    subtitle: "Daily 8:00 AM"
                )
                CHSettingsRow(
                    icon: "exclamationmark.triangle",
                    iconColor: .red,
                    title: "Dietary Alerts",
                    badgeCount: 3
                )
            }
            Section("Value") {
                CHSettingsRow.value(icon: "bolt", iconColor: .yellow, title: "BMR", value: "1,850 kcal")
                CHSettingsRow.value(icon: "flame", iconColor: .orange, title: "TDEE", value: "2,450 kcal")
                CHSettingsRow.value(icon: "clock", iconColor: .gray, title: "Last Backup", value: "2h ago")
            }
        }
        .navigationTitle("Settings")
    }
}
