import SwiftUI

/// Shared settings section for every supported catalog provider.
public struct CHAICatalogProviderSettings: View {
    public let provider: CHAICatalogProvider
    @ObservedObject private var manager = CHAIManager.shared
    @State private var key = ""
    @State private var model = ""

    public init(provider: CHAICatalogProvider) { self.provider = provider }

    public var body: some View {
        Section {
            SecureField("API Key", text: $key)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: key) { _, value in
                    provider.apiKey = value
                    manager.objectWillChange.send()
                }
            Picker("Model", selection: $model) {
                ForEach(provider.definition.models) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .onChange(of: model) { _, value in
                provider.selectedModelID = value
                manager.objectWillChange.send()
            }
            if let url = provider.definition.apiKeyURL { Link("Get API Key", destination: url) }
            if let url = provider.definition.privacyPolicyURL { Link("Privacy Policy", destination: url) }
        } header: {
            Text(provider.displayName)
        } footer: {
            Text("Requests are sent to \(provider.baseURL.absoluteString). Requires your own API key; usage is billed by \(provider.displayName).")
        }
        .onChange(of: provider.definition) { _, _ in model = provider.selectedModelID }
        .onAppear {
            key = provider.apiKey ?? ""
            model = provider.selectedModelID
        }
    }
}
