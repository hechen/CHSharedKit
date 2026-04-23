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

    public init(fallback: String = "None") {
        self.fallback = fallback
    }

    public var body: some View {
        // The read of `manager.activeProviderID` establishes the
        // dependency — even though we project through `activeProvider`,
        // SwiftUI sees the @StateObject access and re-evaluates when
        // objectWillChange fires.
        let _ = manager.activeProviderID
        Text(manager.activeProvider?.displayName ?? fallback)
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
        title: String = "AI Provider",
        fallback: String = "None",
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
