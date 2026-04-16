import SwiftUI

/// A view displaying the list of stored backups with management options
public struct CHBackupListView: View {
    let config: CHBackupConfig

    @StateObject private var loader: CHBackupLoader
    @State private var selectedBackup: BackupFileInfo?
    @State private var showingShareSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var backupToDelete: BackupFileInfo?

    public init(config: CHBackupConfig) {
        self.config = config
        _loader = StateObject(wrappedValue: CHBackupLoader(config: config))
    }

    public var body: some View {
        List {
            if loader.isLoading && loader.backups.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loading backups from iCloud Drive…")
                                .font(.subheadline)
                            Text("This may take a moment if files are still syncing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else if loader.backups.isEmpty {
                ContentUnavailableView(
                    "No Backups",
                    systemImage: "doc.badge.clock",
                    description: Text("Enable auto-backup to automatically save your data.")
                )
            } else {
                ForEach(loader.backups) { backup in
                    BackupRow(
                        backup: backup,
                        isUsingiCloud: CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedBackup = backup
                        showingShareSheet = true
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            backupToDelete = backup
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loader.start() }
        .onDisappear { loader.stop() }
        .refreshable { loader.refresh() }
        .sheet(isPresented: $showingShareSheet) {
            if let backup = selectedBackup {
                #if os(iOS)
                ShareSheet(activityItems: [backup.url])
                #endif
            }
        }
        .confirmationDialog(
            "Delete Backup?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let backup = backupToDelete {
                    deleteBackup(backup)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = backupToDelete {
                Text("This will permanently delete \"\(backup.displayName)\".")
            }
        }
    }

    private func deleteBackup(_ backup: BackupFileInfo) {
        do {
            try CHBackupStorage.delete(at: backup.url)
            loader.refresh()
        } catch {
            print("Failed to delete backup: \(error)")
        }
    }
}

// MARK: - Backup Loader

/// Observes iCloud Drive (via NSMetadataQuery) and the local fallback folder
/// for backup files. Triggers downloads of any iCloud items that haven't been
/// pulled to the device yet.
@MainActor
final class CHBackupLoader: NSObject, ObservableObject {
    @Published var backups: [BackupFileInfo] = []
    @Published var isLoading: Bool = true

    private let config: CHBackupConfig
    private var metadataQuery: NSMetadataQuery?
    private var observersInstalled = false

    init(config: CHBackupConfig) {
        self.config = config
        super.init()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        // Always do a synchronous local scan first — it's fast and may
        // surface backups that pre-date iCloud being enabled.
        loadLocalBackups()

        if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
            startMetadataQuery()
        } else {
            // No iCloud — local scan was authoritative.
            isLoading = false
        }
    }

    func refresh() {
        isLoading = true
        backups = []
        stopMetadataQuery()
        loadLocalBackups()
        if CHBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId) {
            startMetadataQuery()
        } else {
            isLoading = false
        }
    }

    func stop() {
        stopMetadataQuery()
    }

    // MARK: Local scan

    private func loadLocalBackups() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent(config.fallbackFolderName, isDirectory: true)
        let files = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )) ?? []
        let local = files
            .filter { $0.pathExtension == config.fileExtension }
            .map { BackupFileInfo(url: $0) }
        if !local.isEmpty {
            mergeBackups(local)
        }
    }

    // MARK: NSMetadataQuery

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryUbiquitousDataScope
        ]
        // Match files with the configured extension. iCloud may store
        // not-yet-downloaded files as ".name.ext.icloud" placeholders, so
        // also match those.
        query.predicate = NSPredicate(
            format: "(%K LIKE %@) OR (%K LIKE %@)",
            NSMetadataItemFSNameKey, "*.\(config.fileExtension)",
            NSMetadataItemFSNameKey, "*.\(config.fileExtension).icloud"
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)
        ]

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(queryGatheringDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        center.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        observersInstalled = true
        metadataQuery = query
        query.start()
    }

    private func stopMetadataQuery() {
        guard let query = metadataQuery else { return }
        query.stop()
        if observersInstalled {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            observersInstalled = false
        }
        metadataQuery = nil
    }

    @objc nonisolated private func queryGatheringDidFinish(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleQueryResults()
            self?.isLoading = false
        }
    }

    @objc nonisolated private func queryDidUpdate(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleQueryResults()
        }
    }

    private func handleQueryResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var results: [BackupFileInfo] = []
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }

            // Trigger download if the item isn't current on this device.
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }

            let creationDate = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
            let fileSize = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
            results.append(BackupFileInfo(
                url: url,
                creationDate: creationDate,
                fileSize: fileSize
            ))
        }
        mergeBackups(results)
    }

    // MARK: Merge

    private func mergeBackups(_ newBackups: [BackupFileInfo]) {
        var byId: [String: BackupFileInfo] = [:]
        for b in backups { byId[b.id] = b }
        for b in newBackups { byId[b.id] = b }
        backups = byId.values.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
    }
}

// MARK: - Backup File Info

struct BackupFileInfo: Identifiable {
    let id: String
    let url: URL
    let displayName: String
    let creationDate: Date?
    let fileSize: Int64?

    init(url: URL, creationDate: Date? = nil, fileSize: Int64? = nil) {
        self.id = url.absoluteString
        self.url = url
        // Strip ".icloud" placeholder suffix and any leading dot for display.
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".icloud") {
            name = String(name.dropLast(".icloud".count))
        }
        if name.hasPrefix(".") {
            name = String(name.dropFirst())
        }
        self.displayName = name
        self.creationDate = creationDate ?? CHBackupStorage.creationDate(for: url)
        self.fileSize = fileSize ?? CHBackupStorage.fileSize(for: url)
    }

    var formattedSize: String {
        guard let size = fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        guard let date = creationDate else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Backup Row

struct BackupRow: View {
    let backup: BackupFileInfo
    let isUsingiCloud: Bool

    var body: some View {
        HStack(spacing: 12) {
            // iCloud sync indicator
            Image(systemName: isUsingiCloud ? "icloud.fill" : "internaldrive.fill")
                .foregroundStyle(isUsingiCloud ? .blue : .secondary)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(backup.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(backup.formattedDate)
                    Text("•")
                    Text(backup.formattedSize)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#Preview {
    NavigationStack {
        CHBackupListView(config: .init(
            appName: "Preview",
            fileExtension: "backup",
            iCloudContainerId: nil,
            fallbackFolderName: "Preview Backups"
        ))
    }
}
