#if os(macOS)
import SwiftUI
import AppKit
import CHSharedKit

private enum ModelLicenseAcknowledgment {
    static func key(for model: LocalModelInfo) -> String {
        "chlocallm.acked.\(model.id).\(model.release?.revision ?? "legacy")"
    }

    static func isRequired(for model: LocalModelInfo) -> Bool {
        guard model.requiresAcknowledgment else { return false }
        if UserDefaults.standard.bool(forKey: key(for: model)) { return false }
        if model.release == nil && model.license == .llamaCommunity {
            return !UserDefaults.standard.bool(forKey: "chlocallm.acked.llama")
        }
        return true
    }

    static func record(for model: LocalModelInfo) {
        UserDefaults.standard.set(true, forKey: key(for: model))
    }

    static func termsURL(for model: LocalModelInfo) -> URL {
        if let url = model.release?.licenseURL { return url }
        if model.license == .llamaCommunity {
            return URL(string: "https://www.llama.com/llama-downloads")!
        }
        return model.downloadURL
    }
}

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
    @ObservedObject private var catalog = CHOfflineModelCatalog.shared
    @State private var showAcknowledgmentFor: LocalModelInfo?
    @State private var acknowledgmentIsUpdate = false
    @State private var showAddCustomModel = false

    private var deviceRAM_GB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    private var sortedCatalogModels: [LocalModelInfo] {
        store.allModels.filter {
            !$0.isCustom && !store.isInstalled($0)
                && ($0.id == store.activeDownloadModelID || ($0.release?.status ?? "active") == "active")
        }.sorted {
            let sa = $0.recommendationScore(for: appIdentifier)
            let sb = $1.recommendationScore(for: appIdentifier)
            if sa != sb { return sa > sb }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes < $1.sizeBytes }
            return $0.id < $1.id
        }
    }

    private var recommendedModels: [LocalModelInfo] {
        Array(sortedCatalogModels.filter {
            $0.release?.recommendations[appIdentifier.rawValue == "gymlog" ? "liftcoach" : appIdentifier.rawValue]?.verification == "passed"
                && CHOfflineModelCatalog.compatibilityIssue(for: $0) == nil
                && deviceRAM_GB >= $0.minRAM_GB
        }.prefix(3))
    }

    private var otherCatalogModels: [LocalModelInfo] {
        let recommendedIDs = Set(recommendedModels.map(\.id))
        return sortedCatalogModels.filter { !recommendedIDs.contains($0.id) }
    }

    private var installedModels: [LocalModelInfo] {
        store.allModels.filter { !$0.isCustom && store.isInstalled($0) }.sorted {
            if ($0.id == store.activeModelID) != ($1.id == store.activeModelID) {
                return $0.id == store.activeModelID
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
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
            Section {
                catalogStatus
            }

            if !installedModels.isEmpty {
                Section("Installed Models") {
                    ForEach(installedModels, id: \.id) { model in
                        modelRow(model, isTopRecommendation: false)
                    }
                }
            }

            if !recommendedModels.isEmpty {
                Section("Recommended for \(appIdentifier.displayName)") {
                    ForEach(Array(recommendedModels.enumerated()), id: \.element.id) { index, model in
                        modelRow(model, isTopRecommendation: index == 0)
                    }
                }
            }

            if !otherCatalogModels.isEmpty {
                Section("Available Models") {
                    ForEach(otherCatalogModels, id: \.id) { model in
                        modelRow(model, isTopRecommendation: false)
                    }
                }
            }

            if !customModelInfos.isEmpty {
                Section("Custom Models") {
                    ForEach(customModelInfos, id: \.id) { model in
                        modelRow(model, isTopRecommendation: false)
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
                            Text("Add a Hugging Face MLX model")
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
        .task { await catalog.refreshIfNeeded() }
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
                if acknowledgmentIsUpdate {
                    store.downloadModel(model)
                } else {
                    store.selectAndDownload(model)
                }
            } onCancel: {
                showAcknowledgmentFor = nil
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
                store.selectAndDownload(modelInfo)
            }
        }
    }

    private var catalogStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if catalog.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Checking for model updates…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await catalog.refresh() }
                }
                .disabled(catalog.isRefreshing)
            }
            if catalog.lastRefreshError != nil {
                Text("Couldn’t refresh the model list. Your saved list and installed models are still available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let reason) = store.downloadState {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Model action failed", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                    Text(reason).font(.caption)
                }
                .foregroundStyle(.orange)
            }
            Text("Refreshing checks availability. Model downloads start only when you choose them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelRow(_ model: LocalModelInfo, isTopRecommendation: Bool) -> some View {
        MacModelRow(
            model: model,
            appIdentifier: appIdentifier,
            isTopRecommendation: isTopRecommendation,
            deviceRAM_GB: deviceRAM_GB,
            store: store,
            onSelectTapped: { handleSelectTapped(model) },
            onUpdateTapped: { handleUpdateTapped(model) },
            onCancelDownload: { store.cancelDownload() },
            onRetryDownload: { store.retryDownload(model) },
            onRemove: { store.deleteModel(model) }
        )
    }

    /// 2.5.4: same single-tap flow as iOS — acknowledgment if Llama (one-time
    /// per device), otherwise straight to `selectAndDownload`.
    private func handleSelectTapped(_ model: LocalModelInfo) {
        if store.isInstalled(model) {
            store.setActiveModel(model)
            return
        }
        if ModelLicenseAcknowledgment.isRequired(for: model) {
            acknowledgmentIsUpdate = false
            showAcknowledgmentFor = model
        } else {
            store.selectAndDownload(model)
        }
    }

    private func handleUpdateTapped(_ model: LocalModelInfo) {
        if ModelLicenseAcknowledgment.isRequired(for: model) {
            acknowledgmentIsUpdate = true
            showAcknowledgmentFor = model
        } else {
            store.downloadModel(model)
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
    let onSelectTapped: () -> Void
    let onUpdateTapped: () -> Void
    let onCancelDownload: () -> Void
    let onRetryDownload: () -> Void
    let onRemove: () -> Void

    private var displayModel: LocalModelInfo { store.installedModel(forID: model.id) ?? model }
    private var downloadIssue: String? { CHOfflineModelCatalog.compatibilityIssue(for: model) }
    private var installedUseIssue: String? {
        guard let installed = store.installedModel(forID: model.id) else { return nil }
        do {
            try CHLocalMLXPlatform.requireSupported()
            try OfflineModelInstaller.validateSnapshot(at: store.modelURL(for: installed), model: installed)
            return nil
        } catch {
            if LocalModelCatalog.isVisionCapable(installed.id) {
                return "This is an image model. Choose a text model for this app."
            }
            return "Your installed copy isn’t supported by this version of the app. You can remove it to free space."
        }
    }
    private var hasUpdate: Bool { store.updateAvailable(for: model) }
    private var isRetiredOrRemoved: Bool {
        !model.isCustom && (model.release?.status == "retired" || !LocalModelCatalog.all.contains { $0.id == model.id })
    }
    private var isCompatible: Bool { deviceRAM_GB >= displayModel.minRAM_GB }
    private var isBorderline: Bool { deviceRAM_GB == displayModel.minRAM_GB - 1 }
    private var isInstalled: Bool { store.isInstalled(model) }
    private var isActive: Bool { store.activeModelID == model.id && isInstalled && installedUseIssue == nil }
    private var isDownloadingThisModel: Bool { store.activeDownloadModelID == model.id }
    private var anyDownloadActive: Bool { store.activeDownloadModelID != nil }
    private var isPendingActive: Bool { store.pendingActiveModelID == model.id }

    /// 2.5.4: shared state machine — see iOS `ModelCardState` doc comment in
    /// `ModelPickerView.swift`. The macOS row mirrors the iOS card's logic
    /// so behavior stays in lockstep across platforms.
    private enum CardState {
        case notCompatible
        case notInstalled(canStart: Bool)
        case downloading(progress: Double, received: Int64, total: Int64, speed: Double?, eta: TimeInterval?, stalled: Bool)
        case installing
        case pendingActive
        case installed
        case active
    }

    private var cardState: CardState {
        if isDownloadingThisModel, case .downloading(let p, let r, let t) = store.downloadState {
            return .downloading(
                progress: p, received: r, total: t,
                speed: store.currentDownloadSpeedBytesPerSecond,
                eta: store.currentDownloadETA,
                stalled: store.isDownloadStalled
            )
        }
        if isDownloadingThisModel, case .installing = store.downloadState { return .installing }
        if isActive { return .active }
        if isInstalled { return .installed }
        if downloadIssue != nil || (!isCompatible && !isBorderline) { return .notCompatible }
        if isPendingActive { return .pendingActive }
        return .notInstalled(canStart: !anyDownloadActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            chipsRow
            if !displayModel.strengths.isEmpty {
                strengthsRow
            }
            if !model.isCustom {
                Text(displayModel.release == nil
                     ? "Not yet evaluated for \(appIdentifier.displayName)"
                     : displayModel.taskHint(for: appIdentifier))
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
            releaseStatus
            actionView
        }
        .padding(.vertical, 6)
        .opacity((isInstalled || (downloadIssue == nil && (isCompatible || isBorderline))) ? 1.0 : 0.65)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayModel.displayName).font(.headline)
                    if !model.isCustom {
                        qualityChip
                        sizeCategoryChip
                    }
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(model.isCustom ? "Added from Hugging Face" : displayModel.description)
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
            if !model.isCustom { licenseChip }
            compatibilityChip
            Spacer()
            Text(displayModel.sizeBytes > 0 ? formattedSize(displayModel.sizeBytes) : "Size unknown")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// macOS has the horizontal room — strengths flow on a single line
    /// and wrap naturally (no need for the iOS `ScrollView(.horizontal)`).
    @ViewBuilder
    private var strengthsRow: some View {
        FlowHStack(spacing: 6, runSpacing: 6) {
            ForEach(displayModel.strengths, id: \.self) { strength in
                Text(strength)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.08))
                    .foregroundStyle(.indigo)
                    .clipShape(Capsule())
            }
            if !displayModel.languages.isEmpty {
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
        let n = displayModel.languages.count
        if n <= 3 { return displayModel.languages.joined(separator: " · ") }
        return "\(n) languages"
    }

    @ViewBuilder
    private var qualityChip: some View {
        let color: Color = {
            switch displayModel.quality {
            case .fast: return .orange
            case .balanced: return .blue
            case .higher: return .purple
            case .highest: return .indigo
            }
        }()
        Text(displayModel.quality.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var sizeCategoryChip: some View {
        Text(displayModel.sizeCategory.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var licenseChip: some View {
        let color: Color = {
            switch displayModel.license {
            case .apache2: return .green
            case .mit: return .blue
            case .llamaCommunity: return .orange
            case .gemma: return .teal
            case .qwenResearch: return .orange
            case .other: return .secondary
            }
        }()
        Text(displayModel.licenseDisplayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var compatibilityChip: some View {
        let (label, color): (String, Color) = {
            if installedUseIssue != nil || (!isInstalled && downloadIssue != nil) { return ("Not supported", .red) }
            if deviceRAM_GB >= displayModel.minRAM_GB { return ("Meets memory estimate", .green) }
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

    // 2.5.4 state-driven action area (parity with iOS card).

    @ViewBuilder
    private var releaseStatus: some View {
        if model.isCustom {
            Text("Custom model · Not evaluated for \(appIdentifier.displayName)")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let installedUseIssue {
            Text(installedUseIssue)
                .font(.caption).foregroundStyle(.secondary)
        }
        if isRetiredOrRemoved {
            if isInstalled {
                Text(installedUseIssue == nil
                     ? "No longer offered for download. You can keep using your installed copy."
                     : "No longer offered for download. Its files are still stored on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No longer listed. You can let this download finish or cancel it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if hasUpdate {
            if let downloadIssue {
                Text("A newer version is available, but it cannot run in this app. \(downloadIssue)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if deviceRAM_GB < model.minRAM_GB - 1 {
                Text("A newer version is available, but it needs more memory than this device has.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Update available. Your installed copy is kept until the update finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if hasUpdate {
            Button("Update", systemImage: "arrow.down.circle") { onUpdateTapped() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(anyDownloadActive || downloadIssue != nil || deviceRAM_GB < model.minRAM_GB - 1)
                .accessibilityLabel("Update \(displayModel.displayName)")
        }
    }

    @ViewBuilder
    private var removeCustomEntryButton: some View {
        if model.isCustom {
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Remove \(displayModel.displayName)")
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch cardState {
        case .notCompatible:
            HStack {
                Spacer()
                Text(downloadIssue ?? "This model needs more memory than this device has.").font(.caption).foregroundStyle(.tertiary)
                removeCustomEntryButton
            }
        case .notInstalled(let canStart):
            HStack {
                Spacer()
                Button {
                    onSelectTapped()
                } label: {
                    Label("Use", systemImage: "checkmark.circle")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!canStart)
                removeCustomEntryButton
            }
        case .downloading(let progress, let received, let total, let speed, let eta, let stalled):
            inlineProgress(
                progress: progress, received: received, total: total,
                speed: speed, eta: eta, stalled: stalled
            )
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(isInstalled ? "Installing update…" : "Installing…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancelDownload() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .pendingActive:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Selected — finishing setup…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .installed:
            HStack {
                Label("Installed", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                updateButton
                Button {
                    onSelectTapped()
                } label: {
                    Label("Use", systemImage: "checkmark.circle")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(installedUseIssue != nil)
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Delete this model from disk")
            }
        case .active:
            HStack {
                inUsePill
                Spacer()
                updateButton
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Delete this model from disk")
            }
        }
    }

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
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                }
                Button("Cancel") { onCancelDownload() }
                    .buttonStyle(.bordered).controlSize(.small)
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
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(speed)) + "/s")
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
    @State private var fetchedSize: Int64?
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var checkGeneration = UUID()

    private var urlIsValid: Bool {
        guard let url = URL(string: urlText) else { return false }
        return CHLocalMLXRepoID.from(url) != nil
            && url.path.split(separator: "/").count == 2
            && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && url.port == nil
    }

    private var canAdd: Bool {
        urlIsValid && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
            && fetchedSize != nil && fetchError == nil && !isFetching
    }

    var body: some View {
        Form {
            Section {
                TextField("https://huggingface.co/mlx-community/model-name", text: $urlText)
                    .autocorrectionDisabled()
                    .onChange(of: urlText) { _, _ in
                        checkGeneration = UUID()
                        isFetching = false
                        fetchedSize = nil
                        fetchError = nil
                    }
            } header: {
                Text("Hugging Face Model Repository")
            } footer: {
                if let error = fetchError {
                    Text(error).foregroundStyle(.red)
                } else if let size = fetchedSize {
                    Text(size > 0 ? "Repository found · Approx. \(formattedSize(size))" : "Repository found. Download size unavailable.").foregroundStyle(.secondary)
                } else {
                    Text("Use an MLX-format text model. Custom models aren’t evaluated for this app.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(isFetching ? "Checking…" : "Check Repository") {
                    Task { await checkURL() }
                }
                .disabled(!urlIsValid || isFetching)
            }

            Section("Model Name") {
                TextField("e.g. My Custom 7B", text: $modelName)
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
                Button("Add and Download") {
                    guard let url = URL(string: urlText),
                          let size = fetchedSize else { return }
                    let entry = CustomModelEntry(
                        id: UUID().uuidString,
                        displayName: modelName.trimmingCharacters(in: .whitespaces),
                        downloadURL: url,
                        sizeBytes: size,
                        chatTemplate: .chatML
                    )
                    dismiss()
                    onAdd(entry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
    }

    private struct RepositoryMetadata: Decodable {
        struct File: Decodable {
            struct LargeFile: Decodable { let size: Int64 }
            let rfilename: String
            let size: Int64?
            let lfs: LargeFile?
        }
        let siblings: [File]
    }

    private func checkURL() async {
        let checkedText = urlText
        guard urlIsValid, let url = URL(string: checkedText),
              let repoID = CHLocalMLXRepoID.from(url),
              let metadataURL = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true") else { return }
        let generation = UUID()
        checkGeneration = generation
        fetchedSize = nil
        isFetching = true
        fetchError = nil
        defer {
            if checkGeneration == generation { isFetching = false }
        }
        var request = URLRequest(url: metadataURL)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard checkGeneration == generation, urlText == checkedText else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                fetchError = "This repository isn’t available. Use a public model repository."
                return
            }
            let metadata = try JSONDecoder().decode(RepositoryMetadata.self, from: data)
            let files = metadata.siblings.filter {
                $0.rfilename.hasSuffix(".safetensors") || $0.rfilename.hasSuffix(".json")
            }
            guard files.contains(where: { $0.rfilename == "config.json" }),
                  files.contains(where: { $0.rfilename.hasSuffix(".safetensors") }) else {
                fetchError = "This repository doesn’t contain the files needed for an MLX model."
                return
            }
            var total: Int64 = 0
            for file in files {
                let sum = total.addingReportingOverflow(max(0, file.size ?? file.lfs?.size ?? 0))
                guard !sum.overflow else {
                    fetchError = "Couldn’t read the model’s download size."
                    return
                }
                total = sum.partialValue
            }
            fetchedSize = total
            if modelName.trimmingCharacters(in: .whitespaces).isEmpty {
                modelName = url.lastPathComponent
            }
        } catch {
            guard checkGeneration == generation, urlText == checkedText else { return }
            fetchError = "Couldn’t check this repository. Check your connection and try again."
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
            Label(model.licenseDisplayName, systemImage: "checkmark.shield.fill")
                .font(.title3.bold())
            Text("\(model.displayName) is provided under this license. Review its terms before downloading.")
                .foregroundStyle(.secondary)
            Link("Read License Terms", destination: ModelLicenseAcknowledgment.termsURL(for: model))
            Text("Once downloaded, the model runs on your device.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("I Accept") {
                    ModelLicenseAcknowledgment.record(for: model)
                    onAcknowledge()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 240)
    }
}

// 2.5.4: MacPreDownloadSheet was removed. The card now shows size, RAM,
// and license inline; tapping "Use" starts the download immediately. See
// the matching iOS picker note in `ModelPickerView.swift`.

#endif
