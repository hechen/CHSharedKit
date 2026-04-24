import Foundation
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

/// On-device AI provider placeholder.
///
/// The underlying llama.cpp backend (LLM.swift) is temporarily unavailable.
/// This stub preserves the public API so apps that reference the type still
/// compile, but all inference calls throw ``CHAIError.networkError``.
public final class CHLocalLLMProvider: @unchecked Sendable {
    public static let providerID = "on-device-llm"

    private let modelURL: URL
    private let modelInfo: LocalModelInfo
    private let idleInterval: TimeInterval

    /// - Parameters:
    ///   - modelURL: Path to the GGUF model file on disk.
    ///   - modelInfo: Catalog entry for this model.
    ///   - idleInterval: Seconds before the model is unloaded. Retained for API parity.
    public init(modelURL: URL, modelInfo: LocalModelInfo, idleInterval: TimeInterval = 30) {
        self.modelURL = modelURL
        self.modelInfo = modelInfo
        self.idleInterval = idleInterval
    }
}

// MARK: - CHAIProvider conformance

extension CHLocalLLMProvider: CHAIProvider {
    public var id: String { Self.providerID }

    /// Provider-level display name — intentionally does NOT include the
    /// active model name. The model suffix is composed by
    /// `CHAIActiveProviderLabel` from `CHAIManager.activeModelDisplayName`,
    /// which is the single observable source of truth for "which
    /// on-device model is currently selected". Embedding the model name
    /// here caused the 2.4.4 stale-cell bug: the provider instance
    /// captured `modelInfo.displayName` at construction, so after
    /// `LocalModelStore.setActiveModel(newModel)` replaced the dict
    /// entry, any view that read `manager.activeProvider?.displayName`
    /// without a direct dependency on `activeModelDisplayName` kept
    /// rendering the old name. See CHAIManager's 2.4.5 notes.
    public var displayName: String { "On-Device AI" }
    public var supportsVision: Bool { false }

    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        throw Self.unavailableError()
    }

    public func validate() async throws -> Bool {
        false
    }

    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw Self.unavailableError()
    }

    private static func unavailableError() -> Error {
        CHAIError.networkError(
            NSError(
                domain: "CHLocalLLM",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "On-device LLM backend is temporarily unavailable."]
            )
        )
    }
}
