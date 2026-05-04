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
// `claude-sonnet-4-6`. The migration helper now handles BOTH providers
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
    /// Idempotent at provider granularity — each provider has its own
    /// `<appName>_<provider>_model_migrated_v_2_9_5` flag in
    /// `UserDefaults.standard`. Safe to invoke from multiple launch
    /// hooks; only the first call per provider does work.
    @discardableResult
    public static func migrateRetiredModels(appName: String) -> Notice? {
        var migrated: [(provider: String, prev: String, newID: String, newName: String)] = []

        if let m = migrate(
            appName: appName,
            providerKey: "openai",
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
            appName: appName,
            providerKey: "claude",
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
            title = "\(m.provider) model updated"
            bodyLines = [
                "Your previously-selected model (\(m.prev)) was retired. We switched you to \(m.newName).",
                "",
                "Change anytime in Settings → AI."
            ]
        } else {
            title = "AI models updated"
            var lines = ["Some of your AI providers retired the model you had selected:", ""]
            for m in migrated {
                lines.append("• \(m.provider): \(m.prev) → \(m.newName)")
            }
            lines.append("")
            lines.append("Change anytime in Settings → AI.")
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
        let openAIFlag = migrationFlagKey(appName: appName, providerKey: "openai")
        let claudeFlag = migrationFlagKey(appName: appName, providerKey: "claude")

        if !defaults.bool(forKey: openAIFlag),
           let stored = defaults.string(forKey: "clawd_openai_model"),
           CHOpenAIProvider.retiredModelIDs.contains(stored) {
            return true
        }
        if !defaults.bool(forKey: claudeFlag),
           let stored = defaults.string(forKey: "clawd_claude_model"),
           CHClaudeProvider.retiredModelIDs.contains(stored) {
            return true
        }
        return false
    }

    // MARK: - Internals

    private static func migrate(
        appName: String,
        providerKey: String,
        modelDefaultsKey: String,
        retiredSet: Set<String>,
        fallbackID: String,
        displayLookup: (String) -> String
    ) -> (prev: String, newID: String, newName: String)? {
        let defaults = UserDefaults.standard
        let flagKey = migrationFlagKey(appName: appName, providerKey: providerKey)
        guard !defaults.bool(forKey: flagKey) else { return nil }
        defaults.set(true, forKey: flagKey)

        guard let stored = defaults.string(forKey: modelDefaultsKey),
              !stored.isEmpty else {
            // No selection on file — nothing to migrate. Flag is set
            // above so subsequent launches skip the lookup.
            return nil
        }
        guard retiredSet.contains(stored) else { return nil }

        defaults.set(fallbackID, forKey: modelDefaultsKey)
        return (prev: stored, newID: fallbackID, newName: displayLookup(fallbackID))
    }

    private static func migrationFlagKey(appName: String, providerKey: String) -> String {
        "\(appName.lowercased())_\(providerKey)_model_migrated_v_2_9_5"
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
                Button("OK", role: .cancel) { notice = nil }
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
