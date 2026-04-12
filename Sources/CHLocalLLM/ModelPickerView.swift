import SwiftUI
import CHSharedKit

// MARK: - ModelPickerView

/// Scrollable model picker with per-app recommendations, device compatibility badges,
/// license chips, and download/activate actions.
public struct ModelPickerView: View {
    public let appIdentifier: AppIdentifier
    public var onDismiss: (() -> Void)?

    @State private var store = LocalModelStore.shared
    @State private var showAcknowledgmentFor: LocalModelInfo?
    @State private var showPreDownloadFor: LocalModelInfo?

    private var deviceRAM_GB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    private var sortedModels: [LocalModelInfo] {
        LocalModelCatalog.all.sorted {
            let sa = $0.recommendationScore(for: appIdentifier)
            let sb = $1.recommendationScore(for: appIdentifier)
            if sa != sb { return sa > sb }
            return $0.sizeBytes < $1.sizeBytes // tie-break: prefer smaller
        }
    }

    public init(appIdentifier: AppIdentifier, onDismiss: (() -> Void)? = nil) {
        self.appIdentifier = appIdentifier
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(sortedModels.enumerated()), id: \.element.id) { index, model in
                    ModelCard(
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
            .padding()
        }
        .navigationTitle("Choose a Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $showAcknowledgmentFor) { model in
            LlamaAcknowledgmentSheet(model: model) {
                showAcknowledgmentFor = nil
                showPreDownloadFor = model
            } onCancel: {
                showAcknowledgmentFor = nil
            }
        }
        .sheet(item: $showPreDownloadFor) { model in
            PreDownloadSheet(model: model, deviceRAM_GB: deviceRAM_GB) {
                showPreDownloadFor = nil
                store.downloadModel(model)
            } onCancel: {
                showPreDownloadFor = nil
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

// MARK: - ModelCard

private struct ModelCard: View {
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
            Text(model.taskHint(for: appIdentifier))
                .font(.caption)
                .foregroundStyle(.indigo)
            Divider()
            actionRow
            if isDownloadingThisModel, case .downloading(let p, _, _) = store.downloadState {
                ProgressView(value: p).tint(.indigo)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .opacity((isCompatible || isBorderline) ? 1.0 : 0.55)
    }

    // MARK: Header

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline)
                    qualityChip
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

    // MARK: Chips

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
    private var licenseChip: some View {
        let color: Color = {
            switch model.license {
            case .apache2: return .green
            case .mit: return .blue
            case .llamaCommunity: return .orange
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

    // MARK: Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            // Left: status label
            Group {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isInstalled {
                    Label("Installed", systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))

            Spacer()

            // Right: action buttons
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

// MARK: - LlamaAcknowledgmentSheet

private struct LlamaAcknowledgmentSheet: View {
    let model: LocalModelInfo
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("License Acknowledgment", systemImage: "doc.text")
                        .font(.headline)

                    Text("Llama 3.2 is released under the Meta Llama Community License. By downloading you agree to:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        bullet("Use the model only for permitted purposes as defined in the Llama Community License")
                        bullet("Not use outputs to train other LLMs without Meta's permission")
                        bullet("Include required attribution in any products using this model")
                        bullet("Comply with Meta's usage policy at llama.meta.com/llama3/use-policy")
                    }

                    Text("The model runs entirely on your device. No data is sent to Meta or any server.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Llama 3.2 License")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("I Accept") {
                        UserDefaults.standard.set(true, forKey: "chlocallm.acked.llama")
                        onAccept()
                    }
                    .fontWeight(.semibold)
                    .tint(.indigo)
                }
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }
}

// MARK: - PreDownloadSheet

private struct PreDownloadSheet: View {
    let model: LocalModelInfo
    let deviceRAM_GB: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var estimatedMinutes: Int {
        max(1, Int(Double(model.sizeBytes) / (6 * 1_048_576) / 60))
    }

    private var ramUsagePercent: Int {
        guard deviceRAM_GB > 0 else { return 0 }
        // Estimate ~1.5× file size for inference overhead
        let inferenceGB = Double(model.sizeBytes) * 1.5 / 1_073_741_824
        return min(100, Int((inferenceGB / Double(deviceRAM_GB)) * 100))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow("Model", model.displayName)
                    infoRow("Download size", formattedSize(model.sizeBytes))
                    infoRow("RAM usage", "~\(ramUsagePercent)% of \(deviceRAM_GB) GB")
                    infoRow("Estimated time on WiFi", "~\(estimatedMinutes) min")
                    infoRow("License", model.license.rawValue)
                } header: {
                    Text("Download details")
                } footer: {
                    Text("Download continues in the background if you lock your phone or switch apps.")
                }

                Section {
                    Button {
                        onConfirm()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Download \(model.displayName)")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .tint(.indigo)
                }
            }
            .navigationTitle("Confirm Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
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
