import SwiftUI
import CHSharedKit

// MARK: - ClawdAISettingsContent

/// Canonical AI provider settings sections for any CHSharedKit-using app.
///
/// Renders as List sections — embed directly inside a `List {}`. The view
/// owns the entire provider-selection flow, including the on-device model
/// picker and all cloud provider configuration rows.
///
/// **Bug fix (vs per-app copies):** tapping the On-Device row when a model
/// is already installed opens a management sheet instead of immediately
/// reopening the download picker. The download picker only auto-launches
/// when no model is installed.
///
/// ```swift
/// // App AI settings screen:
/// List {
///     ClawdAISettingsContent(appIdentifier: .distill)
///
///     // App-specific sections below:
///     Section("Custom Prompt") { ... }
/// }
/// ```
public struct ClawdAISettingsContent: View {
    public let appIdentifier: AppIdentifier

    @StateObject private var aiManager = ClawdAIManager.shared
    @State private var selectedProvider: String = ClawdAIManager.shared.activeProviderID
    @State private var openaiKey = ""
    @State private var claudeKey = ""
    @State private var customURL = ClawdCustomEndpointProvider.baseURL
    @State private var customModel = ClawdCustomEndpointProvider.model
    @State private var customKey = ""
    @State private var openaiModel = ClawdOpenAIProvider.model
    @State private var claudeModel = ClawdClaudeProvider.model
    @State private var isValidating = false
    @State private var validationResult: String?
    @State private var showingAPIKey = false
    @State private var showModelPicker = false
    @State private var showModelManagement = false

