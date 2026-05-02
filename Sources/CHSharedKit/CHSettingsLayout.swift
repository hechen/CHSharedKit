import Foundation
import CoreGraphics

// MARK: - CHSettingsLayout (2.9.1)
//
// ## Why this exists
//
// Cell-uniformity regressions kept shipping across the fleet —
// EatWisely's BMR/TDEE rows used hand-rolled `HStack { Text; Spacer;
// Text }`, GymLog's settings used Apple's `Label(_:systemImage:)`
// (no icon badge), Closet mixed both. Chen flagged this three times.
// Each round of "fix" missed the surfaces nobody pointed at.
//
// 2.9.1 fixes the structural cause: a single `CHSettingsRow` primitive
// with layout constants baked into THIS file. Consumers reach for the
// constants when they really need them (rare — the row primitive
// applies them internally) but the row itself does not expose any
// padding / size / spacing knobs. There's no public modifier that
// changes the icon-badge size or the row min-height. If a sub-page
// "needs" different padding, it's not a Settings row — it's something
// else, and CHSettingsRow is intentionally the wrong tool.
//
// The companion linter `Scripts/validate-settings-rows.swift` greps
// app source for HStack-shaped rows that bypass the primitive. Run as
// an Xcode build phase, fails the build on uncaught regressions.

/// Layout constants applied to every `CHSettingsRow`. Public for
/// inspection (snapshot tests, diagnostic surfaces) but the row
/// primitive bakes them into its body — there is no public modifier
/// that overrides them per-call-site. By design.
public enum CHSettingsLayout {

    /// Settings-row icon badge. 30×30pt squircle with a 7pt corner
    /// radius — matches Apple's Settings.app convention from iOS 17+.
    public static let iconBadgeSize: CGSize = CGSize(width: 30, height: 30)
    public static let iconBadgeCornerRadius: CGFloat = 7

    /// Inner SF Symbol size — slightly smaller than the badge so the
    /// glyph doesn't crowd the rounded corners. .body weight at 15pt
    /// is the goldilocks size; smaller looks empty, larger clips.
    public static let iconGlyphPointSize: CGFloat = 15
    public static let iconGlyphWeight: CGFloat = 0.4 // .medium

    /// Vertical sizing — single-line rows are 44pt (Apple HIG hit
    /// target); subtitle rows expand to 56pt to give the secondary
    /// line room without crowding.
    public static let minRowHeight: CGFloat = 44
    public static let minRowHeightWithSubtitle: CGFloat = 56

    /// Horizontal spacing between the icon badge and the title block.
    public static let iconToLabelSpacing: CGFloat = 12

    /// Spacing between the title block and the trailing accessory
    /// (toggle, picker preview, value text, chevron).
    public static let labelToTrailingSpacing: CGFloat = 8

    /// Internal padding applied by the row body. The List itself adds
    /// outer insets too — these constants govern the row's intrinsic
    /// edges, not the cell-to-cell separator.
    public static let leadingPadding: CGFloat = 16
    public static let trailingPadding: CGFloat = 16
    public static let verticalPadding: CGFloat = 8

    /// Title font + weight pair. Settings rows use `.body` not
    /// `.subheadline` — matches Apple Settings.app + provides decent
    /// dynamic-type scaling.
    public static let titleFontSize: CGFloat = 17

    /// Subtitle font — secondary metadata under the title. Two-point
    /// gap to the title is enforced by the row body.
    public static let subtitleFontSize: CGFloat = 13
    public static let titleToSubtitleSpacing: CGFloat = 2
}
