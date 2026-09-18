import SwiftUI

/// Modal wrapper for the shared AI-feature settings surface.
///
/// Apps with their own feature form can place that view directly inside
/// ``CHSettingsSheet`` and still receive identical presentation chrome.
public struct CHAIFeaturesSettingsSheet: View {
    private let appName: String
    private let onDismiss: (() -> Void)?
    private let displaySection: () -> AnyView

    public init(
        appName: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder displaySection: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.appName = appName
        self.onDismiss = onDismiss
        self.displaySection = displaySection
    }

    public var body: some View {
        CHSettingsSheet("AI Features", onDismiss: onDismiss) {
            CHAIFeaturesSettingsContent(
                appName: appName,
                displaySection: displaySection
            )
            .themedListBackground()
        }
    }
}

/// Modal wrapper for CHSharedKit's AI usage and pricing surfaces.
public struct CHAIUsageSheet: View {
    private let onDismiss: (() -> Void)?

    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        CHSettingsSheet("AI Usage", onDismiss: onDismiss) {
            CHAIUsageView()
        }
    }
}
