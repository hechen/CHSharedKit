import SwiftUI
import UniformTypeIdentifiers

// MARK: - Configuration

/// Configuration for the backup settings view
public struct CHBackupConfig {
    public let appName: String
    public let fileExtension: String
    public let iCloudContainerId: String?
    public let fallbackFolderName: String
    
    public init(
        appName: String,
        fileExtension: String,
        iCloudContainerId: String?,
        fallbackFolderName: String
    ) {
        self.appName = appName
        self.fileExtension = fileExtension
        self.iCloudContainerId = iCloudContainerId
        self.fallbackFolderName = fallbackFolderName
    }
}

// MARK: - Storage Extensions

extension CHBackupStorage {
    
    // MARK: - UserDefaults Keys
    
    private static func key(_ suffix: String, appName: String) -> String {
        "\(appName.lowercased())_\(suffix)"
    }
    
    // MARK: - Auto-Backup Settings
    
    /// Whether automatic backup is enabled
    public static func autoBackupEnabled(appName: String) -> Bool {
        UserDefaults.standard.bool(forKey: key("auto_backup_enabled", appName: appName))
    }
    
    public static func setAutoBackupEnabled(_ value: Bool, appName: String) {
        UserDefaults.standard.set(value, forKey: key("auto_backup_enabled", appName: appName))
    }
    
    /// Last auto-backup date
    public static func lastAutoBackupDate(appName: String) -> Date? {
        UserDefaults.standard.object(forKey: key("last_auto_backup_date", appName: appName)) as? Date
    }
    
    public static func setLastAutoBackupDate(_ value: Date?, appName: String) {
        UserDefaults.standard.set(value, forKey: key("last_auto_backup_date", appName: appName))
    }
    
    /// Maximum number of auto-backups to keep (default: 5, range: 1...30)
    public static func maxAutoBackups(appName: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: key("max_auto_backups", appName: appName))
        if v <= 0 { return 5 }
        return min(max(v, 1), 30)
    }
    
    public static func setMaxAutoBackups(_ value: Int, appName: String) {
        let clamped = min(max(value, 1), 30)
        UserDefaults.standard.set(clamped, forKey: key("max_auto_backups", appName: appName))
    }
    
    /// Whether backups are stored in iCloud Drive
    public static func isUsingiCloudDrive(iCloudContainerId: String?) -> Bool {
        guard let containerId = iCloudContainerId else { return false }
        return FileManager.default.url(forUbiquityContainerIdentifier: containerId) != nil
    }
    
    /// Delete old backups beyond the retention limit
    public static func pruneOldBackups(
        fileExtension: String,
        iCloudContainerId: String?,
        fallbackFolderName: String,
        maxBackups: Int
    ) {
        let all = list(
            fileExtension: fileExtension,
            iCloudContainerId: iCloudContainerId,
            fallbackFolderName: fallbackFolderName
        )
        guard all.count > maxBackups else { return }
        
        for fileURL in all.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Get file size for a URL
    public static func fileSize(for url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }
    }
    
    /// Get creation date for a URL
    public static func creationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
    
    /// Delete a backup file
    public static func delete(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Backup Settings View

/// A reusable SwiftUI section for backup settings
///
/// Usage:
/// ```swift
/// CHBackupSettingsView(
///     config: .init(
///         appName: "MyApp",
///         fileExtension: "myappbackup",
///         iCloudContainerId: "iCloud.com.example.myapp",
///         fallbackFolderName: "MyApp Backups"
///     ),
///     itemCount: items.count,
///     isExporting: $isExporting,
///     isImporting: $isImporting,
///     onExport: { exportBackup() },
///     onImportTapped: { showingImportPicker = true },
///     onBackupNow: { await performAutoBackup() }
/// )
/// ```
public struct CHBackupSettingsView: View {
    let config: CHBackupConfig
    let itemCount: Int
    @Binding var isExporting: Bool
    @Binding var isImporting: Bool
    let onExport: () -> Void
    let onImportTapped: () -> Void
    let onBackupNow: () async -> Void
    
    @State private var autoBackupEnabled: Bool
    @State private var maxBackups: Int
    @State private var backupCount: Int = 0
    
    public init(
        config: CHBackupConfig,
        itemCount: Int,
        isExporting: Binding<Bool>,
        isImporting: Binding<Bool>,
        onExport: @escaping () -> Void,
        onImportTapped: @escaping () -> Void,
        onBackupNow: @escaping () async -> Void
    ) {
        self.config = config
        self.itemCount = itemCount
        self._isExporting = isExporting
        self._isImporting = isImporting
        self.onExport = onExport
        self.onImportTapped = onImportTapped
        self.onBackupNow = onBackupNow
        self._autoBackupEnabled = State(initialValue: CHBackupStorage.autoBackupEnabled(appName: config.appName))
        self._maxBackups = State(initialValue: CHBackupStorage.maxAutoBackups(appName: config.appName))
    }
    
    public var body: some View {
        Section {
            // Auto-Backup Toggle
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
                // Last Backup Date
                HStack {
                    Text("Last Backup")
                        .foregroundStyle(.secondary)
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
                
                // Backup Count
                if backupCount > 0 {
                    NavigationLink {
                        CHBackupListView(config: config)
                    } label: {
                        HStack {
                            Text("\(backupCount) backup\(backupCount == 1 ? "" : "s") stored")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                
                // Max Backups Stepper
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
                
                // Back Up Now Button
                Button {
                    Task {
                        await onBackupNow()
                        refreshBackupCount()
                    }
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                }
            }
            
            // Export Backup Button
            Button(action: onExport) {
                HStack {
                    Label("Export Backup", systemImage: "arrow.down.doc")
                    Spacer()
                    if isExporting {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isExporting || itemCount == 0)
            
            // Import Backup Button
            Button(action: onImportTapped) {
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
        .onAppear {
            refreshBackupCount()
        }
    }
    
    /// Call this to refresh the backup count (e.g., after a backup is created)
    public func refreshBackupCount() {
        backupCount = CHBackupStorage.list(
            fileExtension: config.fileExtension,
            iCloudContainerId: config.iCloudContainerId,
            fallbackFolderName: config.fallbackFolderName
        ).count
    }
}


