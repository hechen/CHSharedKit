import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AI Service Manager

/// Central manager for AI providers. Handles provider selection, key storage, and requests.
@MainActor
public final class CHAIManager: ObservableObject {
    public static let shared = CHAIManager()
    
    @Published public var activeProviderID: String {
        didSet { UserDefaults.standard.set(activeProviderID, forKey: "clawd_ai_active_provider") }
    }
    @Published public var isProcessing = false
    @Published public var lastError: String?
    
    private var providers: [String: any CHAIProvider] = [:]
    
    private init() {
        // Check if Apple Intelligence is available and default to it, otherwise use OpenAI
        let defaultProvider: String
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            defaultProvider = SystemLanguageModel.default.isAvailable ? CHAppleIntelligenceProvider.providerID : CHOpenAIProvider.providerID
        } else {
            defaultProvider = CHOpenAIProvider.providerID
        }
        #else
        defaultProvider = CHOpenAIProvider.providerID
        #endif
        
        self.activeProviderID = UserDefaults.standard.string(forKey: "clawd_ai_active_provider") ?? defaultProvider
        registerBuiltInProviders()
    }
    
    private func registerBuiltInProviders() {
        // Always register Apple Intelligence (it checks availability internally)
        let apple = CHAppleIntelligenceProvider()
        providers[apple.id] = apple
        
        let openai = CHOpenAIProvider()
        providers[openai.id] = openai
        
        let claude = CHClaudeProvider()
        providers[claude.id] = claude
        
        let custom = CHCustomEndpointProvider()
        providers[custom.id] = custom
    }
    
    /// Register a custom provider
    public func registerProvider(_ provider: any CHAIProvider) {
        providers[provider.id] = provider
    }
    
    /// Currently active provider
    public var activeProvider: (any CHAIProvider)? {
        providers[activeProviderID]
    }
    
    /// List of available providers with their IDs and names
    public var availableProviders: [(id: String, name: String)] {
        providers.values.map { (id: $0.id, name: $0.displayName) }.sorted { $0.name < $1.name }
    }
    
    /// Check if Apple Intelligence is available
    public var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
    
    /// Send a text message using the active provider
    public func send(prompt: String, systemPrompt: String? = nil) async throws -> String {
        guard let provider = activeProvider else {
            throw CHAIError.noProvider
        }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let result = try await provider.sendMessage(prompt: prompt, systemPrompt: systemPrompt)
            // Estimate tokens and log usage
            let inputTokens = (prompt.count + (systemPrompt?.count ?? 0)) / 4
            let outputTokens = result.count / 4
            let tracker = CHAIUsageTracker.shared
            let cost = tracker.logRequest(
                provider: provider.displayName,
                model: provider.id,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            // Log cost to activity log for visibility
            logAICost(provider: provider.displayName, model: provider.id, inputTokens: inputTokens, outputTokens: outputTokens, cost: cost, isVision: false)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Stream a text response using the active provider. Returns an
    /// `AsyncThrowingStream` that yields text deltas as the provider produces
    /// them (or a single chunk for providers that don't support streaming).
    public func stream(prompt: String, systemPrompt: String? = nil) async throws -> AsyncThrowingStream<String, Error> {
        guard let provider = activeProvider else { throw CHAIError.noProvider }
        return try await provider.stream(prompt: prompt, systemPrompt: systemPrompt)
    }

    /// Send a message with an image using the active provider
    public func sendWithVision(prompt: String, imageData: Data) async throws -> String {
        guard let provider = activeProvider else {
            throw CHAIError.noProvider
        }
        guard provider.supportsVision else {
            throw CHAIError.visionNotSupported
        }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let result = try await provider.sendVisionMessage(prompt: prompt, imageData: imageData)
            let inputTokens = (prompt.count / 4) + (imageData.count / 750)
            let outputTokens = result.count / 4
            let imageTokens = imageData.count / 750
            let tracker = CHAIUsageTracker.shared
            let cost = tracker.logRequest(
                provider: provider.displayName,
                model: provider.id,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                imageTokens: imageTokens,
                isVision: true
            )
            logAICost(provider: provider.displayName, model: provider.id, inputTokens: inputTokens, outputTokens: outputTokens, cost: cost, isVision: true)
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Log AI request cost to any registered CHLogger via NotificationCenter.
    /// Apps listen for this notification in their logger wrapper to show costs in Activity Log.
    private func logAICost(provider: String, model: String, inputTokens: Int, outputTokens: Int, cost: Double, isVision: Bool) {
        let costStr = cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.3f", cost)
        let detail = "in=\(inputTokens) out=\(outputTokens) tokens, cost=\(costStr)\(isVision ? " [vision]" : "")"
        // Post to NotificationCenter so each app's logger picks it up
        NotificationCenter.default.post(
            name: Notification.Name("CHAIRequestCompleted"),
            object: nil,
            userInfo: ["provider": provider, "model": model, "detail": detail, "cost": cost]
        )
    }
    
    /// Validate a specific provider's configuration
    public func validateProvider(_ id: String) async throws -> Bool {
        guard let provider = providers[id] else { return false }
        return try await provider.validate()
    }
}

// MARK: - Apple Intelligence Provider

/// Apple Intelligence provider using on-device FoundationModels (iOS 26+)
public struct CHAppleIntelligenceProvider: CHAIProvider, Sendable {
    public static let providerID = "apple-intelligence"
    
    public var id: String { Self.providerID }
    public var displayName: String { "Apple Intelligence" }
    public var supportsVision: Bool { false } // Vision support TBD
    
    public init() {}
    
    public func sendMessage(prompt: String, systemPrompt: String?) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw CHAIError.appleIntelligenceUnavailable
            }
            let session = LanguageModelSession()
            let fullPrompt = systemPrompt.map { "\($0)\n\n\(prompt)" } ?? prompt
            let response = try await session.respond(to: fullPrompt)
            return response.content
        }
        #endif
        throw CHAIError.appleIntelligenceUnavailable
    }
    
    public func validate() async throws -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Streams deltas via FoundationModels `LanguageModelSession.streamResponse(to:)`.
    ///
    /// The framework returns cumulative snapshots (each one contains all the
    /// text generated so far); we diff against the previous snapshot and yield
    /// just the new suffix so consumers can concatenate deltas directly.
    public func stream(prompt: String, systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw CHAIError.appleIntelligenceUnavailable
            }
            let session: LanguageModelSession = {
                if let sys = systemPrompt, !sys.isEmpty {
                    return LanguageModelSession(instructions: sys)
                }
                return LanguageModelSession()
            }()

            return AsyncThrowingStream { continuation in
                let task = Task {
                    var previous = ""
                    do {
                        for try await snapshot in session.streamResponse(to: prompt) {
                            try Task.checkCancellation()
                            let text = Self.snapshotText(snapshot)
                            if text.isEmpty { continue }
                            if text.count > previous.count, text.hasPrefix(previous) {
                                let delta = String(text.dropFirst(previous.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else if text != previous {
                                continuation.yield(text)
                            }
                            previous = text
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
        #endif
        throw CHAIError.appleIntelligenceUnavailable
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private static func snapshotText(_ snapshot: Any) -> String {
        // FoundationModels snapshots expose their text either directly as a
        // String or as a `.content` member. Use Mirror to stay resilient
        // across framework revisions.
        if let s = snapshot as? String { return s }
        let mirror = Mirror(reflecting: snapshot)
        for child in mirror.children {
            if child.label == "content", let s = child.value as? String { return s }
        }
        return String(describing: snapshot)
    }
    #endif
}
