import SwiftUI

// MARK: - AI Provider Settings View

/// SwiftUI view for configuring AI providers
/// Embed this in your app's settings screen
public struct ClawdAISettingsView: View {
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
    
    public init() {}
    
    public var body: some View {
        List {
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
                
                // Other providers
                ForEach(aiManager.availableProviders.filter { $0.id != ClawdAppleIntelligenceProvider.providerID }, id: \.id) { provider in
                    providerRow(provider.id, name: provider.name, badge: nil, badgeColor: .clear, available: true)
                }
            }
            
            // Apple Intelligence info
            if selectedProvider == ClawdAppleIntelligenceProvider.providerID {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("On-device, free, private. No data leaves your device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
            
            // Validate (for non-Apple providers)
            if selectedProvider != ClawdAppleIntelligenceProvider.providerID {
                Section {
                    Button {
                        saveKeys()
                        validateCurrentProvider()
                    } label: {
                        HStack {
                            Text("Test Connection")
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
        .navigationTitle("AI Provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        #endif
        .onAppear {
            openaiKey = ClawdOpenAIProvider.apiKey ?? ""
            claudeKey = ClawdClaudeProvider.apiKey ?? ""
            customKey = ClawdCustomEndpointProvider.apiKey ?? ""
        }
    }
    
    @ViewBuilder
    private func providerRow(_ id: String, name: String, badge: String?, badgeColor: Color, available: Bool, unavailableReason: String? = nil) -> some View {
        Button {
            guard available else { return }
            selectedProvider = id
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
