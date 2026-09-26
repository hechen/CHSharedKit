import SwiftUI
import Combine
import CHSharedKit

// MARK: - CHAIProviderPickerView

/// Full-screen AI provider picker — designed as a **navigation destination**
/// (push), NOT a self-contained scene.
///
/// Sets `.navigationTitle` and a keyboard-dismiss toolbar but does NOT wrap
/// itself in `NavigationStack`. The caller's surrounding `NavigationStack`
/// supplies the nav bar.
///
/// ## Push (recommended)
///
/// ```swift
/// NavigationLink {
///     CHAIProviderPickerView(appIdentifier: .liftcoach)
/// } label: {
///     Label("AI Provider", systemImage: "sparkles")
/// }
/// ```
///
/// ## Modal presentation
///
/// Use ``CHAISettingsSheet`` instead — it owns the `NavigationStack` + Done
/// button. **Do NOT wrap `CHAIProviderPickerView` in your own `NavigationStack`
/// inside a `.sheet { ... }`** — the picker's `.navigationTitle` will pick
/// up the wrapping stack and you'll get a double nav bar (the consumer's
/// outer push stack + the sheet's inner one). Use `CHAISettingsSheet` and
/// the kit handles the modal chrome correctly:
///
/// ```swift
/// .sheet(isPresented: $showAISettings) {
///     CHAISettingsSheet(appIdentifier: .spendwisely)
/// }
/// ```
///
/// ## Embed inside an existing `List`
///
/// Use ``CHAISettingsContent`` (this view's body inlined) for that case.
public struct CHAIProviderPickerView: View {
    public let appIdentifier: AppIdentifier

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
    }

    public var body: some View {
        Group {
            #if os(macOS)
            // 2.17.0: a grouped Form, like every other Mac Settings pane. As
            // a List it drew bold black footers and full-width tinted rows.
            Form {
                CHAISettingsContent(appIdentifier: appIdentifier)
            }
            .formStyle(.grouped)
            #else
            List {
                CHAISettingsContent(appIdentifier: appIdentifier)
            }
            #endif
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

// MARK: - CHAISettingsSheet (2.7.1)

/// Modal-presentation wrapper around ``CHAIProviderPickerView``.
///
/// Uses CHSharedKit's fleet-wide ``CHSettingsSheet`` shell, which owns the
/// `NavigationStack`, Done action, theme-aware header/body/footer surfaces,
/// and standard macOS geometry. Use this for `.sheet { ... }` presentation so
/// consumer apps don't need to hand-roll modal chrome (which causes visual
/// drift and can create a double nav bar when the same content is also pushed
/// somewhere else).
///
/// ```swift
/// .sheet(isPresented: $showAISettings) {
///     CHAISettingsSheet(appIdentifier: .spendwisely)
/// }
/// ```
///
/// Pass `onDismiss` to react to the user tapping Done (defaults to nil —
/// the sheet just dismisses).
public struct CHAISettingsSheet: View {
    public let appIdentifier: AppIdentifier
    public let onDismiss: (() -> Void)?

    public init(
        appIdentifier: AppIdentifier,
        onDismiss: (() -> Void)? = nil
    ) {
        self.appIdentifier = appIdentifier
        self.onDismiss = onDismiss
    }

    public var body: some View {
        CHSettingsSheet("AI Provider", onDismiss: onDismiss) {
            CHAIProviderPickerView(appIdentifier: appIdentifier)
        }
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

    @ObservedObject private var aiManager = CHAIManager.shared
    @ObservedObject private var modelCatalog = CHAICloudModelCatalog.shared
    @State private var openaiKey = ""
    @State private var claudeKey = ""
    @State private var customURL = CHCustomEndpointProvider.baseURL
    @State private var customModel = CHCustomEndpointProvider.model
    @State private var customKey = ""

    // 2.9.6: model selections are bound directly to UserDefaults via
    // `@AppStorage` so any write — from the in-picker dropdown OR
    // from another surface — fires a body re-render. Pre-2.9.6 used
    // `@State` initialized once from `CHOpenAIProvider.model`, with a
    // separate `.onChange` write-back to UserDefaults. That arrangement
    // had a single-pass race: the user picks a new model, @State
    // updates, body re-evaluates immediately, and `cloudProviderMeta`
    // calls `CHOpenAIProvider.currentModel` which reads UserDefaults
    // BEFORE `.onChange` has run its writeback. Result: the
    // OpenAI/Claude rows showed the OLD model until some other state
    // change kicked another body invalidation. `@AppStorage` collapses
    // that path — the dropdown's `$openaiModel` binding writes directly
    // to UserDefaults, the `@AppStorage` property publishes the
    // change, the body sees the new value on the same render pass.
    //
    // The keys here MUST match the static `model` getter in each
    // provider type. If those keys ever change, update both sides
    // together.
    @AppStorage("clawd_openai_model") private var openaiModel: String = "gpt-5.6-terra"
    @AppStorage("clawd_claude_model") private var claudeModel: String = "claude-sonnet-5"

    // 2.17.0: typed state for the Test Connection row, which now sits in
    // the provider's own section instead of a section at the page bottom.
    @State private var connectionTest = CHAIConnectionTestState.idle
    @State private var showingAPIKey = false
    private enum ModelPickerSource { case provider, detail }
    @State private var modelPickerSource: ModelPickerSource?

    // Resolve the singleton only while local models are offered. Its initializer
    // restores installations and cleans staging files, which is unnecessary for
    // hosts that only expose Apple Intelligence and cloud providers.
    private let makeModelStore: @MainActor () -> LocalModelStore

    var showsDownloadableModels: Bool {
        aiManager.isProviderEnabled(CHLocalLLMProvider.providerID)
            && aiManager.availableProvidersFilter.contains(.onDeviceLocal)
    }

    var modelStore: LocalModelStore? {
        guard showsDownloadableModels else { return nil }
        return makeModelStore()
    }

    // 2.6.0 IAP gating — picker mirrors the registered gate's published state
    // and routes locked-row taps to the banner instead of the activate path.
    @State private var unlockState: UnlockState = .none

    /// Whether the host's provider filter offers cloud providers at all.
    /// `CHAIRegionPolicy` removes them on a restricted storefront; then the
    /// unlock banner and the Cloud APIs section have nothing to sell.
    private var offersCloudProviders: Bool {
        aiManager.availableProvidersFilter.contains(.cloudProviders)
    }
    @State private var pulseTrigger: Int = 0
    @State private var purchaseError: String?
    // 2.16.0: restore reports what it achieved, not only failures.
    @State private var isRestoring = false
    @State private var restoreOutcome: CHAIRestoreOutcome?

    private enum UnlockState: Equatable {
        case none                       // no gate registered or empty gatedProviderIDs
        case locked(priceLabel: String?)
        case purchasing
        case unlocked
    }

    public init(appIdentifier: AppIdentifier) {
        self.appIdentifier = appIdentifier
        self.makeModelStore = { LocalModelStore.shared }
    }

    // Test seam: verifies that merely opening a hidden local-model surface
    // never resolves the store. Production always uses the lazy singleton.
    init(appIdentifier: AppIdentifier, makeModelStore: @escaping @MainActor () -> LocalModelStore) {
        self.appIdentifier = appIdentifier
        self.makeModelStore = makeModelStore
    }

    /// Source of truth for the currently-selected provider — reads
    /// straight from the observed `CHAIManager` so the checkmark, the
    /// expanded per-provider section, and the "Active Provider" summary
    /// row stay in sync with any write. Replaces a prior `@State` mirror
    /// that captured `CHAIManager.shared.activeProviderID` once at view
    /// init and drifted stale on re-push.
    private var selectedProvider: String {
        aiManager.effectiveActiveProviderID ?? aiManager.activeProviderID
    }

    // Active installed model — checks allModels so custom models are found too
    private var activeModel: LocalModelInfo? {
        guard let modelStore, let id = modelStore.activeModelID else { return nil }
        return modelStore.allModels.first { $0.id == id && modelStore.isInstalled($0) }
    }

    public var body: some View {
        let _ = modelCatalog.revision
        #if os(iOS)
        // Summary row — always shows the currently-active provider so
        // the user sees at a glance what the app will use before
        // scrolling through the picker below. On the Mac the Provider
        // menu shows the choice itself.
        withSettingsLifecycle(
            Section {
                LabeledContent("Current Provider") {
                    Text(CHAIActiveProviderLabel.text(for: aiManager))
                        .foregroundStyle(.secondary)
                }
            }
        )
        #endif

        // 2.6.0: IAP unlock banner. Renders only when a gate is registered,
        // at least one provider is gated, and the user hasn't unlocked.
        // Tapping a locked provider row pulses this banner via `pulseTrigger`
        // so the user's eye gets drawn to the unlock path instead of a
        // mysterious "tap does nothing" failure.
        // 2.19.4: nothing to unlock where the policy hides cloud providers
        // (a restricted storefront): no banner, no ownership card.
        if offersCloudProviders, case .locked(let priceLabel) = unlockState {
            Section {
                CHAIProviderUnlockBanner(
                    priceLabel: priceLabel,
                    lockedProviderNames: lockedProviderDisplayNames,
                    showsDownloadableModels: showsDownloadableModels,
                    isPurchasing: false,
                    pulseTrigger: pulseTrigger,
                    onPurchase: { Task { await runPurchase() } },
                    onRestore: { Task { await runRestore() } }
                )
                // Keep the banner comfortably inside the List section's own
                // rounded mask. A token inset still lets the two corner arcs
                // intersect on iOS; 12 pt separates the card from that mask.
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if offersCloudProviders, case .purchasing = unlockState {
            Section {
                CHAIProviderUnlockBanner(
                    priceLabel: nil,
                    lockedProviderNames: lockedProviderDisplayNames,
                    showsDownloadableModels: showsDownloadableModels,
                    isPurchasing: true,
                    pulseTrigger: pulseTrigger,
                    onPurchase: {},
                    onRestore: {}
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
            }
        } else if offersCloudProviders, case .unlocked = unlockState {
            // 2.16.0: acknowledge the purchase and keep Restore reachable at
            // full size, instead of a caption link in the Cloud APIs footer.
            Section {
                CHAIProviderOwnershipCard(
                    productName: CHIAPGateRegistry.shared?.unlockProductDisplayName,
                    isRestoring: isRestoring,
                    restoreOutcome: restoreOutcome,
                    onRestore: { Task { await runRestore() } }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        // A restore from the locked banner that found nothing still needs
        // saying; the ownership card shows its own outcome inline.
        if case .locked = unlockState, let restoreOutcome {
            Section {
                Label(restoreOutcome.message, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let purchaseError {
            Section {
                Label(purchaseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        #if os(macOS)
        withSettingsLifecycle(macProviderSection)
        #else
        Section {
            // On-Device — smart tap: management sheet if installed, picker if not
            if showsDownloadableModels {
                onDeviceProviderRow
            }

            // Apple Intelligence — never gated
            providerRow(
                id: CHAppleIntelligenceProvider.providerID,
                icon: "apple.intelligence",
                iconColor: .blue,
                name: "Apple Intelligence",
                badge: "Free",
                badgeColor: .green,
                subtitle: aiManager.isAppleIntelligenceAvailable
                    ? CHAppleIntelligenceProvider.availabilitySubtitle
                    : nil,
                available: aiManager.isAppleIntelligenceAvailable,
                unavailableReason: CHAppleIntelligenceProvider.unavailableReason
            )

        } header: {
            Text("On This Device")
        } footer: {
            if showsDownloadableModels {
                Text("Apple Intelligence and downloaded models keep requests on this device.")
            } else {
                Text("Apple Intelligence keeps requests on this device.")
            }
        }

        // 2.19.4: the whole section goes where cloud providers are not offered.
        if offersCloudProviders {
            Section {
                // Cloud providers. On macOS, Custom Endpoint moves to Advanced.
                // A host can hide it on other platforms via disabledProviderIDs.
                ForEach(
                    aiManager.availableProviders.filter { appearsInCloudAPIs($0.id) },
                    id: \.id
                ) { provider in
                    cloudProviderRow(id: provider.id, name: provider.name)
                }
            } header: {
                Text("Cloud APIs")
            } footer: {
                // 2.16.0: Restore moved to the ownership card at the top. It sat
                // here as a caption-size link from 2.6.0, filed under an
                // explanation of API keys it had nothing to do with.
                // 2.17.0: named every service and wraps. It listed only OpenAI
                // and Anthropic, above a Grok row, and truncated on the Mac.
                Text("Each service uses your own API key and bills your account with that provider. Chat subscriptions such as ChatGPT Plus or Claude Pro do not include API usage.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: unlockState)
        }

        #endif

        // On-Device detail section (when selected)
        if showsDownloadableModels,
           selectedProvider == CHLocalLLMProvider.providerID || modelPickerSource == .detail {
            onDeviceDetailSection
        }

        // Apple Intelligence info. On the Mac the Provider footer says this.
        #if os(iOS)
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
        #endif

        // OpenAI settings
        //
        // 2.5.5: persist on every keystroke via `.onChange(of:)` instead of
        // only on Return via `.onSubmit`. The bug was that users who typed
        // their API key and then navigated away (the common path on iOS —
        // backswipe to settings list, never tap Return) lost the key. The
        // @State-bound text was never written to keychain, and on the next
        // appearance `.onAppear` reloaded from keychain → empty/old value.
        //
        // The same fix is applied to Claude key, custom endpoint URL,
        // custom endpoint model name, and custom endpoint key. Per-provider
        // keychain isolation (added in 2.4.8 via `CHAITokenStore`) is
        // unchanged — this is purely the picker-layer save trigger.
        //
        // `.onChange` fires on every text edit; keychain writes are atomic
        // and cheap so per-keystroke persistence is fine. The initial
        // .onAppear-driven load from keychain DOES trigger a no-op
        // .onChange (load value → write same value back), which is
        // harmless.
        if selectedProvider == CHOpenAIProvider.providerID {
            CHAIProviderCredentialSection(
                providerName: "OpenAI",
                keyPlaceholder: "sk-...",
                apiKey: $openaiKey,
                billingAccountName: "OpenAI",
                endpointHost: URL(string: CHOpenAIProvider.baseURL)?.host(),
                apiKeyURL: URL(string: "https://platform.openai.com/api-keys"),
                privacyPolicyURL: URL(string: "https://openai.com/policies/privacy-policy/"),
                connectionTest: connectionTest,
                onTestConnection: testConnection
            ) {
                // 2.9.6: $openaiModel is `@AppStorage`-bound so the
                // picker writes directly to UserDefaults. No
                // `.onChange { CHOpenAIProvider.model = val }`
                // writeback — that was the source of the same-pass
                // staleness in the OpenAI row.
                Picker("Model", selection: $openaiModel) {
                    ForEach(CHOpenAIProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }
            .onChange(of: openaiKey) { _, val in
                CHOpenAIProvider.apiKey = val
                connectionTest = .idle
            }
            .onAppear { openaiKey = CHOpenAIProvider.apiKey ?? "" }
        }

        // Claude settings
        if selectedProvider == CHClaudeProvider.providerID {
            CHAIProviderCredentialSection(
                providerName: "Anthropic Claude",
                keyPlaceholder: "sk-ant-...",
                apiKey: $claudeKey,
                billingAccountName: "Anthropic",
                endpointHost: URL(string: CHClaudeProvider.baseURL)?.host(),
                apiKeyURL: URL(string: "https://console.anthropic.com/settings/keys"),
                privacyPolicyURL: URL(string: "https://www.anthropic.com/legal/privacy"),
                connectionTest: connectionTest,
                onTestConnection: testConnection
            ) {
                // 2.9.6: same fix as the OpenAI Picker — $claudeModel
                // writes directly via `@AppStorage`.
                Picker("Model", selection: $claudeModel) {
                    ForEach(CHClaudeProvider.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }
            .onChange(of: claudeKey) { _, val in
                CHClaudeProvider.apiKey = val
                connectionTest = .idle
            }
            .onAppear { claudeKey = CHClaudeProvider.apiKey ?? "" }
        }

        // Custom endpoint settings
        if let provider = aiManager.provider(id: selectedProvider) as? CHAICatalogProvider {
            CHAICatalogProviderSettings(
                provider: provider,
                connectionTest: connectionTest,
                onTestConnection: testConnection,
                onAPIKeyChange: { connectionTest = .idle }
            )
            .id(provider.credentialID)
        }

        if selectedProvider == CHCustomEndpointProvider.providerID {
            Section {
                #if os(iOS)
                LabeledContent("Base URL") {
                    TextField("http://localhost:11434/v1", text: $customURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $customModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                #else
                LabeledContent("Base URL") {
                    TextField(text: $customURL, prompt: Text("http://localhost:11434/v1")) { Text("Base URL") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 340)
                        .autocorrectionDisabled()
                }
                LabeledContent("Model") {
                    TextField(text: $customModel, prompt: Text("llama3")) { Text("Model") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 340)
                        .autocorrectionDisabled()
                }
                #endif
                LabeledContent("API Key") {
                    keyField("Optional", key: $customKey)
                }
                CHAIConnectionTestRow(
                    state: connectionTest,
                    canTest: !customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: testConnection
                )
            } header: {
                Text("Custom Endpoint")
            } footer: {
                Text("OpenAI-compatible API — Ollama, vLLM, LMStudio, etc.")
            }
            .onChange(of: customURL) { _, val in
                CHCustomEndpointProvider.baseURL = val
                connectionTest = .idle
            }
            .onChange(of: customModel) { _, val in
                CHCustomEndpointProvider.model = val
                connectionTest = .idle
            }
            .onChange(of: customKey) { _, val in
                CHCustomEndpointProvider.apiKey = val.isEmpty ? nil : val
                connectionTest = .idle
            }
            .onAppear {
                customKey = CHCustomEndpointProvider.apiKey ?? ""
                customURL = CHCustomEndpointProvider.baseURL
                customModel = CHCustomEndpointProvider.model
            }
        }

    }

    // MARK: - Lifecycle

    /// Loads keys, tracks the gate and resets stale state. Attached to the
    /// first always-present section: the summary row on iOS, the Provider
    /// menu on the Mac.
    private func withSettingsLifecycle<V: View>(_ section: V) -> some View {
        section
            .onAppear {
                openaiKey = CHOpenAIProvider.apiKey ?? ""
                claudeKey = CHClaudeProvider.apiKey ?? ""
                customKey = CHCustomEndpointProvider.apiKey ?? ""
                refreshUnlockState()
            }
            .onChange(of: showsDownloadableModels) { _, isAvailable in
                if !isAvailable { modelPickerSource = nil }
            }
            // One provider's test result must not show on the next one's row.
            .onChange(of: selectedProvider) { _, _ in connectionTest = .idle }
            .task { await modelCatalog.refreshIfNeeded() }
            .onReceive(gatePublisher) { _ in
                refreshUnlockState()
            }
    }

    #if os(macOS)
    // MARK: - Mac provider menu

    /// 2.17.0: the Mac chooses a provider from one pop-up menu, the control
    /// System Settings uses for a single choice. It replaced three iOS-style
    /// lists of 36 pt icon tiles that drew as tinted push buttons in a Mac
    /// Form and made the page several times taller than the Settings window.
    @ViewBuilder
    private var macProviderSection: some View {
        let cloudProviders = aiManager.availableProviders.filter { appearsInCloudAPIs($0.id) }
        let offersCustomEndpoint = aiManager.availableProviders.contains {
            $0.id == CHCustomEndpointProvider.providerID
        }
        Section {
            Picker("Provider", selection: Binding(
                get: { selectedProvider },
                set: { selectMacProvider($0) }
            )) {
                Section("On This Device") {
                    macMenuItem(CHAppleIntelligenceProvider.providerID,
                                name: "Apple Intelligence", icon: "apple.intelligence")
                        .disabled(!aiManager.isAppleIntelligenceAvailable)
                    if showsDownloadableModels {
                        macMenuItem(CHLocalLLMProvider.providerID, name: "On-Device AI", icon: "cpu")
                    }
                }
                if !cloudProviders.isEmpty {
                    Section("Cloud") {
                        ForEach(cloudProviders, id: \.id) { provider in
                            macMenuItem(provider.id, name: provider.name,
                                        icon: cloudProviderMeta(provider.id).icon)
                        }
                    }
                }
                if offersCustomEndpoint {
                    Section("Advanced") {
                        macMenuItem(CHCustomEndpointProvider.providerID,
                                    name: "Custom Endpoint", icon: "server.rack")
                    }
                }
            }
            .pickerStyle(.menu)

            if aiManager.isLocked(providerID: selectedProvider) {
                Label("Locked — unlock above to use this provider", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(macProviderFooter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macMenuItem(_ id: String, name: String, icon: String) -> some View {
        let isLocked = aiManager.isLocked(providerID: id)
        return Label(isLocked ? "\(name) (Locked)" : name, systemImage: icon)
            .tag(id)
    }

    private func selectMacProvider(_ id: String) {
        // A locked choice points at the unlock card instead of switching.
        if aiManager.isLocked(providerID: id) {
            pulseTrigger += 1
            return
        }
        if id == CHAppleIntelligenceProvider.providerID,
           !aiManager.isAppleIntelligenceAvailable { return }
        aiManager.activeProviderID = id
        // The Mac has no provider row to present from; the detail
        // section below does, so a first-time pick opens its catalog.
        if id == CHLocalLLMProvider.providerID, activeModel == nil {
            modelPickerSource = .detail
        }
    }

    private var macProviderFooter: String {
        switch selectedProvider {
        case CHAppleIntelligenceProvider.providerID:
            return "Apple Intelligence runs on this Mac. It is free, and requests never leave the device."
        case CHLocalLLMProvider.providerID:
            return "Runs a downloaded model entirely on this Mac, even offline."
        case CHCustomEndpointProvider.providerID:
            return "Connect an OpenAI-compatible service that you operate or trust."
        default:
            return "Cloud providers use your own API key and bill your account with that provider. Chat subscriptions such as ChatGPT Plus or Claude Pro do not include API usage."
        }
    }
    #endif

    // MARK: - On-Device rows

    @ViewBuilder
    private var onDeviceProviderRow: some View {
        // 2.6.0: same lock treatment as cloud providers when on-device-llm
        // is in `gatedProviderIDs`.
        let isLocked = aiManager.isLocked(providerID: CHLocalLLMProvider.providerID)
        let isActiveLocked = isLocked && selectedProvider == CHLocalLLMProvider.providerID

        Button {
            guard showsDownloadableModels else { return }
            if isLocked {
                pulseTrigger += 1
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                return
            }
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
                modelPickerSource = .provider
            }
        } label: {
            HStack(spacing: 12) {
                providerIcon("cpu", color: .indigo, available: true)
                    .opacity(isLocked ? 0.6 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    // 2.7.0: same lock-alignment polish as cloud rows.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("On-Device AI")
                            .font(.body)
                            .opacity(isLocked && !isActiveLocked ? 0.6 : 1.0)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.subheadline)
                                .imageScale(.small)
                                .foregroundStyle(.indigo)
                        }
                        badge("Private", color: .indigo)
                        badge("Offline", color: .orange)
                    }
                    if isActiveLocked {
                        Text("Locked — purchase required")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    } else {
                        Text(activeModel.map { $0.displayName } ?? "Runs fully offline · No API key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(isLocked ? 0.6 : 1.0)
                    }
                }
                Spacer()
                if selectedProvider == CHLocalLLMProvider.providerID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .providerRowButtonStyle()
        .sheet(isPresented: modelPickerPresentation(from: .provider)) {
            modelPickerSheet
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
                Button("Change Model") { modelPickerSource = .detail }
                    .foregroundStyle(.tint)
            } else if modelStore?.activeDownloadModelID != nil {
                LocalModelDownloadView()
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("No model downloaded yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Download a Model") { modelPickerSource = .detail }
                    .foregroundStyle(.tint)
            }
        } header: {
            Text("On-Device")
        }
        // List rows are lazy. Present from the section containing the action,
        // so an offscreen provider row cannot defer the sheet until a scroll.
        // Keep the presenter outside the conditional installed/download rows.
        .sheet(isPresented: modelPickerPresentation(from: .detail)) {
            modelPickerSheet
        }
    }

    private func modelPickerPresentation(from source: ModelPickerSource) -> Binding<Bool> {
        Binding(
            get: { showsDownloadableModels && modelPickerSource == source },
            set: { isPresented in
                if isPresented && showsDownloadableModels { modelPickerSource = source }
                else if modelPickerSource == source { modelPickerSource = nil }
            }
        )
    }

    @ViewBuilder
    private var modelPickerSheet: some View {
        if showsDownloadableModels {
            #if os(iOS)
            NavigationStack {
                ModelPickerView(appIdentifier: appIdentifier) { modelPickerSource = nil }
            }
            #else
            ModelPickerView(appIdentifier: appIdentifier) { modelPickerSource = nil }
            #endif
        }
    }

    // MARK: - Provider row helpers

    @ViewBuilder
    private func cloudProviderRow(id: String, name: String) -> some View {
        let meta = cloudProviderMeta(id)
        providerRow(
            id: id,
            icon: meta.icon,
            iconColor: meta.color,
            name: name,
            badge: nil,
            badgeColor: .clear,
            subtitle: meta.subtitle,
            available: true,
            // 2.17.0: the selected provider cannot answer without a key; say
            // so on its row instead of only in the grey subtitle.
            warning: selectedProvider == id && meta.needsAPIKey
                ? "Needs an API key — add it below"
                : nil
        )
    }

    private func cloudProviderMeta(_ id: String) -> (icon: String, color: Color, subtitle: String?, needsAPIKey: Bool) {
        // 2.9.5 introduced dynamic subtitles; 2.9.6 fixes the
        // observation path. The lookup MUST go through the
        // `@AppStorage` properties (`openaiModel` / `claudeModel`),
        // NOT through the providers' static `currentModel` accessors.
        // The static accessors call into UserDefaults directly with
        // no SwiftUI observation, so a body pass that runs BEFORE
        // a writeback has propagated will read a stale value. The
        // `@AppStorage` properties publish writes synchronously
        // within the same render pass, which is the behavior the
        // row depends on to update without a remount.
        //
        // Strategy:
        //   * If the user has selected a model that's still in the
        //     lineup → show its `displayName`.
        //   * Otherwise → "Recommended: <recommendedModel.displayName>".
        //
        // Custom Endpoint surfaces its configured model. Apple Intelligence
        // and On-Device are handled inline in `body` and don't reach here.
        switch id {
        case CHOpenAIProvider.providerID:
            let match = CHOpenAIProvider.availableModels.first(where: { $0.id == openaiModel })
            return ("brain", .mint, connectionSubtitle(
                model: modelSubtitle(
                    current: match?.displayName,
                    recommendedFallback: CHOpenAIProvider.recommendedModel.displayName
                ),
                hasAPIKey: !openaiKey.isEmpty
            ), openaiKey.isEmpty)
        case CHClaudeProvider.providerID:
            let match = CHClaudeProvider.availableModels.first(where: { $0.id == claudeModel })
            return ("sparkles", .orange, connectionSubtitle(
                model: modelSubtitle(
                    current: match?.displayName,
                    recommendedFallback: CHClaudeProvider.recommendedModel.displayName
                ),
                hasAPIKey: !claudeKey.isEmpty
            ), claudeKey.isEmpty)
        case CHCustomEndpointProvider.providerID:
            let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // The key is optional for a self-hosted endpoint.
            return ("server.rack", .gray, model.isEmpty ? "OpenAI-compatible API" : "\(model) · OpenAI-compatible API", false)
        default:
            if let provider = aiManager.provider(id: id) as? CHAICatalogProvider {
                let hasAPIKey = provider.apiKey != nil
                return ("network", .blue, connectionSubtitle(model: provider.selectedModel.name,
                                                             hasAPIKey: hasAPIKey), !hasAPIKey)
            }
            return ("network", .blue, nil, false)
        }
    }

    private func appearsInCloudAPIs(_ id: String) -> Bool {
        guard id != CHAppleIntelligenceProvider.providerID,
              id != CHLocalLLMProvider.providerID else { return false }
        #if os(macOS)
        return id != CHCustomEndpointProvider.providerID
        #else
        return true
        #endif
    }

    private func connectionSubtitle(model: String, hasAPIKey: Bool) -> String {
        "\(model) · \(hasAPIKey ? "API key saved" : "Add API key")"
    }

    /// 2.9.5: shared subtitle composer for cloud-provider rows. When
    /// the user has a stored model selection that's still in the
    /// canonical lineup, surfaces it directly; otherwise falls back
    /// to "Recommended: <model>" so the row is informative even on
    /// first-time setup.
    private func modelSubtitle(current: String?, recommendedFallback: String) -> String {
        if let current { return current }
        return "Recommended: \(recommendedFallback)"
    }

    private func providerRow(
        id: String,
        icon: String,
        iconColor: Color,
        name: String,
        badge: String?,
        badgeColor: Color,
        subtitle: String?,
        available: Bool,
        unavailableReason: String? = nil,
        warning: String? = nil
    ) -> some View {
        // 2.6.0: gating short-circuit. Locked rows route taps to the unlock
        // banner (pulse) instead of the activate path. Apple Intelligence is
        // never in `gatedProviderIDs` so it stays uniformly tappable.
        let isLocked = aiManager.isLocked(providerID: id)
        let isActiveLocked = isLocked && selectedProvider == id

        return Button {
            guard available else { return }
            if isLocked {
                pulseTrigger += 1
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                return
            }
            aiManager.activeProviderID = id
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 12) {
                providerIcon(icon, color: iconColor, available: available)
                    .opacity(isLocked ? 0.6 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    // 2.7.0: align lock icon with text baseline (was floating
                    // mid-row before) and use a consistent imageScale across
                    // every row's lock — `.subheadline` aligns visually with
                    // the semantic body font on both iOS and macOS.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name)
                            .font(.body)
                            .foregroundStyle(available ? .primary : .secondary)
                            .opacity(isLocked && !isActiveLocked ? 0.6 : 1.0)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.subheadline)
                                .imageScale(.small)
                                .foregroundStyle(.indigo)
                        }
                        if let badge {
                            self.badge(badge, color: badgeColor)
                        }
                    }
                    if isActiveLocked {
                        Text("Locked — purchase required")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    } else if let reason = unavailableReason, !available {
                        Text(reason).font(.caption).foregroundStyle(.tertiary)
                    } else if let warning {
                        Label(warning, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let sub = subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary)
                            .opacity(isLocked ? 0.6 : 1.0)
                    }
                }
                Spacer()
                if selectedProvider == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .providerRowButtonStyle()
        .disabled(!available)
    }

    // MARK: - 2.6.0 IAP gating helpers

    /// Snapshots the registered gate's state and assigns to `unlockState`.
    /// Called on view-appear and whenever the gate publishes a change.
    private func refreshUnlockState() {
        guard !aiManager.gatedProviderIDs.isEmpty,
              let gate = CHIAPGateRegistry.shared
        else {
            unlockState = .none
            return
        }
        unlockState = gate.hasUnlockedProviders
            ? .unlocked
            : .locked(priceLabel: gate.unlockPriceLabel)
    }

    /// Drives `.onReceive`. When no gate is registered, returns an empty
    /// publisher so the modifier is still legal but never fires.
    ///
    /// The two-step (var calls into a generic helper) is required to open
    /// the `any CHIAPGate` existential — Swift can't directly call a method
    /// returning `AnyPublisher<Void, Never>` on `gate.objectWillChange` when
    /// the publisher's associated `Failure` type is hidden behind the
    /// existential. Passing through `bridgeGatePublisher<G>(_ gate: G)`
    /// opens the existential for the call.
    private var gatePublisher: AnyPublisher<Void, Never> {
        guard let gate = CHIAPGateRegistry.shared else {
            return Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()
        }
        return Self.bridgeGatePublisher(gate)
    }

    private static func bridgeGatePublisher<G: CHIAPGate>(_ gate: G) -> AnyPublisher<Void, Never> {
        gate.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    private var lockedProviderDisplayNames: [String] {
        // 2.6.1: subtract `alwaysFreeProviderIDs` (Apple Intelligence) so a
        // misconfigured `gatedProviderIDs` doesn't leak Apple Intelligence
        // into the banner subtitle. Use `displayName(forProviderID:)` so
        // unregistered providers (e.g. on-device-llm before a model is
        // downloaded) still show their kit-canonical name instead of being
        // dropped silently — Chen's screenshot of LiftCoach Build 64 had
        // "On-Device AI" missing from the subtitle for exactly this reason.
        var providerIDs = aiManager.effectiveGatedProviderIDs
            .subtracting(aiManager.disabledProviderIDs)
        if !showsDownloadableModels {
            providerIDs.remove(CHLocalLLMProvider.providerID)
        }
        return providerIDs.map { aiManager.displayName(forProviderID: $0) }.sorted()
    }

    @MainActor
    private func runPurchase() async {
        guard let gate = CHIAPGateRegistry.shared else { return }
        purchaseError = nil
        unlockState = .purchasing
        do {
            try await gate.startPurchase()
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
        refreshUnlockState()
    }

    @MainActor
    private func runRestore() async {
        guard let gate = CHIAPGateRegistry.shared, !isRestoring else { return }
        purchaseError = nil
        restoreOutcome = nil
        isRestoring = true
        defer { isRestoring = false }
        let wasUnlocked = gate.hasUnlockedProviders
        do {
            try await gate.restorePurchases()
            refreshUnlockState()
            restoreOutcome = .after(wasUnlocked: wasUnlocked, isUnlocked: gate.hasUnlockedProviders)
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
            refreshUnlockState()
        }
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
                TextField(text: key, prompt: Text(placeholder)) { Text("API Key") }
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } else {
                SecureField(text: key, prompt: Text(placeholder)) { Text("API Key") }
                    .textContentType(.password)
            }
            Button { showingAPIKey.toggle() } label: {
                Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .labelsHidden()
        #if os(macOS)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 366)
        #endif
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

    private func testConnection() {
        saveKeys()
        let providerID = selectedProvider
        connectionTest = CHAIConnectionTestState(isTesting: true)
        Task {
            let result: CHAIConnectionTestState.Result
            do {
                let ok = try await aiManager.validateProvider(providerID)
                result = ok ? .connected : .failed("Connection failed")
            } catch {
                result = .failed(error.localizedDescription)
            }
            // Drop a late answer once the user has switched provider or
            // edited the settings under test (both reset to idle).
            guard selectedProvider == providerID, connectionTest.isTesting else { return }
            connectionTest = CHAIConnectionTestState(result: result)
        }
    }
}

private extension View {
    /// 2.17.0: on the Mac a default-style Button in a Form draws a grey push
    /// button behind the whole row, so every provider looked pressed. The
    /// row is a list choice, not a push button; the checkmark marks the pick.
    /// iOS keeps the default style for its row tap highlight.
    @ViewBuilder
    func providerRowButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}
