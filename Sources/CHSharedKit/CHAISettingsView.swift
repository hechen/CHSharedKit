import SwiftUI

// MARK: - AI Provider Settings View

/// SwiftUI view for configuring AI providers
/// Embed this in your app's settings screen
public struct CHAISettingsView: View {
    @StateObject private var aiManager = CHAIManager.shared
    @StateObject private var modelCatalog = CHAICloudModelCatalog.shared
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

    public init() {}

    /// Source of truth for which provider is currently selected — reads
    /// straight from the observed `CHAIManager` instead of a local
    /// `@State` mirror. The mirror approach was drifting stale when the
    /// detail page was first pushed (the @State captured at init time
    /// never re-ran), leaving the picker with no checkmark on the active
    /// row. Computed access keeps the checkmark, the expanded
    /// per-provider section, and the summary row all in sync with any
    /// write — local or external.
    private var selectedProvider: String {
        aiManager.effectiveActiveProviderID ?? aiManager.activeProviderID
    }

    public var body: some View {
        let _ = modelCatalog.revision
        List {
            // Summary row — always shows the currently-active provider so
            // the user sees at a glance what the app will use before
            // scrolling through the picker.
            Section {
                LabeledContent(String(localized: "Active Provider", bundle: .module)) {
                    Text(CHAIActiveProviderLabel.text(for: aiManager))
                        .foregroundStyle(.secondary)
                }
                // 2.18.0: a locked choice runs on its fallback until unlocked.
                if let notice = aiManager.activeProviderLockedFallbackNotice {
                    Label(notice, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Choose Provider", bundle: .module)) {
                // Apple Intelligence — only when the current provider
                // filter opts it in (it's part of `.onDeviceOnly` and
                // `.all`, the two common cases).
                if aiManager.availableProvidersFilter.contains(.appleIntelligence) {
                    providerRow(
                        CHAppleIntelligenceProvider.providerID,
                        name: "Apple Intelligence",
                        badge: String(localized: "Free", bundle: .module),
                        badgeColor: .green,
                        available: aiManager.isAppleIntelligenceAvailable,
                        unavailableReason: CHAppleIntelligenceProvider.unavailableReason
                    )
                }

                // Other providers — `availableProviders` already honors
                // the filter, so an on-device-only integration never
                // renders cloud-key rows here.
                ForEach(aiManager.availableProviders.filter { $0.id != CHAppleIntelligenceProvider.providerID }, id: \.id) { provider in
                    providerRow(provider.id, name: provider.name, badge: nil, badgeColor: .clear, available: true)
                }
            }
            
            // Apple Intelligence info
            if selectedProvider == CHAppleIntelligenceProvider.providerID {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "On-device, free, private. No data leaves your device.", bundle: .module))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Intelligence")
                }
            }
            
            // OpenAI settings
            if selectedProvider == CHOpenAIProvider.providerID {
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
                            SecureField(String(localized: "API Key", bundle: .module), text: $openaiKey)
                                .textContentType(.password)
                        }
                        Button { showingAPIKey.toggle() } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onSubmit { CHOpenAIProvider.apiKey = openaiKey }
                    
                    Picker(String(localized: "Model", bundle: .module), selection: $openaiModel) {
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
                            Text(String(localized: "Get your API key at", bundle: .module))
                            if let url = URL(string: "https://platform.openai.com/api-keys") {
                                Link("platform.openai.com", destination: url)
                            }
                        }
                        Text(String(localized: "Your API key is stored securely in the device Keychain.", bundle: .module))
                    }
                }
            }
            
            // Claude settings
            if selectedProvider == CHClaudeProvider.providerID {
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
                            SecureField(String(localized: "API Key", bundle: .module), text: $claudeKey)
                                .textContentType(.password)
                        }
                        Button { showingAPIKey.toggle() } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onSubmit { CHClaudeProvider.apiKey = claudeKey }
                    
                    Picker(String(localized: "Model", bundle: .module), selection: $claudeModel) {
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
                            Text(String(localized: "Get your API key at", bundle: .module))
                            if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                                Link("console.anthropic.com", destination: url)
                            }
                        }
                        Text(String(localized: "Your API key is stored securely in the device Keychain.", bundle: .module))
                    }
                }
            }
            
            // Custom endpoint settings
            if let provider = aiManager.provider(id: selectedProvider) as? CHAICatalogProvider {
            CHAICatalogProviderSettings(provider: provider)
                .id(provider.credentialID)
        }

        if selectedProvider == CHCustomEndpointProvider.providerID {
                Section {
                    HStack {
                        Text(String(localized: "Base URL", bundle: .module))
                        Spacer()
                        TextField("http://localhost:11434/v1", text: $customURL)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit { CHCustomEndpointProvider.baseURL = customURL }
                    }
                    
                    HStack {
                        Text(String(localized: "Model", bundle: .module))
                        Spacer()
                        TextField("llava", text: $customModel)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit { CHCustomEndpointProvider.model = customModel }
                    }
                    
                    HStack {
                        if showingAPIKey {
                            TextField(String(localized: "API Key (optional)", bundle: .module), text: $customKey)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()
                        } else {
                            SecureField(String(localized: "API Key (optional)", bundle: .module), text: $customKey)
                        }
                        Button { showingAPIKey.toggle() } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onSubmit { CHCustomEndpointProvider.apiKey = customKey.isEmpty ? nil : customKey }
                } header: {
                    Text(String(localized: "Custom Endpoint", bundle: .module))
                } footer: {
                    Text(String(localized: "OpenAI-compatible API (Ollama, vLLM, LMStudio, etc.)\nYour API key is stored securely in the device Keychain.", bundle: .module))
                }
            }
            
            // Validate (for non-Apple providers)
            if selectedProvider != CHAppleIntelligenceProvider.providerID {
                Section {
                    Button {
                        saveKeys()
                        validateCurrentProvider()
                    } label: {
                        HStack {
                            Text(String(localized: "Test Connection", bundle: .module))
                            Spacer()
                            if isValidating {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
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
        .navigationTitle(String(localized: "AI Provider", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done", bundle: .module)) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        #endif
        .onAppear {
            openaiKey = CHOpenAIProvider.apiKey ?? ""
            claudeKey = CHClaudeProvider.apiKey ?? ""
            customKey = CHCustomEndpointProvider.apiKey ?? ""
        }
        .task { await modelCatalog.refreshIfNeeded() }
    }
    
    @ViewBuilder
    private func providerRow(_ id: String, name: String, badge: String?, badgeColor: Color, available: Bool, unavailableReason: String? = nil) -> some View {
        Button {
            guard available else { return }
            aiManager.activeProviderID = id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .foregroundStyle(available ? .primary : .secondary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeColor.opacity(0.15))
                                .foregroundStyle(badgeColor)
                                .clipShape(Capsule())
                        }
                    }
                    if let reason = unavailableReason, !available {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                validationResult = ok ? String(localized: "✓ Connected successfully", bundle: .module) : String(localized: "✗ Connection failed", bundle: .module)
            } catch {
                validationResult = String(localized: "✗ \(error.localizedDescription)", bundle: .module)
            }
            isValidating = false
        }
    }
}
