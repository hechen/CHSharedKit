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
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .manual:  return "Manual only"
        }
    }

    public var footerText: String {
        switch self {
        case .daily:
            return "Backs up automatically each day on first foreground."
        case .weekly:
            return "Backs up automatically each week on first foreground."
        case .monthly:
            return "Backs up automatically each month on first foreground."
        case .manual:
            return "Auto-backup is off. Use Back Up Now to trigger manually."
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
        .alert("Backup", isPresented: $showResult) {
            Button("OK") {}
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
                Label("Frequency", systemImage: "calendar")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Schedule")
        } footer: {
            Text(frequency.footerText)
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            HStack {
                Label("Auto-Backup", systemImage: "clock.arrow.2.circlepath")
                Spacer()
                Toggle("", isOn: $autoBackupEnabled)
                    .labelsHidden()
                    .onChange(of: autoBackupEnabled) { _, newValue in
                        CHBackupStorage.setAutoBackupEnabled(newValue, appName: config.appName)
                    }
            }

            if autoBackupEnabled {
                HStack {
                    Text("Last Backup").foregroundStyle(.secondary)
                    Spacer()
                    if let last = CHBackupStorage.lastAutoBackupDate(appName: config.appName) {
                        Text(last.formatted(.relative(presentation: .named)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }

                if backupCount > 0 {
                    NavigationLink {
                        CHBackupListView(config: config)
                    } label: {
                        Text("\(backupCount) backup\(backupCount == 1 ? "" : "s") stored")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper("Keep \(maxBackups) backups", value: $maxBackups, in: 1...30)
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
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                }
            }

            Button {
                Task { await runExport() }
            } label: {
                HStack {
                    Label("Export Backup", systemImage: "arrow.down.doc")
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
                    Label("Import Backup", systemImage: "arrow.up.doc")
                    Spacer()
                    if isImporting {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isImporting)
        } header: {
            Text("Backup")
        } footer: {
            if autoBackupEnabled {
                if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
                    Text("Backups are saved to iCloud Drive and sync across all your devices.")
                } else {
                    Text("Backups are saved locally. Enable iCloud Drive for cross-device sync.")
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
                Label("Reveal in Files…", systemImage: "folder")
            }
        } header: {
            Text("Storage")
        } footer: {
            if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
                Text("Backups are stored in iCloud Drive → \(config.appName) → Backups when iCloud is available, otherwise on this device only.")
            } else {
                Text("Backups are stored on this device. Enable iCloud Drive in Settings to sync them across your devices.")
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
            resultMessage = "Backup failed. \(error.localizedDescription)"
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
            resultMessage = "Export failed. \(error.localizedDescription)"
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
                ? "Imported \(imported) record\(imported == 1 ? "" : "s")."
                : "Backup imported."
            showResult = true
            refreshBackupCount()
        } catch {
            resultMessage = "Import failed. \(error.localizedDescription)"
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
    @MainActor
    public static func runScheduledBackupIfDue(
        appName: String,
        fileExtension: String = "backup",
        iCloudContainerID: String? = nil,
        fallbackFolderName: String? = nil,
        encoder: () async throws -> Data
    ) async {
        guard CHBackupStorage.autoBackupEnabled(appName: appName) else { return }
        let raw = UserDefaults.standard.string(forKey: CHBackupFrequency.storageKey(appName: appName))
            ?? CHBackupFrequency.weekly.rawValue
        let frequency = CHBackupFrequency(rawValue: raw) ?? .weekly
        guard let window = frequency.dueAfter else { return }
        if let last = CHBackupStorage.lastAutoBackupDate(appName: appName) {
            guard Date().timeIntervalSince(last) >= window else { return }
        }
        do {
            let data = try await encoder()
            _ = try writeCoordinated(
                appName: appName,
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName ?? "\(appName) Backups",
                data: data
            )
            CHBackupStorage.setLastAutoBackupDate(Date(), appName: appName)
            CHBackupStorage.pruneOldBackups(
                fileExtension: fileExtension,
                iCloudContainerId: iCloudContainerID,
                fallbackFolderName: fallbackFolderName ?? "\(appName) Backups",
                maxBackups: CHBackupStorage.maxAutoBackups(appName: appName)
            )
        } catch {
            // Auto-backup failures are silent — surfacing them on every
            // foreground would be more annoying than helpful. The user will
            // see "Last Backup: 8 days ago" in the UI if writes are
            // persistently failing.
        }
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
    static func writeCoordinated(
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
