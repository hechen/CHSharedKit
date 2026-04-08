import SwiftUI

/// A view displaying the list of stored backups with management options
public struct ClawdBackupListView: View {
    let config: ClawdBackupConfig
    
    @State private var backups: [BackupFileInfo] = []
    @State private var selectedBackup: BackupFileInfo?
    @State private var showingShareSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var backupToDelete: BackupFileInfo?
    
    public init(config: ClawdBackupConfig) {
        self.config = config
    }
    
    public var body: some View {
        List {
            if backups.isEmpty {
                ContentUnavailableView(
                    "No Backups",
                    systemImage: "doc.badge.clock",
                    description: Text("Enable auto-backup to automatically save your data.")
                )
            } else {
                ForEach(backups) { backup in
                    BackupRow(backup: backup, isUsingiCloud: ClawdBackupStorage.isUsingiCloudDrive(iCloudContainerId: config.iCloudContainerId))
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
        .onAppear { refreshBackups() }
        .refreshable { refreshBackups() }
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
    
    private func refreshBackups() {
        let urls = ClawdBackupStorage.list(
            fileExtension: config.fileExtension,
            iCloudContainerId: config.iCloudContainerId,
            fallbackFolderName: config.fallbackFolderName
        )
        backups = urls.map { BackupFileInfo(url: $0) }
    }
    
    private func deleteBackup(_ backup: BackupFileInfo) {
        do {
            try ClawdBackupStorage.delete(at: backup.url)
            withAnimation {
                backups.removeAll { $0.id == backup.id }
            }
        } catch {
            // Could show an error alert here
            print("Failed to delete backup: \(error)")
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
    
    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
        self.displayName = url.deletingPathExtension().lastPathComponent
        self.creationDate = ClawdBackupStorage.creationDate(for: url)
        self.fileSize = ClawdBackupStorage.fileSize(for: url)
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
        ClawdBackupListView(config: .init(
            appName: "Preview",
            fileExtension: "backup",
            iCloudContainerId: nil,
            fallbackFolderName: "Preview Backups"
        ))
    }
}
