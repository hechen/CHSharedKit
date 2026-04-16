import Foundation

public struct CHBackupFile: Codable, Sendable {
    public let exportDate: Date
    public let appVersion: String
    public let payload: Data

    public init(exportDate: Date = Date(), appVersion: String, payload: Data) {
        self.exportDate = exportDate
        self.appVersion = appVersion
        self.payload = payload
    }
}

public enum CHBackupStorage {
    public static func backupDirectory(iCloudContainerId: String?, fallbackFolderName: String) -> URL {
        let fm = FileManager.default
        if let container = iCloudContainerId,
           let icloud = fm.url(forUbiquityContainerIdentifier: container) {
            let dir = icloud.appendingPathComponent("Documents/Backups", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = docs.appendingPathComponent(fallbackFolderName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func write(
        fileExtension: String,
        appName: String,
        data: Data,
        iCloudContainerId: String?,
        fallbackFolderName: String
    ) throws -> URL {
        let dir = backupDirectory(iCloudContainerId: iCloudContainerId, fallbackFolderName: fallbackFolderName)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(appName)_Backup_\(df.string(from: Date())).\(fileExtension)"
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func list(fileExtension: String, iCloudContainerId: String?, fallbackFolderName: String) -> [URL] {
        let dir = backupDirectory(iCloudContainerId: iCloudContainerId, fallbackFolderName: fallbackFolderName)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == fileExtension }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l > r
            }
    }
}
