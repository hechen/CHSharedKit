import SwiftUI

// MARK: - CHAIActiveProviderLabelView (2.4.8)
//
// ## Why this exists (and why a second label view alongside CHAIActiveProviderLabel)
//
// `CHAIActiveProviderLabel` (2.4.1, in CHAIActiveProviderLabel.swift)
// already solves the same root cause — apps reading
// `CHAIManager.shared.activeProviderID` as a global without binding —
// using a `@StateObject`. It works.
//
// 2.4.8 ships THIS view as a parallel, deliberately-renamed component
// for two reasons:
//
//  1. **Discoverable name in consumer code.** The audit across closet-ios
//     (`SettingsView.swift:359`), GymLog (`SettingsView_GL.swift:23`)
//     and EatWisely (`AIService.swift:176`) shows every consumer named
//     their inline computed property `activeAIProviderLabel` or similar.
//     The 1:1 swap target is a view literally named *...LabelView* —
//     consumers who grep "ActiveProviderLabel" for the right import
//     symbol find both, and the View suffix flags the one to drop into
//     a SwiftUI `body`. The plain `CHAIActiveProviderLabel` keeps
//     working for callers that already adopted it.
//
//  2. **Render shape consumers asked for.** The existing
//     `CHAIActiveProviderLabel` composes `"On-Device AI (<model>)"` with
//     parentheses, matched to the Active-Provider summary row at the top
//     of `CHAISettingsView` (2.4.5 design). Closet's settings row uses a
//     middle-dot separator — `"On-Device AI · <model>"` — so the row
//     reads as "category · variant" alongside the row title on the
//     left. This view ships the dot-separator format, which is the one
//     all three audited consumers were already trying to compute
//     inline. A future cleanup can collapse the two views or take a
//     `style:` parameter, but for 2.4.8 we ship the consumer-shaped
//     resolver and leave the existing view alone.
//
// ## API
//
// ```swift
// public struct CHAIActiveProviderLabelView: View {
//     @ObservedObject private var manager = CHAIManager.shared
//     public init() {}
//     public var body: some View {
//         Text(label)   // bare Text — caller styles it.
//     }
//     private var label: String { /* see resolver below */ }
// }
// ```
//
// The view renders a *bare* `Text` with no styling so consumers can apply
// their own `.font(...)` / `.foregroundStyle(...)` / `.fixedSize()`
// modifiers, matching whatever their existing settings-row HStack does.
// (Closet uses `.font(.caption).foregroundStyle(.secondary).fixedSize()`
// — the view composes cleanly into that.)
//
// ## Why @ObservedObject not @StateObject
//
// `@StateObject` is for view-OWNED reference types (the view instantiates
// and retains them across re-creations); `@ObservedObject` is for
// references the view consumes from outside. `CHAIManager.shared` is a
// singleton that outlives every view that touches it, so
// `@ObservedObject` is the semantically-correct wrapper here. Practical
// difference is small in this case (singleton, lives forever) but using
// the right wrapper avoids the SwiftUI compiler warning about
// `@StateObject` initializers running multiple times.
//
// ## Label resolution
//
// Mirrors the closet-ios `SettingsView.swift:357-363` computed property:
//
// ```
// let id = CHAIManager.shared.activeProviderID
// if id == CHLocalLLMProvider.providerID {
//     if let name = CHAIManager.shared.activeModelDisplayName {
//         return "On-Device AI · \(name)"
//     }
//     return "On-Device AI"
// }
// return CHAIManager.shared.activeProvider?.displayName ?? "Not Set"
// ```
//
// Reads come from the `@ObservedObject manager` instance (not
// `CHAIManager.shared` directly) so SwiftUI tracks the dependency via
// the property wrapper.
public struct CHAIActiveProviderLabelView: View {

    /// On-device provider ID. Hardcoded as a literal so this view (and
    /// the test target) doesn't have to depend on the CHLocalLLM
    /// module — matches the `CHLocalLLMProvider.providerID` constant in
    /// the sibling target and the existing `CHAIActiveProviderLabel`
    /// resolver in this kit.
    fileprivate static let onDeviceProviderID = "on-device-llm"

    @ObservedObject private var manager: CHAIManager = .shared

    public init() {}

    public var body: some View {
        // Explicit reads of the @Published properties so SwiftUI wires
        // up dependency tracking. Without these, the compiler would
        // happily inline `label` and the dependency on
        // `manager.activeModelDisplayName` (computed inside `label`)
        // would route through the @ObservedObject wrapper too — but
        // being explicit here matches the pattern in
        // CHAIActiveProviderLabel.swift and documents intent for
        // anyone scanning the body.
        let _ = manager.activeProviderID
        let _ = manager.activeModelDisplayName
        Text(Self.label(for: manager))
    }

    /// Unit-testable projection of the rendered label string. Mirrors
    /// the closet-ios `activeAIProviderLabel` computed property (2.4.8
    /// audit reference) so swapping the inline property for this view
    /// is a literal byte-for-byte UI no-op.
    @MainActor
    public static func label(for manager: CHAIManager) -> String {
        let id = manager.activeProviderID
        if id == onDeviceProviderID {
            if let name = manager.activeModelDisplayName, !name.isEmpty {
                return "On-Device AI · \(name)"
            }
            return "On-Device AI"
        }
        return manager.activeProvider?.displayName ?? "Not Set"
    }
}
