import Foundation
import Observation
import UserNotifications
import CHSharedKit

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
/// Uses the App Group container so models are shared across all CHLocalLLM-enabled apps.
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
        didSet { _sharedDefaults = nil } // invalidate cache when group changes
    }

    /// Identifies the consuming app. Drives the default onboarding copy and
    /// the local notification fired when a model finishes downloading, so
    /// each app shows text that matches its own use case instead of the
    /// Distill-flavored defaults that shipped in 1.2.0/1.3.0.
    /// Set this at app launch, before the first download starts.
    public var appIdentifier: AppIdentifier = .distill

    /// Optional override for the "download complete" notification title.
    /// When nil, uses ``AppIdentifier/defaultDownloadCompletionTitle``.
    public var downloadCompletionTitle: String?

    /// Optional override for the "download complete" notification body.
    /// When nil, uses ``AppIdentifier/defaultDownloadCompletionBody``.
    public var downloadCompletionBody: String?

    private static let activeModelKey = "chlocallm.activeModelID"
    private static let customModelsKey = "chlocallm.customModels"

    // Custom models added by the user
    public private(set) var customModels: [CustomModelEntry] = []

    // Cached shared UserDefaults suite — invalidated when appGroupID changes
    @ObservationIgnored private var _sharedDefaults: UserDefaults?
    private var sharedDefaults: UserDefaults {
        if let cached = _sharedDefaults { return cached }
        let suite = UserDefaults(suiteName: appGroupID) ?? .standard
        _sharedDefaults = suite
        return suite
    }

    // Background session delegate — persists for app lifetime so iOS can reconnect downloads
    let bgDelegate: BackgroundDownloadDelegate

    private init() {
        // Load persisted active model ID — prefer shared suite, fall back + migrate from standard
        let sharedSuite = UserDefaults(suiteName: "group.app.chen.sharedllm") ?? .standard
        if let id = sharedSuite.string(forKey: LocalModelStore.activeModelKey) {
            activeModelID = id
        } else if let legacyID = UserDefaults.standard.string(forKey: LocalModelStore.activeModelKey) {
            // Migrate legacy per-app value to shared suite on first launch after update
            activeModelID = legacyID
            sharedSuite.set(legacyID, forKey: LocalModelStore.activeModelKey)
            UserDefaults.standard.removeObject(forKey: LocalModelStore.activeModelKey)
        }

        // Load custom models — prefer shared suite, migrate from standard if needed
        if let data = sharedSuite.data(forKey: LocalModelStore.customModelsKey),
           let entries = try? JSONDecoder().decode([CustomModelEntry].self, from: data) {
            customModels = entries
        } else if let legacyData = UserDefaults.standard.data(forKey: LocalModelStore.customModelsKey),
                  let entries = try? JSONDecoder().decode([CustomModelEntry].self, from: legacyData) {
            customModels = entries
            sharedSuite.set(legacyData, forKey: LocalModelStore.customModelsKey)
            UserDefaults.standard.removeObject(forKey: LocalModelStore.customModelsKey)
        }

        // BackgroundDownloadDelegate resolves its models directory lazily so appGroupID overrides
        // (set after init but before the first download) are respected. Using LocalModelStore.shared
        // inside the closure is safe: by the time any download completes, the singleton exists.
        bgDelegate = BackgroundDownloadDelegate(
            resolveModelsDir: { LocalModelStore.shared.modelsDirectory }
        )
        // Eagerly create the session — must happen before iOS delivers background events
        _ = bgDelegate.session

        bgDelegate.onStateChange = { [weak self] state, modelID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadState = state
                switch state {
                case .installed:
                    self.activeDownloadModelID = nil
                    self.fireCompletionNotification()
                case .failed:
                    self.activeDownloadModelID = nil
                case .downloading, .installing, .paused, .idle:
                    if let modelID { self.activeDownloadModelID = modelID }
                }
            }
        }

        // Reconnect any in-flight background download (e.g. after app relaunch)
        reconnectPendingTasks()

        // Migrate model files from per-app Application Support → shared container (runs once, background).
        let sharedDir = Self.resolveModelsDirectory(appGroupID: "group.app.chen.sharedllm")
        let legacyDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CHLocalModels")
        Task.detached(priority: .background) {
            Self.migrateModelFilesIfNeeded(from: legacyDir, to: sharedDir)
        }
    }

    // MARK: - Completion notification

    /// Fires a local "download complete" notification using app-specific copy.
    /// Title/body default to the active ``appIdentifier``'s strings and can be
    /// overridden via ``downloadCompletionTitle`` / ``downloadCompletionBody``.
    private func fireCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = downloadCompletionTitle ?? appIdentifier.defaultDownloadCompletionTitle
        content.body = downloadCompletionBody ?? appIdentifier.defaultDownloadCompletionBody
        content.sound = .default
        content.userInfo = ["destination": "ai-settings"]
        let request = UNNotificationRequest(
            identifier: appIdentifier.downloadCompletionNotificationIdentifier,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Storage

    private static func resolveModelsDirectory(appGroupID: String) -> URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CHLocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var modelsDirectory: URL {
        Self.resolveModelsDirectory(appGroupID: appGroupID)
    }

    public func modelURL(for model: LocalModelInfo) -> URL {
        modelsDirectory.appendingPathComponent("\(model.id).gguf")
    }

    // MARK: - Queries

    /// Returns true if the model file exists and is at least 80 % of the expected size.
    public func isInstalled(_ model: LocalModelInfo) -> Bool {
        let url = modelURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(fileSize) > model.sizeBytes * 4 / 5
    }

    public var installedModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { isInstalled($0) }
    }

    public var availableModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { !isInstalled($0) }
    }

    /// All models: catalog + user-added custom models.
    public var allModels: [LocalModelInfo] {
        LocalModelCatalog.all + customModels.map { localModelInfo(for: $0) }
    }

    /// Convert a CustomModelEntry to a LocalModelInfo for use in the download/install flow.
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

    /// The default catalog model if already installed, else nil.
    public var installedDefaultModel: LocalModelInfo? {
        isInstalled(LocalModelCatalog.default) ? LocalModelCatalog.default : nil
    }

    /// Total bytes used by installed models.
    public var totalStorageUsed: Int64 {
        installedModels.reduce(0) { acc, model in
            let url = modelURL(for: model)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return acc + Int64(size)
        }
    }

    // MARK: - Download

    public func downloadModel(_ model: LocalModelInfo) {
        switch downloadState {
        case .idle, .installed, .failed: break
        default: return  // don't interrupt an active download
        }
        activeDownloadModelID = model.id
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.sizeBytes)

        requestNotificationPermission()

        let task = bgDelegate.session.downloadTask(with: model.downloadURL)
        task.resume()
    }

    public func cancelDownload() {
        bgDelegate.session.getAllTasks { tasks in
            tasks.compactMap { $0 as? URLSessionDownloadTask }.forEach { task in
                task.cancel { resumeData in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.activeDownloadModelID = nil
                        if let data = resumeData {
                            self.downloadState = .paused(resumeData: data)
                        } else {
                            self.downloadState = .idle
                        }
                    }
                }
            }
        }
    }

    public func resumeDownload(model: LocalModelInfo, resumeData: Data) {
        guard case .paused = downloadState else { return }
        activeDownloadModelID = model.id
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.sizeBytes)

        let task = bgDelegate.session.downloadTask(withResumeData: resumeData)
        task.resume()
    }

    public func deleteModel(_ model: LocalModelInfo) {
        try? FileManager.default.removeItem(at: modelURL(for: model))
        if activeModelID == model.id {
            clearActiveModel()
        }
        if model.isCustom {
            customModels.removeAll { $0.id == model.id }
            persistCustomModels()
        }
    }

    // MARK: - Custom models

    /// Register a new custom model. Caller should then call downloadModel(_:) with localModelInfo(for:).
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

    /// Make `model` the active on-device provider. Registers `CHLocalLLMProvider` and persists the choice.
    public func setActiveModel(_ model: LocalModelInfo) {
        guard isInstalled(model) else { return }
        activeModelID = model.id
        sharedDefaults.set(model.id, forKey: Self.activeModelKey)
        let provider = CHLocalLLMProvider(
            modelURL: modelURL(for: model),
            modelInfo: model
        )
        CHAIManager.shared.registerProvider(provider)
        CHAIManager.shared.activeProviderID = CHLocalLLMProvider.providerID
    }

    /// Clear the active model selection (e.g. after deleting it).
    public func clearActiveModel() {
        activeModelID = nil
        sharedDefaults.removeObject(forKey: Self.activeModelKey)
    }

    /// Reset download state to idle (call after a failed download to allow retry).
    public func resetDownloadState() {
        downloadState = .idle
        activeDownloadModelID = nil
    }

    // MARK: - Background events

    /// Called by AppDelegate.handleEventsForBackgroundURLSession. Stores the system-provided
    /// completion handler so it can be called after all delegate callbacks have fired.
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == bgDelegate.sessionIdentifier else {
            completionHandler()
            return
        }
        bgDelegate.backgroundCompletionHandler = completionHandler
        // Session was already created at init, but ensure it's alive
        _ = bgDelegate.session
    }

    // MARK: - Private helpers

    private func reconnectPendingTasks() {
        bgDelegate.session.getAllTasks { [weak self] tasks in
            guard let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first else { return }
            guard let url = task.originalRequest?.url,
                  let model = LocalModelCatalog.all.first(where: { $0.downloadURL == url }) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeDownloadModelID = model.id
                let written = task.countOfBytesReceived
                let expected = task.countOfBytesExpectedToReceive
                let total = expected > 0 ? expected : model.sizeBytes
                let progress = total > 0 ? Double(written) / Double(total) : 0
                self.downloadState = .downloading(progress: progress, bytesReceived: written, totalBytes: total)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Legacy file migration

    /// Moves GGUF files from the old per-app Application Support path to the shared group container.
    /// Called once at init on a background task. Idempotent: safe to call repeatedly.
    /// - If shared copy already exists, deletes the per-app copy to reclaim disk space.
    /// - If only per-app copy exists, moves it atomically to shared location.
    private static func migrateModelFilesIfNeeded(from legacyDir: URL, to sharedDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDir.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: [.fileSizeKey])
            for file in files where file.pathExtension == "gguf" {
                let dest = sharedDir.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    // Shared copy already present — remove stale per-app copy
                    try? fm.removeItem(at: file)
                } else {
                    // Only per-app copy exists — move to shared container
                    try fm.moveItem(at: file, to: dest)
                }
            }
            // Remove empty legacy directory
            let remaining = try? fm.contentsOfDirectory(atPath: legacyDir.path)
            if remaining?.isEmpty == true {
                try? fm.removeItem(at: legacyDir)
            }
        } catch { /* non-fatal: model will re-download if needed */ }
    }
}

