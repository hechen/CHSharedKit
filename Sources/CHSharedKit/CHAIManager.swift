import Combine
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

    /// Provider IDs that the host app does not support on the current device.
    /// Disabled providers are excluded from settings and per-feature pickers,
    /// cannot be resolved for dispatch, and are replaced by a safe effective
    /// provider when their ID arrives through synced preferences.
    ///
    /// The persisted ``activeProviderID`` is intentionally left untouched.
    /// This matters for cross-platform apps: an iPhone can disable a provider
    /// that remains valid on the user's Mac without syncing an unwanted
    /// replacement back to macOS.
    @Published public var disabledProviderIDs: Set<String> = []

    /// 2.7.0: domain-context injector. When set, the manager calls
    /// `buildContext()` before every `send`/`stream`/`sendWithVision` and
    /// prepends the result (plus the anti-disclaimer instruction) to the
    /// caller-supplied `systemPrompt`. Apps wire this once at launch:
    ///
    /// ```swift
    /// CHAIManager.shared.contextProvider = LiftCoachContextProvider.shared
    /// ```
    ///
    /// Set to `nil` (default) for apps that don't need automatic context
    /// injection. See `docs/CHAT_UI.md` for integration patterns and the
    /// per-app context shapes (LiftCoach, EatWisely, Closet, etc.).
    @Published public var contextProvider: (any CHAIContextProvider)?

    /// 2.6.0: provider IDs gated behind a one-time IAP. Empty by default
    /// (no gating). When non-empty AND `CHIAPGateRegistry.shared` is set
    /// AND the gate's `hasUnlockedProviders == false`, the matching
    /// providers are locked: the picker's `CHAISettingsContent` renders an
    /// unlock banner + locks the matching rows, and no request is ever
    /// dispatched to them.
    ///
    /// 2.18.0: a locked stored choice (never bought, refunded, revoked)
    /// no longer fails every request. ``effectiveActiveProviderID`` serves
    /// it from Apple Intelligence when available, else from another
    /// unlocked provider, while ``activeProviderID`` and the provider's API
    /// key stay untouched, so a restore or re-purchase resumes the user's
    /// provider automatically. Only when no unlocked provider can serve the
    /// request do `send` / `stream` / `sendWithVision` throw
    /// ``CHAIError/providerLocked(displayName:)``.
    ///
    /// Common config (all paid providers, Apple Intelligence stays free):
    ///
    /// ```swift
    /// CHAIManager.shared.gateAllExceptAppleIntelligence()
    /// // equivalent to:
    /// CHAIManager.shared.gatedProviderIDs = [
    ///     CHOpenAIProvider.providerID,
    ///     CHClaudeProvider.providerID,
    ///     CHCustomEndpointProvider.providerID,
    ///     CHLocalLLMProvider.providerID,
    /// ]
    /// ```
    @Published public var gatedProviderIDs: Set<String> = []

    private var catalogProviderIDs: Set<String> = []
    private var hostProviderIDs: Set<String> = []
    private var providers: [String: any CHAIProvider] = [:]

    /// Forwards the registered ``CHIAPGate``'s changes to this manager's
    /// observers. A refund or restore changes which provider serves
    /// requests, so every view that shows the effective provider must
    /// re-render when the entitlement flips, not only the picker banner.
    private var iapGateObservation: AnyCancellable?

    /// Test seam for ``isAppleIntelligenceAvailable``. `nil` in production,
    /// where FoundationModels answers.
    var appleIntelligenceAvailabilityOverride: Bool?

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
        synchronizeCatalogProviders(CHAICloudModelCatalog.snapshot)
        observeIAPGate(CHIAPGateRegistry.shared)
    }

    /// 2.18.0: subscribes to the registered gate. Called by
    /// ``CHIAPGateRegistry/shared`` whenever a host registers or clears its
    /// gate, so hosts need no extra wiring.
    func observeIAPGate(_ gate: (any CHIAPGate)?) {
        guard let gate else {
            iapGateObservation = nil
            objectWillChange.send()
            return
        }
        // Forwarded synchronously on the main thread, like any nested
        // ObservableObject. A gate that publishes from a StoreKit listener
        // thread is hopped to main; the closure is deliberately nonisolated
        // so an off-main delivery cannot trip a main-actor assertion.
        iapGateObservation = Self.changes(of: gate).sink { @Sendable [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.objectWillChange.send() }
                }
            }
        }
        objectWillChange.send()
    }

    /// Opens the `any CHIAPGate` existential so its publisher can be erased.
    /// `nonisolated` so the `map` closure carries no main-actor assertion:
    /// it runs on whichever thread the gate publishes from.
    nonisolated private static func changes<G: CHIAPGate>(of gate: G) -> AnyPublisher<Void, Never> {
        gate.objectWillChange.map { _ in () }.eraseToAnyPublisher()
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
        objectWillChange.send()
        hostProviderIDs.insert(provider.id)
        catalogProviderIDs.remove(provider.id)
        providers[provider.id] = provider
    }

    /// Release a host-registered provider, for example after deleting its local
    /// model. Removing an active offline model must never select a cloud service.
    public func unregisterProvider(_ id: String) {
        guard hostProviderIDs.remove(id) != nil else { return }
        objectWillChange.send()
        providers.removeValue(forKey: id)
        if activeProviderID == id { activeProviderID = CHAppleIntelligenceProvider.providerID }
    }

    /// Test seam: swaps a registered provider in place without changing how
    /// it was registered (built-in, host or catalog), so a test can stand
    /// in for a built-in such as Apple Intelligence and put it back exactly.
    /// Returns the provider it replaced.
    @discardableResult
    func _swapProviderForTesting(_ provider: any CHAIProvider) -> (any CHAIProvider)? {
        objectWillChange.send()
        let previous = providers[provider.id]
        providers[provider.id] = provider
        return previous
    }

    /// Reconcile only catalog-owned registrations; host overrides remain authoritative.
    func synchronizeCatalogProviders(_ manifest: CHAICloudModelCatalogManifest) {
        objectWillChange.send()
        for id in catalogProviderIDs { providers.removeValue(forKey: id) }
        catalogProviderIDs.removeAll()
        for definition in manifest.providers where !hostProviderIDs.contains(definition.id) {
            guard providers[definition.id] == nil, let provider = CHAICatalogProvider(definition) else { continue }
            providers[definition.id] = provider
            catalogProviderIDs.insert(definition.id)
        }
    }

    /// Provider ID used for requests on this device. This normally matches
    /// ``activeProviderID``. When the stored provider is disabled locally,
    /// or (2.18.0) locked behind an unlock the user does not own, the
    /// manager selects a fallback without changing persistence. See
    /// ``effectiveProviderID(forStoredChoice:)``.
    public var effectiveActiveProviderID: String? {
        effectiveProviderID(forStoredChoice: activeProviderID)
    }

    /// Resolves a stored provider choice (the global selection or a
    /// per-feature override) to the provider that may serve requests now.
    ///
    /// * Usable choice: returned unchanged.
    /// * Disabled on this device: the first unlocked fallback, else the
    ///   pre-2.18 fallback order.
    /// * 2.18.0, locked (gating active, gate not unlocked: never bought,
    ///   refunded, revoked): Apple Intelligence when available, else another
    ///   unlocked provider, never another locked one. With no such provider
    ///   the locked ID itself is returned, so dispatch fails with
    ///   ``CHAIError/providerLocked(displayName:)`` naming the user's choice.
    /// * Not registered, or excluded by ``availableProvidersFilter``: `nil`.
    ///
    /// The stored choice and its API key are never modified, so a restore
    /// or re-purchase resumes the user's provider on the next request.
    public func effectiveProviderID(forStoredChoice id: String) -> String? {
        if !isProviderEnabled(id) {
            return unlockedFallbackProviderID(excluding: id) ?? disabledFallbackProviderID()
        }
        guard provider(id: id) != nil else { return nil }
        guard isLocked(providerID: id) else { return id }
        return unlockedFallbackProviderID(excluding: id) ?? id
    }

    /// Apple Intelligence first (it is never gated), then OpenAI, Claude and
    /// any other provider in ID order. Every candidate must be registered,
    /// enabled, allowed by the filter, not locked, and pass `accepts`.
    private func unlockedFallbackProviderID(
        excluding excludedID: String,
        accepts: (any CHAIProvider) -> Bool = { _ in true }
    ) -> String? {
        let apple = CHAppleIntelligenceProvider.providerID
        if isAppleIntelligenceAvailable, isAvailableFallback(apple),
           let provider = providers[apple], accepts(provider) {
            return apple
        }
        let preferred = [CHOpenAIProvider.providerID, CHClaudeProvider.providerID]
        return (preferred + providers.keys.sorted()).first { id in
            guard id != excludedID, id != apple, isAvailableFallback(id),
                  !isLocked(providerID: id), let provider = providers[id] else { return false }
            return accepts(provider)
        }
    }

    /// 2.18.0: an image request needs a vision-capable fallback. When the
    /// stored choice is locked and its fallback is text-only (Apple
    /// Intelligence), use an unlocked vision provider if one exists;
    /// otherwise report the lock, which tells the user how to proceed,
    /// rather than "vision not supported".
    func visionProvider(for resolved: any CHAIProvider, storedChoice: String) throws -> any CHAIProvider {
        guard !resolved.supportsVision, resolved.id != storedChoice,
              isProviderEnabled(storedChoice), isLocked(providerID: storedChoice) else { return resolved }
        if let id = unlockedFallbackProviderID(excluding: storedChoice, accepts: { $0.supportsVision }),
           let provider = providers[id] {
            return provider
        }
        throw CHAIError.providerLocked(displayName: displayName(forProviderID: storedChoice))
    }

    /// The pre-2.18 fallback for a disabled choice, used only when no
    /// unlocked provider exists. It may name a locked provider, whose
    /// request then fails with the actionable locked error.
    private func disabledFallbackProviderID() -> String? {
        if isAppleIntelligenceAvailable,
           isAvailableFallback(CHAppleIntelligenceProvider.providerID) {
            return CHAppleIntelligenceProvider.providerID
        }

        for id in [CHOpenAIProvider.providerID, CHClaudeProvider.providerID] {
            if isAvailableFallback(id) {
                return id
            }
        }

        return providers.values
            .filter { isProviderEnabled($0.id) && availableProvidersFilter.contains($0.category) }
            .map(\.id)
            .sorted()
            .first
    }

    private func isAvailableFallback(_ id: String) -> Bool {
        guard isProviderEnabled(id), let provider = providers[id] else { return false }
        return availableProvidersFilter.contains(provider.category)
    }

    /// Currently active provider for this device.
    public var activeProvider: (any CHAIProvider)? {
        guard let id = effectiveActiveProviderID else { return nil }
        return providers[id]
    }

    /// 2.10.0: lookup by ID for the per-feature resolver. Returns `nil`
    /// when the requested provider isn't registered (e.g. the user's
    /// stored override points at On-Device LLM but the app didn't
    /// register that provider). Callers fall back to the active
    /// provider in that case.
    public func provider(id: String) -> (any CHAIProvider)? {
        guard isProviderEnabled(id) else { return nil }
        guard let provider = providers[id], availableProvidersFilter.contains(provider.category) else { return nil }
        return provider
    }

    /// Whether a provider can be shown or used on this device.
    public func isProviderEnabled(_ id: String) -> Bool {
        !disabledProviderIDs.contains(id)
    }
    
    /// List of available providers with their IDs and names, filtered
    /// by `availableProvidersFilter`. Settings UIs should read this
    /// property — it already honors on-device-only / cloud-only etc.
    public var availableProviders: [(id: String, name: String)] {
        providers.values
            .filter {
                isProviderEnabled($0.id)
                    && availableProvidersFilter.contains($0.category)
            }
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
        if let appleIntelligenceAvailabilityOverride { return appleIntelligenceAvailabilityOverride }
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
        return try await send(prompt: prompt, systemPrompt: systemPrompt, to: provider)
    }

    /// Shared dispatch for the global and per-feature `send` overloads. The
    /// provider is resolved by the caller; nothing here writes
    /// ``activeProviderID``, so concurrent requests cannot leave a
    /// temporary provider behind as the user's saved choice.
    func send(prompt: String, systemPrompt: String?, to provider: any CHAIProvider) async throws -> String {
        // Last line of defence: resolution already avoids locked providers
        // whenever an unlocked fallback exists.
        try checkProviderUnlocked(provider)
        let composedSystem = await composedSystemPrompt(systemPrompt)
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let result = try await provider.sendMessage(prompt: prompt, systemPrompt: composedSystem)
            // Estimate tokens and log usage
            let inputTokens = (prompt.count + (systemPrompt?.count ?? 0)) / 4
            let outputTokens = result.count / 4
            let tracker = CHAIUsageTracker.shared
            let cost = tracker.logRequest(
                provider: provider.displayName,
                model: (provider as? CHAICatalogProvider)?.selectedModelID ?? provider.id,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            // Log cost to activity log for visibility
            logAICost(provider: provider.displayName, model: (provider as? CHAICatalogProvider)?.selectedModelID ?? provider.id, inputTokens: inputTokens, outputTokens: outputTokens, cost: cost, isVision: false)
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
        return try await stream(prompt: prompt, systemPrompt: systemPrompt, to: provider)
    }

    /// Shared dispatch for the global and per-feature `stream` overloads.
    func stream(prompt: String, systemPrompt: String?, to provider: any CHAIProvider) async throws -> AsyncThrowingStream<String, Error> {
        try checkProviderUnlocked(provider)
        let composedSystem = await composedSystemPrompt(systemPrompt)
        return try await provider.stream(prompt: prompt, systemPrompt: composedSystem)
    }

    /// Send a message with an image using the active provider
    public func sendWithVision(prompt: String, imageData: Data) async throws -> String {
        guard let provider = activeProvider else {
            throw CHAIError.noProvider
        }
        let imageProvider = try visionProvider(for: provider, storedChoice: activeProviderID)
        return try await sendWithVision(prompt: prompt, imageData: imageData, to: imageProvider)
    }

    /// Shared dispatch for the global and per-feature vision overloads.
    func sendWithVision(prompt: String, imageData: Data, to provider: any CHAIProvider) async throws -> String {
        try checkProviderUnlocked(provider)
        guard provider.supportsVision else {
            throw CHAIError.visionNotSupported
        }
        // 2.7.0: vision providers don't accept a separate system prompt
        // (`sendVisionMessage(prompt:imageData:)`). Prepend the context
        // provider's output to the prompt itself when set, with a small
        // header so the model knows what's data vs question.
        let composedPromptForVision: String
        if let contextProvider {
            let context = await contextProvider.buildContext()
            if !context.isEmpty {
                composedPromptForVision = """
                User data:
                \(context)

                \(CHAIContextSystemPrompt.antiDisclaimerInstruction)

                Question: \(prompt)
                """
            } else {
                composedPromptForVision = prompt
            }
        } else {
            composedPromptForVision = prompt
        }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            let result = try await provider.sendVisionMessage(prompt: composedPromptForVision, imageData: imageData)
            let inputTokens = (composedPromptForVision.count / 4) + (imageData.count / 750)
            let outputTokens = result.count / 4
            let imageTokens = imageData.count / 750
            let tracker = CHAIUsageTracker.shared
            let cost = tracker.logRequest(
                provider: provider.displayName,
                model: (provider as? CHAICatalogProvider)?.selectedModelID ?? provider.id,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                imageTokens: imageTokens,
                isVision: true
            )
            logAICost(provider: provider.displayName, model: (provider as? CHAICatalogProvider)?.selectedModelID ?? provider.id, inputTokens: inputTokens, outputTokens: outputTokens, cost: cost, isVision: true)
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
        guard let provider = provider(id: id) else { return false }
        return try await provider.validate()
    }

    // MARK: - 2.6.0 IAP gating

    /// Throws ``CHAIError/providerLocked(displayName:)`` when the active
    /// provider is in `gatedProviderIDs` and the registered ``CHIAPGate``
    /// reports `hasUnlockedProviders == false`. Returns silently in every
    /// other case (including: gate not registered, provider not gated,
    /// already unlocked).
    ///
    /// 2.18.0: `send` / `stream` / `sendWithVision` resolve a locked choice
    /// to an unlocked fallback first, so this throws only when no unlocked
    /// provider can serve the request.
    public func checkProviderUnlocked(_ provider: any CHAIProvider) throws {
        guard isLocked(providerID: provider.id) else { return }
        guard let gate = CHIAPGateRegistry.shared else { return }
        if gate.hasUnlockedProviders { return }
        throw CHAIError.providerLocked(displayName: provider.displayName)
    }

    // MARK: - 2.7.0 Context provider composition

    /// Composes the final system prompt for `send` / `stream`. Combines (in
    /// order): the context provider's `buildContext()` output, the
    /// anti-disclaimer instruction, and the caller-supplied `userSystem`.
    /// Returns nil only if there's nothing to prepend AND no caller system
    /// prompt — otherwise returns a non-nil composed string.
    ///
    /// Public so consumer apps can inspect what the kit actually sent (the
    /// composed prompt is logged to the AI Request Log if enabled, but
    /// having a programmatic accessor is useful for debugging context
    /// providers that misbehave).
    public func composedSystemPrompt(_ userSystem: String?) async -> String? {
        guard let contextProvider else { return userSystem }
        let context = await contextProvider.buildContext()
        guard !context.isEmpty else { return userSystem }
        let userTail = (userSystem?.isEmpty == false) ? "\n\n\(userSystem!)" : ""
        return """
        \(CHAIContextSystemPrompt.antiDisclaimerInstruction)

        User data:
        \(context)\(userTail)
        """
    }
}

