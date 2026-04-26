import SwiftUI
import CHSharedKit

// MARK: - CHAIProviderPickerView

/// Full-screen standalone AI provider picker.
///
/// A ready-to-push navigation destination — has its own `List {}` and
/// `navigationTitle`. Use this when you want a dedicated "AI Provider"
/// screen with no extra sections.
///
/// ```swift
/// NavigationLink {
///     CHAIProviderPickerView(appIdentifier: .gymlog)
/// } label: {
///     Label("AI Provider", systemImage: "sparkles")
/// }
/// ```
public struct CHAIProviderPickerView: View {
    public let appIdentifier: AppIdentifier

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
    }

    public var body: some View {
        List {
            CHAISettingsContent(appIdentifier: appIdentifier)
        }
        .themedListBackground()
        .themedNavigationBar()
        .navigationTitle("AI Provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

// MARK: - CHAISettingsContent

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
///     CHAISettingsContent(appIdentifier: .distill)
///     Section("Custom Prompt") { ... }
/// }
/// ```
public struct CHAISettingsContent: View {
    public let appIdentifier: AppIdentifier

    @StateObject private var aiManager = CHAIManager.shared
    @State private var openaiKey = ""
    @State private var claudeKey = ""
    @State private var customURL = CHCustomEndpointProvider.baseURL
    @State private var customModel = CHCustomEndpointProvider.model
    @State private var customKey = ""
    @State private var openaiModel = CHOpenAIProvider.model
    @State private var claudeModel = CHClaudeProvider.model
    @State private var isValidating = false
    @State private var validationResult: String?
    @State private var showingAPIKey = false
    @State private var showModelPicker = false

    @State private var modelStore = LocalModelStore.shared

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
    }

    /// Source of truth for the currently-selected provider — reads
    /// straight from the observed `CHAIManager` so the checkmark, the
    /// expanded per-provider section, and the "Active Provider" summary
    /// row stay in sync with any write. Replaces a prior `@State` mirror
    /// that captured `CHAIManager.shared.activeProviderID` once at view
    /// init and drifted stale on re-push.
    private var selectedProvider: String { aiManager.activeProviderID }

    // Active installed model — checks allModels so custom models are found too
    private var activeModel: LocalModelInfo? {
        guard let id = modelStore.activeModelID else { return nil }
        return modelStore.allModels.first { $0.id == id && modelStore.isInstalled($0) }
    }

    public var body: some View {
        // Summary row — always shows the currently-active provider so
        // the user sees at a glance what the app will use before
        // scrolling through the picker below.
        Section {
            LabeledContent("Active Provider") {
                Text(CHAIActiveProviderLabel.text(for: aiManager))
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            // On-Device — smart tap: management sheet if installed, picker if not
            onDeviceProviderRow

            // Apple Intelligence
            providerRow(
                id: CHAppleIntelligenceProvider.providerID,
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
                    $0.id != CHAppleIntelligenceProvider.providerID &&
                    $0.id != CHLocalLLMProvider.providerID
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
        if selectedProvider == CHLocalLLMProvider.providerID {
            onDeviceDetailSection
        }

        // Apple Intelligence info
        if selectedProvider == CHAppleIntelligenceProvider.providerID {
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
        if selectedProvider == CHOpenAIProvider.providerID {
            Section {
                keyField("sk-...", key: $openaiKey)
                    .onSubmit { CHOpenAIProvider.apiKey = openaiKey }

                Picker("Model", selection: $openaiModel) {
                    ForEach(CHOpenAIProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .onChange(of: openaiModel) { _, val in CHOpenAIProvider.model = val }
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
        if selectedProvider == CHClaudeProvider.providerID {
            Section {
                keyField("sk-ant-...", key: $claudeKey)
                    .onSubmit { CHClaudeProvider.apiKey = claudeKey }

                Picker("Model", selection: $claudeModel) {
                    ForEach(CHClaudeProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .onChange(of: claudeModel) { _, val in CHClaudeProvider.model = val }
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
        if selectedProvider == CHCustomEndpointProvider.providerID {
            Section {
                #if os(iOS)
                LabeledContent("Base URL") {
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onSubmit { CHCustomEndpointProvider.baseURL = customURL }
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { CHCustomEndpointProvider.model = customModel }
                }
                #else
                LabeledContent("Base URL") {
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit { CHCustomEndpointProvider.baseURL = customURL }
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit { CHCustomEndpointProvider.model = customModel }
                }
                #endif
                keyField("API Key (optional)", key: $customKey)
                    .onSubmit { CHCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey }
            } header: {
                Text("Custom Endpoint")
            } footer: {
                Text("OpenAI-compatible API — Ollama, vLLM, LMStudio, etc.")
            }
        }

        // Test Connection (cloud providers only)
        let isCloudProvider = selectedProvider != CHAppleIntelligenceProvider.providerID
                           && selectedProvider != CHLocalLLMProvider.providerID
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
            // Always activate the on-device provider first — tapping the row
            // is foremost a provider selection, matching every other row.
            // Sheet presentation is secondary.
            aiManager.activeProviderID = CHLocalLLMProvider.providerID
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif

            // Onboarding: if no model is installed yet, auto-open the picker
            // so the user can download one. If a model is already active,
            // just leave it selected — the detail section below exposes
            // "Change Model" which jumps straight to the catalog.
            if activeModel == nil {
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
                if selectedProvider == CHLocalLLMProvider.providerID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
        // Download/browse picker sheet — tapping "Change Model" on the
        // detail row opens this directly (2.4.6). Removed a prior
        // management-intermediate sheet that added a redundant screen
        // plus a 0.35s dismiss-then-present delay.
        #if os(iOS)
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                ModelPickerView(appIdentifier: appIdentifier) {
                    showModelPicker = false
                }
            }
        }
        #endif
        .onAppear {
            openaiKey = CHOpenAIProvider.apiKey ?? ""
            claudeKey = CHClaudeProvider.apiKey ?? ""
            customKey = CHCustomEndpointProvider.apiKey ?? ""
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
                Button("Change Model") { showModelPicker = true }
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
        case CHOpenAIProvider.providerID:
            return ("brain", .mint, "GPT-4o, GPT-4o mini")
        case CHClaudeProvider.providerID:
            return ("sparkles", .orange, "Sonnet, Haiku")
        case CHCustomEndpointProvider.providerID:
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
        if !openaiKey.isEmpty { CHOpenAIProvider.apiKey = openaiKey }
        if !claudeKey.isEmpty { CHClaudeProvider.apiKey = claudeKey }
        CHCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey
        CHCustomEndpointProvider.baseURL = customURL
        CHCustomEndpointProvider.model = customModel
        CHOpenAIProvider.model = openaiModel
        CHClaudeProvider.model = claudeModel
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

