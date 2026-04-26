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

    // Configuration — apps can override appGroupID before first use
    public var appGroupID: String = "group.app.chen.sharedllm" {
        didSet {
            _sharedDefaults = nil
            CHLocalMLXStorage.baseDirectory = Self.resolveBaseDirectory(appGroupID: appGroupID)
        }
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
    private var sharedDefaults: UserDefaults {
        if let cached = _sharedDefaults { return cached }
        let suite = UserDefaults(suiteName: appGroupID) ?? .standard
        _sharedDefaults = suite
        return suite
    }

    // Active download task (HubApi.snapshot wrapped in Task) — non-nil while a
    // download is running; cancelled by `cancelDownload()`.
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    private init() {
        // Point shared MLX storage at the App Group container before first use.
        CHLocalMLXStorage.baseDirectory = Self.resolveBaseDirectory(appGroupID: appGroupID)

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

    private static func resolveBaseDirectory(appGroupID: String) -> URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CHSharedKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local on-disk directory for a model (whether or not it's downloaded).
    /// Layout: `<base>/models/<repo-org>/<repo-name>/`.
    public func modelURL(for model: LocalModelInfo) -> URL {
        if let repoID = CHLocalMLXRepoID.from(model.downloadURL) {
            return CHLocalMLXStorage.localDirectory(forRepoID: repoID)
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
        let dir = modelURL(for: model)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        let configURL = dir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configURL.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
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
        requestNotificationPermission()

        let totalEstimate = model.sizeBytes
        activeTask = Task { [weak self] in
            do {
                let hub = CHLocalMLXStorage.hubApi()
                let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    let total = progress.totalUnitCount > 0
                        ? progress.totalUnitCount : totalEstimate
                    let received = progress.completedUnitCount
                    Task { @MainActor [weak self] in
                        self?.downloadState = .downloading(
                            progress: fraction,
                            bytesReceived: received,
                            totalBytes: total
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
                    self.downloadState = .installed
                    self.activeDownloadModelID = nil
                    self.fireCompletionNotification()
                    self.activeTask = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloadState = .idle
                    self.activeDownloadModelID = nil
                    self.activeTask = nil
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloadState = .failed(message)
                    self.activeDownloadModelID = nil
                    self.activeTask = nil
                }
            }
        }
    }

    public func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        if case .downloading = downloadState {
            downloadState = .idle
            activeDownloadModelID = nil
        }
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
}

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
