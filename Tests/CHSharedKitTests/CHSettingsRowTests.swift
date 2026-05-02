import Testing
import Foundation
import SwiftUI
@testable import CHSharedKit

// MARK: - CHSettingsLayout — constants are pinned

@Suite("CHSettingsLayout constants")
struct CHSettingsLayoutTests {

    @Test("Icon badge dimensions match Chen's spec (30×30, 7pt corner)")
    func iconBadgeDimensions() {
        #expect(CHSettingsLayout.iconBadgeSize.width == 30)
        #expect(CHSettingsLayout.iconBadgeSize.height == 30)
        #expect(CHSettingsLayout.iconBadgeCornerRadius == 7)
    }

    @Test("Row min-height pair matches the spec (44pt single, 56pt with subtitle)")
    func rowMinHeights() {
        #expect(CHSettingsLayout.minRowHeight == 44)
        #expect(CHSettingsLayout.minRowHeightWithSubtitle == 56)
    }

    @Test("Internal padding matches the spec (16pt L+R, 12pt icon-to-label)")
    func internalPadding() {
        #expect(CHSettingsLayout.leadingPadding == 16)
        #expect(CHSettingsLayout.trailingPadding == 16)
        #expect(CHSettingsLayout.iconToLabelSpacing == 12)
    }
}

// MARK: - CHSettingsRow — structural / render
//
// These exercise the actual rendered geometry via ImageRenderer.
// SwiftPM tests run on macOS where ImageRenderer is available; the
// scale is fixed at 2 so the byte-level output is reproducible.
//
// We don't byte-hash the PNG (font hinting drifts across macOS minor
// versions, which would create flake). Instead we assert:
//   * the renderer produces a non-nil image
//   * the rendered height matches the expected min-height for the
//     row variant (single-line vs subtitle)
//   * the rendered width is non-zero and bounded
//
// The pixel-perfect baseline is left to per-app snapshot tests (apps
// pin to one OS version + one device size at a time).

@MainActor
@Suite("CHSettingsRow render geometry")
struct CHSettingsRowGeometryTests {

    @Test("Single-line row renders at min-height 44pt")
    func singleLineMinHeight() {
        let row = CHSettingsRow(icon: "paintbrush", iconColor: .purple, title: "Theme")
            .frame(width: 375)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced nil cgImage")
            return
        }
        // Height in points = pixel height ÷ scale. The row's frame
        // will exceed 44pt because of the .padding modifiers, but it
        // must be >= 44pt.
        let heightPoints = CGFloat(image.height) / 2
        #expect(heightPoints >= CHSettingsLayout.minRowHeight)
        // Sanity ceiling — single-line rows shouldn't be huge.
        #expect(heightPoints <= 80)
    }

    @Test("Subtitle row renders at min-height 56pt")
    func subtitleRowMinHeight() {
        let row = CHSettingsRow(
            icon: "bell",
            iconColor: .orange,
            title: "Notifications",
            subtitle: "Daily 8:00 AM"
        )
        .frame(width: 375)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced nil cgImage")
            return
        }
        let heightPoints = CGFloat(image.height) / 2
        #expect(heightPoints >= CHSettingsLayout.minRowHeightWithSubtitle)
        #expect(heightPoints <= 100)
    }

    @Test("Value row renders without crashing")
    func valueRowRenders() {
        let row = CHSettingsRow.value(
            icon: "bolt",
            iconColor: .yellow,
            title: "BMR",
            value: "1,850 kcal"
        )
        .frame(width: 375)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2

        let image = renderer.cgImage
        #expect(image != nil)
    }

    @Test("Badge-count row renders with non-zero width")
    func badgeCountRowRenders() {
        let row = CHSettingsRow(
            icon: "exclamationmark.triangle",
            iconColor: .red,
            title: "Dietary Alerts",
            badgeCount: 3
        )
        .frame(width: 375)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced nil cgImage")
            return
        }
        #expect(image.width > 0)
    }
}