// MARK: - CustomModelEntry

/// A user-supplied model added via URL. Persisted in UserDefaults as JSON.
public struct CustomModelEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    public let chatTemplate: LocalModelInfo.ChatTemplate
}

// MARK: - BackgroundDownloadDelegate

/// Persistent URLSession delegate for background model downloads.
/// A single instance lives for the app's lifetime to ensure iOS can always deliver callbacks.
public final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Session identifier — derived from appGroupID so each app gets a unique background session.
    /// e.g. "group.app.chen.sharedllm" → "app.chen.sharedllm.llm-download"
    public let sessionIdentifier: String

    /// Set by AppDelegate.handleEventsForBackgroundURLSession; called in urlSessionDidFinishEvents.
    public var backgroundCompletionHandler: (() -> Void)?

    /// Callback bridge to LocalModelStore (set at store init).
    var onStateChange: ((ModelDownloadState, String?) -> Void)?

    /// Closure that resolves the models directory lazily — called when a download finishes.
    private let resolveModelsDir: () -> URL

    public private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(resolveModelsDir: @escaping () -> URL, appGroupID: String = "group.app.chen.sharedllm") {
        self.resolveModelsDir = resolveModelsDir
        // Derive a per-app session ID from the app group, e.g.:
        // "group.app.chen.sharedllm" → "app.chen.sharedllm.llm-download"
        let stripped = appGroupID.hasPrefix("group.") ? String(appGroupID.dropFirst("group.".count)) : appGroupID
        self.sessionIdentifier = "\(stripped).llm-download"
    }

    // MARK: Helpers

    private func modelInfo(for task: URLSessionDownloadTask) -> LocalModelInfo? {
        guard let url = task.originalRequest?.url else { return nil }
        return LocalModelCatalog.all.first { $0.downloadURL == url }
    }

    private func destURL(for model: LocalModelInfo) -> URL {
        resolveModelsDir().appendingPathComponent("\(model.id).gguf")
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let modelID = modelInfo(for: downloadTask)?.id
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onStateChange?(.downloading(progress: progress, bytesReceived: totalBytesWritten, totalBytes: total), modelID)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let model = modelInfo(for: downloadTask) else {
            onStateChange?(.failed("Internal error: unrecognized download URL"), nil)
            return
        }
        let dest = destURL(for: model)
        onStateChange?(.installing, model.id)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onStateChange?(.installed, model.id)
        } catch {
            onStateChange?(.failed("Failed to save model: \(error.localizedDescription)"), model.id)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        let modelID = (task as? URLSessionDownloadTask).flatMap { modelInfo(for: $0)?.id }
        onStateChange?(.failed(error.localizedDescription), modelID)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
