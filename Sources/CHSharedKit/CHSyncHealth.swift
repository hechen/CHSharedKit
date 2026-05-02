import Foundation
import SwiftUI

// MARK: - CHSyncHealth (2.9.0)
//
// ## Why this exists
//
// Pre-2.9.0 a user with a sync regression had no surface to diagnose
// the failure. They'd say "AI key didn't sync" and Chen had to either
// reproduce locally on two devices or ask the user to re-enter and
// hope. `CHSyncHealthRegistry` collects per-data-source liveness
// signals (last write, last external update, last force-sync) and
// `CHSyncHealthView` renders them as a "Sync Health" sub-page that
// any app drops into Settings → iCloud.
//
// The registry is a singleton fed by:
//   * `CHSyncedKeychain.set(...)` — writes beat under "keychain.<service>"
//   * `CHSyncedSettingsStore.set*(...)` — writes beat under "settings.<key>"
//   * External-change notifications — beat as "settings.<key>" / external
//   * Force-sync calls — beat as "<source>.sync"
//
// Registry entries are in-memory only. Persisting them across launches
// would be misleading — "last sync 8 days ago" might just mean "we
// haven't reopened the app." The view is intentionally about live
// session state, not historical audit.

@MainActor
public final class CHSyncHealthRegistry: ObservableObject {

    public static let shared = CHSyncHealthRegistry()

    @Published public private(set) var entries: [String: Entry] = [:]
    @Published public private(set) var conflictCount: Int = 0

    private init() {}

    /// Record a local write to `source`. `source` is a freeform
    /// namespace string — e.g. "keychain.chsk-ai-tokens",
    /// "settings.theme", "backups". The view groups by prefix.
    public func recordWrite(source: String, at date: Date = Date()) {
        var entry = entries[source] ?? Entry(source: source)
        entry.lastLocalWrite = date
        entries[source] = entry
    }

    /// Record an external-change notification (another device's write
    /// has arrived locally).
    public func recordExternalUpdate(source: String, at date: Date = Date()) {
        var entry = entries[source] ?? Entry(source: source)
        entry.lastExternalUpdate = date
        entries[source] = entry
    }

    /// Record a successful `synchronize()` round-trip.
    public func recordSync(source: String, at date: Date = Date()) {
        var entry = entries[source] ?? Entry(source: source)
        entry.lastSync = date
        entries[source] = entry
    }

    /// Increment the global conflict counter — used when a sync
    /// primitive detects a drop (incoming value older than local
    /// already-stored value, last-write-wins discarded the incoming).
    public func recordConflict() {
        conflictCount += 1
    }

    /// Trigger a force-resync across every primitive that has one.
    /// Wired to the "Force resync" button in `CHSyncHealthView`.
    public func forceResync() {
        _ = CHSyncedSettingsStore.shared.synchronize()
        // Keychain doesn't expose a synchronize hook — Apple's
        // iCloud Keychain runs continuously. Beat the source so
        // the user sees the button did something.
        recordSync(source: "keychain", at: Date())
        recordSync(source: "settings", at: Date())
    }

    public struct Entry: Identifiable, Sendable {
        public var id: String { source }
        public let source: String
        public var lastLocalWrite: Date?
        public var lastExternalUpdate: Date?
        public var lastSync: Date?

        /// Most recent of the three. The view sorts by this so the
        /// "freshest" sources are at the top.
        public var mostRecent: Date? {
            [lastLocalWrite, lastExternalUpdate, lastSync].compactMap { $0 }.max()
        }
    }
}

// MARK: - View

/// Drop-in Settings sub-page. Apps embed via:
///
/// ```swift
/// NavigationLink("Sync Health") { CHSyncHealthView() }
/// ```
public struct CHSyncHealthView: View {

    @ObservedObject private var registry = CHSyncHealthRegistry.shared
    @State private var resyncFlash: Bool = false

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(sortedEntries) { entry in
                    row(for: entry)
                }
                if sortedEntries.isEmpty {
                    Text("No sync activity yet this session.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("Per-source last write, external update, and sync round-trip. Resets when the app relaunches.")
            }

            if registry.conflictCount > 0 {
                Section("Conflicts") {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(registry.conflictCount) discarded write\(registry.conflictCount == 1 ? "" : "s")")
                    }
                    .font(.subheadline)
                }
            }

            Section {
                Button {
                    registry.forceResync()
                    resyncFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        resyncFlash = false
                    }
                } label: {
                    Label(
                        resyncFlash ? "Resync requested" : "Force resync",
                        systemImage: resyncFlash ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(resyncFlash)
            } footer: {
                Text("Asks every sync primitive to push local state to iCloud and pull whatever's pending. Apple's daemon decides when to actually run the round-trip.")
            }
        }
        .navigationTitle("Sync Health")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var sortedEntries: [CHSyncHealthRegistry.Entry] {
        registry.entries.values.sorted { lhs, rhs in
            switch (lhs.mostRecent, rhs.mostRecent) {
            case let (.some(l), .some(r)): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.source < rhs.source
            }
        }
    }

    @ViewBuilder
    private func row(for entry: CHSyncHealthRegistry.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.source)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                stamp(label: "Wrote", date: entry.lastLocalWrite)
                stamp(label: "Pulled", date: entry.lastExternalUpdate)
                stamp(label: "Synced", date: entry.lastSync)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stamp(label: String, date: Date?) -> some View {
        if let date {
            Text("\(label) \(relative(date))")
        } else {
            Text("\(label) —")
        }
    }

    private func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 1 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        CHSyncHealthView()
            .task {
                let r = CHSyncHealthRegistry.shared
                r.recordWrite(source: "keychain.chsk-ai-tokens", at: Date().addingTimeInterval(-30))
                r.recordExternalUpdate(source: "settings.theme", at: Date().addingTimeInterval(-12))
                r.recordSync(source: "settings", at: Date().addingTimeInterval(-3))
            }
    }
}
