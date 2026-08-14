import Testing
import Foundation
import SwiftUI
@testable import CHSharedKit

// MARK: - 2.10.0 — Per-feature provider override
//
// Covers:
//   * `CHAIFeatureRegistry.register/features/feature` — the lookup
//     surface the resolver depends on.
//   * Capability filtering — vision-only feature filters out
//     text-only providers; cloud-only feature filters out
//     Apple Intelligence + On-Device LLM.
//   * `CHAIFeatureProviderResolver.providerID(for:)` — override hit
//     vs miss.
//   * `CHAIFeatureProviderResolver.modelID(for:)` — override hit
//     vs miss.
//   * `CHAIModelMigration.migrateLegacyFeatureToggles` — copies
//     legacy values forward, idempotent.
//
// Tests use a custom UserDefaults suite to avoid polluting the host
// app's defaults across test runs.
//
// `.serialized` because the registry and UserDefaults are
// process-globals — parallel tests would race.

@MainActor
@Suite("CHAIFeatureRegistry", .serialized)
struct CHAIFeatureRegistryTests {

    @Test("register/features round-trip")
    func registerRoundTrip() {
        CHAIFeatureRegistry._resetForTesting()
        let f1 = CHAIFeature(id: "test.a", displayName: "A", symbol: "star")
        let f2 = CHAIFeature(id: "test.b", displayName: "B", symbol: "heart")
        CHAIFeatureRegistry.register([f1, f2], appName: "TestApp")

        let registered = CHAIFeatureRegistry.features(for: "TestApp")
        #expect(registered.count == 2)
        #expect(registered.map(\.id) == ["test.a", "test.b"])
    }

    @Test("re-register replaces previous list")
    func reRegisterReplaces() {
        CHAIFeatureRegistry._resetForTesting()
        CHAIFeatureRegistry.register(
            [CHAIFeature(id: "test.a", displayName: "A", symbol: "star")],
            appName: "TestApp"
        )
        CHAIFeatureRegistry.register(
            [CHAIFeature(id: "test.b", displayName: "B", symbol: "heart")],
            appName: "TestApp"
        )

        let registered = CHAIFeatureRegistry.features(for: "TestApp")
        #expect(registered.map(\.id) == ["test.b"])
    }

    @Test("feature(id:) finds across apps")
    func featureLookupAcrossApps() {
        CHAIFeatureRegistry._resetForTesting()
        CHAIFeatureRegistry.register(
            [CHAIFeature(id: "alpha.f1", displayName: "F1", symbol: "1.circle")],
            appName: "Alpha"
        )
        CHAIFeatureRegistry.register(
            [CHAIFeature(id: "beta.f2", displayName: "F2", symbol: "2.circle")],
            appName: "Beta"
        )

        #expect(CHAIFeatureRegistry.feature(id: "alpha.f1")?.displayName == "F1")
        #expect(CHAIFeatureRegistry.feature(id: "beta.f2")?.displayName == "F2")
        #expect(CHAIFeatureRegistry.feature(id: "nope") == nil)
    }
}

// MARK: - Capability filtering

@MainActor
@Suite("CHAIFeatureProviderResolver capability filtering", .serialized)
struct CHAIFeatureCapabilityFilterTests {

