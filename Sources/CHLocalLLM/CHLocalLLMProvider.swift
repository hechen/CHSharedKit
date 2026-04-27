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

    /// True when the model container is loaded and the next `sendMessage`
    /// will be warm (sub-second prompt-to-first-token). Driven by the
    /// internal `_container` cache. False after init, after `setActiveModel`,
    /// and during in-flight load — call ``warmUp()`` to flip it to true
    /// without generating tokens.
    public var isModelLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _container != nil
    }

    /// Rough seconds-until-first-token estimate for the currently active
    /// model. When the model isn't loaded yet, this is the cold-start window
    /// (model size × per-GB load time, minimum 1.5 s — see
    /// ``CHLocalMLXColdStart``). When loaded, returns ~0.5 s for the
    /// generation-only path. Use to drive UI: `if estimate > 2 { show
    /// "Warming up…" }` and otherwise show a normal spinner.
    public var coldStartLatencyEstimate: TimeInterval {
        if isModelLoaded { return 0.5 }
        return CHLocalMLXColdStart.estimate(forBytes: modelInfo.sizeBytes)
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
        let t0 = Date()
        print("[CHLocalLLM] performLoad start id=\(info.id) name=\(info.displayName) url=\(url.path)")

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            print("[CHLocalLLM] performLoad ERROR: directory missing at \(url.path)")
            throw CHAIError.modelLoadFailed(
                "Model files for \(info.displayName) are missing. Re-download from Settings → AI Provider."
            )
        }
        let configURL = url.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configURL.path) else {
            print("[CHLocalLLM] performLoad ERROR: config.json missing at \(configURL.path)")
            throw CHAIError.modelLoadFailed(
                "Model snapshot for \(info.displayName) is incomplete (missing config.json). Re-download to fix."
            )
        }
        // Surface every file the snapshot has — when Chen's report says
        // "Qwen 2.5 doesn't work", this single line in the device console
        // reveals whether the snapshot is missing tokenizer.json,
        // model.safetensors, or any other expected MLX input.
        let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let safetensorsCount = entries.filter { $0.hasSuffix(".safetensors") }.count
        let hasTokenizer = entries.contains("tokenizer.json")
        let hasTokenizerConfig = entries.contains("tokenizer_config.json")
        print("[CHLocalLLM] performLoad files: total=\(entries.count) safetensors=\(safetensorsCount) tokenizer.json=\(hasTokenizer) tokenizer_config.json=\(hasTokenizerConfig)")

        await MainActor.run {
            NotificationCenter.default.post(
                name: .chLocalLLMWillLoad, object: nil,
                userInfo: ["modelName": info.displayName]
            )
        }

        do {
            print("[CHLocalLLM] performLoad calling LLMModelFactory.shared.loadContainer (this is the cold-start step, ~3-8 s on Apple Silicon)")
            let configuration = ModelConfiguration(directory: url)
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: CHLocalMLXStorage.hubApi(),
                configuration: configuration,
                progressHandler: { _ in }
            )
            let elapsed = Date().timeIntervalSince(t0)
            print("[CHLocalLLM] performLoad SUCCESS id=\(info.id) elapsed=\(String(format: "%.2f", elapsed))s")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .chLocalLLMDidLoad, object: nil,
                    userInfo: ["modelName": info.displayName]
                )
            }
            return container
        } catch {
            let nserror = error as NSError
            print("[CHLocalLLM] performLoad ERROR id=\(info.id) domain=\(nserror.domain) code=\(nserror.code) desc=\(nserror.localizedDescription)")
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
        let t0 = Date()
        let modelID = modelInfo.id
        print("[CHLocalLLM] sendMessage start id=\(modelID) prompt.count=\(prompt.count) systemPrompt.set=\(systemPrompt != nil)")
        do {
            let result = try await runChat(prompt: prompt, systemPrompt: systemPrompt)
            try Task.checkCancellation()
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                print("[CHLocalLLM] sendMessage ERROR id=\(modelID) reason=empty-response elapsed=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
                throw CHAIError.invalidResponse
            }
            print("[CHLocalLLM] sendMessage SUCCESS id=\(modelID) chars=\(trimmed.count) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            return trimmed
        } catch let e as CHAIError {
            print("[CHLocalLLM] sendMessage ERROR id=\(modelID) CHAIError=\(e.errorDescription ?? "nil")")
            throw e
        } catch is CancellationError {
            print("[CHLocalLLM] sendMessage CANCELLED id=\(modelID)")
            throw CancellationError()
        } catch {
            print("[CHLocalLLM] sendMessage ERROR id=\(modelID) underlying=\(error.localizedDescription)")
            throw CHAIError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// 2.5.6: eager-load the model container without generating anything.
    ///
    /// Call from view-appear of an AI feature, or right after
    /// `setActiveModel(...)`, so the expensive cold-start (~3-8 s for
    /// Qwen 2.5 3B on Apple Silicon) happens BEFORE the user triggers
    /// the feature. Without this, the first `sendMessage` on a
    /// freshly-activated provider blocks for that whole cold-start
    /// window — visually indistinguishable from a hang. TrainInsight
    /// hit exactly this on first use.
    ///
    /// Idempotent. Safe to call multiple times concurrently — the
    /// underlying load task is shared. No-op if the container is
    /// already loaded. Cancellation-safe: if the calling Task is
    /// cancelled, the load itself continues in the background so the
    /// next `sendMessage` is still warm.
    public func warmUp() async throws {
        print("[CHLocalLLM] warmUp start id=\(modelInfo.id) alreadyLoaded=\(isModelLoaded)")
        _ = try await container()
        print("[CHLocalLLM] warmUp complete id=\(modelInfo.id)")
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
