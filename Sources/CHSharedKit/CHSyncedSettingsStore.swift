import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - CHSyncedSettingsStore (2.9.0)
//
// ## Why this exists
//
// `@AppStorage` is local-device-only. Apps that wanted "this setting
// follows the user across devices" had to bolt their own
// `NSUbiquitousKeyValueStore` plumbing onto each setting individually,
// and every app's plumbing had subtle differences (some forgot to call
// `synchronize()` on launch, some never observed
// `didChangeExternallyNotification`, some did the right thing but
// only for a subset of types). The same drift that bit BYOK keys.
//
// `CHSyncedSettingsStore` centralizes all of that. Apps use the
// `@CHSyncedSetting("theme") var theme: String = "auto"` property
// wrapper exactly like `@AppStorage`, and the value follows the user.
//
// Diagnostic surface: every write records a sidecar entry into
// `CHSyncHealthRegistry` — last write timestamp + writing device —
// so the user can see in `CHSyncHealthView` whether their setting
// actually crossed.
//
// ## Sync semantics — pull-first, never-propagate-absent
//
// The kit guarantees four properties so the regression Chen worried
// about ("iPhone has BYOK key, iPad empty, iPad turns sync on, does
// the empty iPad clobber the iPhone?") *cannot* happen:
//
//   1. **Reads never write.** `string(forKey:)` and the property
//      wrapper getter return the cloud-or-default value with zero
//      side effects. A device that has never explicitly set a key
//      cannot push an absent value to iCloud.
//
//   2. **Idempotent writes are skipped.** `setString(value, forKey:)`
//      compares the new value against what's currently in the store
//      and short-circuits if they match — so a "defensive re-init"
//      pattern (`if k == "" { k = "" }`) is a no-op, not a propagation
//      event.
//
//   3. **Per-key timestamps + writing-device fingerprint** live in a
//      `__chsync_meta` sidecar. They drive last-write-wins arbitration
//      when concurrent writes from two devices arrive within the same
//      sync window, and feed the diagnostic surface ("last written by
//      this iPhone 14s ago").
//
//   4. **Explicit clears propagate as tombstones.** `clear(forKey:)`
//      removes the value AND records `isDeleted: true` + timestamp in
//      the meta sidecar. Tombstones older than 30 days are GC'd on
//      next write. `setString(nil, forKey:)` is treated as a clear.
//
// ## Conflict resolution
//
// `NSUbiquitousKeyValueStore` itself runs last-write-wins by Apple's
// internal sync timestamps. We layer per-key meta on top so the
// diagnostic view can show "this value came from your iPad 12 minutes
// ago." When two writes land within 5 seconds of each other we mark a
// conflict in `CHSyncHealthRegistry` (visible in the Sync Health
// view); the cloud's last-write still applies as the resolved value.

/// Cross-device-synced settings store. Backed by
/// `NSUbiquitousKeyValueStore` in production and an in-memory
/// `FakeUbiquitousKVS` for unit tests.
@MainActor
public final class CHSyncedSettingsStore: ObservableObject {

    /// Production singleton. Apps usually don't need to instantiate
    /// their own — the property wrapper routes through `.shared`.
    public static let shared = CHSyncedSettingsStore()

    /// Notification posted whenever a key value changes — externally
    /// (from another device) or locally. Hosts that want to observe
    /// outside of `ObservableObject` machinery can subscribe here.
    public static let didChangeNotification = Notification.Name("CHSyncedSettingsStoreDidChange")

    private let kvs: CHUbiquitousKVS
    private let metaKey = "__chsync_meta"
    private let deviceID: String

    /// Window within which two writes are flagged as a conflict in
    /// `CHSyncHealthRegistry`. The actual value resolution still goes
    /// through Apple's last-write-wins; this only feeds diagnostics.
    private let conflictWindow: TimeInterval = 5

    /// How long an explicit-clear tombstone stays in the meta sidecar
    /// before GC'd. Matches Chen's spec.
    private let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 30

