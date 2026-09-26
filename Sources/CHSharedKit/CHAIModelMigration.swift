import Foundation
import SwiftUI

// MARK: - Retired-model migration
//
// 2.8.2 — OpenAI's BYOK lineup turned over (gpt-4o, gpt-4o-mini, gpt-4.1
// (+ mini, + nano), o4-mini, gpt-5-instant, gpt-5-thinking). A user who
// picked any of those in Settings → AI before upgrading would land on
// the new build with a stale identifier in UserDefaults, then hit a 404
// on their first request.
//
// 2.9.5 — Anthropic's lineup turned over too: `claude-sonnet-3-7` and
// `claude-haiku-3-5` are deprecated; new default for Claude BYOK is
// `claude-sonnet-4-6`. The migration helper handles BOTH providers
// in one pass with a per-provider idempotency flag, so a user who
// already migrated under 2.8.2 doesn't re-trigger the OpenAI path on
// 2.9.5 launch but DOES get the Claude path checked.
//
// Notice composition: when both providers migrate in the same launch,
// a single combined notice is returned (one alert, lists both
// migrations). When only one provider migrates, the notice title
// names that provider explicitly.

/// Once-per-app, per-provider migration that rewrites retired model IDs
/// forward to each provider's `migrationFallbackModelID`. Designed to be
/// called from each app's launch path (e.g. inside `App.init` or the
/// root view's `.task`) before the first AI request fires.
@MainActor
public enum CHAIModelMigration {

    /// Snapshot returned to callers so they can decide whether and how
    /// to surface the change. `nil` body means there's nothing to show.
    public struct Notice: Sendable, Equatable {
        /// Localized title suitable for a toast banner or alert.
        public let title: String
        /// Body copy explaining what happened and where the new pick lives.
        public let body: String
        /// The retired identifier that was overwritten. Useful for logs.
        /// When multiple providers migrate in the same call this carries
        /// the first migrated identifier; consult `body` for the full
        /// list.
        public let previousModelID: String
        /// The replacement identifier the user is now on. Same caveat
        /// as `previousModelID` for multi-provider migrations.
        public let newModelID: String
    }

    /// Apply the migration for `appName`. Walks every supported
    /// provider, migrates any whose stored ID is in that provider's
    /// `retiredModelIDs`, and returns a single `Notice` covering all
    /// migrations that fired this call. Returns `nil` when nothing
    /// needed migrating.
    ///
    /// Idempotent by value: after a retired ID is replaced, the stored value
    /// is no longer retired. This intentionally avoids a permanent one-time
    /// flag so future retirements delivered by the remote catalog also work.
    @discardableResult
    public static func migrateRetiredModels(appName: String) -> Notice? {
        var migrated: [(provider: String, prev: String, newID: String, newName: String)] = []

        if let m = migrate(
            modelDefaultsKey: "clawd_openai_model",
            retiredSet: CHOpenAIProvider.retiredModelIDs,
            fallbackID: CHOpenAIProvider.migrationFallbackModelID,
            displayLookup: { id in
                CHOpenAIProvider.availableModels.first(where: { $0.id == id })?.name ?? id
            }
        ) {
            migrated.append((provider: "OpenAI", prev: m.prev, newID: m.newID, newName: m.newName))
        }

        if let m = migrate(
            modelDefaultsKey: "clawd_claude_model",
            retiredSet: CHClaudeProvider.retiredModelIDs,
            fallbackID: CHClaudeProvider.migrationFallbackModelID,
            displayLookup: { id in
                CHClaudeProvider.availableModels.first(where: { $0.id == id })?.name ?? id
            }
        ) {
            migrated.append((provider: "Anthropic Claude", prev: m.prev, newID: m.newID, newName: m.newName))
        }

        guard !migrated.isEmpty else { return nil }

        let title: String
        let bodyLines: [String]
        if migrated.count == 1 {
            let m = migrated[0]
            title = String(localized: "\(m.provider) model updated", bundle: .module)
            bodyLines = [
                String(localized: "Your previously-selected model (\(m.prev)) was retired. We switched you to \(m.newName).", bundle: .module),
                "",
                String(localized: "Change anytime in Settings → AI.", bundle: .module)
            ]
        } else {
            title = String(localized: "AI models updated", bundle: .module)
            var lines = [String(localized: "Some of your AI providers retired the model you had selected:", bundle: .module), ""]
            for m in migrated {
                lines.append(String(localized: "• \(m.provider): \(m.prev) → \(m.newName)", bundle: .module))
            }
            lines.append("")
            lines.append(String(localized: "Change anytime in Settings → AI.", bundle: .module))
            bodyLines = lines
        }

        return Notice(
            title: title,
            body: bodyLines.joined(separator: "\n"),
            previousModelID: migrated[0].prev,
            newModelID: migrated[0].newID
        )
    }

