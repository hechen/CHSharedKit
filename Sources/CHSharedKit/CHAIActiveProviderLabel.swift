import SwiftUI

// MARK: - CHAIActiveProviderLabel

/// A self-observing `Text` view that always shows the display name of the
/// currently-active `CHAIManager` provider.
///
/// ## Why this exists
///
/// Apps used to hand-roll the parent Settings → AI cell like this:
///
/// ```swift
/// // BUG: not observing CHAIManager, cell renders stale after picker pop.
/// private var activeProviderLabel: String {
///     CHAIManager.shared.activeProvider?.displayName ?? "None"
/// }
///
/// NavigationLink {
///     CHAIProviderPickerView(appIdentifier: .myApp)
/// } label: {
///     HStack {
///         Text("AI Provider")
///         Spacer()
///         Text(activeProviderLabel)     // ← reads singleton, no subscription
///     }
/// }
/// ```
///
/// The computed `activeProviderLabel` reads `CHAIManager.shared` directly —
/// there's no `@StateObject` / `@ObservedObject` / `@EnvironmentObject`
/// binding, so SwiftUI has no reason to re-render the parent view after
/// the picker writes `activeProviderID` and pops. The user picks
/// "On-Device AI", navigates back, and the cell still says "OpenAI"
/// until the view is recreated for some unrelated reason (next Settings
/// visit, app relaunch, etc.) — exactly the Build-reported stale-cell
/// regression.
///
/// This view fixes the pattern by holding `CHAIManager.shared` as a
/// `@StateObject` inside the view itself — every consumer that drops
/// this in automatically subscribes to `@Published activeProviderID`
/// changes without having to remember the binding dance.
///
/// ## Usage
///
/// ```swift
/// NavigationLink {
///     CHAIProviderPickerView(appIdentifier: .myApp)
/// } label: {
///     HStack {
///         Text("AI Provider")
///         Spacer()
///         CHAIActiveProviderLabel()     // ← self-observing, always fresh
///             .foregroundStyle(.secondary)
///     }
/// }
/// ```
///
/// The label text defaults to the active provider's `displayName`, or a
/// `fallback` string (default `"None"`) when no provider is registered
/// for the stored ID — which happens if the user's saved choice refers
/// to a provider the app no longer ships.
public struct CHAIActiveProviderLabel: View {

    /// Text shown when `CHAIManager.shared.activeProvider` resolves to
    /// nil. Defaults to `"None"`. Override for brand-specific copy (e.g.
    /// `"Not configured"`).
    public let fallback: String

    @StateObject private var manager = CHAIManager.shared

    public init(fallback: String = CHSharedLocalization.string("None")) {
        self.fallback = fallback
    }

    public var body: some View {
        // Explicit reads of the properties `text(for:)` depends on —
        // SwiftUI uses these accesses to wire up dependency tracking
        // against the @StateObject. When `CHAIManager` fires
        // `objectWillChange` (either because `activeProviderID` changed
        // or because `setActiveOnDeviceModel` swapped the model
        // display name), the view re-evaluates and the label updates.
        let _ = manager.activeProviderID
        let _ = manager.activeModelDisplayName
        Text(Self.text(for: manager, fallback: fallback))
    }

    /// Unit-testable projection of the label's rendered text.
    ///
    /// `CHAISettingsView` and `CHAISettingsContent` use this to populate
    /// the "Active Provider" summary row at the top of the detail page,
    /// so the same resolution rule drives every on-screen surface that
    /// names the current provider. Unit tests pin the projection without
    /// needing a SwiftUI renderer.
    ///
    /// ## 2.4.5: composed display
    ///
    /// For the on-device provider, the rendered text is
    /// `"On-Device AI (<model display name>)"` — the model suffix comes
    /// from `CHAIManager.activeModelDisplayName`, the single source of
    /// truth for the current model. Before 2.4.5 the suffix was baked
    /// into `CHLocalLLMProvider.displayName` at construction time and
    /// drifted stale after model switches; see CHAIManager's 2.4.5
    /// notes for the full story.
    ///
    /// For every other provider, the rendered text is simply the
    /// provider's `displayName`.
    @MainActor
    public static func text(for manager: CHAIManager, fallback: String = CHSharedLocalization.string("None")) -> String {
        guard let provider = manager.activeProvider else { return fallback }
        // On-device provider: compose the model suffix from the
        // manager's @Published selection so every observing view
        // updates in lockstep with a single write.
        if provider.id == "on-device-llm",
           let model = manager.activeModelDisplayName,
           !model.isEmpty {
            return "\(provider.displayName) (\(model))"
        }
        return provider.displayName
    }
}

// MARK: - CHAIActiveProviderRow

/// Drop-in NavigationLink-style Settings row that combines a localized
/// "AI Provider" title with the self-observing `CHAIActiveProviderLabel`
/// and pushes to a caller-supplied destination (typically
/// `CHAIProviderPickerView`).
///
/// Apps that want to swap out their hand-rolled row entirely use this;
/// apps that keep their own row layout (custom icon, telemetry, analytics
/// on tap) use `CHAIActiveProviderLabel` inside their existing HStack.
///
/// ## Usage
///
/// ```swift
/// Section("AI") {
///     CHAIActiveProviderRow {
///         CHAIProviderPickerView(appIdentifier: .myApp)
///     }
/// }
/// ```
///
/// The `title` argument is customizable for apps that localize or
/// re-brand the row label — defaults to `"AI Provider"`.
public struct CHAIActiveProviderRow<Destination: View>: View {

    public let title: String
    public let fallback: String
    public let destination: () -> Destination

    public init(
        title: String = CHSharedLocalization.string("AI Provider"),
        fallback: String = CHSharedLocalization.string("None"),
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.fallback = fallback
        self.destination = destination
    }

    public var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                Spacer()
                CHAIActiveProviderLabel(fallback: fallback)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
