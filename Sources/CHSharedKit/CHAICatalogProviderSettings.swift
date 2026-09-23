import SwiftUI

/// Shared settings section for every supported catalog provider.
///
/// 2.17.0: built on ``CHAIProviderCredentialSection`` so a catalog provider
/// (Grok) reads the same as OpenAI and Claude — a bordered key field, links in
/// the footer instead of bare rows, and the endpoint host instead of its full
/// URL.
public struct CHAICatalogProviderSettings: View {
    public let provider: CHAICatalogProvider
    private let connectionTest: CHAIConnectionTestState?
    private let onTestConnection: (() -> Void)?
    private let onAPIKeyChange: (() -> Void)?
    @ObservedObject private var manager = CHAIManager.shared
    @State private var key = ""
    @State private var model = ""

    public init(provider: CHAICatalogProvider) {
        self.init(provider: provider, connectionTest: nil, onTestConnection: nil, onAPIKeyChange: nil)
    }

    /// - Parameters:
    ///   - onTestConnection: adds a Test Connection row; `nil` hides it.
    ///   - onAPIKeyChange: called after each key edit, so the host can clear
    ///     a result that no longer describes the saved key.
    public init(
        provider: CHAICatalogProvider,
        connectionTest: CHAIConnectionTestState?,
        onTestConnection: (() -> Void)?,
        onAPIKeyChange: (() -> Void)? = nil
    ) {
        self.provider = provider
        self.connectionTest = connectionTest
        self.onTestConnection = onTestConnection
        self.onAPIKeyChange = onAPIKeyChange
    }

    public var body: some View {
        CHAIProviderCredentialSection(
            providerName: provider.displayName,
            keyPlaceholder: "Paste API key",
            apiKey: $key,
            billingAccountName: provider.displayName,
            endpointHost: provider.baseURL.host(),
            apiKeyURL: provider.definition.apiKeyURL,
            privacyPolicyURL: provider.definition.privacyPolicyURL,
            connectionTest: connectionTest,
            onTestConnection: onTestConnection
        ) {
            Picker("Model", selection: $model) {
                ForEach(provider.definition.models) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
        .onChange(of: key) { _, value in
            provider.apiKey = value
            manager.objectWillChange.send()
            onAPIKeyChange?()
        }
        .onChange(of: model) { _, value in
            provider.selectedModelID = value
            manager.objectWillChange.send()
        }
        .onChange(of: provider.definition) { _, _ in model = provider.selectedModelID }
        .onAppear {
            key = provider.apiKey ?? ""
            model = provider.selectedModelID
        }
    }
}
