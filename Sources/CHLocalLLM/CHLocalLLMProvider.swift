import Foundation
import CHSharedKit
import Hub
import MLXLMCommon
import MLXLLM

// MARK: - Notifications

public extension Notification.Name {
    /// Posted on the main thread when the on-device model begins loading into memory.
    /// userInfo: ["modelName": String]
    static let chLocalLLMWillLoad  = Notification.Name("CHLocalLLMWillLoad")
    /// Posted when the model finishes loading and is ready to accept prompts.
    static let chLocalLLMDidLoad   = Notification.Name("CHLocalLLMDidLoad")
    /// Posted when the model is unloaded (e.g. the provider is released).
    static let chLocalLLMDidUnload = Notification.Name("CHLocalLLMDidUnload")
}

// MARK: - Provider

/// On-device AI provider backed by Apple MLX (`MLXLLM` / `MLXLMCommon`).
///
/// Loads a quantized model from `modelURL` lazily on first request. The model
/// stays resident in the underlying `ModelContainer` until the provider is
/// released — there is no automatic idle unload in 2.5.0 (apps that need to
/// reclaim RAM should drop their reference to the provider and re-create it
/// on next use).
///
/// Construct via:
/// ```swift
/// let provider = CHLocalLLMProvider() // uses LocalModelCatalog.default
/// // or:
/// let provider = CHLocalLLMProvider(modelInfo: LocalModelCatalog.qwen2_5_3B)
/// // or, with an explicit on-disk directory:
/// let provider = CHLocalLLMProvider(modelURL: dir, modelInfo: info)
/// ```
public final class CHLocalLLMProvider: @unchecked Sendable {
    public static let providerID = "on-device-llm"

    /// Per-call generation parameters. Defaults match `GenerateParameters.init()`.
    public var generateParameters: GenerateParameters = .init()

    private let lock = NSLock()
    private var _modelURL: URL
    private var _modelInfo: LocalModelInfo
    private let idleInterval: TimeInterval
    private var _container: ModelContainer?
    private var _loadTask: Task<ModelContainer, Error>?

    // MARK: - Init

    /// Default initializer — uses ``LocalModelCatalog/default`` and resolves the
    /// on-disk path via ``LocalModelStore/shared``. Useful for apps that want a
    /// no-arg construction at launch.
    @MainActor
    public convenience init() {
        let info = LocalModelCatalog.default
        let url = LocalModelStore.shared.modelURL(for: info)
        self.init(modelURL: url, modelInfo: info, idleInterval: 30)
    }

    /// Construct from a catalog descriptor; resolves the on-disk path via
    /// ``LocalModelStore/shared``.
    @MainActor
    public convenience init(modelInfo: LocalModelInfo) {
        let url = LocalModelStore.shared.modelURL(for: modelInfo)
        self.init(modelURL: url, modelInfo: modelInfo, idleInterval: 30)
    }

    /// Designated initializer.
    /// - Parameters:
    ///   - modelURL: Directory containing `config.json`, `tokenizer.json`, and
    ///     `*.safetensors`. Typically `LocalModelStore.shared.modelURL(for:)`.
    ///   - modelInfo: Catalog descriptor (drives display name and size).
    ///   - idleInterval: Retained for API parity with 2.4.x; unused in 2.5.0.
    public init(modelURL: URL, modelInfo: LocalModelInfo, idleInterval: TimeInterval = 30) {
        self._modelURL = modelURL
        self._modelInfo = modelInfo
        self.idleInterval = idleInterval
    }

    // MARK: - Public API

    /// The catalog descriptor for the currently active model.
    public var modelInfo: LocalModelInfo {
        lock.lock(); defer { lock.unlock() }
        return _modelInfo
    }

    /// The on-disk directory backing the currently active model.
    public var modelURL: URL {
        lock.lock(); defer { lock.unlock() }
        return _modelURL
    }

    /// Rough seconds-until-first-token estimate for the *currently active* model
    /// (cold start). Surface to UI so the spinner before the first token doesn't
    /// look like a hang.
    public var coldStartLatencyEstimate: TimeInterval {
        CHLocalMLXColdStart.estimate(forBytes: modelInfo.sizeBytes)
    }

    /// Switch to a different model at runtime. Drops the cached container so
    /// the next call to `sendMessage`/`stream` triggers a fresh load.
    /// Pass a model that's already installed; otherwise the next call will
    /// throw ``CHAIError/modelLoadFailed(_:)``.
    @MainActor
    public func setActiveModel(_ info: LocalModelInfo) {
        let url = LocalModelStore.shared.modelURL(for: info)
        lock.lock()
        _modelURL = url
        _modelInfo = info
        _container = nil
        _loadTask?.cancel()
        _loadTask = nil
        lock.unlock()
        NotificationCenter.default.post(
            name: .chLocalLLMDidUnload, object: nil,
            userInfo: ["modelName": info.displayName]
        )
    }