// MARK: - Apple Intelligence Provider

/// Apple Intelligence provider using on-device Foundation Models.
public struct CHAppleIntelligenceProvider: CHAIProvider, Sendable {
    public static let providerID = "apple-intelligence"

    /// Requirement copy is centralized here so every shared settings surface
    /// names the OS it is actually running on instead of leaking iOS copy into
    /// the native macOS app.
    public static var minimumOSRequirement: String {
        #if os(macOS)
        "macOS 26+"
        #elseif os(visionOS)
        "visionOS 26+"
        #else
        "iOS 26+"
        #endif
    }

    public static var availabilitySubtitle: String {
        String(localized: "On-device · \(minimumOSRequirement)", bundle: .module)
    }

    public static var unavailableReason: String {
        String(localized: "Requires \(minimumOSRequirement)", bundle: .module)
    }

    static var unavailableErrorDescription: String {
        #if os(macOS)
        String(localized: "Apple Intelligence requires macOS 26 or later", bundle: .module)
        #elseif os(visionOS)
        String(localized: "Apple Intelligence requires visionOS 26 or later", bundle: .module)
        #else
        String(localized: "Apple Intelligence requires iOS 26 or later", bundle: .module)
        #endif
    }
    
    public var id: String { Self.providerID }
    public var displayName: String { "Apple Intelligence" }
    public var supportsVision: Bool { false } // Vision support TBD
    /// 2.10.0: text-only on OS 26 (FoundationModels has no vision
    /// or function-calling APIs as of this writing). Streaming via
    /// the manager's default fallback only.
    public var capabilities: Set<CHAICapability> {
        [.textInput]
    }
    
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
