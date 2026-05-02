import Testing
import Foundation
@testable import CHSharedKit

// MARK: - CHSyncedKeychain
//
// Uses the in-process `_testOverride` so we never touch the host
// keychain. The whole purpose is to exercise the sync-flag plumbing
// + access-group routing without depending on the actual Keychain
// Services partition.
//
// `.serialized` because `_testOverride` is a process-global static —
// running these in parallel races on the override pointer.

@Suite("CHSyncedKeychain", .serialized)
struct CHSyncedKeychainTests {

    @Test("set + get round-trip with default service")
    func setGetRoundTrip() {
        let backing = CHSyncedKeychain.TestBacking()
        CHSyncedKeychain._testOverride = backing
        defer { CHSyncedKeychain._testOverride = nil }

        CHSyncedKeychain.setString("sk-abc-123", forKey: "openai-key")

        #expect(CHSyncedKeychain.string(forKey: "openai-key") == "sk-abc-123")
    }

    @Test("nil write deletes the slot")
    func nilWriteDeletes() {
        let backing = CHSyncedKeychain.TestBacking()
        CHSyncedKeychain._testOverride = backing
        defer { CHSyncedKeychain._testOverride = nil }

        CHSyncedKeychain.setString("present", forKey: "k")
        CHSyncedKeychain.setString(nil, forKey: "k")

        #expect(CHSyncedKeychain.string(forKey: "k") == nil)
    }

    @Test("access group is routed into the storage slot identity")
    func accessGroupRouting() {
        let backing = CHSyncedKeychain.TestBacking()
        CHSyncedKeychain._testOverride = backing
        defer { CHSyncedKeychain._testOverride = nil }

        // Same key, two different access groups → two distinct slots.
        CHSyncedKeychain.setString("a", forKey: "k", accessGroup: "TEAM.app1")
        CHSyncedKeychain.setString("b", forKey: "k", accessGroup: "TEAM.app2")

        #expect(CHSyncedKeychain.string(forKey: "k", accessGroup: "TEAM.app1") == "a")
        #expect(CHSyncedKeychain.string(forKey: "k", accessGroup: "TEAM.app2") == "b")
        // No-access-group read sees neither.
        #expect(CHSyncedKeychain.string(forKey: "k") == nil)
    }

    @Test("idempotent write — same value is a no-op")
    func idempotentWrite() {
        let backing = CHSyncedKeychain.TestBacking()
        CHSyncedKeychain._testOverride = backing
        defer { CHSyncedKeychain._testOverride = nil }

        CHSyncedKeychain.setString("v", forKey: "k")
        let firstSnapshot = backing.dump()
        CHSyncedKeychain.setString("v", forKey: "k")
        let secondSnapshot = backing.dump()

        // The slot still exists with the same content. Nothing was
        // re-written. (We can't observe "was SecItemAdd called?"
        // through the test backing — but we CAN observe that no
        // duplicate or extra slot appeared.)
        #expect(firstSnapshot.count == secondSnapshot.count)
        #expect(firstSnapshot.count == 1)
    }

    @Test("CHAITokenStore round-trips through the synced keychain")
    func tokenStoreRoutesThroughSynced() {
        let backing = CHSyncedKeychain.TestBacking()
        CHSyncedKeychain._testOverride = backing
        defer { CHSyncedKeychain._testOverride = nil }

        CHAITokenStore.setToken("test-key", for: "openai")
        #expect(CHAITokenStore.token(for: "openai") == "test-key")

        // Verify the slot landed under the expected service/account
        // shape (no access group at this layer).
        let slots = backing.dump()
        #expect(slots.contains(where: { $0.service == CHAITokenStore.service && $0.length > 0 }))
    }
}

// MARK: - CHSyncedSettingsStore (in-process two-device propagation)
//
// The bigger win. We instantiate two `CHSyncedSettingsStore` instances
// pointed at the SAME `FakeUbiquitousKVS` transport, write on "device
// A", deliver an external-change notification, assert "device B" sees
// the new value AND that the meta sidecar names the writing device.

@MainActor
@Suite("CHSyncedSettingsStore propagation")
struct CHSyncedSettingsStorePropagationTests {

    @Test("write on store A is visible on store B after fan-out")
    func crossStoreReadAfterFanout() async {
        let transport = FakeUbiquitousKVS()
        let storeA = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPhone-A")
        let storeB = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPad-B")

        storeA.setString("dark", forKey: "theme")
        // Simulate iCloud's external-change delivery on the sibling.
        transport.deliverExternalChange(keys: ["theme"])

        // storeB reads through the same transport, so the value is
        // already visible — the notification is what makes the
        // ObservableObject machinery fire.
        #expect(storeB.string(forKey: "theme") == "dark")
    }

    @Test("meta sidecar records writing device for diagnostic surface")
    func metaSidecar() {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPhone-XYZ")

        store.setString("dark", forKey: "theme")

        let device = store.lastWriteDevice(forKey: "theme")
        let date = store.lastWriteDate(forKey: "theme")
        #expect(device == "iPhone-XYZ")
        #expect(date != nil)
        #expect(date.map { Date().timeIntervalSince($0) < 5 } == true)
    }

    @Test("typed accessors round-trip Bool / Int / Double / Data")
    func typedAccessors() {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport)

        store.setBool(true, forKey: "b")
        store.setInteger(42, forKey: "i")
        store.setDouble(3.14, forKey: "d")
        store.setData(Data([0xDE, 0xAD]), forKey: "raw")

