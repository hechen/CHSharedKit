import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
import UIKit
#endif

// MARK: - CHBackupFrequency

/// Cadence for the consumer-side auto-backup scheduler. Used by both the
/// in-view frequency picker and the static
/// `CHStorageSection.runScheduledBackupIfDue(...)` entry point that apps
/// call from `scenePhase == .active`.
public enum CHBackupFrequency: String, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case manual

    public var label: String {
        switch self {
        case .daily:   return String(localized: "Daily", bundle: .module)
        case .weekly:  return String(localized: "Weekly", bundle: .module)
        case .monthly: return String(localized: "Monthly", bundle: .module)
        case .manual:  return String(localized: "Manual only", bundle: .module)
        }
    }

    public var footerText: String {
        switch self {
        case .daily:
            return String(localized: "Backs up automatically each day on first foreground.", bundle: .module)
        case .weekly:
            return String(localized: "Backs up automatically each week on first foreground.", bundle: .module)
        case .monthly:
            return String(localized: "Backs up automatically each month on first foreground.", bundle: .module)
        case .manual:
            return String(localized: "Auto-backup is off. Use Back Up Now to trigger manually.", bundle: .module)
        }
    }

    /// Calendar window the scheduler uses to decide if a fresh backup is
    /// due. `nil` for `.manual` — never auto-runs.
    public var dueAfter: TimeInterval? {
        switch self {
        case .daily:   return 24 * 60 * 60
        case .weekly:  return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        case .manual:  return nil
        }
    }

    public static func storageKey(appName: String) -> String {
        "\(appName.lowercased()).backup.frequency"
    }
}

// MARK: - CHStorageSection

/// Drop-in Settings replacement that gives an app the full LiftCoach-quality
/// backup experience in three Form sections — Schedule (frequency picker),
/// Backup (auto-backup toggle, last date, in-app backup list, max stepper,
/// Back Up Now, Export, Import), and Storage (Reveal in Files + status).
///
/// The kit owns:
///   - File IO via `NSFileCoordinator` (iCloud-safe under concurrent writes)
///   - iCloud Documents resolution (with local-Documents fallback)
///   - Daily/weekly/monthly throttle on the auto-backup path
///   - The share sheet + temp-file cleanup for one-shot Export
///   - The file picker + result alert for Import
///   - `shareddocuments://` deep link to Files for Reveal in Files
///   - The in-app backup list (via `CHBackupListView`) with delete-confirmation
///
/// Apps own the data — encoder closure produces backup bytes, decoder closure
/// restores them and returns the count of imported records for the user
/// message. Everything else is the kit.
///
/// Typical use, dropped directly into a `Form` (the type returns three
/// sibling `Section`s):
///
///     Form {
///         // …other settings sections…
///         CHStorageSection(
///             appName: "Closet",
///             fileExtension: "closetbackup",
///             iCloudContainerID: "iCloud.app.chen.closet",
///             itemCount: items.count,
///             encoder: { try await ClosetBackupService.shared.encode() },
///             decoder: { data in
///                 try await ClosetBackupService.shared.decode(data)
///             }
///         )
///     }
public struct CHStorageSection: View {

    private let config: CHBackupConfig
    private let itemCount: Int
    private let defaultFrequency: CHBackupFrequency
    private let encoder: () async throws -> Data
    private let decoder: (Data) async throws -> Int

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImportFilePicker = false
    @State private var resultMessage: String? = nil
    @State private var showResult = false
    @State private var shareableBackup: ShareableBackup? = nil
    @State private var frequencyRaw: String
    @State private var autoBackupEnabled: Bool
    @State private var maxBackups: Int
    @State private var backupCount: Int = 0

    public init(
        appName: String,
        fileExtension: String = "backup",
        iCloudContainerID: String? = nil,
        fallbackFolderName: String? = nil,
        itemCount: Int,
        defaultFrequency: CHBackupFrequency = .weekly,
        encoder: @escaping () async throws -> Data,
        decoder: @escaping (Data) async throws -> Int
    ) {
        self.config = CHBackupConfig(
            appName: appName,
            fileExtension: fileExtension,
            iCloudContainerId: iCloudContainerID,
            fallbackFolderName: fallbackFolderName ?? "\(appName) Backups"
        )
        self.itemCount = itemCount
        self.defaultFrequency = defaultFrequency
        self.encoder = encoder
        self.decoder = decoder

        let raw = UserDefaults.standard.string(forKey: CHBackupFrequency.storageKey(appName: appName))
            ?? defaultFrequency.rawValue
        _frequencyRaw = State(initialValue: raw)
        _autoBackupEnabled = State(initialValue: CHBackupStorage.autoBackupEnabled(appName: appName))
        _maxBackups = State(initialValue: CHBackupStorage.maxAutoBackups(appName: appName))
    }

