import Foundation
import Security

// MARK: - CHSyncedKeychain (2.9.0)
//
// ## Why this exists
//
// Pre-2.9.0 each consuming app rolled its own `SecItem*` calls. Several
// of those callsites omitted `kSecAttrSynchronizable: kCFBooleanTrue`,
// which is the literal one-line difference between "this credential
// follows the user across devices" and "this credential is stuck on
// the device the user typed it on." That's how the BYOK API key
// regression shipped: enter key on iPhone → can't make AI requests on
// iPad until you re-enter it.
//
// `CHSyncedKeychain` is the only sanctioned keychain entry point for
// CHSharedKit consumers from 2.9.0 onward. It always sets the sync
// flag, supports an optional access group for app-group sharing, and
// exposes a test backing store so unit tests can assert behavior
// without touching the real keychain.
//
// `CHAITokenStore` (which existed in 2.4.8) routes through this — see
// `CHAITokenStore.swift` for the migration glue.
//
// ## Sync semantics — pull-first, never-propagate-absent
//
// iCloud Keychain itself has the right behavior natively: a device
// that has never called `SecItemAdd` for a given service/account
// will never push an "absent" value up. The cloud keeps whatever the
// last writer set. This wrapper preserves that property and adds:
//
//   * **Idempotent writes are skipped.** If the slot already contains
//     exactly the bytes you're writing, the call is a no-op. Defends
//     against "re-init" patterns that would otherwise generate
//     spurious propagation events.
//   * **Reads never write.** `data(forKey:)` and `string(forKey:)`
//     have zero side effects.
//   * **Explicit deletes propagate.** `set(nil, forKey:)` removes the
//     iCloud Keychain item, which Apple propagates as a delete.

/// Cross-device-synced keychain wrapper. All writes set
/// `kSecAttrSynchronizable: kCFBooleanTrue`, so values follow the user
/// to any device signed into the same iCloud Keychain.
public enum CHSyncedKeychain {

    // MARK: - Public API

    /// Default keychain service for app-level credentials. Apps can
    /// pass an explicit `service` to scope further (e.g. one service
    /// per provider, per data type). Default keeps the kit footprint
    /// to a single keychain attribute namespace.
    public static let defaultService = "ch-synced-keychain"

    /// Read raw bytes for `key`. Returns `nil` if no item exists or
    /// the keychain refused the read (caller should treat both the
    /// same — "ask the user to enter it again").
    public static func data(
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) -> Data? {
        if let backing = _testOverride {
            return backing.read(service: service, account: key, accessGroup: accessGroup)
        }
        var query = baseQuery(service: service, account: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else { return nil }
        return bytes
    }

    /// Write raw bytes. Pass `nil` to delete. Always synchronizable.
    /// On every write we record a sync-health beat so the diagnostic
    /// view can show "last keychain write: 12s ago from this device".
    ///
    /// Idempotent: if `data` matches the current slot exactly, the
    /// keychain write is skipped (and no health beat is fired). This
    /// is the same defense `CHSyncedSettingsStore` runs — prevents a
    /// "defensive re-init" pattern from clobbering an existing iCloud
    /// Keychain entry on a fresh device.
    public static func set(
        _ data: Data?,
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil,
        recordHealth: Bool = true
    ) {
        // Idempotent skip — same value, no-op.
        let current = Self.data(forKey: key, service: service, accessGroup: accessGroup)
        if current == data { return }

        if let backing = _testOverride {
            if let data {
                backing.write(value: data, service: service, account: key, accessGroup: accessGroup)
            } else {
                backing.delete(service: service, account: key, accessGroup: accessGroup)
            }
            if recordHealth { Self.beat(service: service) }
            return
        }
        // Always delete first, then add — `SecItemUpdate` semantics
        // are dependent on which attributes match, and we'd rather
        // pay the SecItemDelete on every write than debug missing
        // updates from a partial query match.
        let query = baseQuery(service: service, account: key, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)

        guard let data else {
            if recordHealth { Self.beat(service: service) }
            return
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
        if recordHealth { Self.beat(service: service) }
    }

    /// Convenience: UTF-8 string read.
    public static func string(
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) -> String? {
        data(forKey: key, service: service, accessGroup: accessGroup)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Convenience: UTF-8 string write. Pass `nil` or empty string to delete.
    public static func setString(
        _ value: String?,
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) {
        guard let value, !value.isEmpty else {
            set(nil, forKey: key, service: service, accessGroup: accessGroup)
            return
        }
        set(value.data(using: .utf8), forKey: key, service: service, accessGroup: accessGroup)
    }

    /// Delete the item for `key`. Equivalent to `set(nil, forKey:)`.
    public static func remove(
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) {
        set(nil, forKey: key, service: service, accessGroup: accessGroup)
    }

    // MARK: - Health beat

    /// Each successful write records a beat in `CHSyncHealthRegistry`
    /// so the diagnostic view can show liveness. Reads do not beat
    /// because they don't represent state change.
    private static func beat(service: String) {
        Task { @MainActor in
            CHSyncHealthRegistry.shared.recordWrite(
                source: "keychain.\(service)",
                at: Date()
            )
        }
    }

    // MARK: - Test seam

    /// Tests inject a `TestBacking` so we don't pollute the host
    /// keychain (flaky on macOS unit tests with restrictive signing).
    /// `nonisolated(unsafe)` is fine: tests install the override
    /// inside a single suite, production leaves it nil.
    nonisolated(unsafe) public static var _testOverride: TestBacking?

    public final class TestBacking: @unchecked Sendable {
        private struct Slot: Hashable {
            let service: String
            let account: String
            let accessGroup: String?
        }
        private var storage: [Slot: Data] = [:]
        private let lock = NSLock()

        public init() {}

        public func read(service: String, account: String, accessGroup: String?) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return storage[Slot(service: service, account: account, accessGroup: accessGroup)]
        }
        public func write(value: Data, service: String, account: String, accessGroup: String?) {
            lock.lock(); defer { lock.unlock() }
            storage[Slot(service: service, account: account, accessGroup: accessGroup)] = value
        }
        public func delete(service: String, account: String, accessGroup: String?) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: Slot(service: service, account: account, accessGroup: accessGroup))
        }
        public func reset() {
            lock.lock(); defer { lock.unlock() }
            storage.removeAll()
        }
        /// Snapshot for assertions — `[(service, account, accessGroup, valueLength)]`.
        public func dump() -> [(service: String, account: String, accessGroup: String?, length: Int)] {
            lock.lock(); defer { lock.unlock() }
            return storage.map { ($0.key.service, $0.key.account, $0.key.accessGroup, $0.value.count) }
        }
    }

    // MARK: - Internals

    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }
}
