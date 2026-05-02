import Foundation
import Observation
import UserNotifications
import CHSharedKit
import Hub

// MARK: - Download state

public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(progress: Double, bytesReceived: Int64, totalBytes: Int64)
    case installing
    case installed
    case failed(String)
    case paused(resumeData: Data)

    public static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.installing, .installing), (.installed, .installed): return true
        case (.downloading(let a, _, _), .downloading(let b, _, _)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        case (.paused, .paused): return true
        default: return false
        }
    }
}

// MARK: - LocalModelStore

/// Manages on-device LLM model downloads and storage.
///
/// 2.5.0: Reworked to download MLX-format Hugging Face repos via
/// `HubApi.snapshot(...)` instead of single-file GGUF URLs over a background
/// `URLSession`. The public API surface is preserved; the iOS background
/// continuation behavior is the only intentional behavior change (HubApi
/// uses a foreground session, so multi-file downloads pause when the app
/// suspends — we resume on next foreground).
@Observable
@MainActor
public final class LocalModelStore {
    public static let shared = LocalModelStore()

    // Published state
    public private(set) var downloadState: ModelDownloadState = .idle
    public private(set) var activeDownloadModelID: String?
    /// ID of the model the user has chosen as active (persisted across launches).
    public private(set) var activeModelID: String?
    /// 2.5.4: ID of the model the user tapped "Use" on while the bytes weren't
    /// yet on disk. Once the corresponding download completes, the model is
    /// auto-promoted to active and `pendingActiveModelID` clears. This drives
    /// the picker's single-tap UX: `Use Phi-3.5 Mini` → kicks download +
    /// queues the promotion → "In Use" pill appears once bytes arrive.
    public private(set) var pendingActiveModelID: String?

    /// 2.5.4: smoothed download speed in bytes/sec for the in-flight download,
    /// nil before enough samples are collected (first ~2 s) and outside of
    /// active downloads. The ring averages the most recent 3 ticks so the
    /// displayed value doesn't jitter on bursty HTTP throughput.
    public private(set) var currentDownloadSpeedBytesPerSecond: Double?

    /// 2.5.8: true when an in-flight download has gone `stallThresholdSeconds`
    /// without a progress callback. The picker / `LocalModelDownloadView`
    /// surface a "Stalled — Retry" UI when this is set; tapping Retry calls
    /// `retryDownload(_:)` which re-issues the snapshot (HubApi resumes
    /// per-file from cached partials, so re-issued downloads pick up where
    /// they stalled).
    public private(set) var isDownloadStalled: Bool = false

    /// Seconds without a progress callback before `isDownloadStalled` flips
    /// true. Default 30 s — long enough that brief HTTP retries don't trip
    /// it, short enough that users notice within a minute. Configurable for
    /// tests (use a tiny value to assert behavior synchronously).
    public var stallThresholdSeconds: TimeInterval = 30

    /// 2.5.4: ETA for the in-flight download. nil when speed is unknown.
    public var currentDownloadETA: TimeInterval? {
        guard let speed = currentDownloadSpeedBytesPerSecond, speed > 0,
              case let .downloading(_, received, total) = downloadState,
              total > received
        else { return nil }
        return Double(total - received) / speed
    }

    @ObservationIgnored private var speedRing: [Double] = []
    @ObservationIgnored private var lastTickTime: Date?
    @ObservationIgnored private var lastTickBytes: Int64 = 0

    // Configuration — apps can override appGroupID before first use.
    //
    // 2.5.3 P0 storage fix: changing `appGroupID` no longer relocates model
    // storage. Models always live in `Application Support/CHSharedKit/`
    // (see `CHLocalMLXStorage.baseDirectory`) — the 2.5.0–2.5.2 default of
    // preferring the App Group container (`group.app.chen.sharedllm`) wiped
    // 1.7 GB+ of downloaded models on TestFlight reinstall when only one
    // app in the group was installed. `appGroupID` still controls the
    // shared `UserDefaults` suite used for persisting `activeModelID` +
    // `customModels` across apps in the same group.
    public var appGroupID: String = "group.app.chen.sharedllm" {
        didSet { _sharedDefaults = nil }
    }

    /// Identifies the consuming app. Drives the default onboarding copy and
    /// the local notification fired when a model finishes downloading.
    public var appIdentifier: AppIdentifier = .distill

