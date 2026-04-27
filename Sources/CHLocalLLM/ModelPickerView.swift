#if os(iOS)
import SwiftUI
import CHSharedKit

// MARK: - ModelPickerView

/// Scrollable model picker with per-app recommendations, device compatibility badges,
/// license chips, and download/activate actions. Includes custom model support.
public struct ModelPickerView: View {
    public let appIdentifier: AppIdentifier
    public var onDismiss: (() -> Void)?

    @State private var store = LocalModelStore.shared
    @State private var showAcknowledgmentFor: LocalModelInfo?
    @State private var showAddCustomModel = false

    private var deviceRAM_GB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Catalog models sorted by recommendation score descending.
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Recommended section
                sectionHeader("Recommended for \(appIdentifier.displayName)")
                ForEach(Array(recommendedModels.enumerated()), id: \.element.id) { index, model in
                    modelCard(model, isTopRecommendation: index == 0)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                }

                // All Models section
                sectionHeader("All Models")
                ForEach(otherCatalogModels, id: \.id) { model in
                    modelCard(model, isTopRecommendation: false)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                }

                // Custom Models section
                if !customModelInfos.isEmpty {
                    sectionHeader("Custom Models")
                    ForEach(customModelInfos, id: \.id) { model in
                        modelCard(model, isTopRecommendation: false)
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                    }
                }

