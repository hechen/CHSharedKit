import Foundation
import LLM
import CHSharedKit

// MARK: - Notifications

public extension Notification.Name {
    /// Posted on the main thread when the on-device model begins loading into memory.
    /// userInfo: ["modelName": String]
    static let chLocalLLMWillLoad  = Notification.Name("CHLocalLLMWillLoad")
    /// Posted when the model finishes loading and is ready to accept prompts.
    static let chLocalLLMDidLoad   = Notification.Name("CHLocalLLMDidLoad")
    /// Posted when the model is unloaded to reclaim RAM after idle timeout.
    static let chLocalLLMDidUnload = Notification.Name("CHLocalLLMDidUnload")
}

// MARK: - Provider

/// On-device AI provider backed by llama.cpp via LLM.swift.
///
/// Loads the GGUF model lazily on first request, keeps it warm for 30 s,
/// then unloads to free RAM.
///
/// Register with ``CHAIManager``:
/// ```swift
/// let provider = CHLocalLLMProvider(modelURL: url, modelInfo: .default)
/// CHAIManager.shared.registerProvider(provider)
/// ```
public final class CHLocalLLMProvider: @unchecked Sendable {
    public static let providerID = "on-device-llm"

    private let modelURL: URL
    private let modelInfo: LocalModelInfo
    private let idleInterval: TimeInterval

    // Protected by lock to avoid data races when accessed from multiple async contexts
    private let lock = NSLock()
    private var _bot: LLM?
    private var _idleTask: Task<Void, Never>?

    /// - Parameters:
    ///   - modelURL: Path to the GGUF model file on disk.
    ///   - modelInfo: Catalog entry for this model (drives template selection).
    ///   - idleInterval: Seconds before the model is unloaded from memory. Default: 30 s.
    public init(modelURL: URL, modelInfo: LocalModelInfo, idleInterval: TimeInterval = 30) {
        self.modelURL = modelURL
        self.modelInfo = modelInfo
        self.idleInterval = idleInterval
    }
}

// MARK: - CHAIProvider conformance

extension CHLocalLLMProvider: CHAIProvider {
    public var id: String { Self.providerID }
    public var displayName: String { "On-Device AI (\(modelInfo.displayName))" }
    public var supportsVision: Bool { false }

    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        let bot = try await loadBotIfNeeded()
        rescheduleIdleUnload()

        // Build the full prompt manually so getCompletion (which bypasses preprocess)
        // receives a correctly-formatted chat string with the right control tokens.
        let formatted = formattedPrompt(user: prompt, system: systemPrompt)
        let response = await bot.getCompletion(from: formatted)

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw CHAIError.invalidResponse }
        return trimmed
    }

    public func validate() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        let readable = (try? modelURL.resourceValues(forKeys: [.isReadableKey]))?.isReadable ?? false
        return readable
    }
}

// MARK: - Private helpers

private extension CHLocalLLMProvider {

    // MARK: Model lifecycle

    func loadBotIfNeeded() async throws -> LLM {
        lock.lock()
        if let existing = _bot {
            lock.unlock()
            return existing
        }
        lock.unlock()

        // Cold-start: notify UI so it can show "Starting on-device AI…"
        await MainActor.run {
            NotificationCenter.default.post(
                name: .chLocalLLMWillLoad,
                object: nil,
                userInfo: ["modelName": modelInfo.displayName]
            )
        }

        let template = makeTemplate(for: modelInfo, systemPrompt: nil)
        let localURL = modelURL

        // llama_model_load_from_file() reads the entire GGUF file synchronously and
        // can block for many seconds on large models. After `await MainActor.run`
        // above, the caller may remain on the main thread depending on the call chain,
        // which would trigger the scene-update watchdog (0x8BADF00D). Detach so this
        // always runs on the cooperative thread pool regardless of the calling context.
        let botOptional: LLM? = await Task.detached(priority: .userInitiated) {
            LLM(from: localURL, template: template, maxTokenCount: 2048)
        }.value
        guard let bot = botOptional else {
            throw CHAIError.networkError(
                NSError(domain: "CHLocalLLM", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load model from \(localURL.lastPathComponent)"])
            )
        }

        lock.lock()
        _bot = bot
        lock.unlock()

        await MainActor.run {
            NotificationCenter.default.post(name: .chLocalLLMDidLoad, object: nil)
        }

        return bot
    }

    func rescheduleIdleUnload() {
        lock.lock()
        _idleTask?.cancel()
        let timeout = idleInterval
        _idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.unloadBot()
        }
        lock.unlock()
    }

    func unloadBot() {
        lock.lock()
        let wasLoaded = _bot != nil
        _bot = nil
        _idleTask = nil
        lock.unlock()

        if wasLoaded {
            Task { @MainActor in
                NotificationCenter.default.post(name: .chLocalLLMDidUnload, object: nil)
            }
        }
    }

    // MARK: Prompt formatting

    /// Formats a chat turn into the model-specific control-token format.
    /// `getCompletion` calls `core.generateResponseStream` directly, bypassing
    /// `LLM.preprocess`, so we must apply the template ourselves.
    func formattedPrompt(user: String, system: String?) -> String {
        switch modelInfo.chatTemplate {

        case .llama3:
            // Llama 3 instruct format
            var out = "<|begin_of_text|>"
            if let sys = system, !sys.isEmpty {
                out += "<|start_header_id|>system<|end_header_id|>\n\n\(sys)<|eot_id|>"
            }
            out += "<|start_header_id|>user<|end_header_id|>\n\n\(user)<|eot_id|>"
            out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
            return out

        case .chatML:
            // ChatML used by Qwen 2.5, Phi, etc.
            var out = ""
            if let sys = system, !sys.isEmpty {
                out += "<|im_start|>system\n\(sys)<|im_end|>\n"
            }
            out += "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
            return out

        case .llama2:
            // Llama 2 / Mistral instruct
            var out = "<s>[INST] "
            if let sys = system, !sys.isEmpty {
                out += "<<SYS>>\n\(sys)\n<</SYS>>\n\n"
            }
            out += "\(user) [/INST]"
            return out

        case .gemma:
            // Gemma 2 instruct (no dedicated system turn; prepend to user if provided)
            var out = ""
            let userContent = (system.map { "\($0)\n\n" } ?? "") + user
            out += "<start_of_turn>user\n\(userContent)<end_of_turn>\n"
            out += "<start_of_turn>model\n"
            return out
        }
    }

    // MARK: Template (for stop-sequence wiring via LLM init)

    func makeTemplate(for model: LocalModelInfo, systemPrompt: String?) -> Template {
        switch model.chatTemplate {
        case .llama3:
            return Template(
                system: ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
                user: ("<|start_header_id|>user<|end_header_id|>\n\n", "<|eot_id|>"),
                bot: ("<|start_header_id|>assistant<|end_header_id|>\n\n", "<|eot_id|>"),
                stopSequence: "<|eot_id|>",
                systemPrompt: systemPrompt
            )
        case .chatML:
            return Template.chatML(systemPrompt)
        case .llama2:
            return Template.llama(systemPrompt)
        case .gemma:
            return Template(
                system: nil,
                user: ("<start_of_turn>user\n", "<end_of_turn>\n"),
                bot: ("<start_of_turn>model\n", "<end_of_turn>\n"),
                stopSequence: "<end_of_turn>",
                systemPrompt: systemPrompt
            )
        }
    }
}