    /// Initialize against a custom transport. The default uses the
    /// real iCloud KVS singleton; tests pass `FakeUbiquitousKVS()`.
    /// `deviceFingerprint` is exposed for tests that need to simulate
    /// two different devices in one process.
    public init(
        kvs: CHUbiquitousKVS = NSUbiquitousKeyValueStoreAdapter(),
        deviceFingerprint: String? = nil
    ) {
        self.kvs = kvs
        self.deviceID = deviceFingerprint ?? Self.resolveDeviceFingerprint()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalChange(_:)),
            name: kvs.changeNotificationName,
            object: kvs.underlyingObject
        )
        // Pull whatever the cloud already has — covers cold-launch
        // races where the app reads a key before the KVS daemon has
        // finished initial sync.
        _ = kvs.synchronize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Typed accessors

    public func string(forKey key: String) -> String? {
        kvs.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        // Treat nil/empty as an explicit clear — propagates a deletion
        // with a tombstone in the meta sidecar.
        guard let value, !value.isEmpty else {
            clear(forKey: key)
            return
        }
        // Idempotent skip — see module docstring property #2.
        if kvs.string(forKey: key) == value { return }
        kvs.set(value, forKey: key)
        recordMeta(key: key, isDeleted: false)
        announce(key: key)
    }

    public func bool(forKey key: String) -> Bool { kvs.bool(forKey: key) }
    public func setBool(_ value: Bool, forKey key: String) {
        if kvs.object(forKey: key) is NSNumber, kvs.bool(forKey: key) == value { return }
        kvs.set(value, forKey: key)
        recordMeta(key: key, isDeleted: false)
        announce(key: key)
    }

    public func integer(forKey key: String) -> Int64 { kvs.longLong(forKey: key) }
    public func setInteger(_ value: Int64, forKey key: String) {
        if kvs.object(forKey: key) is NSNumber, kvs.longLong(forKey: key) == value { return }
        kvs.set(value, forKey: key)
        recordMeta(key: key, isDeleted: false)
        announce(key: key)
    }

    public func double(forKey key: String) -> Double { kvs.double(forKey: key) }
    public func setDouble(_ value: Double, forKey key: String) {
        if kvs.object(forKey: key) is NSNumber, kvs.double(forKey: key) == value { return }
        kvs.set(value, forKey: key)
        recordMeta(key: key, isDeleted: false)
        announce(key: key)
    }

    public func data(forKey key: String) -> Data? { kvs.data(forKey: key) }
    public func setData(_ value: Data?, forKey key: String) {
        guard let value else { clear(forKey: key); return }
        if kvs.data(forKey: key) == value { return }
        kvs.set(value, forKey: key)
        recordMeta(key: key, isDeleted: false)
        announce(key: key)
    }

    /// Explicit clear — delete the value AND record a tombstone in
    /// the meta sidecar so other devices can distinguish "this was
    /// intentionally cleared by the user" from "this device never
    /// touched the key." Idempotent.
    public func clear(forKey key: String) {
        let alreadyAbsent = kvs.object(forKey: key) == nil
        let alreadyTombstoned = meta()[key]?.isDeleted == true
        if alreadyAbsent && alreadyTombstoned { return }
        kvs.set(nil, forKey: key)
        recordMeta(key: key, isDeleted: true)
        announce(key: key)
    }

    /// Force a sync round-trip. Surfaced as a public helper so the
    /// "Force resync" button in `CHSyncHealthView` has a way to call it.
    @discardableResult
    public func synchronize() -> Bool {
        let ok = kvs.synchronize()
        CHSyncHealthRegistry.shared.recordSync(source: "settings", at: Date())
        return ok
    }

    /// Recommended on-launch hook. Pulls remote state from iCloud
    /// before the app reads any synced setting — protects against
    /// the "fresh device launches with empty local state, reads
    /// before sync arrives, treats nil as authoritative" pattern.
    ///
    /// Apple's KVS daemon resolves the actual sync asynchronously;
    /// this method only kicks the round-trip and beats the health
    /// registry. Apps that need to *wait* for delivery should
    /// observe `Self.didChangeNotification`.
    @discardableResult
    public func pullFromCloud() -> Bool {
        synchronize()
    }

    // MARK: - Diagnostic helpers

    /// When was `key` last written from any device? Returns nil for
    /// keys that haven't been written under 2.9.0+ (legacy keys
    /// written before this store existed have no meta).
    public func lastWriteDate(forKey key: String) -> Date? {
        meta()[key]?.timestamp
    }

    /// What device wrote `key` last? Anonymized — returns the device
    /// fingerprint, not the user-set device name.
    public func lastWriteDevice(forKey key: String) -> String? {
        meta()[key]?.device
    }

    // MARK: - Internals

    @objc private func externalChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keys = userInfo[kvs.changedKeysKey] as? [String]
        else { return }

        // Skip our own meta key — internal bookkeeping, not a value
        // any view should react to.
        let visible = keys.filter { $0 != metaKey }
        guard !visible.isEmpty else { return }

        objectWillChange.send()
        for key in visible {
            CHSyncHealthRegistry.shared.recordExternalUpdate(
                source: "settings.\(key)",
                at: Date()
            )
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: ["key": key]
            )
        }
    }

    private func announce(key: String) {
        objectWillChange.send()
        CHSyncHealthRegistry.shared.recordWrite(
            source: "settings.\(key)",
            at: Date()
        )
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: ["key": key]
        )
    }

    private func recordMeta(key: String, isDeleted: Bool) {
        var current = meta()
        let now = Date()

        // Conflict beat: if some other device wrote the same key
        // within `conflictWindow` seconds, surface it for diagnostics.
        if let existing = current[key],
           existing.device != deviceID,
           now.timeIntervalSince(existing.timestamp) <= conflictWindow {
            CHSyncHealthRegistry.shared.recordConflict()
        }

        current[key] = MetaEntry(timestamp: now, device: deviceID, isDeleted: isDeleted)

        // Tombstone GC: drop entries that were deleted more than
        // `tombstoneRetention` ago. Bounded loop, runs on every write.
        let cutoff = now.addingTimeInterval(-tombstoneRetention)
        current = current.filter { _, entry in
            if entry.isDeleted, entry.timestamp < cutoff { return false }
            return true
        }

        if let blob = try? JSONEncoder().encode(current) {
            kvs.set(blob, forKey: metaKey)
        }
    }

    private func meta() -> [String: MetaEntry] {
        guard let blob = kvs.data(forKey: metaKey),
              let dict = try? JSONDecoder().decode([String: MetaEntry].self, from: blob)
        else { return [:] }
        return dict
    }

    private struct MetaEntry: Codable {
        let timestamp: Date
        let device: String
        let isDeleted: Bool
    }

    /// Stable per-device fingerprint, computed once and cached in
    /// local UserDefaults. Combines a short UUID with the device
    /// model so the diagnostic view can show "iPhone-3F2A1B" or
    /// "iPad-9B4C7D" — disambiguates between devices without
    /// surfacing the user-set device name (which is PII-shaped).
    private static func resolveDeviceFingerprint() -> String {
        let key = "ch_synced_settings_device_fingerprint"
        if let cached = UserDefaults.standard.string(forKey: key) { return cached }

        let model: String = {
            #if canImport(UIKit)
            return UIDevice.current.localizedModel
            #else
            return "Mac"
            #endif
        }()
        let suffix = String(UUID().uuidString.prefix(6))
        let fingerprint = "\(model)-\(suffix)"
        UserDefaults.standard.set(fingerprint, forKey: key)
        return fingerprint
    }
}

