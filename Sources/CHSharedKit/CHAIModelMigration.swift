import Foundation
import SwiftUI

// MARK: - Retired-model migration
//
// 2.8.2 — OpenAI's BYOK lineup turned over: gpt-4o, gpt-4o-mini, gpt-4.1
// (+ mini, + nano), o4-mini, gpt-5-instant, and gpt-5-thinking are no
// longer served. A user who picked any of those in Settings → AI before
// upgrading would land on the new build with a stale identifier in
// UserDefaults, then hit a 404 on their next request.
//
// This file silently rewrites the stored selection forward to
// `gpt-5.4-mini` (the new default) the first time the app launches under
// 2.8.2, and surfaces a one-shot toast so the user knows why their pick
// changed. The migration is keyed by app name so each app pays the
// "first launch" cost exactly once even when CHSharedKit is shared
// across the whole stable.

/// Once-per-app migration that rewrites retired OpenAI model IDs forward
/// to `gpt-5.4-mini`. Designed to be called from each app's launch path
/// (e.g. inside `App.init` or the root view's `.task`) before the first
/// AI request fires.
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
        public let previousModelID: String
        /// The replacement identifier the user is now on.
        public let newModelID: String
    }

    /// Apply the migration for `appName`. Returns a `Notice` the first
    /// time it runs for a given app (so the host can render a toast),
    /// and `nil` on every subsequent call.
    ///
    /// Idempotent — guarded by `<appName>_openai_model_migrated_v_2_8_2`
    /// in `UserDefaults.standard`. Safe to invoke from multiple launch
    /// hooks; only the first call in a process does work.
    @discardableResult
    public static func migrateRetiredModels(appName: String) -> Notice? {
        let defaults = UserDefaults.standard
        let flagKey = migrationFlagKey(appName: appName)
        guard !defaults.bool(forKey: flagKey) else { return nil }
        defaults.set(true, forKey: flagKey)

        let modelKey = "clawd_openai_model"
        let stored = defaults.string(forKey: modelKey)

        // No stored selection — nothing to migrate. Mark the flag so we
        // don't re-check on every launch, but no notice needed.
        guard let stored, !stored.isEmpty else { return nil }

        // Already on a current ID — flag the migration done and bail.
        guard CHOpenAIProvider.retiredModelIDs.contains(stored) else { return nil }

        let target = CHOpenAIProvider.migrationFallbackModelID
        defaults.set(target, forKey: modelKey)

        return Notice(
            title: "OpenAI model updated",
            body: "Your previously-selected model (\(stored)) was retired by OpenAI. We switched you to \(displayName(for: target)). Change anytime in Settings → AI.",
            previousModelID: stored,
            newModelID: target
        )
    }

    /// Inspect-only sibling that returns whether a migration *would*
    /// fire, without flipping the flag. Handy for previews and tests.
    public static func wouldMigrate(appName: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey(appName: appName)) { return false }
        guard let stored = defaults.string(forKey: "clawd_openai_model") else { return false }
        return CHOpenAIProvider.retiredModelIDs.contains(stored)
    }

    // MARK: - Internals

    private static func migrationFlagKey(appName: String) -> String {
        "\(appName.lowercased())_openai_model_migrated_v_2_8_2"
    }

    private static func displayName(for id: String) -> String {
        CHOpenAIProvider.availableModels.first(where: { $0.id == id })?.name ?? id
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