    @Test("Vision-only feature filters out text-only providers")
    func visionFiltersTextOnly() {
        // OpenAI + Claude + Custom have visionInput; Apple
        // Intelligence does NOT. The shared CHAIManager registers
        // those four (apart from on-device-llm which the host app
        // wires separately) — see CHAIManager.init.
        let visionFeature = CHAIFeature(
            id: "test.vision",
            displayName: "Vision",
            symbol: "photo",
            requiredCapabilities: [.textInput, .visionInput]
        )
        let eligible = CHAIFeatureProviderResolver.eligibleProviderIDs(for: visionFeature)
        #expect(!eligible.contains(CHAppleIntelligenceProvider.providerID),
                "Apple Intelligence is text-only — must not appear for a vision feature")
        // OpenAI + Claude + Custom should be eligible (the manager
        // registers them in init).
        #expect(eligible.contains(CHOpenAIProvider.providerID))
        #expect(eligible.contains(CHClaudeProvider.providerID))
    }

    @Test("isCloudOnly filters out Apple Intelligence + On-Device LLM")
    func cloudOnlyFiltersOnDevice() {
        let cloudFeature = CHAIFeature(
            id: "test.cloud",
            displayName: "Cloud Only",
            symbol: "cloud",
            requiredCapabilities: [.textInput],
            isCloudOnly: true
        )
        let eligible = CHAIFeatureProviderResolver.eligibleProviderIDs(for: cloudFeature)
        #expect(!eligible.contains(CHAppleIntelligenceProvider.providerID),
                "Apple Intelligence is on-device — must not appear for a cloudOnly feature")
        #expect(!eligible.contains("on-device-llm"),
                "On-Device LLM must not appear for a cloudOnly feature")
    }
}

// MARK: - Provider resolution + override storage

@MainActor
@Suite("CHAIFeatureProviderResolver overrides", .serialized)
struct CHAIFeatureResolverOverrideTests {

    @Test("No override: providerID falls back to active")
    func noOverrideFallsBackToActive() {
        let key = CHAIFeatureProviderResolver.providerOverrideKey(featureID: "test.fallback")
        UserDefaults.standard.removeObject(forKey: key)
        let resolved = CHAIFeatureProviderResolver.providerID(for: "test.fallback")
        #expect(resolved == CHAIManager.shared.activeProviderID)
    }

    @Test("Override hit: providerID returns the override")
    func overrideHit() {
        let featureID = "test.override"
        // Override to OpenAI explicitly. CHOpenAIProvider is
        // pre-registered by CHAIManager.init.
        CHAIFeatureProviderResolver.setProviderOverride(
            CHOpenAIProvider.providerID,
            for: featureID
        )
        defer { CHAIFeatureProviderResolver.setProviderOverride(nil, for: featureID) }

        let resolved = CHAIFeatureProviderResolver.providerID(for: featureID)
        #expect(resolved == CHOpenAIProvider.providerID)
    }

    @Test("Override pointing at unregistered provider falls back to active")
    func overrideForUnregisteredProviderFallsBack() {
        let featureID = "test.bad-override"
        CHAIFeatureProviderResolver.setProviderOverride(
            "definitely-not-a-real-provider",
            for: featureID
        )
        defer { CHAIFeatureProviderResolver.setProviderOverride(nil, for: featureID) }

        let resolved = CHAIFeatureProviderResolver.providerID(for: featureID)
        #expect(resolved == (CHAIManager.shared.effectiveActiveProviderID ?? CHAIManager.shared.activeProviderID))
    }

    @Test("Override pointing at a disabled provider falls back locally")
    func overrideForDisabledProviderFallsBack() {
        let manager = CHAIManager.shared
        let featureID = "test.disabled-override"
        let previousActive = manager.activeProviderID
        let previousDisabled = manager.disabledProviderIDs
        defer {
            CHAIFeatureProviderResolver.setProviderOverride(nil, for: featureID)
            manager.activeProviderID = previousActive
            manager.disabledProviderIDs = previousDisabled
        }

        manager.activeProviderID = CHOpenAIProvider.providerID
        manager.disabledProviderIDs = [CHCustomEndpointProvider.providerID]
        CHAIFeatureProviderResolver.setProviderOverride(
            CHCustomEndpointProvider.providerID,
            for: featureID
        )

        #expect(CHAIFeatureProviderResolver.providerID(for: featureID) == CHOpenAIProvider.providerID)
    }