    /// Optional override for the "download complete" notification title.
    public var downloadCompletionTitle: String?

    /// Optional override for the "download complete" notification body.
    public var downloadCompletionBody: String?

    private static let activeModelKey = "chlocallm.activeModelID"
    private static let customModelsKey = "chlocallm.customModels"

    // Custom models added by the user
    public private(set) var customModels: [CustomModelEntry] = []

    // Cached shared UserDefaults suite
    @ObservationIgnored private var _sharedDefaults: UserDefaults?
    /// 2.9.2: process-global flag so the suite-fallback warning only
    /// logs once per launch, not on every read.
    @ObservationIgnored private static var didLogSuiteFallback = false
    private var sharedDefaults: UserDefaults {
        if let cached = _sharedDefaults { return cached }
        // 2.9.2: explicitly distinguish "suite resolved" from
        // "fallback to .standard". The fallback is the silent
        // failure that produces "models aren't shared across apps"
        // — apps without the App Group entitlement land here and
        // see an isolated picker state.
        if let suite = UserDefaults(suiteName: appGroupID) {
            _sharedDefaults = suite
            return suite
        }
        if !Self.didLogSuiteFallback {
            Self.didLogSuiteFallback = true
            print("""
                [CHSharedKit] ⚠ App Group suite "\(appGroupID)" is not accessible. \
                Falling back to UserDefaults.standard. Active model selection and \
                custom models will not sync to other CHSharedKit apps until the \
                consuming app declares com.apple.security.application-groups → \
                \(appGroupID) in its .entitlements file and is rebuilt.
                """)
        }
        _sharedDefaults = .standard
        return .standard
    }

    // Active download task (HubApi.snapshot wrapped in Task) — non-nil while a
    // download is running; cancelled by `cancelDownload()`.
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// 2.5.8: companion task that polls every 5 s during a download and flips
    /// `isDownloadStalled` if the most recent progress tick is older than
    /// `stallThresholdSeconds`. Cancelled when `activeTask` finishes,
    /// fails, or is cancelled.
    @ObservationIgnored private var stallWatcher: Task<Void, Never>?

    private init() {
        // 2.5.3: storage location is now fixed at `Application Support/CHSharedKit/`
        // (see CHLocalMLXStorage). The 2.5.0–2.5.2 line that overrode it to the
        // App Group container is gone — App Group containers were wiped on TF
        // reinstall when only one app in the group was installed.

        // Restore active model id (prefer App Group suite; migrate from .standard if needed).
        let sharedSuite = UserDefaults(suiteName: "group.app.chen.sharedllm") ?? .standard
        if let id = sharedSuite.string(forKey: LocalModelStore.activeModelKey) {
            activeModelID = id
        } else if let legacyID = UserDefaults.standard.string(forKey: LocalModelStore.activeModelKey) {
            activeModelID = legacyID
            sharedSuite.set(legacyID, forKey: LocalModelStore.activeModelKey)
            UserDefaults.standard.removeObject(forKey: LocalModelStore.activeModelKey)
        }

        // Restore custom models.
        if let data = sharedSuite.data(forKey: LocalModelStore.customModelsKey),
           let entries = try? JSONDecoder().decode([CustomModelEntry].self, from: data) {
            customModels = entries
        } else if let legacyData = UserDefaults.standard.data(forKey: LocalModelStore.customModelsKey),
                  let entries = try? JSONDecoder().decode([CustomModelEntry].self, from: legacyData) {
            customModels = entries
            sharedSuite.set(legacyData, forKey: LocalModelStore.customModelsKey)
            UserDefaults.standard.removeObject(forKey: LocalModelStore.customModelsKey)
        }

        // Cold-launch: if the user had selected an on-device model that's still
        // installed (now in MLX format), wire up the provider with CHAIManager
        // so the unified "Active Provider" label resolves on first render.
        if let id = activeModelID,
           let info = (LocalModelCatalog.all + customModels.map(localModelInfo(for:)))
               .first(where: { $0.id == id }) {
            CHAIManager.shared.setActiveOnDeviceModel(
                id: id,
                displayName: info.displayName
            )
            if isInstalled(info) {
                let provider = CHLocalLLMProvider(
                    modelURL: modelURL(for: info),
                    modelInfo: info
                )
                CHAIManager.shared.registerProvider(provider)
            }
        }

        // 2.5.0 migration: legacy `<group>/CHLocalModels/*.gguf` files are
        // useless under MLX. Sweep them on a background task to reclaim disk.
        let legacyDir = Self.legacyGGUFDirectory(appGroupID: appGroupID)
        Task.detached(priority: .background) {
            Self.removeLegacyGGUFFilesIfNeeded(at: legacyDir)
        }
    }

