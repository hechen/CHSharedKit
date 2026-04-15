import SwiftUI
import CHSharedKit

// MARK: - ClawdAIProviderPickerView

/// Full-screen standalone AI provider picker.
///
/// A ready-to-push navigation destination — has its own `List {}` and
/// `navigationTitle`. Use this when you want a dedicated "AI Provider"
/// screen with no extra sections.
///
/// ```swift
/// NavigationLink {
///     ClawdAIProviderPickerView(appIdentifier: .gymlog)
/// } label: {
///     Label("AI Provider", systemImage: "sparkles")
/// }
/// ```
public struct ClawdAIProviderPickerView: View {
    public let appIdentifier: AppIdentifier

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
    }

    public var body: some View {
        List {
            ClawdAISettingsContent(appIdentifier: appIdentifier)
        }
        .themedListBackground()
        .themedNavigationBar()
        .navigationTitle("AI Provider")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil)
                }
            }
        }
        #endif
    }
}

// MARK: - ClawdAISettingsContent

/// Canonical AI provider settings sections — embed directly inside a `List {}`.
///
/// Renders the provider list + per-provider config as List sections.
/// Use this when you need to mix in additional sections (e.g. a custom
/// prompt editor) alongside the provider picker.
///
/// **Bug fix:** tapping the On-Device row when a model is already installed
/// opens a management sheet instead of immediately reopening the download
/// picker. The download picker only auto-launches when no model is installed.
///
/// ```swift
/// List {
///     ClawdAISettingsContent(appIdentifier: .distill)
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

    // Active installed model — checks allModels so custom models are found too
    private var activeModel: LocalModelInfo? {
        guard let id = modelStore.activeModelID else { return nil }
        return modelStore.allModels.first { $0.id == id && modelStore.isInstalled($0) }
    }

    public var body: some View {
        Section {
            // On-Device — smart tap: management sheet if installed, picker if not
            onDeviceProviderRow

            // Apple Intelligence
            providerRow(
                id: ClawdAppleIntelligenceProvider.providerID,
                icon: "apple.intelligence",
                iconColor: .blue,
                name: "Apple Intelligence",
                badge: "Free",
                badgeColor: .green,
                subtitle: aiManager.isAppleIntelligenceAvailable ? "On-device · iOS 26+" : nil,
                available: aiManager.isAppleIntelligenceAvailable,
                unavailableReason: "Requires iOS 26+"
            )

            // Cloud providers (excluding Apple + On-Device which are listed above)
            ForEach(
                aiManager.availableProviders.filter {
                    $0.id != ClawdAppleIntelligenceProvider.providerID &&
                    $0.id != ClawdLocalLLMProvider.providerID
                },
                id: \.id
            ) { provider in
                cloudProviderRow(id: provider.id, name: provider.name)
            }
        } header: {
            Text("AI Provider")
        } footer: {
            Text("On-Device runs fully offline. No data leaves your device.")
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
                keyField("sk-...", key: $openaiKey)
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
                    Text("API key stored securely in Keychain.")
                }
            }
        }

        // Claude settings
        if selectedProvider == ClawdClaudeProvider.providerID {
            Section {
                keyField("sk-ant-...", key: $claudeKey)
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
                    Text("API key stored securely in Keychain.")
                }
            }
        }

        // Custom endpoint settings
        if selectedProvider == ClawdCustomEndpointProvider.providerID {
            Section {
                #if os(iOS)
                LabeledContent("Base URL") {
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.baseURL = customURL }
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.model = customModel }
                }
                #else
                LabeledContent("Base URL") {
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.baseURL = customURL }
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit { ClawdCustomEndpointProvider.model = customModel }
                }
                #endif
                keyField("API Key (optional)", key: $customKey)
                    .onSubmit { ClawdCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey }
            } header: {
                Text("Custom Endpoint")
            } footer: {
                Text("OpenAI-compatible API — Ollama, vLLM, LMStudio, etc.")
            }
        }

        // Test Connection (cloud providers only)
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
            HStack(spacing: 12) {
                providerIcon("cpu", color: .indigo, available: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("On-Device AI")
                            .font(.system(size: 16))
                        badge("Private", color: .indigo)
                        badge("Offline", color: .orange)
                    }
                    Text(activeModel.map { $0.displayName } ?? "Runs fully offline · No API key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedProvider == ClawdLocalLLMProvider.providerID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
        // Management sheet — shown when a model is already installed
        .sheet(isPresented: $showModelManagement, onDismiss: {
            selectedProvider = aiManager.activeProviderID
        }) {
            NavigationStack {
                OnDeviceModelManagementView(
                    store: modelStore,
                    onChangeTapped: {
                        showModelManagement = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showModelPicker = true
                        }
                    }
                )
            }
        }
        // Download/browse picker sheet
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
                        Text("Active · Runs offline on this device")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Change Model") { showModelManagement = true }
                    .foregroundStyle(.tint)
            } else if modelStore.activeDownloadModelID != nil {
                LocalModelDownloadView()
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("No model downloaded yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Download a Model") { showModelPicker = true }
                    .foregroundStyle(.tint)
            }
        } header: {
            Text("On-Device")
        }
    }

    // MARK: - Provider row helpers

    @ViewBuilder
    private func cloudProviderRow(id: String, name: String) -> some View {
        let (icon, iconColor, subtitle) = cloudProviderMeta(id)
        providerRow(
            id: id,
            icon: icon,
            iconColor: iconColor,
            name: name,
            badge: nil,
            badgeColor: .clear,
            subtitle: subtitle,
            available: true
        )
    }

    private func cloudProviderMeta(_ id: String) -> (icon: String, color: Color, subtitle: String?) {
        switch id {
        case ClawdOpenAIProvider.providerID:
            return ("brain", .mint, "GPT-4o, GPT-4o mini")
        case ClawdClaudeProvider.providerID:
            return ("sparkles", .orange, "Sonnet, Haiku")
        case ClawdCustomEndpointProvider.providerID:
            return ("server.rack", .gray, "Ollama, LM Studio, vLLM")
        default:
            return ("network", .blue, nil)
        }
    }

    @ViewBuilder
    private func providerRow(
        id: String,
        icon: String,
        iconColor: Color,
        name: String,
        badge: String?,
        badgeColor: Color,
        subtitle: String?,
        available: Bool,
        unavailableReason: String? = nil
    ) -> some View {
        Button {
            guard available else { return }
            selectedProvider = id
            aiManager.activeProviderID = id
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 12) {
                providerIcon(icon, color: iconColor, available: available)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 16))
                            .foregroundStyle(available ? .primary : .secondary)
                        if let badge {
                            self.badge(badge, color: badgeColor)
                        }
                    }
                    if let reason = unavailableReason, !available {
                        Text(reason).font(.caption).foregroundStyle(.tertiary)
                    } else if let sub = subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selectedProvider == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
        .disabled(!available)
    }

    @ViewBuilder
    private func providerIcon(_ systemName: String, color: Color, available: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(available ? 0.15 : 0.08))
                .frame(width: 36, height: 36)
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(available ? color : .gray)
        }
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func keyField(_ placeholder: String, key: Binding<String>) -> some View {
        HStack {
            if showingAPIKey {
                TextField(placeholder, text: key)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } else {
                SecureField(placeholder, text: key)
                    .textContentType(.password)
            }
            Button { showingAPIKey.toggle() } label: {
                Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

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
}

// MARK: - OnDeviceModelManagementView

/// Sheet shown when the user taps On-Device and a model is already installed.
/// Lets the user inspect the active model and optionally switch to a different one.
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
                        Text("Active · Runs offline on this device")
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
