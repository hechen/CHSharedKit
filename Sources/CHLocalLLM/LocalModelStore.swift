import Foundation
import Observation

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

    private var downloadHelper: DownloadHelper?

    private init() {}

    // MARK: - Storage

    private var modelsDirectory: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CHLocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

        let destURL = modelURL(for: model)
        let helper = DownloadHelper(downloadURL: model.downloadURL, destURL: destURL) { [weak self] state in
            Task { @MainActor [weak self] in
                self?.downloadState = state
                if case .installed = state { self?.activeDownloadModelID = nil }
                if case .failed = state { self?.activeDownloadModelID = nil }
            }
        }
        downloadHelper = helper
        helper.start()
    }

    public func cancelDownload() {
        downloadHelper?.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                self?.activeDownloadModelID = nil
                if let data = resumeData {
                    self?.downloadState = .paused(resumeData: data)
                } else {
                    self?.downloadState = .idle
                }
            }
        }
    }

    public func resumeDownload(model: LocalModelInfo, resumeData: Data) {
        guard case .paused = downloadState else { return }
        activeDownloadModelID = model.id
        downloadState = .downloading(progress: 0, bytesReceived: 0, totalBytes: model.fileSizeBytes)

        let destURL = modelURL(for: model)
        let helper = DownloadHelper(downloadURL: model.downloadURL, destURL: destURL) { [weak self] state in
            Task { @MainActor [weak self] in
                self?.downloadState = state
                if case .installed = state { self?.activeDownloadModelID = nil }
                if case .failed = state { self?.activeDownloadModelID = nil }
            }
        }
        downloadHelper = helper
        helper.resume(resumeData: resumeData)
    }

    public func deleteModel(_ model: LocalModelInfo) {
        try? FileManager.default.removeItem(at: modelURL(for: model))
    }

    /// Reset download state to idle (call after a failed download to allow retry).
    public func resetDownloadState() {
        downloadHelper = nil
        downloadState = .idle
    }
}

// MARK: - DownloadHelper (URLSession delegate, runs off-main-thread)

private final class DownloadHelper: NSObject, URLSessionDownloadDelegate {
    private let downloadURL: URL
    private let destURL: URL
    private let onStateChange: (ModelDownloadState) -> Void

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionDownloadTask?

    init(downloadURL: URL, destURL: URL, onStateChange: @escaping (ModelDownloadState) -> Void) {
        self.downloadURL = downloadURL
        self.destURL = destURL
        self.onStateChange = onStateChange
    }

    func start() {
        task = session.downloadTask(with: downloadURL)
        task?.resume()
    }

    func resume(resumeData: Data) {
        task = session.downloadTask(withResumeData: resumeData)
        task?.resume()
    }

    func cancel(completion: @escaping (Data?) -> Void) {
        task?.cancel(byProducingResumeData: completion)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onStateChange(.downloading(progress: progress, bytesReceived: totalBytesWritten, totalBytes: total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        onStateChange(.installing)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            onStateChange(.installed)
        } catch {
            onStateChange(.failed("Failed to save model: \(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return } // user-initiated cancel
        onStateChange(.failed(error.localizedDescription))
    }
}