    // MARK: - Completion notification

    private func fireCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = downloadCompletionTitle ?? appIdentifier.defaultDownloadCompletionTitle
        content.body = downloadCompletionBody ?? appIdentifier.defaultDownloadCompletionBody
        content.sound = .default
        content.userInfo = ["destination": "ai-settings"]
        let request = UNNotificationRequest(
            identifier: appIdentifier.downloadCompletionNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Storage

    /// Local on-disk directory for a model.
    ///
    /// 2.5.3: returns wherever the bytes actually live — canonical
    /// `Application Support/CHSharedKit/models/<repo>/` if present, else any
    /// 2.5.0–2.5.2 legacy App Group container path that still has the
    /// snapshot. New downloads always land at the canonical path. See
    /// ``CHLocalMLXStorage/resolvedDirectory(forRepoID:)``.
    public func modelURL(for model: LocalModelInfo) -> URL {
        if let repoID = CHLocalMLXRepoID.from(model.downloadURL) {
            return CHLocalMLXStorage.resolvedDirectory(forRepoID: repoID)
        }
        // Fall back: derive a stable folder name from the model id so custom
        // entries that don't parse as Hub URLs still have a local home.
        return CHLocalMLXStorage.baseDirectory
            .appendingPathComponent("custom", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }

    // MARK: - Queries

    /// True when the model snapshot exists locally with the files required
    /// to load via MLX (`config.json` + at least one `.safetensors`).
    public func isInstalled(_ model: LocalModelInfo) -> Bool {
        CHLocalMLXStorage.isSnapshotPresent(at: modelURL(for: model))
    }

    public var installedModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { isInstalled($0) }
    }

    public var availableModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { !isInstalled($0) }
    }

    public var allModels: [LocalModelInfo] {
        LocalModelCatalog.all + customModels.map { localModelInfo(for: $0) }
    }