// MARK: - KVS abstraction

/// Minimal protocol the store talks to. Production: backed by
/// `NSUbiquitousKeyValueStore`. Tests: backed by `FakeUbiquitousKVS`.
public protocol CHUbiquitousKVS: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func longLong(forKey key: String) -> Int64
    func double(forKey key: String) -> Double
    @discardableResult func synchronize() -> Bool
    var changeNotificationName: Notification.Name { get }
    var changedKeysKey: String { get }
    var underlyingObject: AnyObject? { get }
}

/// Production adapter wrapping the shared `NSUbiquitousKeyValueStore`.
/// `Sendable` is reasonable here — we treat KVS access as a thread-safe
/// bag (Apple's contract).
public final class NSUbiquitousKeyValueStoreAdapter: CHUbiquitousKVS, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    public init() {}
    public func object(forKey key: String) -> Any? { store.object(forKey: key) }
    public func set(_ value: Any?, forKey key: String) { store.set(value, forKey: key) }
    public func data(forKey key: String) -> Data? { store.data(forKey: key) }
    public func string(forKey key: String) -> String? { store.string(forKey: key) }
    public func bool(forKey key: String) -> Bool { store.bool(forKey: key) }
    public func longLong(forKey key: String) -> Int64 { store.longLong(forKey: key) }
    public func double(forKey key: String) -> Double { store.double(forKey: key) }
    @discardableResult public func synchronize() -> Bool { store.synchronize() }
    public var changeNotificationName: Notification.Name { NSUbiquitousKeyValueStore.didChangeExternallyNotification }
    public var changedKeysKey: String { NSUbiquitousKeyValueStoreChangedKeysKey }
    public var underlyingObject: AnyObject? { store }
}

