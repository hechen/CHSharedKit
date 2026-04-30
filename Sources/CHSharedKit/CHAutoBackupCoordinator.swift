import Foundation

// MARK: - Auto-backup coordinator
//
// 2.8.1 — fixes the "N devices = N backups per day" duplication Chen
// reported (4 backups in 10 minutes on EatWisely + same pattern across
// every app with backup features).
//
// Two races were stacked together in 2.8.0:
//
//   1. Multi-device race. The .daily / .weekly / .monthly throttle
//      checked `CHBackupStorage.lastAutoBackupDate(appName:)` which is
//      stored in *local* `UserDefaults`. iCloud Documents syncs files
//      across devices; the timestamp doesn't. So on a fresh foreground,
//      each device sees its own UserDefaults still empty for today,
//      writes a backup, then UserDefaults updates locally — but the
//      OTHER devices still see their UserDefaults empty and write
//      their own backup. N devices → N backups.
//
//   2. Multi-trigger-per-launch race. `runScheduledBackupIfDue` could be
//      called from `scenePhase == .active`, foreground notification, or
//      a view's `.task { }` block more or less simultaneously. All three
//      reach the throttle check, all three see "nothing today", all
//      three start a write before any of them finishes updating
//      `lastAutoBackupDate`.
//
// This file fixes both:
//
//   * `AutoBackupCoordinator` is an actor — `runIfNeeded(...)` serializes
//     concurrent triggers behind one in-flight check + one decision.
//
//   * `shouldRunAutoBackup(...)` reads the iCloud Documents/Backups
//     directory's most-recent file mtime as the ground truth. iCloud
//     metadata is the same on every device (within sync latency), so
//     two devices both polling at the same instant will see the same
//     "most recent backup was 3 hours ago" answer and both correctly
//     decline. Falls back to local UserDefaults only when iCloud is
//     genuinely unavailable (signed-out user, ubiquity unresolved).
//
//   * `keepOnePerDay(...)` runs after every successful backup AND on
//     first launch of 2.8.1 — groups files by calendar day, keeps the
//     most recent backup per day, deletes the rest. This retroactively
//     dedupes existing iCloud directories where 2.8.0 already wrote
//     N copies for a given day.

/// Process-wide actor that owns auto-backup scheduling. Concurrent
/// trigger sources (scene activate, foreground, view task) all serialize
/// here so only one decision + one write happens per launch window.
public actor CHAutoBackupCoordinator {

    public static let shared = CHAutoBackupCoordinator()

    private var inFlight = false
    private var didRunRetroactiveDedupOnce = Set<String>()

    private init() {}

    /// Single entry point for all auto-backup triggers. Idempotent under
    /// concurrent calls — second caller short-circuits while the first
    /// is still running.
    ///
    /// - Returns: `true` if a backup was actually written, `false` if the
    ///   throttle decided nothing was due (or another caller was already
    ///   in flight). The boolean lets the caller log "skipped" vs "wrote"
    ///   without needing its own state.
    @discardableResult
    public func runIfNeeded(
        appName: String,
        fileExtension: String,
        iCloudContainerID: String?,
        fallbackFolderName: String,
        encoder: @Sendable () async throws -> Data
    ) async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }

        // Retroactive dedup runs once per process per app — collapses
        // any 2.8.0-vintage same-day duplicates before we make a new
        // decision. Cheap on already-clean directories.
        if !didRunRetroactiveDedupOnce.contains(appName) {
            didRunRetroactiveDedupOnce.insert(appName)
            CHBackupStorage.keepOnePerDay(
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName
            )
        }

        guard await CHBackupStorage.autoBackupEnabledRead(appName: appName) else { return false }
        let frequency = CHBackupFrequency.current(appName: appName)
        guard let window = frequency.dueAfter else { return false }
        guard CHBackupStorage.shouldRunAutoBackup(
            appName: appName,
            window: window,
            fileExtension: fileExtension,
            iCloudContainerId: iCloudContainerID,
            fallbackFolderName: fallbackFolderName
        ) else { return false }

        do {
            let data = try await encoder()
            _ = try CHStorageSection.writeCoordinated(
                appName: appName,
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName,
                data: data
            )
            await MainActor.run {
                CHBackupStorage.setLastAutoBackupDate(Date(), appName: appName)
            }
            // Per-day cap kicks in after every write so we self-heal even
            // if two devices race past the iCloud freshness check during
            // the same sync window.
            CHBackupStorage.keepOnePerDay(
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName
            )
            // Then the existing user-controlled cap (default 5 keep-most-
            // recent overall).
            CHBackupStorage.pruneOldBackups(
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName,
                maxBackups: CHBackupStorage.maxAutoBackups(appName: appName)
            )
            return true
        } catch {
            // Auto-backup failures stay silent — surfacing them on every
            // foreground would be more annoying than helpful. If writes
            // are persistently failing the user will notice "Last Backup:
            // 8 days ago" in the Settings UI.
            return false
        }
    }
}

