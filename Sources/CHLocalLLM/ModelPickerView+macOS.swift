#if os(macOS)
import SwiftUI
import AppKit
import CHSharedKit

// MARK: - ModelPickerView (macOS)

/// macOS-native variant of the on-device model picker. Same public API as
/// the iOS version (`Sources/CHLocalLLM/ModelPickerView.swift`) so the
/// `.sheet { ModelPickerView(...) }` call sites in `CHAISettingsContent`
/// work unchanged on both platforms.
///
/// Designed as a grouped `Form` (`.formStyle(.grouped)`) so each model
/// renders inside a native macOS inset-grouped section with proper Aqua
/// chrome — borders, separators, and background tint come from AppKit
/// rather than being hand-painted as on iOS. Sheet has a sensible
/// minimum size so the layout doesn't get cramped.
public struct ModelPickerView: View {
    public let appIdentifier: AppIdentifier
    public var onDismiss: (() -> Void)?

    @State private var store = LocalModelStore.shared
    @State private var showAcknowledgmentFor: LocalModelInfo?
    @State private var showPreDownloadFor: LocalModelInfo?
    @State private var showAddCustomModel = false

    private var deviceRAM_GB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    private var sortedCatalogModels: [LocalModelInfo] {
        LocalModelCatalog.all.sorted {
            let sa = $0.recommendationScore(for: appIdentifier)
            let sb = $1.recommendationScore(for: appIdentifier)
            if sa != sb { return sa > sb }
            return $0.sizeBytes < $1.sizeBytes
        }
    }

    private var recommendedModels: [LocalModelInfo] {
        Array(sortedCatalogModels.prefix(3))
    }

    private var otherCatalogModels: [LocalModelInfo] {
        Array(sortedCatalogModels.dropFirst(3))
    }

    private var customModelInfos: [LocalModelInfo] {
        store.customModels.map { store.localModelInfo(for: $0) }
    }