        #expect(store.bool(forKey: "b") == true)
        #expect(store.integer(forKey: "i") == 42)
        #expect(store.double(forKey: "d") == 3.14)
        #expect(store.data(forKey: "raw") == Data([0xDE, 0xAD]))
    }

    @Test("synchronize() beats the sync-health registry")
    func synchronizeBeatsRegistry() async {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport)

        let before = CHSyncHealthRegistry.shared.entries["settings"]?.lastSync
        _ = store.synchronize()
        let after = CHSyncHealthRegistry.shared.entries["settings"]?.lastSync

        #expect(after != nil)
        if let before, let after {
            #expect(after >= before)
        }
    }
}

// MARK: - Pull-first / never-propagate-absent semantics
//
// Direct verification of Chen's spec — the iPhone-has-key,
// iPad-empty, iPad-toggles-on scenario.

@MainActor
@Suite("CHSyncedSettingsStore — never propagate absent")
struct CHSyncedSettingsStoreSemanticTests {

    @Test("Fresh device joins: empty local does not clobber populated cloud")
    func freshDeviceDoesNotClobber() async {
        let transport = FakeUbiquitousKVS()

        // Sim A (iPhone): user has been using the app, BYOK key set.
        let iPhone = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPhone-A")
        iPhone.setString("sk-real-key", forKey: "byok")

        // Pre-condition.
        #expect(iPhone.string(forKey: "byok") == "sk-real-key")
        let metaBefore = iPhone.lastWriteDevice(forKey: "byok")
        #expect(metaBefore == "iPhone-A")

        // Sim B (iPad): fresh device. Spinning up the store does NOT
        // call any setter — `init` is read-only against the transport.
        let iPad = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPad-B")

        // iPad reads the BYOK key — sees the iPhone's value via the
        // shared transport.
        #expect(iPad.string(forKey: "byok") == "sk-real-key")

        // CRITICAL: iPad must NOT have written anything up. The meta
        // sidecar still names iPhone-A as the writing device.
        let metaAfter = iPad.lastWriteDevice(forKey: "byok")
        #expect(metaAfter == "iPhone-A")

        // iPhone still sees its own value — nothing was clobbered.
        #expect(iPhone.string(forKey: "byok") == "sk-real-key")
    }

    @Test("Idempotent setString skips the write — no propagation event")
    func idempotentSetStringSkipped() async throws {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "device")

        store.setString("v", forKey: "k")
        let firstWriteAt = store.lastWriteDate(forKey: "k")

        // Sleep so a real write would advance the timestamp by a
        // measurable amount.
        try await Task.sleep(nanoseconds: 50_000_000)

        store.setString("v", forKey: "k") // SAME value
        let secondWriteAt = store.lastWriteDate(forKey: "k")

        #expect(firstWriteAt == secondWriteAt) // skipped, no advance
    }

    @Test("Explicit clear records a tombstone with isDeleted = true")
    func clearLeavesTombstone() async {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "device")

        store.setString("v", forKey: "k")
        #expect(store.string(forKey: "k") == "v")

        store.clear(forKey: "k")
        #expect(store.string(forKey: "k") == nil)
        // Meta still exists — the tombstone — even though the value
        // is gone. Other devices can use it to distinguish "never
        // set" from "explicitly cleared".
        #expect(store.lastWriteDate(forKey: "k") != nil)
        #expect(store.lastWriteDevice(forKey: "k") == "device")
    }

    @Test("setString(nil) is treated as an explicit clear")
    func nilStringClears() {
        let transport = FakeUbiquitousKVS()
        let store = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "device")

        store.setString("v", forKey: "k")
        store.setString(nil, forKey: "k")

        #expect(store.string(forKey: "k") == nil)
        // Tombstone is recorded.
        #expect(store.lastWriteDate(forKey: "k") != nil)
    }

    @Test("Concurrent writes from two devices within 5s record a conflict")
    func conflictDetectionWithinWindow() async {
        let transport = FakeUbiquitousKVS()
        let iPhone = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPhone-A")
        let iPad = CHSyncedSettingsStore(kvs: transport, deviceFingerprint: "iPad-B")

        let baseline = CHSyncHealthRegistry.shared.conflictCount

        iPhone.setString("first", forKey: "race")
        // Simulate iPad writing to the same key within the conflict
        // window — different device fingerprint, timestamp gap < 5s.
        iPad.setString("second", forKey: "race")

        #expect(CHSyncHealthRegistry.shared.conflictCount == baseline + 1)
    }
}

// MARK: - CHSyncHealthRegistry

@MainActor
@Suite("CHSyncHealthRegistry")
struct CHSyncHealthRegistryTests {

    @Test("recordWrite stores the source and timestamp")
    func recordWrite() {
        let registry = CHSyncHealthRegistry.shared
        let date = Date()
        registry.recordWrite(source: "test.write", at: date)

        let entry = registry.entries["test.write"]
        #expect(entry != nil)
        #expect(entry?.lastLocalWrite == date)
    }

    @Test("mostRecent returns the freshest of write/external/sync")
    func mostRecent() {
        let registry = CHSyncHealthRegistry.shared
        let now = Date()
        registry.recordWrite(source: "test.recent", at: now.addingTimeInterval(-30))
        registry.recordExternalUpdate(source: "test.recent", at: now.addingTimeInterval(-10))
        registry.recordSync(source: "test.recent", at: now.addingTimeInterval(-20))

        #expect(registry.entries["test.recent"]?.mostRecent == now.addingTimeInterval(-10))
    }
}