// MARK: - CHBackupStorage extensions for 2.8.1 race fix

extension CHBackupStorage {

    /// Cross-device throttle. Reads the most-recent backup file's
    /// modification time from the iCloud directory; iCloud Documents
    /// syncs file metadata on a similar latency to syncing the file
    /// itself, so two devices polling at roughly the same time will
    /// both see the same answer and both correctly decline.
    ///
    /// Falls back to local `UserDefaults.lastAutoBackupDate` when iCloud
    /// is unavailable. The local fallback is still racy across devices
    /// in that mode, but only one device is normally active without
    /// iCloud at a time so the practical exposure is small.
    nonisolated public static func shouldRunAutoBackup(
        appName: String,
        window: TimeInterval,
        fileExtension: String,
        iCloudContainerId: String?,
        fallbackFolderName: String
    ) -> Bool {
        // First try iCloud truth.
        if let iCloudId = iCloudContainerId,
           let ubiq = FileManager.default.url(forUbiquityContainerIdentifier: iCloudId) {
            let cloudDir = ubiq.appendingPathComponent("Documents/Backups", isDirectory: true)
            if let mostRecent = mostRecentBackupModificationDate(
                in: cloudDir, fileExtension: fileExtension
            ) {
                return Date().timeIntervalSince(mostRecent) >= window
            }
            // No backups yet — first run.
            return true
        }
        // Fallback to UserDefaults timestamp on the local fallback dir.
        let fallback = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(fallbackFolderName, isDirectory: true)
        if let mostRecent = mostRecentBackupModificationDate(
            in: fallback, fileExtension: fileExtension
        ) {
            return Date().timeIntervalSince(mostRecent) >= window
        }
        // Last resort: the per-device UserDefaults timestamp. Empty = run.
        let last = UserDefaults.standard.object(
            forKey: "\(appName.lowercased())_last_auto_backup_date"
        ) as? Date
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= window
    }

    /// Group `<dir>/*.<ext>` files by Gregorian calendar day (local
    /// timezone) and keep only the most recent file per day; delete the
    /// rest. Idempotent — safe to call repeatedly.
    nonisolated public static func keepOnePerDay(
        fileExtension: String,
        iCloudContainerId: String?,
        fallbackFolderName: String
    ) {
        let dir = backupDirectory(
            iCloudContainerId: iCloudContainerId,
            fallbackFolderName: fallbackFolderName
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let backups: [(URL, Date)] = entries
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url in
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (url, date)
            }
        if backups.count <= 1 { return }
        let calendar = Calendar.current
        var keeperPerDay: [DateComponents: (URL, Date)] = [:]
        for entry in backups {
            let components = calendar.dateComponents([.year, .month, .day], from: entry.1)
            if let existing = keeperPerDay[components], existing.1 >= entry.1 {
                // existing keeper is newer — this one becomes a delete candidate
                continue
            }
            // This file is newer than (or equal to) the previous keeper.
            // Demote the previous keeper if there was one.
            if let displaced = keeperPerDay[components] {
                try? FileManager.default.removeItem(at: displaced.0)
            }
            keeperPerDay[components] = entry
        }
        // Anything not in keeperPerDay was already pruned in the loop;
        // do a sweep for files whose mtime is older than the keeper for
        // their day (handles unsorted iteration order).
        let kept = Set(keeperPerDay.values.map { $0.0 })
        for (url, _) in backups where !kept.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Read newest mtime in `<dir>/*.<ext>` via `NSFileCoordinator` so
    /// CloudKit / iCloud's metadata layer can answer with the synced
    /// state, not whatever stale snapshot the local fs has.
    private static func mostRecentBackupModificationDate(
        in dir: URL,
        fileExtension: String
    ) -> Date? {
        var newest: Date?
        let coord = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coord.coordinate(
            readingItemAt: dir,
            options: .immediatelyAvailableMetadataOnly,
            error: &coordError
        ) { url in
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            newest = entries
                .filter { $0.pathExtension == fileExtension }
                .compactMap {
                    try? $0.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                }
                .max()
        }
        return newest
    }

    /// Bridge for the actor — UserDefaults read needs main-actor isolation
    /// in strict-concurrency builds.
    @MainActor
    static func autoBackupEnabledRead(appName: String) -> Bool {
        autoBackupEnabled(appName: appName)
    }
}

// MARK: - CHBackupFrequency current

extension CHBackupFrequency {
    /// Reads the current persisted frequency for an app, defaulting to
    /// weekly when nothing is set. Avoids the actor needing to know the
    /// storage key shape.
    nonisolated public static func current(appName: String) -> CHBackupFrequency {
        let raw = UserDefaults.standard.string(forKey: storageKey(appName: appName))
            ?? CHBackupFrequency.weekly.rawValue
        return CHBackupFrequency(rawValue: raw) ?? .weekly
    }
}