    @Test("Model override roundtrips through UserDefaults")
    func modelOverrideRoundTrip() {
        let featureID = "test.modelpick"
        CHAIFeatureProviderResolver.setProviderOverride(
            CHOpenAIProvider.providerID,
            for: featureID
        )
        defer {
            CHAIFeatureProviderResolver.setProviderOverride(nil, for: featureID)
        }
        CHAIFeatureProviderResolver.setModelOverride(
            "gpt-5.4-mini",
            for: featureID,
            providerID: CHOpenAIProvider.providerID
        )
        defer {
            CHAIFeatureProviderResolver.setModelOverride(
                nil,
                for: featureID,
                providerID: CHOpenAIProvider.providerID
            )
        }

        #expect(CHAIFeatureProviderResolver.modelID(for: featureID) == "gpt-5.4-mini")
    }

    @Test("Enabled defaults to true and round-trips")
    func enabledDefaultAndRoundTrip() {
        let featureID = "test.enabled"
        // Clean slate.
        UserDefaults.standard.removeObject(
            forKey: CHAIFeatureProviderResolver.enabledKey(featureID: featureID)
        )
        #expect(CHAIFeatureProviderResolver.isEnabled(featureID: featureID) == true)

        CHAIFeatureProviderResolver.setEnabled(false, for: featureID)
        #expect(CHAIFeatureProviderResolver.isEnabled(featureID: featureID) == false)

        CHAIFeatureProviderResolver.setEnabled(true, for: featureID)
        #expect(CHAIFeatureProviderResolver.isEnabled(featureID: featureID) == true)
    }
}

// MARK: - Legacy migration

@MainActor
@Suite("CHAIModelMigration.migrateLegacyFeatureToggles", .serialized)
struct CHAILegacyToggleMigrationTests {

    @Test("Copies legacy values forward exactly once")
    func migratesLegacyKeys() {
        let appName = "TestMigrate-\(UUID().uuidString.prefix(8))"
        let flagKey = "\(appName.lowercased())_feature_toggles_migrated_v_2_10_0"
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.set(false, forKey: "legacy.stylist.enabled")
        UserDefaults.standard.set(true,  forKey: "legacy.tagger.enabled")

        let didMigrate = CHAIModelMigration.migrateLegacyFeatureToggles(
            legacyKeyMap: [
                "legacy.stylist.enabled": "test.stylist",
                "legacy.tagger.enabled":  "test.tagger"
            ],
            appName: appName
        )
        #expect(didMigrate == true)

        let stylistKey = CHAIFeatureProviderResolver.enabledKey(featureID: "test.stylist")
        let taggerKey  = CHAIFeatureProviderResolver.enabledKey(featureID: "test.tagger")
        #expect(UserDefaults.standard.bool(forKey: stylistKey) == false)
        #expect(UserDefaults.standard.bool(forKey: taggerKey) == true)

        // Second call is a no-op.
        let again = CHAIModelMigration.migrateLegacyFeatureToggles(
            legacyKeyMap: [
                "legacy.stylist.enabled": "test.stylist",
                "legacy.tagger.enabled":  "test.tagger"
            ],
            appName: appName
        )
        #expect(again == false)

        // Cleanup.
        UserDefaults.standard.removeObject(forKey: "legacy.stylist.enabled")
        UserDefaults.standard.removeObject(forKey: "legacy.tagger.enabled")
        UserDefaults.standard.removeObject(forKey: stylistKey)
        UserDefaults.standard.removeObject(forKey: taggerKey)
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    @Test("Skips legacy keys that were never explicitly set")
    func skipsUnsetLegacyKeys() {
        let appName = "TestMigrateUnset-\(UUID().uuidString.prefix(8))"
        let flagKey = "\(appName.lowercased())_feature_toggles_migrated_v_2_10_0"
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: "legacy.unset.enabled")

        _ = CHAIModelMigration.migrateLegacyFeatureToggles(
            legacyKeyMap: ["legacy.unset.enabled": "test.unset"],
            appName: appName
        )

        // Helper reads as default-true (registered defaults), but
        // there's no explicit value at the new key.
        let newKey = CHAIFeatureProviderResolver.enabledKey(featureID: "test.unset")
        let raw = UserDefaults.standard.object(forKey: newKey)
        #expect(raw == nil, "Migration must not write a key when the legacy was unset")

        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
