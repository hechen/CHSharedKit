import SwiftUI

/// 2.17.0: result of a Test Connection run, for ``CHAIProviderCredentialSection``.
public struct CHAIConnectionTestState: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case connected
        case failed(String)
    }

    public var isTesting: Bool
    public var result: Result?

    public init(isTesting: Bool = false, result: Result? = nil) {
        self.isTesting = isTesting
        self.result = result
    }

    public static let idle = CHAIConnectionTestState()
}

/// 2.17.0: one settings section for every bring-your-own-key provider.
///
/// Before 2.17.0 OpenAI, Claude and the catalog providers (Grok) each built
/// their own section, and on the Mac all three read badly:
///
/// - The key field was a bare `SecureField` with no bezel, so its placeholder
///   ("API Key", "sk-...") looked like a static label — nothing said "type here".
/// - Catalog providers listed Get API Key and Privacy Policy as plain rows
///   and printed the full endpoint URL; OpenAI and Claude put a key link in the
///   footer instead. Same job, three layouts.
/// - Test Connection sat in its own section at the bottom of the page, away
///   from the key it tests, and was enabled even with no key to test.
///
/// This section gives every provider the same shape: a labelled, visibly
/// editable key field with a reveal toggle, the model picker, Test Connection
/// beside the key, and a wrapping secondary footer that says where the key is
/// stored, where requests go, who bills them, and links out.
public struct CHAIProviderCredentialSection<ModelPicker: View>: View {
    public let providerName: String
    public let keyPlaceholder: String
    @Binding public var apiKey: String
    public let billingAccountName: String
    public let endpointHost: String?
    public let apiKeyURL: URL?
    public let privacyPolicyURL: URL?
    public let connectionTest: CHAIConnectionTestState?
    public let onTestConnection: (() -> Void)?
    private let modelPicker: ModelPicker

    @State private var isRevealed = false

    /// - Parameters:
    ///   - billingAccountName: who charges for usage, as it should read in
    ///     "billed to your … account" (e.g. "OpenAI", "Anthropic").
    ///   - endpointHost: shown so the user knows requests go straight to the
    ///     provider. Pass the live host, not a constant — base URLs can be
    ///     overridden.
    ///   - onTestConnection: `nil` hides the Test Connection row.
    public init(
        providerName: String,
        keyPlaceholder: String,
        apiKey: Binding<String>,
        billingAccountName: String,
        endpointHost: String? = nil,
        apiKeyURL: URL? = nil,
        privacyPolicyURL: URL? = nil,
        connectionTest: CHAIConnectionTestState? = nil,
        onTestConnection: (() -> Void)? = nil,
        @ViewBuilder modelPicker: () -> ModelPicker
    ) {
        self.providerName = providerName
        self.keyPlaceholder = keyPlaceholder
        self._apiKey = apiKey
        self.billingAccountName = billingAccountName
        self.endpointHost = endpointHost
        self.apiKeyURL = apiKeyURL
        self.privacyPolicyURL = privacyPolicyURL
        self.connectionTest = connectionTest
        self.onTestConnection = onTestConnection
        self.modelPicker = modelPicker()
    }

    private var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        Section {
            LabeledContent(String(localized: "API Key", bundle: .module)) {
                HStack(spacing: 6) {
                    keyInput
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? String(localized: "Hide API key", bundle: .module) : String(localized: "Show API key", bundle: .module))
                    .accessibilityLabel(isRevealed ? String(localized: "Hide API key", bundle: .module) : String(localized: "Show API key", bundle: .module))
                }
            }

            modelPicker

            if let onTestConnection {
                CHAIConnectionTestRow(
                    state: connectionTest ?? .idle,
                    canTest: hasKey,
                    action: onTestConnection
                )
            }
        } header: {
            Text(providerName)
        } footer: {
            footer
        }
    }

    // MARK: - Key field

    @ViewBuilder
    private var keyInput: some View {
        Group {
            // The placeholder goes in `prompt`: a grouped macOS Form draws a
            // field's title as a label beside it, outside the empty box.
            if isRevealed {
                TextField(text: $apiKey, prompt: Text(keyPlaceholder)) { Text(String(localized: "API Key", bundle: .module)) }
            } else {
                SecureField(text: $apiKey, prompt: Text(keyPlaceholder)) { Text(String(localized: "API Key", bundle: .module)) }
            }
        }
        .labelsHidden()
        .textContentType(.password)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .multilineTextAlignment(.trailing)
        #else
        // A bordered field is what tells a Mac user this is editable; the
        // bare style rendered the placeholder as if it were a label.
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 340)
        #endif
        .accessibilityLabel(String(localized: "\(providerName) API key", bundle: .module))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detailText)
            if apiKeyURL != nil || privacyPolicyURL != nil {
                HStack(spacing: 14) {
                    if let apiKeyURL {
                        Link(destination: apiKeyURL) {
                            Label(String(localized: "Get an API key", bundle: .module), systemImage: "arrow.up.right")
                                .labelStyle(TrailingIconLabelStyle())
                        }
                    }
                    if let privacyPolicyURL {
                        Link(destination: privacyPolicyURL) {
                            Label(String(localized: "Privacy policy", bundle: .module), systemImage: "arrow.up.right")
                                .labelStyle(TrailingIconLabelStyle())
                        }
                    }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        // Footers truncated to one line on the Mac without this.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detailText: String {
        if let endpointHost, !endpointHost.isEmpty {
            return String(localized: "Your key is stored in the Keychain and requests go directly to \(endpointHost). Usage is billed to your \(billingAccountName) account.", bundle: .module)
        }
        return String(localized: "Your key is stored in the Keychain. Usage is billed to your \(billingAccountName) account.", bundle: .module)
    }
}

/// 2.17.0: Test Connection button with its result beside it.
///
/// Replaces a full-width button in a section of its own, whose result read
/// "✓ Connected successfully" in green caption text below it.
public struct CHAIConnectionTestRow: View {
    public let state: CHAIConnectionTestState
    public let canTest: Bool
    public let action: () -> Void

    /// - Parameter canTest: `false` disables the button, e.g. with no key.
    public init(state: CHAIConnectionTestState, canTest: Bool = true, action: @escaping () -> Void) {
        self.state = state
        self.canTest = canTest
        self.action = action
    }

    public var body: some View {
        #if os(macOS)
        // A labelled row with a trailing push button, as System Settings
        // lays out an action beside its status.
        LabeledContent(String(localized: "Connection", bundle: .module)) {
            HStack(spacing: 8) {
                if state.isTesting {
                    ProgressView().controlSize(.small)
                } else if let result = state.result {
                    resultLabel(result)
                }
                testButton(title: "Test")
            }
        }
        #else
        HStack(spacing: 10) {
            testButton(title: "Test Connection")
                .buttonStyle(.bordered)

            if state.isTesting {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 8)

            if let result = state.result, !state.isTesting {
                resultLabel(result)
            }
        }
        #endif
    }

    private func testButton(title: LocalizedStringKey) -> some View {
        Button(action: action) { Text(title, bundle: .module) }
            // A second run while one is in flight would race the first result.
            .disabled(!canTest || state.isTesting)
            .accessibilityLabel(String(localized: "Test Connection", bundle: .module))
    }

    @ViewBuilder
    private func resultLabel(_ result: CHAIConnectionTestState.Result) -> some View {
        switch result {
        case .connected:
            Label {
                Text(String(localized: "Connected", bundle: .module))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        case .failed(let message):
            // Colour stays on the icon; red body text is hard to read.
            Label {
                Text(message)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .font(.callout)
        }
    }
}

/// Text then icon, so an external-link arrow trails the words.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