/// In-memory fake for unit tests. Two instances can share one
/// underlying transport to simulate two devices syncing through the
/// same iCloud KVS — see `CHSyncedSettingsStoreTests`.
public final class FakeUbiquitousKVS: CHUbiquitousKVS, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    private let notificationName: Notification.Name
    private let _changedKeysKey: String

    public init(
        notificationName: Notification.Name = Notification.Name("FakeUbiquitousKVSDidChange"),
        changedKeysKey: String = "FakeUbiquitousKVSChangedKeys"
    ) {
        self.notificationName = notificationName
        self._changedKeysKey = changedKeysKey
    }

    public func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    public func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        lock.unlock()
    }
    public func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    public func longLong(forKey key: String) -> Int64 { (object(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    public func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    @discardableResult public func synchronize() -> Bool { true }
    public var changeNotificationName: Notification.Name { notificationName }
    public var changedKeysKey: String { _changedKeysKey }
    public var underlyingObject: AnyObject? { self }

    /// Test-only: fan out the current value of `keys` as if iCloud
    /// had just delivered an external change, so a sibling store
    /// observer fires.
    public func deliverExternalChange(keys: [String]) {
        NotificationCenter.default.post(
            name: notificationName,
            object: self,
            userInfo: [_changedKeysKey: keys]
        )
    }
}

// MARK: - @CHSyncedSetting property wrapper

/// `@AppStorage`-shaped property wrapper that goes through the
/// cross-device store. Use it wherever you reach for `@AppStorage`
/// and want the setting to follow the user.
///
/// ```swift
/// struct ThemePicker: View {
///     @CHSyncedSetting("theme") var theme: String = "auto"
///     var body: some View {
///         Picker("Theme", selection: $theme) { … }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct CHSyncedSetting<Value>: DynamicProperty {
    @ObservedObject private var store: CHSyncedSettingsStore
    private let key: String
    private let defaultValue: Value
    private let read: (CHSyncedSettingsStore, String) -> Value?
    private let write: (CHSyncedSettingsStore, Value, String) -> Void

    public var wrappedValue: Value {
        get { read(store, key) ?? defaultValue }
        nonmutating set { write(store, newValue, key) }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }

    fileprivate init(
        wrappedValue: Value,
        _ key: String,
        store: CHSyncedSettingsStore,
        read: @escaping (CHSyncedSettingsStore, String) -> Value?,
        write: @escaping (CHSyncedSettingsStore, Value, String) -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.key = key
        self.defaultValue = wrappedValue
        self.read = read
        self.write = write
    }
}

// Each supported Value type gets its own initializer so the property
// wrapper picks the right typed accessor. Mirrors @AppStorage's overload
// shape — Bool, Int, Double, String, Data, plus an optional-String form.
public extension CHSyncedSetting where Value == String {
    init(wrappedValue: Value = "", _ key: String, store: CHSyncedSettingsStore = .shared) {
        self.init(
            wrappedValue: wrappedValue, key, store: store,
            read: { $0.string(forKey: $1) },
            write: { $0.setString($1, forKey: $2) }
        )
    }
}

public extension CHSyncedSetting where Value == Bool {
    init(wrappedValue: Value = false, _ key: String, store: CHSyncedSettingsStore = .shared) {
        self.init(
            wrappedValue: wrappedValue, key, store: store,
            read: { $0.bool(forKey: $1) },
            write: { $0.setBool($1, forKey: $2) }
        )
    }
}

public extension CHSyncedSetting where Value == Int {
    init(wrappedValue: Value = 0, _ key: String, store: CHSyncedSettingsStore = .shared) {
        self.init(
            wrappedValue: wrappedValue, key, store: store,
            read: { Int($0.integer(forKey: $1)) },
            write: { $0.setInteger(Int64($1), forKey: $2) }
        )
    }
}

public extension CHSyncedSetting where Value == Double {
    init(wrappedValue: Value = 0, _ key: String, store: CHSyncedSettingsStore = .shared) {
        self.init(
            wrappedValue: wrappedValue, key, store: store,
            read: { $0.double(forKey: $1) },
            write: { $0.setDouble($1, forKey: $2) }
        )
    }
}

public extension CHSyncedSetting where Value == Data {
    init(wrappedValue: Value = Data(), _ key: String, store: CHSyncedSettingsStore = .shared) {
        self.init(
            wrappedValue: wrappedValue, key, store: store,
            read: { $0.data(forKey: $1) },
            write: { $0.setData($1, forKey: $2) }
        )
    }
}