    private var frequency: CHBackupFrequency {
        CHBackupFrequency(rawValue: frequencyRaw) ?? defaultFrequency
    }

    public var body: some View {
        Group {
            scheduleSection
            backupSection
            storageSection
        }
        .fileImporter(
            isPresented: $showImportFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImportPicked(result) }
        }
        .alert(String(localized: "Backup", bundle: .module), isPresented: $showResult) {
            Button(String(localized: "OK", bundle: .module)) {}
        } message: {
            Text(resultMessage ?? "Done")
        }
        #if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
        .sheet(item: $shareableBackup) { share in
            CHShareSheet(url: share.url) {
                try? FileManager.default.removeItem(at: share.url)
                shareableBackup = nil
            }
            .presentationDetents([.medium, .large])
        }
        #endif
        .onAppear { refreshBackupCount() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Picker(selection: Binding(
                get: { frequency },
                set: {
                    frequencyRaw = $0.rawValue
                    UserDefaults.standard.set(
                        $0.rawValue,
                        forKey: CHBackupFrequency.storageKey(appName: config.appName)
                    )
                }
            )) {
                ForEach(CHBackupFrequency.allCases, id: \.self) { freq in
                    Text(freq.label).tag(freq)
                }
            } label: {
                Label(String(localized: "Frequency", bundle: .module), systemImage: "calendar")
            }
            .pickerStyle(.menu)
        } header: {
            Text(String(localized: "Schedule", bundle: .module))
        } footer: {
            Text(frequency.footerText)
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            HStack {
                Label(String(localized: "Auto-Backup", bundle: .module), systemImage: "clock.arrow.2.circlepath")
                Spacer()
                Toggle("", isOn: $autoBackupEnabled)
                    .labelsHidden()
                    .onChange(of: autoBackupEnabled) { _, newValue in
                        CHBackupStorage.setAutoBackupEnabled(newValue, appName: config.appName)
                    }
            }

            if autoBackupEnabled {
                HStack {
                    Text(String(localized: "Last Backup", bundle: .module)).foregroundStyle(.secondary)
                    Spacer()
                    if let last = CHBackupStorage.lastAutoBackupDate(appName: config.appName) {
                        Text(last.formatted(.relative(presentation: .named)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Never", bundle: .module))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }

                if backupCount > 0 {
                    NavigationLink {
                        CHBackupListView(config: config)
                    } label: {
                        Text(String(localized: "\(backupCount) backups stored", bundle: .module))
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(String(localized: "Keep \(maxBackups) backups", bundle: .module), value: $maxBackups, in: 1...30)
                    .onChange(of: maxBackups) { _, newValue in
                        CHBackupStorage.setMaxAutoBackups(newValue, appName: config.appName)
                        CHBackupStorage.pruneOldBackups(
                            fileExtension: config.fileExtension,
                            iCloudContainerId: config.iCloudContainerId,
                            fallbackFolderName: config.fallbackFolderName,
                            maxBackups: newValue
                        )
                        refreshBackupCount()
                    }

                Button {
                    Task { await runBackupNow() }
                } label: {
                    Label(String(localized: "Back Up Now", bundle: .module), systemImage: "icloud.and.arrow.up")
                }
            }

            Button {
                Task { await runExport() }
            } label: {
                HStack {
                    Label(String(localized: "Export Backup", bundle: .module), systemImage: "arrow.down.doc")
                    Spacer()
                    if isExporting {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isExporting || itemCount == 0)

            Button {
                showImportFilePicker = true
            } label: {
                HStack {
                    Label(String(localized: "Import Backup", bundle: .module), systemImage: "arrow.up.doc")
                    Spacer()
                    if isImporting {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isImporting)
        } header: {
            Text(String(localized: "Backup", bundle: .module))
        } footer: {
            if autoBackupEnabled {
                if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
                    Text(String(localized: "Backups are saved to iCloud Drive and sync across all your devices.", bundle: .module))
                } else {
                    Text(String(localized: "Backups are saved locally. Enable iCloud Drive for cross-device sync.", bundle: .module))
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        #if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
        Section {
            Button {
                revealBackupFolderInFiles()
            } label: {
                Label(String(localized: "Reveal in Files…", bundle: .module), systemImage: "folder")
            }
        } header: {
            Text(String(localized: "Storage", bundle: .module))
        } footer: {
            if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
                Text(String(localized: "Backups are stored in iCloud Drive → \(config.appName) → Backups when iCloud is available, otherwise on this device only.", bundle: .module))
            } else {
                Text(String(localized: "Backups are stored on this device. Enable iCloud Drive in Settings to sync them across your devices.", bundle: .module))
            }
        }
        #endif
    }

    // MARK: - Actions

    private func refreshBackupCount() {
        backupCount = CHBackupStorage.list(
            fileExtension: config.fileExtension,
            iCloudContainerId: config.iCloudContainerId,
            fallbackFolderName: config.fallbackFolderName
        ).count
    }

    private func runBackupNow() async {
        do {
            let data = try await encoder()
            _ = try Self.writeCoordinated(
                appName: config.appName,
                fileExtension: config.fileExtension,
                iCloudContainerId: config.iCloudContainerId,
                fallbackFolderName: config.fallbackFolderName,
                data: data
            )
            CHBackupStorage.setLastAutoBackupDate(Date(), appName: config.appName)
            CHBackupStorage.pruneOldBackups(
                fileExtension: config.fileExtension,
                iCloudContainerId: config.iCloudContainerId,
                fallbackFolderName: config.fallbackFolderName,
                maxBackups: maxBackups
            )
            refreshBackupCount()
        } catch {
            resultMessage = String(localized: "Backup failed. \(error.localizedDescription)", bundle: .module)
            showResult = true
        }
    }

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await encoder()
            let url = try Self.prepareSharableBackup(
                appName: config.appName,
                fileExtension: config.fileExtension,
                data: data
            )
            shareableBackup = ShareableBackup(url: url)
        } catch {
            resultMessage = String(localized: "Export failed. \(error.localizedDescription)", bundle: .module)
            showResult = true
        }
    }

    private func handleImportPicked(_ result: Result<[URL], Error>) async {
        isImporting = true
        defer { isImporting = false }
        do {
            guard let url = try result.get().first else { return }
            let needsScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let imported = try await decoder(data)
            resultMessage = imported > 0
                ? String(localized: "Imported \(imported) records.", bundle: .module)
                : String(localized: "Backup imported.", bundle: .module)
            showResult = true
            refreshBackupCount()
        } catch {
            resultMessage = String(localized: "Import failed. \(error.localizedDescription)", bundle: .module)
            showResult = true
        }
    }

    #if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
    @MainActor
    private func revealBackupFolderInFiles() {
        let dir = CHBackupStorage.backupDirectory(
            iCloudContainerId: config.iCloudContainerId,
            fallbackFolderName: config.fallbackFolderName
        )
        let path = dir.path.removingPercentEncoding ?? dir.path
        var components = URLComponents(string: "shareddocuments://")
        components?.path = path
        guard let url = components?.url else { return }
        UIApplication.shared.open(url) { ok in
            if !ok, let root = URL(string: "shareddocuments://") {
                UIApplication.shared.open(root)
            }
        }
    }
    #endif
}

// MARK: - Static API: scheduler + migration

extension CHStorageSection {

    /// Run a scheduled backup if the user's frequency cadence has elapsed
    /// AND the kit's auto-backup toggle is on. Hook into `scenePhase ==
    /// .active` at the app level so backups run on first foreground without
    /// background-task scheduling. `frequency == .manual` and
    /// auto-backup-disabled both short-circuit.
    ///
    /// 2.8.1: delegates to `CHAutoBackupCoordinator.shared` so concurrent
    /// triggers (scene-activate + foreground notification + view-task)
    /// serialize behind one in-flight check, and the throttle reads the
    /// iCloud directory's most-recent file mtime as ground truth instead
    /// of per-device `UserDefaults`. Multi-device + multi-trigger races
    /// no longer produce duplicate same-day backups. Existing call sites
    /// in consuming apps don't need to change — just bump CHSharedKit.
    public static func runScheduledBackupIfDue(
        appName: String,
        fileExtension: String = "backup",
        iCloudContainerID: String? = nil,
        fallbackFolderName: String? = nil,
        encoder: @Sendable () async throws -> Data
    ) async {
        await CHAutoBackupCoordinator.shared.runIfNeeded(
            appName: appName,
            fileExtension: fileExtension,
            iCloudContainerID: iCloudContainerID,
            fallbackFolderName: fallbackFolderName ?? "\(appName) Backups",
            encoder: encoder
        )
    }

    /// One-shot pass: lift any backup files in the local-fallback directory
    /// into the iCloud Documents container so they sync across devices.
    /// Tracked in UserDefaults so subsequent calls no-op. When iCloud isn't
    /// available (signed-out user, ubiquity not yet resolved) the flag stays
    /// unset and the next call retries.
    @MainActor
    public static func migrateLocalBackupsToICloudIfNeeded(
        appName: String,
        fileExtension: String = "backup",
        iCloudContainerID: String?,
        fallbackFolderName: String? = nil
    ) {
        let key = "chstoragesection.\(appName.lowercased()).icloud_migration_v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        guard let iCloud = iCloudContainerID,
              let ubiq = FileManager.default.url(forUbiquityContainerIdentifier: iCloud) else {
            return
        }
        let cloudDir = ubiq.appendingPathComponent("Documents/Backups", isDirectory: true)
        let folderName = fallbackFolderName ?? "\(appName) Backups"
        let localFallback = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: localFallback.path) else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        try? FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: localFallback, includingPropertiesForKeys: nil)) ?? []
        for src in files where src.pathExtension == fileExtension {
            let dst = cloudDir.appendingPathComponent(src.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dst.path) else {
                try? FileManager.default.removeItem(at: src)
                continue
            }
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: Internal write helpers

    /// `NSFileCoordinator`-backed write that won't generate
    /// "Document Conflict" copies under concurrent edits from multiple
    /// iCloud-enabled devices. Filename pattern matches the kit's reader
    /// (`<AppName>_Backup_<yyyy-MM-dd_HHmmss>.<ext>`) so existing
    /// `CHBackupStorage.list(...)` calls continue to surface the file.
    ///
    /// `nonisolated` so the 2.8.1 `CHAutoBackupCoordinator` actor can
    /// call it off the main actor without a hop. The work is pure I/O
    /// (NSFileCoordinator + Data.write) and touches no main-actor state.
    nonisolated static func writeCoordinated(
        appName: String,
        fileExtension: String,
        iCloudContainerId: String?,
        fallbackFolderName: String,
        data: Data
    ) throws -> URL {
        let dir = CHBackupStorage.backupDirectory(
            iCloudContainerId: iCloudContainerId,
            fallbackFolderName: fallbackFolderName
        )
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = dir.appendingPathComponent(
            "\(appName)_Backup_\(df.string(from: Date())).\(fileExtension)"
        )
        let coord = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var writeError: Error?
        coord.coordinate(writingItemAt: url, options: [], error: &coordError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let err = writeError ?? coordError { throw err }
        return url
    }

    /// Stateless temp-file write for the one-shot Export share path.
    /// Filename embeds version + build + timestamp so a user exporting
    /// several backups can tell them apart in Files / Mail attachments.
    /// Caller is responsible for cleaning up after the share sheet
    /// dismisses.
    static func prepareSharableBackup(
        appName: String,
        fileExtension: String,
        data: Data
    ) throws -> URL {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "\(appName)-\(version)-build\(build)-\(df.string(from: Date())).\(fileExtension)"
        let url = URL.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Internal helpers

private struct ShareableBackup: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit) && !os(macOS) && !os(watchOS) && !os(tvOS)
private struct CHShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onCompletion() }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Preview

#Preview {
    NavigationStack {
        Form {
            CHStorageSection(
                appName: "Preview",
                fileExtension: "previewbackup",
                iCloudContainerID: nil,
                itemCount: 42,
                encoder: { Data("preview-payload".utf8) },
                decoder: { _ in 0 }
            )
        }
    }
}