    /// Inspect-only sibling that returns whether a migration *would*
    /// fire on any provider, without flipping any flag. Handy for
    /// previews and tests.
    public static func wouldMigrate(appName: String) -> Bool {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "clawd_openai_model"),
           CHOpenAIProvider.retiredModelIDs.contains(stored) {
            return true
        }
        if let stored = defaults.string(forKey: "clawd_claude_model"),
           CHClaudeProvider.retiredModelIDs.contains(stored) {
            return true
        }
        return false
    }

    // MARK: - Internals

    private static func migrate(
        modelDefaultsKey: String,
        retiredSet: Set<String>,
        fallbackID: String,
        displayLookup: (String) -> String
    ) -> (prev: String, newID: String, newName: String)? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: modelDefaultsKey),
              !stored.isEmpty else {
            return nil
        }
        guard retiredSet.contains(stored) else { return nil }

        defaults.set(fallbackID, forKey: modelDefaultsKey)
        return (prev: stored, newID: fallbackID, newName: displayLookup(fallbackID))
    }

    // MARK: - Legacy feature-toggle migration (2.10.0)
    //
    // Apps that pre-date the per-feature override surface stored
    // their own enabled/disabled toggles under per-app keys
    // ("closet_ai_stylist_enabled", "eatwisely_food_parser_enabled",
    // etc.). 2.10.0 unifies those under
    // `ch_ai_feature_enabled_<featureID>`. This helper walks a
    // caller-supplied map of legacy → new keys and copies values
    // forward exactly once per app, then never again.

    /// Idempotently copies legacy feature-toggle values into the
    /// canonical `ch_ai_feature_enabled_<featureID>` keys.
    ///
    /// - Parameters:
    ///   - legacyKeyMap: dict mapping the app's legacy UserDefaults
    ///     key (e.g. `"closet_ai_stylist_enabled"`) to the new
    ///     featureID (e.g. `"closet.ai_stylist"`).
    ///   - appName: stable app name; used in the idempotency flag so
    ///     each app pays the migration once even when CHSharedKit
    ///     is shared across the fleet.
    /// - Returns: `true` if the migration ran on this call (first
    ///   launch under 2.10.0); `false` on every subsequent call.
    @discardableResult
    public static func migrateLegacyFeatureToggles(
        legacyKeyMap: [String: String],
        appName: String
    ) -> Bool {
        let defaults = UserDefaults.standard
        let flagKey = "\(appName.lowercased())_feature_toggles_migrated_v_2_10_0"
        guard !defaults.bool(forKey: flagKey) else { return false }
        defaults.set(true, forKey: flagKey)

        for (legacyKey, featureID) in legacyKeyMap {
            // Only copy when the legacy key was explicitly set (the
            // user toggled the feature off). Unset = "default true",
            // which the resolver already provides via
            // `register(defaults:)`. Don't write `true` defaults
            // explicitly because that defeats the test for "user
            // hasn't touched this".
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            let value = defaults.bool(forKey: legacyKey)
            let newKey = CHAIFeatureProviderResolver.enabledKey(featureID: featureID)
            defaults.set(value, forKey: newKey)
        }
        return true
    }
}

// MARK: - Toast helper

/// SwiftUI view modifier that consumes a `CHAIModelMigration.Notice` and
/// presents it as a one-shot alert. Apps that already have their own
/// toast/banner system can skip this and render the `Notice` themselves.
public struct CHAIModelMigrationAlertModifier: ViewModifier {
    @State private var notice: CHAIModelMigration.Notice?
    private let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    public func body(content: Content) -> some View {
        content
            .task {
                // Run the migration once per appearance of the host view.
                // The flag inside `migrateRetiredModels` ensures this is
                // a no-op after the first successful call.
                if notice == nil {
                    notice = CHAIModelMigration.migrateRetiredModels(appName: appName)
                }
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                ),
                presenting: notice
            ) { _ in
                Button(String(localized: "OK", bundle: .module), role: .cancel) { notice = nil }
            } message: { notice in
                Text(notice.body)
            }
    }
}

extension View {
    /// Drop-in launch hook: attach to the root view and the OpenAI
    /// retired-model migration runs (and surfaces a one-shot alert)
    /// the first time this app launches under 2.8.2.
    ///
    /// ```swift
    /// WindowGroup { RootView()
    ///     .chAIModelMigrationAlert(appName: "EatWisely")
    /// }
    /// ```
    public func chAIModelMigrationAlert(appName: String) -> some View {
        modifier(CHAIModelMigrationAlertModifier(appName: appName))
    }
}
