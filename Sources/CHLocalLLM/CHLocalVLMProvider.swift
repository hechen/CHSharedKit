import Foundation
import CoreImage
import CHSharedKit
import Hub
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

// MARK: - Vision provider

/// On-device vision-language provider backed by Apple MLX (`MLXVLM`).
///
/// Same shape as ``CHLocalLLMProvider`` but loads via `VLMModelFactory.shared`
/// and accepts `imageData` in `sendVisionMessage(prompt:imageData:)`.
public final class CHLocalVLMProvider: @unchecked Sendable {
    public static let providerID = "on-device-vlm"

    public var generateParameters: GenerateParameters = .init()

    private let lock = NSLock()
    private var _modelURL: URL
    private var _modelInfo: LocalModelInfo
    private var _container: ModelContainer?
    private var _loadTask: Task<ModelContainer, Error>?

    // MARK: - Init

    @MainActor
    public convenience init() {
        let info = LocalModelCatalog.qwen2VL_2B
        let url = LocalModelStore.shared.modelURL(for: info)
        self.init(modelURL: url, modelInfo: info)
    }

    @MainActor
    public convenience init(modelInfo: LocalModelInfo) {
        let url = LocalModelStore.shared.modelURL(for: modelInfo)
        self.init(modelURL: url, modelInfo: modelInfo)
    }

    public init(modelURL: URL, modelInfo: LocalModelInfo) {
        self._modelURL = modelURL
        self._modelInfo = modelInfo
    }

    // MARK: - Public API

    public var modelInfo: LocalModelInfo {
        lock.lock(); defer { lock.unlock() }
        return _modelInfo
    }

    public var modelURL: URL {
        lock.lock(); defer { lock.unlock() }
        return _modelURL
    }

    public var coldStartLatencyEstimate: TimeInterval {
        CHLocalMLXColdStart.estimate(forBytes: modelInfo.sizeBytes)
    }

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

    // MARK: - Loading

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
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.json").path
        ) else {
            throw CHAIError.modelLoadFailed(
                String(localized: "Model snapshot for \(info.displayName) is missing or incomplete. Re-download from Settings → AI Provider.", bundle: .module)
            )
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .chLocalLLMWillLoad, object: nil,
                userInfo: ["modelName": info.displayName]
            )
        }

        do {
            let container = try await VLMModelFactory.shared.loadContainer(
                from: url,
                using: #huggingFaceTokenizerLoader()
            )
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .chLocalLLMDidLoad, object: nil,
                    userInfo: ["modelName": info.displayName]
                )
            }
            return container
        } catch {
            let lowered = (error as NSError).localizedDescription.lowercased()
            if lowered.contains("memory") || lowered.contains("alloc") {
                throw CHAIError.modelLoadFailed(
                    String(localized: "Insufficient memory — close other apps and try again.", bundle: .module)
                )
            }
            throw CHAIError.modelLoadFailed(
                String(localized: "Could not load \(info.displayName): \(error.localizedDescription)", bundle: .module)
            )
        }
    }
}

// MARK: - CHAIProvider conformance

extension CHLocalVLMProvider: CHAIProvider {
    public var id: String { Self.providerID }
    public var displayName: String { String(localized: "On-Device Vision", bundle: .module) }
    public var supportsVision: Bool { true }

    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        let container = try await container()
        let turn = CHLocalLLMProvider.turn(
            prompt: prompt, systemPrompt: systemPrompt, template: CHLocalLLMProvider.chatTemplate(at: modelURL)
        )
        let prompt = turn.prompt
        let session = ChatSession(
            container,
            instructions: turn.instructions,
            generateParameters: generateParameters,
            additionalContext: CHLocalLLMProvider.templateContext
        )
        let result = try await session.respond(to: prompt)
        try Task.checkCancellation()
        let trimmed = CHLocalLLMOutputFilter.clean(result)
        if trimmed.isEmpty { throw CHAIError.invalidResponse }
        return trimmed
    }

    public func sendVisionMessage(prompt: String, imageData: Data) async throws -> String {
        guard let ciImage = CIImage(data: imageData) else {
            throw CHAIError.invalidResponse
        }
        let container = try await container()
        let session = ChatSession(
            container,
            generateParameters: generateParameters,
            additionalContext: CHLocalLLMProvider.templateContext
        )
        let result = try await session.respond(to: prompt, image: .ciImage(ciImage))
        try Task.checkCancellation()
        let trimmed = CHLocalLLMOutputFilter.clean(result)
        if trimmed.isEmpty { throw CHAIError.invalidResponse }
        return trimmed
    }

    public func validate() async throws -> Bool {
        try CHLocalMLXPlatform.requireSupported()
        return FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("config.json").path
        )
    }

    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        let container = try await container()
        let turn = CHLocalLLMProvider.turn(
            prompt: prompt, systemPrompt: systemPrompt, template: CHLocalLLMProvider.chatTemplate(at: modelURL)
        )
        let prompt = turn.prompt
        let session = ChatSession(
            container,
            instructions: turn.instructions,
            generateParameters: generateParameters,
            additionalContext: CHLocalLLMProvider.templateContext
        )
        let upstream = session.streamResponse(to: prompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var filter = CHLocalLLMOutputFilter()
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        let shown = filter.feed(chunk)
                        if !shown.isEmpty { continuation.yield(shown) }
                        if filter.isFinished { break }
                    }
                    let rest = filter.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
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