    public func localModelInfo(for entry: CustomModelEntry) -> LocalModelInfo {
        let minRAM = max(2, Int(Double(entry.sizeBytes) * 1.5 / 1_073_741_824) + 1)
        return LocalModelInfo(
            id: entry.id,
            displayName: entry.displayName,
            description: "Custom model · \(formattedSize(entry.sizeBytes))",
            sizeBytes: entry.sizeBytes,
            quantization: "Custom",
            downloadURL: entry.downloadURL,
            minRAM_GB: minRAM,
            license: .apache2,
            quality: .balanced,
            chatTemplate: entry.chatTemplate,
            languages: [],
            strengths: [],
            isCustom: true
        )
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    public var installedDefaultModel: LocalModelInfo? {
        isInstalled(LocalModelCatalog.default) ? LocalModelCatalog.default : nil
    }

    /// Total bytes used by installed models (recursive directory size).
    public var totalStorageUsed: Int64 {
        installedModels.reduce(0) { acc, model in
            acc + Self.directorySize(at: modelURL(for: model))
        }
    }

    // MARK: - Download

    public func downloadModel(_ model: LocalModelInfo) {
        switch downloadState {
        case .idle, .installed, .failed: break
        default: return
        }
        guard let repoID = CHLocalMLXRepoID.from(model.downloadURL) else {
            downloadState = .failed("Model URL is not a Hugging Face repo: \(model.downloadURL.absoluteString)")
            return
        }

        activeDownloadModelID = model.id
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.sizeBytes)
        // Reset 2.5.4 speed-tracking state for this download.
        speedRing.removeAll()
        lastTickTime = Date()
        lastTickBytes = 0
        currentDownloadSpeedBytesPerSecond = nil
        // 2.5.8: reset stall state and arm the watcher. HubApi can stall
        // mid-download (network drop, server-side pause); the watcher flips
        // `isDownloadStalled` after `stallThresholdSeconds` of progress
        // silence so the picker UI shows a Retry button instead of a
        // frozen 72%.
        isDownloadStalled = false
        startStallWatcher()
        print("[CHLocalModelStore] downloadModel start id=\(model.id) repoID=\(repoID) sizeBytes=\(model.sizeBytes)")
        requestNotificationPermission()

        let totalEstimate = model.sizeBytes
        let modelID = model.id
        activeTask = Task { [weak self] in
            do {
                let hub = CHLocalMLXStorage.hubApi()
                // 2.5.3: HubApi reports progress in *file count* (e.g. 8/10
                // files), not bytes. We synthesize bytes from the catalog's
                // known total × fraction; not byte-perfect but tracks reality.
                let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    let total = totalEstimate
                    let received = Int64(Double(total) * fraction)
                    let filesDone = progress.completedUnitCount
                    let filesTotal = progress.totalUnitCount
                    print("[CHLocalModelStore] progress fraction=\(String(format: "%.3f", fraction)) files=\(filesDone)/\(filesTotal) bytesEst=\(received)/\(total)")
                    Task { @MainActor [weak self] in
                        self?.applyDownloadProgress(
                            fraction: fraction,
                            received: received,
                            total: total
                        )
                    }
                }
                _ = try await hub.snapshot(
                    from: Hub.Repo(id: repoID),
                    matching: ["*.safetensors", "*.json"],
                    progressHandler: progressHandler
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("[CHLocalModelStore] downloadModel SUCCESS id=\(modelID)")
                    self.downloadState = .installed
                    self.activeDownloadModelID = nil
                    self.activeTask = nil
                    self.stopStallWatcher()
                    self.isDownloadStalled = false
                    self.currentDownloadSpeedBytesPerSecond = nil
                    self.fireCompletionNotification()
                    // 2.5.4: auto-promote pending → active if the user
                    // selected this model before/during the download.
                    self.promotePendingActiveIfMatches(modelID: modelID)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("[CHLocalModelStore] downloadModel CANCELLED id=\(modelID)")
                    self.downloadState = .idle
                    self.activeDownloadModelID = nil
                    self.activeTask = nil
                    self.stopStallWatcher()
                    self.isDownloadStalled = false
                    self.currentDownloadSpeedBytesPerSecond = nil
                    // Cancellation drops any pending-active intent for this model.
                    if self.pendingActiveModelID == modelID {
                        self.pendingActiveModelID = nil
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("[CHLocalModelStore] downloadModel ERROR id=\(modelID) underlying=\(message)")
                    self.downloadState = .failed(message)
                    self.activeDownloadModelID = nil
                    self.activeTask = nil
                    self.stopStallWatcher()
                    self.isDownloadStalled = false
                    self.currentDownloadSpeedBytesPerSecond = nil
                    if self.pendingActiveModelID == modelID {
                        self.pendingActiveModelID = nil
                    }
                }
            }
        }
    }