    @State private var modelStore = LocalModelStore.shared

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
    }

    // Active installed model (prefers custom models too, not just catalog)
    private var activeModel: LocalModelInfo? {
        guard let id = modelStore.activeModelID else { return nil }
        return modelStore.allModels.first { $0.id == id && modelStore.isInstalled($0) }
    }

    public var body: some View {
        Section("Provider") {
            // Apple Intelligence
            providerRow(
                ClawdAppleIntelligenceProvider.providerID,
                name: "Apple Intelligence",
                badge: "Free",
                badgeColor: .green,
                available: aiManager.isAppleIntelligenceAvailable,
                unavailableReason: "Requires iOS 26+"
            )

            // On-Device LLM — smart tap: management if installed, picker if not
            onDeviceProviderRow

            // Cloud providers
            ForEach(
                aiManager.availableProviders.filter {
                    $0.id != ClawdAppleIntelligenceProvider.providerID &&
                    $0.id != ClawdLocalLLMProvider.providerID
                },
                id: \.id
            ) { provider in
                providerRow(provider.id, name: provider.name, badge: nil, badgeColor: .clear, available: true)
            }
        }

        // On-Device detail section (when selected)
        if selectedProvider == ClawdLocalLLMProvider.providerID {
            onDeviceDetailSection
        }

        // Apple Intelligence info
        if selectedProvider == ClawdAppleIntelligenceProvider.providerID {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("On-device, free, private. No data leaves your device.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Intelligence")
            }
        }

        // OpenAI settings
        if selectedProvider == ClawdOpenAIProvider.providerID {
            Section {
                HStack {
                    if showingAPIKey {
                        TextField("sk-...", text: $openaiKey)
                            .textContentType(.password)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API Key", text: $openaiKey)
                            .textContentType(.password)
                    }
                    Button { showingAPIKey.toggle() } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onSubmit { ClawdOpenAIProvider.apiKey = openaiKey }

                Picker("Model", selection: $openaiModel) {
                    ForEach(ClawdOpenAIProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .onChange(of: openaiModel) { _, val in ClawdOpenAIProvider.model = val }
            } header: {
                Text("OpenAI")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Get your API key at")
                        if let url = URL(string: "https://platform.openai.com/api-keys") {
                            Link("platform.openai.com", destination: url)
                        }
                    }
                    Text("Your API key is stored securely in the device Keychain.")
                }
            }
        }

        // Claude settings
        if selectedProvider == ClawdClaudeProvider.providerID {
            Section {
                HStack {
                    if showingAPIKey {
                        TextField("sk-ant-...", text: $claudeKey)
                            .textContentType(.password)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API Key", text: $claudeKey)
                            .textContentType(.password)
                    }
                    Button { showingAPIKey.toggle() } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onSubmit { ClawdClaudeProvider.apiKey = claudeKey }

                Picker("Model", selection: $claudeModel) {
                    ForEach(ClawdClaudeProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .onChange(of: claudeModel) { _, val in ClawdClaudeProvider.model = val }
            } header: {
                Text("Anthropic Claude")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Get your API key at")
                        if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                            Link("console.anthropic.com", destination: url)
                        }
                    }
                    Text("Your API key is stored securely in the device Keychain.")
                }
            }
        }

        // Custom endpoint settings
        if selectedProvider == ClawdCustomEndpointProvider.providerID {
            Section {
                HStack {
                    Text("Base URL")
                    Spacer()
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.baseURL = customURL }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    TextField("llava", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.model = customModel }
                }
                HStack {
                    if showingAPIKey {
                        TextField("API Key (optional)", text: $customKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API Key (optional)", text: $customKey)
                    }
                    Button { showingAPIKey.toggle() } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onSubmit { ClawdCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey }
            } header: {
                Text("Custom Endpoint")
            } footer: {
                Text("OpenAI-compatible API (Ollama, vLLM, LMStudio, etc.)\nYour API key is stored securely in the device Keychain.")
            }
        }

        // Test Connection (cloud providers only — not Apple/on-device)
        let isCloudProvider = selectedProvider != ClawdAppleIntelligenceProvider.providerID
                           && selectedProvider != ClawdLocalLLMProvider.providerID
        if isCloudProvider {
            Section {
                Button {
                    saveKeys()
                    validateCurrentProvider()
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if isValidating { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(isValidating)

                if let result = validationResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("✓") ? .green : .red)
                }
            }
        }
    }

    // MARK: - On-Device rows

    @ViewBuilder
    private var onDeviceProviderRow: some View {
        Button {
            // If a model is already installed, show the management sheet.
            // Only open the download picker directly when no model exists yet.
            if activeModel != nil {
                showModelManagement = true
            } else {
                showModelPicker = true
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("On-Device AI")
                        badge("Free", color: .indigo)
                        badge("Offline", color: .orange)
                    }
                    Text(activeModel.map { $0.displayName } ?? "Tap to choose a model")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if selectedProvider == ClawdLocalLLMProvider.providerID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Management sheet — shown when a model is already installed.
        .sheet(isPresented: $showModelManagement, onDismiss: {
            selectedProvider = aiManager.activeProviderID
        }) {
            NavigationStack {
                OnDeviceModelManagementView(
                    store: modelStore,
                    onChangeTapped: {
                        showModelManagement = false
                        // Brief delay so the management sheet fully dismisses
                        // before the picker sheet appears.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showModelPicker = true
                        }
                    }
                )
            }
        }
        // Download/browse picker sheet.
        .sheet(isPresented: $showModelPicker, onDismiss: {
            selectedProvider = aiManager.activeProviderID
        }) {
            NavigationStack {
                ModelPickerView(appIdentifier: appIdentifier) {
                    showModelPicker = false
                }
            }
        }
        .onAppear {
            openaiKey = ClawdOpenAIProvider.apiKey ?? ""
            claudeKey = ClawdClaudeProvider.apiKey ?? ""
            customKey = ClawdCustomEndpointProvider.apiKey ?? ""
        }
    }

    @ViewBuilder
    private var onDeviceDetailSection: some View {
        Section {
            if let model = activeModel {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.subheadline.weight(.medium))
                        Text("Running on your device. No network used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label(formattedSize(modelStore.totalStorageUsed), systemImage: "internaldrive")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Change Model") { showModelManagement = true }
                        .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
            } else if modelStore.activeDownloadModelID != nil {
                // Download in progress — show inline progress
                LocalModelDownloadView()
            } else {
                // No model yet — explicit button, never auto-opens the picker
                Button {
                    showModelPicker = true
                } label: {
                    Label("Browse Models", systemImage: "cpu").font(.subheadline)
                }
            }
        } header: {
            Text("On-Device Model")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func providerRow(
        _ id: String,
        name: String,
        badge: String?,
        badgeColor: Color,
        available: Bool,
        unavailableReason: String? = nil
    ) -> some View {
        Button {
            guard available else { return }
            selectedProvider = id
            aiManager.activeProviderID = id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).foregroundStyle(available ? .primary : .secondary)
                        if let badge {
                            self.badge(badge, color: badgeColor)
                        }
                    }
                    if let reason = unavailableReason, !available {
                        Text(reason).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if selectedProvider == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
        }
        .disabled(!available)
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func saveKeys() {
        if !openaiKey.isEmpty { ClawdOpenAIProvider.apiKey = openaiKey }
        if !claudeKey.isEmpty { ClawdClaudeProvider.apiKey = claudeKey }
        ClawdCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey
        ClawdCustomEndpointProvider.baseURL = customURL
        ClawdCustomEndpointProvider.model = customModel
        ClawdOpenAIProvider.model = openaiModel
        ClawdClaudeProvider.model = claudeModel
    }

    private func validateCurrentProvider() {
        isValidating = true
        validationResult = nil
        Task {
            do {
                let ok = try await aiManager.validateProvider(selectedProvider)
                validationResult = ok ? "✓ Connected successfully" : "✗ Connection failed"
            } catch {
                validationResult = "✗ \(error.localizedDescription)"
            }
            isValidating = false
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - OnDeviceModelManagementView

/// Sheet shown when the user taps the On-Device row and a model is already
/// installed. Lets the user inspect the current model and optionally switch
/// to a different one (which opens the full ModelPickerView).
private struct OnDeviceModelManagementView: View {
    let store: LocalModelStore
    let onChangeTapped: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var activeModel: LocalModelInfo? {
        guard let id = store.activeModelID else { return nil }
        return store.allModels.first { $0.id == id && store.isInstalled($0) }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    var body: some View {
        List {
            if let model = activeModel {
                Section("Active Model") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(model.displayName).font(.headline)
                        }
                        Text("Running on your device. No network used.")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(formattedSize(store.totalStorageUsed), systemImage: "internaldrive")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button("Change Model") {
                        onChangeTapped()
                    }
                } footer: {
                    Text("Opens the full model catalog to download a different model.")
                }
            } else {
                // Shouldn't happen — management view only shown when model is installed
                Section {
                    ContentUnavailableView("No Model Installed", systemImage: "cpu")
                }
            }
        }
        .navigationTitle("On-Device AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