                // Add Custom Model row
                addCustomRow
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .padding(.top, 8)
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
                // 2.5.4: post-acknowledgment, kick straight into select-and-download.
                // The previous two-step pre-download sheet is removed; the card
                // already shows size, RAM, and license.
                store.selectAndDownload(model)
            } onCancel: {
                showAcknowledgmentFor = nil
            }
        }
        .sheet(isPresented: $showAddCustomModel) {
            AddCustomModelSheet { entry in
                store.addCustomModel(
                    id: entry.id,
                    displayName: entry.displayName,
                    downloadURL: entry.downloadURL,
                    sizeBytes: entry.sizeBytes,
                    chatTemplate: entry.chatTemplate
                )
                let modelInfo = store.localModelInfo(for: entry)
                store.selectAndDownload(modelInfo)
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func modelCard(_ model: LocalModelInfo, isTopRecommendation: Bool) -> some View {
        ModelCard(
            model: model,
            appIdentifier: appIdentifier,
            isTopRecommendation: isTopRecommendation,
            deviceRAM_GB: deviceRAM_GB,
            store: store,
            onSelectTapped: { handleSelectTapped(model) },
            onCancelDownload: { store.cancelDownload() },
            onRetryDownload: { store.retryDownload(model) },
            onRemove: { store.deleteModel(model) }
        )
    }

    @ViewBuilder
    private var addCustomRow: some View {
        Button {
            showAddCustomModel = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Custom Model")
                        .font(.subheadline.weight(.medium))
                    Text("Paste any HuggingFace GGUF URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// 2.5.4: single-tap "Use" entry point. Replaces the 2.4.x two-step
    /// (Download → Pre-download confirm sheet → Use). The card itself
    /// shows size, RAM compatibility, and license — the sheet was
    /// redundant. Only the Llama community-license acknowledgment sheet
    /// is kept because Meta's terms require explicit one-time consent.
    private func handleSelectTapped(_ model: LocalModelInfo) {
        let llamaAcked = UserDefaults.standard.bool(forKey: "chlocallm.acked.llama")
        if model.requiresAcknowledgment && !llamaAcked {
            showAcknowledgmentFor = model
        } else {
            store.selectAndDownload(model)
        }
    }
}

// MARK: - ModelCard
//
// 2.5.4 state machine — derived once per render from the store + model:
//
//   notCompatible   — device RAM too low, even for borderline tier
//   notInstalled    — bytes absent on disk
//   downloading     — this model is the in-flight download
//   pendingActive   — download for this model finished but auto-promote
//                     hasn't fired yet (transient — usually one tick)
//   installed       — bytes present, not the active model
//   active          — bytes present AND store.activeModelID == model.id
//
// The previous 2.4.x layout had a contradictory branch: when the user's
// `activeModelID` referred to a model whose bytes had been wiped (the
// 2.5.0 GGUF→MLX migration cleared old GGUF files), the row showed both
// "Active" and "Download" simultaneously. The fix is structural: derive
// `.active` only when the model is also `isInstalled`. Stale activeModelID
// pointing at a never-migrated GGUF model now renders as `.notInstalled`,
// and the action button becomes "Use" — re-downloading restores it as
// active automatically via `pendingActiveModelID`.

private enum ModelCardState {
    case notCompatible
    case notInstalled(canStart: Bool)
    /// 2.5.8: `stalled` flips true when the underlying store hasn't seen a
    /// progress callback for `stallThresholdSeconds` (default 30 s). The
    /// inline progress UI shows a "Stalled — Retry" banner instead of the
    /// frozen byte/speed numbers.
    case downloading(progress: Double, received: Int64, total: Int64, speed: Double?, eta: TimeInterval?, stalled: Bool)
    case pendingActive
    case installed
    case active
}

private struct ModelCard: View {
    let model: LocalModelInfo
    let appIdentifier: AppIdentifier
    let isTopRecommendation: Bool
    let deviceRAM_GB: Int
    var store: LocalModelStore
    let onSelectTapped: () -> Void
    let onCancelDownload: () -> Void
    let onRetryDownload: () -> Void
    let onRemove: () -> Void

    private var isCompatible: Bool { deviceRAM_GB >= model.minRAM_GB }
    private var isBorderline: Bool { deviceRAM_GB == model.minRAM_GB - 1 }
    private var isInstalled: Bool { store.isInstalled(model) }
    private var isActive: Bool { store.activeModelID == model.id && isInstalled }
    private var isDownloadingThisModel: Bool { store.activeDownloadModelID == model.id }
    private var anyDownloadActive: Bool { store.activeDownloadModelID != nil }
    private var isPendingActive: Bool { store.pendingActiveModelID == model.id }

    private var state: ModelCardState {
        if !isCompatible && !isBorderline { return .notCompatible }
        if isDownloadingThisModel, case .downloading(let p, let r, let t) = store.downloadState {
            return .downloading(
                progress: p,
                received: r,
                total: t,
                speed: store.currentDownloadSpeedBytesPerSecond,
                eta: store.currentDownloadETA,
                stalled: store.isDownloadStalled
            )
        }
        if isActive { return .active }
        if isInstalled { return .installed }
        if isPendingActive { return .pendingActive }
        return .notInstalled(canStart: !anyDownloadActive)
    }

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
            Divider()
            actionView
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(borderColor, lineWidth: borderLineWidth)
        )
        .opacity((isCompatible || isBorderline) ? 1.0 : 0.55)
    }

    private var borderColor: Color {
        if case .active = state { return Color.green.opacity(0.55) }
        return .clear
    }
    private var borderLineWidth: CGFloat {
        if case .active = state { return 1.75 }
        return 0
    }

    // MARK: Header

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline)
                    qualityChip
                    sizeCategoryChip
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
    private var strengthsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.strengths, id: \.self) { strength in
                    Text(strength)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.08))
                        .foregroundStyle(.indigo)
                        .clipShape(Capsule())
                }
                if model.languages.count > 1 {
                    Text("\(model.languages.count) languages")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
            }
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
    private var sizeCategoryChip: some View {
        Text(model.sizeCategory.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(.systemGray5))
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

    // MARK: Actions (2.5.4 state-driven)

    @ViewBuilder
    private var actionView: some View {
        switch state {
        case .notCompatible:
            HStack {
                Spacer()
                Text("Not supported on this device")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .notInstalled(let canStart):
            HStack {
                Spacer()
                Button {
                    onSelectTapped()
                } label: {
                    Label("Use", systemImage: "checkmark.circle")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canStart)
            }
        case .downloading(let progress, let received, let total, let speed, let eta, let stalled):
            inlineProgress(
                progress: progress, received: received, total: total,
                speed: speed, eta: eta, stalled: stalled
            )
        case .pendingActive:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Selected — finishing setup…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .installed:
            HStack {
                Label("Installed", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onSelectTapped()
                } label: {
                    Label("Use", systemImage: "checkmark.circle")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        case .active:
            HStack {
                inUsePill
                Spacer()
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Delete this model from disk")
            }
        }
    }

    /// Inline progress + bytes + speed + ETA. 2.5.8 adds a stalled banner
    /// + Retry button when the underlying store has gone
    /// `stallThresholdSeconds` without a progress callback.
    @ViewBuilder
    private func inlineProgress(
        progress: Double, received: Int64, total: Int64,
        speed: Double?, eta: TimeInterval?, stalled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress).tint(stalled ? .orange : .indigo)
            HStack(spacing: 8) {
                if stalled {
                    Label("Stalled — \(Int(progress * 100))% complete", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text(progressDetailLabel(received: received, total: total, speed: speed, eta: eta))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if stalled {
                    Button("Retry") { onRetryDownload() }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(.orange)
                }
                Button("Cancel") { onCancelDownload() }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }

    private func progressDetailLabel(
        received: Int64, total: Int64, speed: Double?, eta: TimeInterval?
    ) -> String {
        let receivedStr = Self.byteFormatter.string(fromByteCount: received)
        let totalStr = Self.byteFormatter.string(fromByteCount: total)
        var parts = ["\(receivedStr) / \(totalStr)"]
        if let speed, speed > 0 {
            let speedStr = Self.byteFormatter.string(fromByteCount: Int64(speed)) + "/s"
            parts.append(speedStr)
        } else {
            parts.append("calculating speed…")
        }
        if let eta {
            parts.append("ETA \(Self.formatETA(eta))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var inUsePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text("In Use")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.green.opacity(0.18))
        .foregroundStyle(.green)
        .clipShape(Capsule())
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        f.zeroPadsFractionDigits = false
        return f
    }()

    private static func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - AddCustomModelSheet

struct AddCustomModelSheet: View {
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
        NavigationStack {
            Form {
                Section {
                    TextField("https://huggingface.co/.../resolve/main/model.gguf", text: $urlText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
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
            .navigationTitle("Add Custom Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                    .fontWeight(.semibold)
                    .disabled(!canAdd)
                }
            }
        }
    }

    private func checkURL() async {
        guard let url = URL(string: urlText) else { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 || http.statusCode == 206 {
                    let size = http.value(forHTTPHeaderField: "Content-Length")
                        .flatMap { Int64($0) }
                        ?? http.value(forHTTPHeaderField: "x-linked-size")
                        .flatMap { Int64($0) }
                    if let size, size > 0 {
                        fetchedSize = size
                    } else {
                        fetchError = "Could not determine file size. Try downloading anyway?"
                        fetchedSize = 0 // allow proceeding
                    }
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    fetchError = "This file requires authentication and cannot be downloaded."
                } else {
                    fetchError = "HTTP \(http.statusCode) — file may not exist."
                }
            }
        } catch {
            fetchError = "Network error: \(error.localizedDescription)"
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

// 2.5.4: PreDownloadSheet was removed. The card now shows size, RAM, and
// license inline, and tapping "Use" starts the download immediately
// (single-tap UX). The Llama community-license acknowledgment sheet stays
// because Meta's terms require explicit one-time consent.

#endif
