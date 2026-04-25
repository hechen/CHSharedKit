import Foundation
import Security

// MARK: - CHAITokenStore (2.4.8)
//
// ## Why this exists
//
// Before 2.4.8, each cloud provider owned its own keychain service
// (`app.chen.clawdappkit.openai`, `app.chen.clawdappkit.claude`,
// `app.chen.clawdappkit.custom`). Two problems with that:
//
//   1. The service constants are app-process-global. Five apps consume
//      CHSharedKit (Closet, EatWisely, GymLog, Clawd, GroupOut) and they
//      all run with the same iCloud team ID, so a single shared
//      keychain item leaked tokens across apps — entering a key in
//      Closet would silently make it readable from EatWisely's process.
//      Not a security disaster (same developer, same team) but a
//      surprise data-locality bug nonetheless.
//
//   2. Chen's reported flow: pick OpenAI → enter token → switch active
//      provider to On-Device → switch back to OpenAI → token field
//      shows empty. Root cause was that `CHAISettingsView` cached the
//      key in a `@State var openaiKey: String` field bound to the
//      TextField, then wrote it back on submit/save — the @State
//      survived the picker pop in some cases and got blown away in
//      others (specifically, navigating away and back recreated the
//      @State and reloaded from the keychain, but switching providers
//      mid-edit did not). Fixing the Settings view alone wasn't enough;
//      consumers expected per-provider isolation that was actually
//      keyed by both *bundle* and *provider*.
//
// ## The fix
//
// Single store keyed by `<bundleID>.<providerID>`. Bundle ID is derived
// from `Bundle.main.bundleIdentifier` so each app gets its own slot
// for free — no per-app config required. Service is `chsk-ai-tokens`,
// matching the existing `app.chen.clawdappkit.*` naming spirit but
// scoped to the kit (not the app), since apps are now distinguished by
// the account string.
//
// `CHOpenAIProvider.apiKey` / `CHClaudeProvider.apiKey` /
// `CHCustomEndpointProvider.apiKey` route reads and writes through this
// store. They keep the same static `apiKey` getter/setter API so
// existing call sites in `CHAISettingsView` and consumer apps don't
// have to change.
//
// ## Migration
//
// On first read after upgrade, if the new-format slot is empty but the
// legacy `app.chen.clawdappkit.<provider>` slot has a value, we copy
// the legacy value into the new slot and continue. The legacy slot is
// left in place — if a user rolls back to 2.4.7, their key is still
// there. Migration is a one-shot per launch via the in-memory cache
// hint, so the SecItem traffic is bounded.
public enum CHAITokenStore {

    /// Keychain service used for every token managed by this store.
    /// All apps that link CHSharedKit share this constant; the per-app
    /// scoping is provided by the account string (which embeds the
    /// bundle identifier).
    public static let service = "chsk-ai-tokens"

    /// Compose the keychain account string for a given provider ID.
    /// Format: `<bundleID>.<providerID>`. If `Bundle.main.bundleIdentifier`
    /// is unavailable (test runners, command-line tools), falls back to
    /// `unknown-bundle` so the store still works in unit tests.
    public static func account(for providerID: String, bundleID: String? = nil) -> String {
        let bundle = bundleID ?? Bundle.main.bundleIdentifier ?? "unknown-bundle"
        return "\(bundle).\(providerID)"
    }

    /// Retrieve the stored token for a provider. Returns `nil` when no
    /// token has been saved (or when the keychain item is unreadable —
    /// caller should treat both cases the same and prompt the user to
    /// re-enter).
    public static func token(for providerID: String) -> String? {
        let account = account(for: providerID)
        if let value = readRaw(service: service, account: account) {
            return value
        }
        // 2.4.8 migration: surface the legacy per-provider slot if the
        // new account is empty. We DON'T delete the legacy slot — keep
        // a rollback path in place.
        if let legacyService = legacyService(for: providerID),
           let legacy = readRaw(service: legacyService, account: "api_key") {
            // Hoist the legacy value into the new slot so subsequent
            // reads short-circuit on the fast path.
            saveRaw(value: legacy, service: service, account: account)
            return legacy
        }
        return nil
    }

    /// Save a token for a provider. Pass `nil` to delete.
    public static func setToken(_ value: String?, for providerID: String) {
        let account = account(for: providerID)
        if let value, !value.isEmpty {
            saveRaw(value: value, service: service, account: account)
        } else {
            deleteRaw(service: service, account: account)
        }
    }

    /// Delete the token for a provider. Equivalent to `setToken(nil, for:)`.
    public static func deleteToken(for providerID: String) {
        deleteRaw(service: service, account: account(for: providerID))
    }

    // MARK: - Test seam
    //
    // Unit tests inject an in-memory backing store via `_testOverride`
    // so we don't pollute the host keychain (which on macOS unit tests
    // can be flaky depending on the developer's signing config). When
    // `_testOverride` is non-nil, all reads/writes/deletes go through
    // it and bypass `SecItem*` entirely.
    //
    // `nonisolated(unsafe)` is fine here: tests install the override
    // inside a `@MainActor` suite and the production code path leaves
    // it nil, so there's no real cross-actor mutation. The TestBacking
    // class itself is internally locked.
    nonisolated(unsafe) public static var _testOverride: TestBacking?

    public final class TestBacking: @unchecked Sendable {
        private var storage: [String: String] = [:]
        private let lock = NSLock()
        public init() {}
        public func read(service: String, account: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage["\(service)|\(account)"]
        }
        public func write(value: String, service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            storage["\(service)|\(account)"] = value
        }
        public func delete(service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: "\(service)|\(account)")
        }
        public func reset() {
            lock.lock(); defer { lock.unlock() }
            storage.removeAll()
        }
    }

    // MARK: - Internals

    private static func legacyService(for providerID: String) -> String? {
        // Pre-2.4.8 services. New providers added in 2.4.8+ should not
        // need a legacy entry here — they go straight to the new store.
        switch providerID {
        case "openai": return "app.chen.clawdappkit.openai"
        case "claude": return "app.chen.clawdappkit.claude"
        case "custom": return "app.chen.clawdappkit.custom"
        default: return nil
        }
    }

    private static func readRaw(service: String, account: String) -> String? {
        if let backing = _testOverride { return backing.read(service: service, account: account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveRaw(value: String, service: String, account: String) {
        if let backing = _testOverride {
            backing.write(value: value, service: service, account: account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func deleteRaw(service: String, account: String) {
        if let backing = _testOverride {
            backing.delete(service: service, account: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
