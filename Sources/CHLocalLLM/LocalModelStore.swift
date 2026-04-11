import Foundation
import Observation
import UserNotifications

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

    // Configuration — apps can override appGroupID before first use
    public var appGroupID: String = "group.app.chen.distill"

    // Background session delegate — persists for app lifetime so iOS can reconnect downloads
    let bgDelegate: BackgroundDownloadDelegate

    private init() {
        let modelsDir = Self.resolveModelsDirectory(appGroupID: "group.app.chen.distill")
        bgDelegate = BackgroundDownloadDelegate(modelsDirectory: modelsDir)
        // Eagerly create the session — must happen before iOS delivers background events
        _ = bgDelegate.session

        bgDelegate.onStateChange = { [weak self] state, modelID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadState = state
                switch state {
                case .installed, .failed:
                    self.activeDownloadModelID = nil
                case .downloading, .installing, .paused, .idle:
                    if let modelID { self.activeDownloadModelID = modelID }
                }
            }
        }

        // Reconnect any in-flight background download (e.g. after app relaunch)
        reconnectPendingTasks()
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
        return Int64(fileSize) > model.fileSizeBytes * 4 / 5
    }

    public var installedModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { isInstalled($0) }
    }

    public var availableModels: [LocalModelInfo] {
        LocalModelCatalog.all.filter { !isInstalled($0) }
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
        guard case .idle = downloadState else { return }
        activeDownloadModelID = model.id
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.fileSizeBytes)

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
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.fileSizeBytes)

        let task = bgDelegate.session.downloadTask(withResumeData: resumeData)
        task.resume()
    }

    public func deleteModel(_ model: LocalModelInfo) {
        try? FileManager.default.removeItem(at: modelURL(for: model))
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
        guard identifier == BackgroundDownloadDelegate.sessionIdentifier else {
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
                let total = expected > 0 ? expected : model.fileSizeBytes
                let progress = total > 0 ? Double(written) / Double(total) : 0
                self.downloadState = .downloading(progress: progress, bytesReceived: written, totalBytes: total)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - BackgroundDownloadDelegate

/// Persistent URLSession delegate for background model downloads.
/// A single instance lives for the app's lifetime to ensure iOS can always deliver callbacks.
public final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public static let sessionIdentifier = "app.chen.distill.llm-download"

    /// Set by AppDelegate.handleEventsForBackgroundURLSession; called in urlSessionDidFinishEvents.
    public var backgroundCompletionHandler: (() -> Void)?

    /// Callback bridge to LocalModelStore (set at store init).
    var onStateChange: ((ModelDownloadState, String?) -> Void)?

    private let modelsDirectory: URL

    public private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: Helpers

    private func modelInfo(for task: URLSessionDownloadTask) -> LocalModelInfo? {
        guard let url = task.originalRequest?.url else { return nil }
        return LocalModelCatalog.all.first { $0.downloadURL == url }
    }

    private func destURL(for model: LocalModelInfo) -> URL {
        modelsDirectory.appendingPathComponent("\(model.id).gguf")
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
            fireCompletionNotification()
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

    // MARK: Notification

    private func fireCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Model Ready"
        content.body = "On-device AI is ready. Distill can now summarize articles offline."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "app.chen.distill.llm.ready",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
