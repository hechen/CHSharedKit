import SwiftUI

// MARK: - CHAIFeaturesSettingsContent (2.10.0)
//
// Drop-in SwiftUI surface for an app's "AI Features" settings page.
// Renders one row per feature registered for `appName` via
// `CHAIFeatureRegistry.register(_:appName:)`. Each row tappable to a
// detail view with: enabled toggle, provider override picker (filtered
// by capability + isCloudOnly), model override picker, "Reset to
// default provider" button.
//
// Apps replace their hand-rolled "AI Features" Form with:
//
// ```swift
// NavigationStack {
//     CHAIFeaturesSettingsContent(appName: "Closet")
// }
// ```
//
// Or embed alongside other sections by wrapping their own content
// in a `displaySection:` closure:
//
// ```swift
// CHAIFeaturesSettingsContent(appName: "Closet") {
//     AnyView(
//         Section("Display") {
//             Toggle("Show Suggested Questions", isOn: $showSuggestions)
//         }
//     )
// }
// ```

public struct CHAIFeaturesSettingsContent: View {
    private let appName: String
    private let displaySection: () -> AnyView

    public init(
        appName: String,
        @ViewBuilder displaySection: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.appName = appName
        self.displaySection = displaySection
    }

    public var body: some View {
        Form {
            Section {
                let features = CHAIFeatureRegistry.features(for: appName)
                if features.isEmpty {
                    Text("This app hasn't registered any AI features yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(features) { feature in
                        NavigationLink {
                            CHAIFeatureDetailView(feature: feature)
                        } label: {
                            CHAIFeatureRow(feature: feature)
                        }
                    }
                }
            } header: {
                Text("AI-Powered Features")
            } footer: {
                Text("Each feature can use its own AI provider. Tap a feature to override the default.")
            }

            displaySection()

            Section {
                NavigationLink {
                    // Local-LLM-aware picker; consumer apps that don't link
                    // CHLocalLLM still build because this view is in the
                    // CHSharedKit module.
                    CHAIDefaultProviderLink()
                } label: {
                    HStack {
                        Text("Default Provider")
                        Spacer()
                        Text(CHAIManager.shared.activeProvider?.displayName ?? "None")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Used by features without an override.")
            }
        }
    }
}

// MARK: - CHAIFeatureRow

/// One row in the features list — icon badge + label + footnote +
/// chevron. Toggling enabled lives in the detail view, not on the
/// row itself, to keep the row tap target unambiguous.
public struct CHAIFeatureRow: View {
    let feature: CHAIFeature

    public init(feature: CHAIFeature) {
        self.feature = feature
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(feature.tint)
                Image(systemName: feature.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)
                    .font(.body)
                Text(currentProviderLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }

    private var currentProviderLabel: String {
        let resolvedID = CHAIFeatureProviderResolver.providerID(for: feature.id)
        let isOverride = (UserDefaults.standard.string(
            forKey: CHAIFeatureProviderResolver.providerOverrideKey(featureID: feature.id)
        ) ?? "").isEmpty == false
        let providerName = CHAIManager.shared.provider(id: resolvedID)?.displayName ?? "Unknown"
        return isOverride ? "Override · \(providerName)" : "Default · \(providerName)"
    }
}

// MARK: - CHAIFeatureDetailView

/// Detail page for one feature: enabled toggle, provider override
/// picker (filtered by capability + isCloudOnly), model override
/// picker, reset button.

public struct CHAIFeatureDetailView: View {
    let feature: CHAIFeature

    @State private var refreshTick: Int = 0

    public init(feature: CHAIFeature) {
        self.feature = feature
    }

    public var body: some View {
        Form {
            // Footnote header
            if let footnote = feature.footnote {
                Section {
                    Text(footnote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Enabled toggle
            Section {
                Toggle("Enabled", isOn: enabledBinding)
            } footer: {
                Text("When off, this feature won't make AI requests.")
            }

            // Provider override
            Section {
                Picker("Provider", selection: providerBinding) {
                    Text("Default (\(CHAIManager.shared.activeProvider?.displayName ?? "None"))")
                        .tag("")
                    let eligible = CHAIFeatureProviderResolver.eligibleProviderIDs(for: feature)
                    ForEach(eligible, id: \.self) { id in
                        let name = CHAIManager.shared.provider(id: id)?.displayName ?? id
                        Text(name).tag(id)
                    }
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerFooter)
            }

            // Model override (only when an override provider is set)
            if let modelPickerProviderID = currentOverrideProviderID,
               let models = modelsForProvider(modelPickerProviderID),
               !models.isEmpty {
                Section {
                    Picker("Model", selection: modelBinding(providerID: modelPickerProviderID)) {
                        Text("Default").tag("")
                        ForEach(models, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Override the model this feature uses on \(CHAIManager.shared.provider(id: modelPickerProviderID)?.displayName ?? modelPickerProviderID).")
                }
            }

            // Reset button
            if currentOverrideProviderID != nil {
                Section {
                    Button(role: .destructive) {
                        CHAIFeatureProviderResolver.setProviderOverride(nil, for: feature.id)
                        refreshTick += 1
                    } label: {
                        Text("Reset to Default Provider")
                    }
                }
            }
        }
        .navigationTitle(feature.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { CHAIFeatureProviderResolver.isEnabled(featureID: feature.id) },
            set: { CHAIFeatureProviderResolver.setEnabled($0, for: feature.id); refreshTick += 1 }
        )
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: {
                UserDefaults.standard.string(
                    forKey: CHAIFeatureProviderResolver.providerOverrideKey(featureID: feature.id)
                ) ?? ""
            },
            set: { newValue in
                CHAIFeatureProviderResolver.setProviderOverride(
                    newValue.isEmpty ? nil : newValue,
                    for: feature.id
                )
                refreshTick += 1
            }
        )
    }

    private func modelBinding(providerID: String) -> Binding<String> {
        Binding(
            get: {
                UserDefaults.standard.string(
                    forKey: CHAIFeatureProviderResolver.modelOverrideKey(
                        featureID: feature.id,
                        providerID: providerID
                    )
                ) ?? ""
            },
            set: { newValue in
                CHAIFeatureProviderResolver.setModelOverride(
                    newValue.isEmpty ? nil : newValue,
                    for: feature.id,
                    providerID: providerID
                )
                refreshTick += 1
            }
        )
    }

    // MARK: - Helpers

    private var currentOverrideProviderID: String? {
        let value = UserDefaults.standard.string(
            forKey: CHAIFeatureProviderResolver.providerOverrideKey(featureID: feature.id)
        )
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var providerFooter: String {
        let resolved = CHAIFeatureProviderResolver.providerID(for: feature.id)
        let name = CHAIManager.shared.provider(id: resolved)?.displayName ?? resolved
        if currentOverrideProviderID == nil {
            return "Following the default provider (\(name))."
        }
        return "This feature uses \(name) instead of the default."
    }

    private func modelsForProvider(_ id: String) -> [(id: String, name: String)]? {
        switch id {
        case CHOpenAIProvider.providerID:
            return CHOpenAIProvider.availableModels.map { (id: $0.id, name: $0.name) }
        case CHClaudeProvider.providerID:
            return CHClaudeProvider.availableModels.map { (id: $0.id, name: $0.name) }
        default:
            // Custom Endpoint / Apple Intelligence / On-Device LLM:
            // model selection lives in the provider's own settings,
            // not per-feature. The picker just hides the model
            // section in those cases.
            return nil
        }
    }
}

// MARK: - Default-provider link wrapper
//
// Carved out so the file doesn't need to depend on CHLocalLLM (where
// `CHAIProviderPickerView` lives). Consumer apps that already link
// CHLocalLLM can use that directly; apps that don't can still embed
// `CHAIFeaturesSettingsContent` and the link gracefully degrades to
// a label only.

private struct CHAIDefaultProviderLink: View {
    var body: some View {
        // The kit doesn't reach into CHLocalLLM from CHSharedKit (no
        // module dependency upward). Apps that want the full picker
        // can NavigationLink to `CHAIProviderPickerView` directly
        // from their Settings page; this placeholder keeps the
        // section visible in case the parent is just embedding the
        // features view alone.
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Provider")
                .font(.headline)
            Text("Embed `CHAIProviderPickerView(appIdentifier:)` from CHLocalLLM in this NavigationStack to switch the default provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