    deinit {
        _loadTask?.cancel()
    }

    // MARK: - Model loading

    /// Returns the cached container if loaded; otherwise kicks off a single
    /// load task (concurrent callers share the same task). All NSLock work
    /// happens in sync helpers; the async boundary is the `await task.value`
    /// outside any lock.
    private func container() async throws -> ModelContainer {
        try CHLocalMLXPlatform.requireSupported()

        if let cached = readCachedContainer() { return cached }
        let task = startOrJoinLoadTask()
        do {
            let container = try await task.value
            recordLoadedContainer(container)
            return container
        } catch {
            clearLoadTask()
            throw error
        }
    }

    private func readCachedContainer() -> ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return _container
    }

    /// Returns the in-flight load task if one already exists, otherwise
    /// installs and returns a freshly created one. Race-safe: a second caller
    /// that beat us to the lock will return the same task.
    private func startOrJoinLoadTask() -> Task<ModelContainer, Error> {
        lock.lock(); defer { lock.unlock() }
        if let pending = _loadTask { return pending }
        let url = _modelURL
        let info = _modelInfo
        let task = Task<ModelContainer, Error> {
            try await Self.performLoad(url: url, info: info)
        }
        _loadTask = task
        return task
    }

    private func recordLoadedContainer(_ container: ModelContainer) {
        lock.lock(); defer { lock.unlock() }
        _container = container
        _loadTask = nil
    }

    private func clearLoadTask() {
        lock.lock(); defer { lock.unlock() }
        _loadTask = nil
    }

    private static func performLoad(
        url: URL, info: LocalModelInfo
    ) async throws -> ModelContainer {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CHAIError.modelLoadFailed(
                "Model files for \(info.displayName) are missing. Re-download from Settings → AI Provider."
            )
        }
        let configURL = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CHAIError.modelLoadFailed(
                "Model snapshot for \(info.displayName) is incomplete (missing config.json). Re-download to fix."
            )
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .chLocalLLMWillLoad, object: nil,
                userInfo: ["modelName": info.displayName]
            )
        }

        do {
            let configuration = ModelConfiguration(directory: url)
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: CHLocalMLXStorage.hubApi(),
                configuration: configuration,
                progressHandler: { _ in }
            )
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .chLocalLLMDidLoad, object: nil,
                    userInfo: ["modelName": info.displayName]
                )
            }
            return container
        } catch {
            let nserror = error as NSError
            // MLX surfaces Metal allocation failures as runtime errors; the
            // most common phrasing on iOS is "out of memory" or "alloc".
            let lowered = nserror.localizedDescription.lowercased()
            if lowered.contains("memory") || lowered.contains("alloc") {
                throw CHAIError.modelLoadFailed(
                    "Insufficient memory — close other apps and try again."
                )
            }
            throw CHAIError.modelLoadFailed(
                "Could not load \(info.displayName): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Inference

    fileprivate func runChat(
        prompt: String, systemPrompt: String?
    ) async throws -> String {
        let container = try await container()
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: generateParameters
        )
        return try await session.respond(to: prompt)
    }

    fileprivate func runStream(
        prompt: String, systemPrompt: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let container = try await container()
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: generateParameters
        )
        return session.streamResponse(to: prompt)
    }
}

// MARK: - CHAIProvider conformance

extension CHLocalLLMProvider: CHAIProvider {
    public var id: String { Self.providerID }

    /// Provider-level display name — intentionally does NOT include the active
    /// model name. The model suffix is composed by `CHAIActiveProviderLabel`
    /// from `CHAIManager.activeModelDisplayName`, which is the single
    /// observable source of truth for "which on-device model is currently
    /// selected". Embedding the model name here caused the 2.4.4 stale-cell
    /// bug — see CHAIManager's 2.4.5 notes.
    public var displayName: String { "On-Device AI" }
    public var supportsVision: Bool { false }

    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        do {
            let result = try await runChat(prompt: prompt, systemPrompt: systemPrompt)
            try Task.checkCancellation()
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw CHAIError.invalidResponse }
            return trimmed
        } catch let e as CHAIError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CHAIError.modelLoadFailed(error.localizedDescription)
        }
    }

    public func validate() async throws -> Bool {
        try CHLocalMLXPlatform.requireSupported()
        return FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("config.json").path
        )
    }

    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        let upstream = try await runStream(prompt: prompt, systemPrompt: systemPrompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
