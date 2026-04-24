import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AI Service Manager

/// Central manager for AI providers. Handles provider selection, key storage, and requests.
///
/// ## Observing the active provider from Settings
///
/// SwiftUI views that display the current provider (e.g. a
/// "Settings → AI" parent row showing "OpenAI" / "Claude") **must**
/// establish an observation relationship with this manager, otherwise
/// the row renders stale after the child picker writes a new value and
/// pops back:
///
/// ```swift
/// // ❌ WRONG — reads the singleton directly, no subscription,
/// // the row stays stuck on the old provider name after picker pop.
/// Text(CHAIManager.shared.activeProvider?.displayName ?? "None")
///
/// // ✅ RIGHT — drop-in component that self-observes.
/// CHAIActiveProviderLabel()
///
/// // ✅ ALSO FINE — explicit @StateObject / @ObservedObject binding
/// // in the enclosing view.
/// @StateObject private var ai = CHAIManager.shared
/// var body: some View {
///     Text(ai.activeProvider?.displayName ?? "None")
/// }
/// ```
///
/// All writes to `activeProviderID` happen on the main actor (the
/// enclosing `@MainActor` class enforces this) and the `didSet` hook
/// persists to `UserDefaults` synchronously on the same tick, so there
/// is no race between the picker's write and the parent's re-render —
/// the fix for the reported "cell shows stale provider" bug is purely
/// on the subscribe side.
@MainActor
public final class CHAIManager: ObservableObject {
    public static let shared = CHAIManager()

    @Published public var activeProviderID: String {
        didSet { UserDefaults.standard.set(activeProviderID, forKey: "clawd_ai_active_provider") }
    }
    @Published public var isProcessing = false
    @Published public var lastError: String?

    // MARK: - Unified active-selection (2.4.5)
    //
    // ## The bug this fixes
    //
    // Before 2.4.5, "what is the current on-device model" was stored in
    // three places that could drift:
    //
    //   1. `LocalModelStore.activeModelID` — App Group UserDefaults,
    //      drives the row subtitle + On-Device detail section.
    //   2. `CHAIManager.providers["on-device-llm"]` — the last
    //      `CHLocalLLMProvider` instance registered via
    //      `registerProvider`. Its `displayName` embedded the model name
    //      captured at construction (e.g. `"On-Device AI (Qwen 2.5 1.5B)"`).
    //   3. `CHAIActiveProviderLabel.text(for:)` read (2) and therefore
    //      the "Active Provider" summary row re-used whichever model
    //      name was baked into the cached provider instance — which
    //      diverged from (1) on relaunch (LocalModelStore restores
    //      persisted activeModelID but never re-registers the provider)
    //      and after model switches where the dict entry was replaced
    //      but the observing view didn't rebind.
    //
    // Chen's Build 257 screenshot on EatWisely was the proof point:
    //   - Active Provider cell: "On-Device AI (Qwen 2.5 1.5B)"     ← stale (2)
    //   - AI Provider row:      "On-Device AI · Phi-3.5 Mini" ✓    ← fresh (1)
    //   - On-Device section:    "Phi-3.5 Mini · Active"        ✓   ← fresh (1)
    //
    // ## The fix
    //
    // `CHAIManager` now owns the ONE source of truth: a pair of
    // `@Published` properties (`activeModelID` + `activeModelDisplayName`)
    // persisted to UserDefaults and written via
    // `setActiveOnDeviceModel(id:displayName:)`. Every consumer that
    // wants to display "the current model" must read through these
    // properties. `CHLocalLLMProvider.displayName` no longer embeds a
    // model suffix — the suffix is composed by
    // `CHAIActiveProviderLabel` from the manager's published state, so
    // one @Published write propagates to every observing view.
    //
    // `LocalModelStore.setActiveModel`/`clearActiveModel` delegate to
    // this method so the previous persistence path is preserved but the
    // canonical value lives here.
    @Published public private(set) var activeModelID: String?
    @Published public private(set) var activeModelDisplayName: String?

    /// Restricts which providers `availableProviders` and
    /// `CHAISettingsView` expose. Apps that ship an on-device-only
    /// privacy story should set this to `.onDeviceOnly` at launch —
    /// cloud-provider rows will never appear in the settings picker.
    /// Defaults to `.all` so existing integrations behave as before.
    @Published public var availableProvidersFilter: CHAIProviderFilter = .all

    private var providers: [String: any CHAIProvider] = [:]

    private static let activeModelIDKey = "clawd_ai_active_model_id"
    private static let activeModelDisplayNameKey = "clawd_ai_active_model_name"

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
        // Restore the persisted on-device model selection so the
        // "Active Provider" summary row renders correctly on cold start
        // even before LocalModelStore has a chance to call
        // setActiveOnDeviceModel (which happens only after a user tap or
        // a fresh install-and-use).
        self.activeModelID = UserDefaults.standard.string(forKey: Self.activeModelIDKey)
        self.activeModelDisplayName = UserDefaults.standard.string(forKey: Self.activeModelDisplayNameKey)
        registerBuiltInProviders()
    }

    /// Record the currently-active on-device model. Called by
    /// `LocalModelStore.setActiveModel` — apps SHOULD NOT call this
    /// directly; go through `LocalModelStore` so the model file, the
    /// CHLocalLLMProvider instance, and this published state all update
    /// together.
    ///
    /// Writing both properties here in order means a single SwiftUI
    /// re-eval observes the final state. The @Published wrappers fire
    /// `objectWillChange` twice in quick succession — harmless, SwiftUI
    /// coalesces — and persistence runs synchronously on the main tick
    /// so a subsequent cold launch reads the same values.
    public func setActiveOnDeviceModel(id: String, displayName: String) {
        self.activeModelID = id
        self.activeModelDisplayName = displayName
        UserDefaults.standard.set(id, forKey: Self.activeModelIDKey)
        UserDefaults.standard.set(displayName, forKey: Self.activeModelDisplayNameKey)
    }

    /// Clear the on-device model selection. Called by
    /// `LocalModelStore.clearActiveModel` / `deleteModel`.
    public func clearActiveOnDeviceModel() {
        self.activeModelID = nil
        self.activeModelDisplayName = nil
        UserDefaults.standard.removeObject(forKey: Self.activeModelIDKey)
        UserDefaults.standard.removeObject(forKey: Self.activeModelDisplayNameKey)
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
    
    /// List of available providers with their IDs and names, filtered
    /// by `availableProvidersFilter`. Settings UIs should read this
    /// property — it already honors on-device-only / cloud-only etc.
    public var availableProviders: [(id: String, name: String)] {
        providers.values
            .filter { availableProvidersFilter.contains($0.category) }
            .map { (id: $0.id, name: $0.displayName) }
            .sorted { $0.name < $1.name }
    }

    /// Unfiltered providers — use only when the caller truly needs
    /// every registered provider (e.g., diagnostic UIs). App settings
    /// UIs should prefer `availableProviders`.
    public var allProviders: [(id: String, name: String)] {
        providers.values
            .map { (id: $0.id, name: $0.displayName) }
            .sorted { $0.name < $1.name }
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