    public func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        stopStallWatcher()
        isDownloadStalled = false
        if case .downloading = downloadState {
            downloadState = .idle
            activeDownloadModelID = nil
            pendingActiveModelID = nil
            currentDownloadSpeedBytesPerSecond = nil
        }
    }

    /// 2.5.8: re-issue a stalled or failed download for the same model.
    /// HubApi resumes per-file from the partial-cache metadata so files
    /// that already completed don't re-download — only the remaining
    /// shards do. Calling `retryDownload` while another download is in
    /// flight is a no-op (caller should call `cancelDownload()` first).
    public func retryDownload(_ model: LocalModelInfo) {
        // Reset terminal state so `downloadModel`'s guard accepts the call.
        if case .failed = downloadState {
            downloadState = .idle
        }
        // If we got here while marked stalled but `activeTask` is still alive,
        // cancel it first so the new download can take over the in-flight
        // URLSession connections cleanly.
        if isDownloadStalled, activeTask != nil {
            cancelDownload()
        }
        downloadModel(model)
    }

    // 2.5.8 — stall watcher

    @MainActor
    private func startStallWatcher() {
        stallWatcher?.cancel()
        let threshold = stallThresholdSeconds
        stallWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await MainActor.run { [weak self] in
                    guard let self, let lastTick = self.lastTickTime else { return }
                    let elapsed = Date().timeIntervalSince(lastTick)
                    let stalled = elapsed > threshold
                    if stalled != self.isDownloadStalled {
                        print("[CHLocalModelStore] stallWatcher: isDownloadStalled \(self.isDownloadStalled) → \(stalled) (elapsed=\(String(format: "%.1f", elapsed))s threshold=\(threshold)s)")
                        self.isDownloadStalled = stalled
                    }
                }
            }
        }
    }

    @MainActor
    private func stopStallWatcher() {
        stallWatcher?.cancel()
        stallWatcher = nil
    }

    // MARK: - 2.5.4 — single-tap select-and-download

    /// Single-tap UX entry point used by the picker's "Use \(model)" button.
    ///
    /// - If the model is already installed: promotes to active immediately,
    ///   no download.
    /// - If the model is not installed and no other download is in flight:
    ///   marks this model as the user's intended-active and starts the
    ///   download. The model becomes active automatically when the download
    ///   completes (handled in `downloadModel`'s success branch).
    /// - If a different download is already in flight: cancels it (the
    ///   caller is expected to confirm with the user first), then starts
    ///   this one.
    public func selectAndDownload(_ model: LocalModelInfo) {
        if isInstalled(model) {
            setActiveModel(model)
            return
        }
        if let inFlight = activeDownloadModelID, inFlight != model.id {
            cancelDownload()
        }
        pendingActiveModelID = model.id
        downloadModel(model)
    }

    @MainActor
    private func applyDownloadProgress(fraction: Double, received: Int64, total: Int64) {
        downloadState = .downloading(
            progress: fraction,
            bytesReceived: received,
            totalBytes: total
        )
        // 2.5.8: any progress callback resets the stall state. Useful for the
        // "stall recovers on its own" path — HubApi may pause for >30 s during
        // a slow shard but eventually resume. We don't want a stuck "Stalled"
        // banner if bytes are still flowing.
        if isDownloadStalled { isDownloadStalled = false }
        // Speed sampling: take a tick at most once per second so bursty
        // HTTP doesn't pollute the average.
        let now = Date()
        if let lastTick = lastTickTime {
            let elapsed = now.timeIntervalSince(lastTick)
            if elapsed >= 1.0 {
                let bytesDelta = received - lastTickBytes
                let speed = elapsed > 0 ? Double(bytesDelta) / elapsed : 0
                lastTickTime = now
                lastTickBytes = received
                if speed >= 0 {
                    speedRing.append(speed)
                    if speedRing.count > 3 { speedRing.removeFirst() }
                    if speedRing.count >= 2 {
                        let avg = speedRing.reduce(0, +) / Double(speedRing.count)
                        currentDownloadSpeedBytesPerSecond = avg
                    }
                }
            }
        } else {
            lastTickTime = now
            lastTickBytes = received
        }
    }

    @MainActor
    private func promotePendingActiveIfMatches(modelID: String) {
        guard pendingActiveModelID == modelID else { return }
        let candidate = (LocalModelCatalog.all + customModels.map { localModelInfo(for: $0) })
            .first { $0.id == modelID }
        guard let model = candidate else {
            pendingActiveModelID = nil
            return
        }
        pendingActiveModelID = nil
        setActiveModel(model)
    }

    /// Resume a previously paused download. With HubApi the snapshot resumes
    /// missing files automatically — `resumeData` is ignored and we just
    /// re-issue `downloadModel(_:)`.
    public func resumeDownload(model: LocalModelInfo, resumeData: Data) {
        downloadState = .idle
        downloadModel(model)
    }

    public func deleteModel(_ model: LocalModelInfo) {
        let dir = modelURL(for: model)
        try? FileManager.default.removeItem(at: dir)
        if activeModelID == model.id {
            clearActiveModel()
        }
        if model.isCustom {
            customModels.removeAll { $0.id == model.id }
            persistCustomModels()
        }
    }

    // MARK: - Custom models

    public func addCustomModel(
        id: String = UUID().uuidString,
        displayName: String,
        downloadURL: URL,
        sizeBytes: Int64,
        chatTemplate: LocalModelInfo.ChatTemplate
    ) {
        let entry = CustomModelEntry(
            id: id,
            displayName: displayName,
            downloadURL: downloadURL,
            sizeBytes: sizeBytes,
            chatTemplate: chatTemplate
        )
        customModels.append(entry)
        persistCustomModels()
    }

    private func persistCustomModels() {
        let data = try? JSONEncoder().encode(customModels)
        sharedDefaults.set(data, forKey: LocalModelStore.customModelsKey)
    }

    // MARK: - Active model

    public func setActiveModel(_ model: LocalModelInfo) {
        guard isInstalled(model) else { return }
        activeModelID = model.id
        sharedDefaults.set(model.id, forKey: Self.activeModelKey)
        let provider = CHLocalLLMProvider(
            modelURL: modelURL(for: model),
            modelInfo: model
        )
        CHAIManager.shared.registerProvider(provider)
        CHAIManager.shared.setActiveOnDeviceModel(
            id: model.id,
            displayName: model.displayName
        )
        CHAIManager.shared.activeProviderID = CHLocalLLMProvider.providerID
    }

    public func clearActiveModel() {
        activeModelID = nil
        sharedDefaults.removeObject(forKey: Self.activeModelKey)
        CHAIManager.shared.clearActiveOnDeviceModel()
    }

    public func resetDownloadState() {
        downloadState = .idle
        activeDownloadModelID = nil
    }

    // MARK: - Background events (no-op in 2.5.0)

    /// Retained for source compatibility with apps that wired up
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// in 2.4.x. HubApi-based downloads do not use a background URLSession,
    /// so the system will never call this for our identifier — the handler is
    /// invoked immediately so the OS doesn't keep the app alive waiting.
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: - Helpers

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Legacy GGUF cleanup

    private static func legacyGGUFDirectory(appGroupID: String) -> URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CHLocalModels", isDirectory: true)
    }

    private nonisolated static func removeLegacyGGUFFilesIfNeeded(at dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "gguf" {
            try? fm.removeItem(at: file)
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: dir.path), remaining.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - 2.5.3 — verifyOnLaunch

    /// Snapshot of where on-device models live and what's installed. Use this
    /// to log storage state on app launch + surface in a Storage panel for
    /// users.
    public struct StorageReport: Sendable {
        /// Canonical write location (`Application Support/CHSharedKit/`).
        public let canonicalDirectory: URL
        /// Legacy locations scanned for backwards-compat reads. Empty in
        /// fresh installs.
        public let legacyDirectories: [URL]
        /// Each installed model's id, on-disk location, and total snapshot
        /// size in bytes.
        public let installedModels: [ModelEntry]
        /// 2.9.2: did the App Group entitlement actually resolve to a
        /// container at launch? `false` here means the consuming app
        /// is missing `com.apple.security.application-groups` with
        /// `group.app.chen.sharedllm` — its `activeModelID` /
        /// `customModels` won't sync across the suite.
        public let appGroupAccessible: Bool
        /// 2.9.2: human-readable warning string when entitlement check
        /// fails. `nil` when everything is fine.
        public let entitlementWarning: String?

        public struct ModelEntry: Sendable {
            public let id: String
            public let displayName: String
            public let directory: URL
            public let sizeBytes: Int64
            /// True if the model lives in `legacyDirectories` rather than the
            /// canonical path. Indicates a 2.5.0–2.5.2 install that hasn't
            /// been migrated yet.
            public let isLegacyLocation: Bool
        }

        /// Total bytes used by installed models.
        public var totalBytes: Int64 {
            installedModels.reduce(0) { $0 + $1.sizeBytes }
        }

        /// Human-readable one-liner suitable for a console log.
        ///
        ///   `CHSharedKit: 2 models installed (Qwen2.5-3B, Phi-3-mini), total 3.20 GB. Path: <canonical>`
        public var summary: String {
            let names = installedModels.map(\.displayName).joined(separator: ", ")
            let totalGB = Double(totalBytes) / 1_073_741_824
            let count = installedModels.count
            let names_ = names.isEmpty ? "" : " (\(names))"
            let legacyNote = installedModels.contains(where: \.isLegacyLocation)
                ? " — \(installedModels.filter(\.isLegacyLocation).count) in legacy location"
                : ""
            let entitlementNote = appGroupAccessible
                ? ""
                : " ⚠ App Group entitlement missing — model selection won't sync across apps"
            return "CHSharedKit: \(count) model\(count == 1 ? "" : "s") installed\(names_), total \(String(format: "%.2f", totalGB)) GB. Path: \(canonicalDirectory.path)\(legacyNote)\(entitlementNote)"
        }
    }

    /// Inspects the canonical + legacy storage paths, returns an inventory of
    /// what's actually on disk, and prints a one-line summary to the system
    /// log so missing-models bug reports can be diagnosed at a glance.
    ///
    /// Call from your `App.init` (or as early as possible at launch):
    ///
    /// ```swift
    /// @main
    /// struct YourApp: App {
    ///     init() {
    ///         CHLocalModelStore.verifyOnLaunch()
    ///     }
    /// }
    /// ```
    @discardableResult
    public static func verifyOnLaunch() -> StorageReport {
        let canonical = CHLocalMLXStorage.baseDirectory
        let legacy = CHLocalMLXStorage.legacyBaseDirectories
        let fm = FileManager.default

        var entries: [StorageReport.ModelEntry] = []
        for model in LocalModelCatalog.all {
            guard let repoID = CHLocalMLXRepoID.from(model.downloadURL) else { continue }
            let resolved = CHLocalMLXStorage.resolvedDirectory(forRepoID: repoID)
            guard CHLocalMLXStorage.isSnapshotPresent(at: resolved) else { continue }
            let canonicalDir = CHLocalMLXStorage.localDirectory(forRepoID: repoID)
            let isLegacy = resolved.standardizedFileURL != canonicalDir.standardizedFileURL
            let size = directorySize(at: resolved, fm: fm)
            entries.append(.init(
                id: model.id,
                displayName: model.displayName,
                directory: resolved,
                sizeBytes: size,
                isLegacyLocation: isLegacy
            ))
        }
        // 2.9.2: probe the App Group entitlement. If this comes back
        // nil, the consuming app is missing
        // `com.apple.security.application-groups` with
        // `group.app.chen.sharedllm` — `activeModelID` and
        // `customModels` will silently fall back to the local
        // `UserDefaults.standard` suite, so each app sees a different
        // "active model" picker state. That's the most common cause
        // of "models aren't shared between my apps" reports.
        let configuredGroupID = CHLocalModelStore.shared.appGroupID
        let groupAccessible = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuredGroupID
        ) != nil
        let entitlementWarning: String? = groupAccessible ? nil : """
            App Group "\(configuredGroupID)" is not accessible from this app. \
            Add com.apple.security.application-groups → \(configuredGroupID) \
            to the app's .entitlements file and rebuild. Until that's fixed, \
            this app falls back to UserDefaults.standard for model metadata, \
            so the active-model selection won't sync with other CHSharedKit apps.
            """

        let report = StorageReport(
            canonicalDirectory: canonical,
            legacyDirectories: legacy,
            installedModels: entries,
            appGroupAccessible: groupAccessible,
            entitlementWarning: entitlementWarning
        )
        print("[CHSharedKit] " + report.summary)
        if let warning = entitlementWarning {
            print("[CHSharedKit] " + warning)
        }
        return report
    }

    private static func directorySize(at url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

/// Spec-canonical name. The implementation lives on ``LocalModelStore`` (the
/// existing 2.4.x type name); this typealias matches what 2.5.x docs and
/// public APIs reference (`CHLocalModelStore.shared`,
/// `CHLocalModelStore.verifyOnLaunch()`).
public typealias CHLocalModelStore = LocalModelStore

// MARK: - CustomModelEntry

/// A user-supplied model added via URL. Persisted in UserDefaults as JSON.
/// In 2.5.0 the `downloadURL` should be a Hugging Face repo URL
/// (e.g. `https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit`);
/// custom GGUF URLs are no longer loadable.
public struct CustomModelEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    public let chatTemplate: LocalModelInfo.ChatTemplate
}

// MARK: - BackgroundDownloadDelegate (deprecated stub)

/// Retained as a no-op stub for source compatibility. 2.5.0 downloads use
/// Hugging Face `HubApi` (foreground `URLSession`) so this delegate is never
/// invoked. Apps may safely stop wiring it into `AppDelegate`.
@available(*, deprecated, message: "2.5.0 uses HubApi for downloads; this delegate is unused.")
public final class BackgroundDownloadDelegate: NSObject, @unchecked Sendable {
    public let sessionIdentifier: String
    public var backgroundCompletionHandler: (() -> Void)?

    public init(appGroupID: String = "group.app.chen.sharedllm") {
        let stripped = appGroupID.hasPrefix("group.")
            ? String(appGroupID.dropFirst("group.".count)) : appGroupID
        self.sessionIdentifier = "\(stripped).llm-download"
    }
}
