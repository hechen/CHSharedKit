import SwiftUI

// MARK: - CHSettingsPresentationLayout

/// Fleet-wide geometry for settings sheets on macOS.
///
/// Settings content remains adaptive on iOS and visionOS. On macOS, sheets
/// need an explicit size or SwiftUI derives their window geometry from each
/// content tree, which makes sibling settings pages jump between heights.
/// Keep these values centralized and non-configurable at call sites so every
/// app presents the same stable window.
public enum CHSettingsPresentationLayout {
    public static let macOSWidth: CGFloat = 560
    public static let macOSHeight: CGFloat = 600
}

/// Controls whether a presentation root receives only the shared surfaces or
/// the fleet-wide macOS settings-sheet geometry as well.
public enum CHSettingsPresentationSizing: Sendable {
    /// Theme the presentation without imposing a content size.
    case adaptive

    /// Use the stable geometry reserved for modal settings sheets on macOS.
    case standardSheet
}

// MARK: - CHSettingsSheet

/// A theme-aware modal shell for settings content shared across applications.
///
/// The shell owns the presentation boundary: `NavigationStack`, title, Done
/// action, theme tint, page canvas, chrome surfaces, and macOS geometry.
/// Content views stay presentation-agnostic so the same view can still be
/// pushed in a navigation stack or displayed in a split-view detail column.
///
/// ```swift
/// .sheet(isPresented: $showFeatures) {
///     CHSettingsSheet("AI Features") {
///         MyAIFeaturesView()
///     }
/// }
/// ```
public struct CHSettingsSheet<Content: View>: View {
    private let title: LocalizedStringKey
    private let doneButtonTitle: LocalizedStringKey
    private let onDismiss: (() -> Void)?
    private let content: Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    public init(
        _ title: LocalizedStringKey,
        doneButtonTitle: LocalizedStringKey = "Done",
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.doneButtonTitle = doneButtonTitle
        self.onDismiss = onDismiss
        self.content = content()
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(macOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(doneButtonTitle, action: finish)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("ch-settings-sheet-done")
                    }
                }
                #endif
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button(doneButtonTitle, action: finish)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ch-settings-sheet-done")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(theme.backgroundElevated)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.divider)
                    .frame(height: 1)
            }
            .accessibilityIdentifier("ch-settings-sheet-footer")
        }
        #endif
        .chSettingsPresentation(sizing: .standardSheet)
        .accessibilityIdentifier("ch-settings-sheet")
    }

    private func finish() {
        dismiss()
        onDismiss?()
    }
}

// MARK: - Presentation contract

private struct CHSettingsPresentationModifier: ViewModifier {
    let sizing: CHSettingsPresentationSizing

    @Environment(\.theme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        macOSPresentation(content)
        #elseif os(iOS)
        iOSPresentation(content)
        #else
        basePresentation(content)
        #endif
    }

    private func basePresentation(_ content: Content) -> some View {
        content
            .tint(theme.accent)
            .foregroundStyle(theme.textPrimary)
            .background(theme.background.ignoresSafeArea())
            .presentationBackground(theme.background)
    }

    #if os(macOS)
    @ViewBuilder
    private func macOSPresentation(_ content: Content) -> some View {
        if #available(macOS 15.0, *) {
            applyMacOSGeometry(
                basePresentation(content)
                    .toolbarBackground(theme.backgroundElevated, for: .windowToolbar)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            )
        } else {
            applyMacOSGeometry(
                basePresentation(content)
                    .toolbarBackground(theme.backgroundElevated, for: .windowToolbar)
                    .toolbarBackground(.visible, for: .windowToolbar)
            )
        }
    }

    @ViewBuilder
    private func applyMacOSGeometry(_ content: some View) -> some View {
        switch sizing {
        case .adaptive:
            content
        case .standardSheet:
            content.frame(
                width: CHSettingsPresentationLayout.macOSWidth,
                height: CHSettingsPresentationLayout.macOSHeight
            )
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private func iOSPresentation(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            basePresentation(content)
                .toolbarBackground(theme.backgroundElevated, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        } else {
            basePresentation(content)
                .toolbarBackground(theme.backgroundElevated, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
    #endif
}

public extension View {
    /// Apply the shared settings-sheet surfaces to a custom presentation root
    /// that already owns its navigation and dismissal UI. The default leaves
    /// sizing adaptive; request `.standardSheet` only for a modal root whose
    /// content owns its scrolling behavior. Prefer ``CHSettingsSheet`` for
    /// ordinary settings sheets.
    func chSettingsPresentation(
        sizing: CHSettingsPresentationSizing = .adaptive
    ) -> some View {
        modifier(CHSettingsPresentationModifier(sizing: sizing))
    }
}