    public init(appIdentifier: AppIdentifier, onDismiss: (() -> Void)? = nil) {
        self.appIdentifier = appIdentifier
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Form {
            Section("Recommended for \(appIdentifier.displayName)") {
                ForEach(Array(recommendedModels.enumerated()), id: \.element.id) { index, model in
                    MacModelRow(
                        model: model,
                        appIdentifier: appIdentifier,
                        isTopRecommendation: index == 0,
                        deviceRAM_GB: deviceRAM_GB,
                        store: store,
                        onDownloadTapped: { handleDownloadTapped(model) },
                        onUse: { store.setActiveModel(model) },
                        onRemove: { store.deleteModel(model) }
                    )
                }
            }

            Section("All Models") {
                ForEach(otherCatalogModels, id: \.id) { model in
                    MacModelRow(
                        model: model,
                        appIdentifier: appIdentifier,
                        isTopRecommendation: false,
                        deviceRAM_GB: deviceRAM_GB,
                        store: store,
                        onDownloadTapped: { handleDownloadTapped(model) },
                        onUse: { store.setActiveModel(model) },
                        onRemove: { store.deleteModel(model) }
                    )
                }
            }

            if !customModelInfos.isEmpty {
                Section("Custom Models") {
                    ForEach(customModelInfos, id: \.id) { model in
                        MacModelRow(
                            model: model,
                            appIdentifier: appIdentifier,
                            isTopRecommendation: false,
                            deviceRAM_GB: deviceRAM_GB,
                            store: store,
                            onDownloadTapped: { handleDownloadTapped(model) },
                            onUse: { store.setActiveModel(model) },
                            onRemove: { store.deleteModel(model) }
                        )
                    }
                }
            }

            Section {
                Button {
                    showAddCustomModel = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add Custom Model")
                                .font(.body.weight(.medium))
                            Text("Paste any HuggingFace GGUF URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Choose a Model")
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 720)
        .sheet(item: $showAcknowledgmentFor) { model in
            MacLlamaAcknowledgmentSheet(model: model) {
                showAcknowledgmentFor = nil
                showPreDownloadFor = model
            } onCancel: {
                showAcknowledgmentFor = nil
            }
        }
        .sheet(item: $showPreDownloadFor) { model in
            MacPreDownloadSheet(model: model, deviceRAM_GB: deviceRAM_GB) {
                showPreDownloadFor = nil
                store.downloadModel(model)
            } onCancel: {
                showPreDownloadFor = nil
            }
        }
        .sheet(isPresented: $showAddCustomModel) {
            MacAddCustomModelSheet { entry in
                store.addCustomModel(
                    id: entry.id,
                    displayName: entry.displayName,
                    downloadURL: entry.downloadURL,
                    sizeBytes: entry.sizeBytes,
                    chatTemplate: entry.chatTemplate
                )
                let modelInfo = store.localModelInfo(for: entry)
                showPreDownloadFor = modelInfo
            }
        }
    }

    private func handleDownloadTapped(_ model: LocalModelInfo) {
        let llamaAcked = UserDefaults.standard.bool(forKey: "chlocallm.acked.llama")
        if model.requiresAcknowledgment && !llamaAcked {
            showAcknowledgmentFor = model
        } else {
            showPreDownloadFor = model
        }
    }
}

// MARK: - MacModelRow

/// One row inside the macOS picker's `Form`. Each row stacks: title +
/// chips, a description line, capability chips, the per-app task hint,
/// progress (when downloading), and an action HStack with state-aware
/// buttons. The whole row sits inside a `Form Section` group so the
/// border + background come from AppKit's grouped form chrome.
private struct MacModelRow: View {
    let model: LocalModelInfo
    let appIdentifier: AppIdentifier
    let isTopRecommendation: Bool
    let deviceRAM_GB: Int
    var store: LocalModelStore
    let onDownloadTapped: () -> Void
    let onUse: () -> Void
    let onRemove: () -> Void

    private var isCompatible: Bool { deviceRAM_GB >= model.minRAM_GB }
    private var isBorderline: Bool { deviceRAM_GB == model.minRAM_GB - 1 }
    private var isInstalled: Bool { store.isInstalled(model) }
    private var isActive: Bool { store.activeModelID == model.id }
    private var isDownloadingThisModel: Bool { store.activeDownloadModelID == model.id }
    private var anyDownloadActive: Bool { store.activeDownloadModelID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            chipsRow
            if !model.strengths.isEmpty {
                strengthsRow
            }
            if !model.isCustom {
                Text(model.taskHint(for: appIdentifier))
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
            if isDownloadingThisModel, case .downloading(let p, _, _) = store.downloadState {
                ProgressView(value: p).tint(.indigo)
            }
            actionRow
        }
        .padding(.vertical, 6)
        .opacity((isCompatible || isBorderline) ? 1.0 : 0.55)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline)
                    qualityChip
                    sizeCategoryChip
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isTopRecommendation {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Recommended")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundStyle(.brown)
                        .clipShape(Capsule())
                    Text("for \(appIdentifier.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chipsRow: some View {
        HStack(spacing: 6) {
            licenseChip
            compatibilityChip
            Spacer()
            Text(formattedSize(model.sizeBytes))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// macOS has the horizontal room — strengths flow on a single line
    /// and wrap naturally (no need for the iOS `ScrollView(.horizontal)`).
    @ViewBuilder
    private var strengthsRow: some View {
        FlowHStack(spacing: 6, runSpacing: 6) {
            ForEach(model.strengths, id: \.self) { strength in
                Text(strength)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.08))
                    .foregroundStyle(.indigo)
                    .clipShape(Capsule())
            }
            if !model.languages.isEmpty {
                Text(languagesLabel)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }
        }
    }

    private var languagesLabel: String {
        let n = model.languages.count
        if n <= 3 { return model.languages.joined(separator: " · ") }
        return "\(n) languages"
    }

    @ViewBuilder
    private var qualityChip: some View {
        let color: Color = {
            switch model.quality {
            case .fast: return .orange
            case .balanced: return .blue
            case .higher: return .purple
            case .highest: return .indigo
            }
        }()
        Text(model.quality.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var sizeCategoryChip: some View {
        Text(model.sizeCategory.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var licenseChip: some View {
        let color: Color = {
            switch model.license {
            case .apache2: return .green
            case .mit: return .blue
            case .llamaCommunity: return .orange
            case .gemma: return .teal
            }
        }()
        Text(model.license.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var compatibilityChip: some View {
        let (label, color): (String, Color) = {
            if deviceRAM_GB >= model.minRAM_GB { return ("Compatible", .green) }
            if isBorderline { return ("May run slowly", .yellow) }
            return ("Not supported", .red)
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            if isInstalled && !isActive {
                Label("Installed", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isCompatible && !isBorderline {
                Text("Not supported").font(.caption).foregroundStyle(.tertiary)
            } else if isDownloadingThisModel {
                downloadingButtons
            } else if isInstalled {
                if !isActive {
                    Button("Use") { onUse() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Delete this model from disk")
            } else {
                Button("Download") { onDownloadTapped() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(anyDownloadActive && !isDownloadingThisModel)
            }
        }
    }

    @ViewBuilder
    private var downloadingButtons: some View {
        let label: String = {
            switch store.downloadState {
            case .downloading(let p, _, _): return "\(Int(p * 100))%"
            case .installing: return "Installing…"
            default: return "Downloading…"
            }
        }()
        HStack(spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Button("Cancel") { store.cancelDownload() }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - FlowHStack (line-wrapping HStack)

/// Lightweight wrap-flow layout for the strengths chips. macOS gives us
/// the horizontal room to wrap chips onto a second line instead of
/// hiding them in a horizontal scroll like iOS.
private struct FlowHStack: Layout {
    var spacing: CGFloat = 6
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var totalW: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                y += rowH + runSpacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            totalW = max(totalW, x - spacing)
        }
        return CGSize(width: totalW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                y += rowH + runSpacing
                x = bounds.minX
                rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - MacAddCustomModelSheet

private struct MacAddCustomModelSheet: View {
    let onAdd: (CustomModelEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var modelName = ""
    @State private var selectedTemplate: LocalModelInfo.ChatTemplate = .chatML
    @State private var fetchedSize: Int64?
    @State private var isFetching = false
    @State private var fetchError: String?

    private var urlIsValid: Bool {
        guard let url = URL(string: urlText) else { return false }
        return url.scheme == "https"
            && url.host == "huggingface.co"
            && urlText.contains("/resolve/main/")
            && urlText.hasSuffix(".gguf")
    }

    private var canAdd: Bool {
        urlIsValid && !modelName.trimmingCharacters(in: .whitespaces).isEmpty && fetchedSize != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("https://huggingface.co/.../resolve/main/model.gguf", text: $urlText)
                    .autocorrectionDisabled()
                    .onChange(of: urlText) { _, _ in
                        fetchedSize = nil
                        fetchError = nil
                    }
            } header: {
                Text("HuggingFace GGUF URL")
            } footer: {
                if let error = fetchError {
                    Text(error).foregroundStyle(.red)
                } else if let size = fetchedSize {
                    Text("File size: \(formattedSize(size))").foregroundStyle(.secondary)
                } else {
                    Text("Must be a direct .gguf file URL from huggingface.co")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(isFetching ? "Checking…" : "Check URL") {
                    Task { await checkURL() }
                }
                .disabled(!urlIsValid || isFetching)
            }

            Section("Model Name") {
                TextField("e.g. My Custom 7B", text: $modelName)
            }

            Section {
                Picker("Template", selection: $selectedTemplate) {
                    Text("ChatML (Qwen, Phi, SmolLM)").tag(LocalModelInfo.ChatTemplate.chatML)
                    Text("Llama 3").tag(LocalModelInfo.ChatTemplate.llama3)
                    Text("Llama 2 / Mistral").tag(LocalModelInfo.ChatTemplate.llama2)
                    Text("Gemma 2").tag(LocalModelInfo.ChatTemplate.gemma)
                }
            } header: {
                Text("Chat Template")
            } footer: {
                Text("Match the template to the model family. Most HuggingFace GGUF models are ChatML.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add Custom Model")
        .frame(minWidth: 480, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let url = URL(string: urlText),
                          let size = fetchedSize else { return }
                    let entry = CustomModelEntry(
                        id: UUID().uuidString,
                        displayName: modelName.trimmingCharacters(in: .whitespaces),
                        downloadURL: url,
                        sizeBytes: size,
                        chatTemplate: selectedTemplate
                    )
                    dismiss()
                    onAdd(entry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
    }

    private func checkURL() async {
        guard let url = URL(string: urlText) else { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                fetchError = "Could not reach URL"
                return
            }
            guard http.statusCode == 200 else {
                fetchError = "HTTP \(http.statusCode) — check the URL"
                return
            }
            let size = http.expectedContentLength
            if size > 0 {
                fetchedSize = size
                if modelName.isEmpty {
                    modelName = url.deletingPathExtension().lastPathComponent
                }
            } else {
                fetchError = "Server didn't report a size"
            }
        } catch {
            fetchError = error.localizedDescription
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - MacLlamaAcknowledgmentSheet

private struct MacLlamaAcknowledgmentSheet: View {
    let model: LocalModelInfo
    let onAcknowledge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Llama Community License")
                    .font(.title3.bold())
            }
            Text("\(model.displayName) is distributed under Meta's Llama Community License. By downloading you agree to abide by Meta's Acceptable Use Policy.")
                .font(.body)
                .foregroundStyle(.primary)
            Text("This is a one-time acknowledgment. You can review the full terms at llama.com/llama-downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("I Agree — Continue") {
                    UserDefaults.standard.set(true, forKey: "chlocallm.acked.llama")
                    onAcknowledge()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 220)
    }
}

// MARK: - MacPreDownloadSheet

private struct MacPreDownloadSheet: View {
    let model: LocalModelInfo
    let deviceRAM_GB: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Confirm Download")
                .font(.title3.bold())
                .padding(.bottom, 12)

            Form {
                Section("\(model.displayName)") {
                    infoRow("Quality", model.quality.rawValue)
                    infoRow("License", model.license.rawValue)
                    infoRow("Size", formattedSize(model.sizeBytes))
                    infoRow("Min RAM", "\(model.minRAM_GB) GB")
                    infoRow("Your RAM", "\(deviceRAM_GB) GB")
                }
                Section {
                    Text("Download continues in the background. The file is stored in the app's shared model directory and is shared across iOS, iPadOS, and Mac apps that use CHLocalLLM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Download") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

#endif
