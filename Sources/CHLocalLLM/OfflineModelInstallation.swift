import Foundation
import CryptoKit

/// Installation metadata belongs to the device, independently of the remote catalog.
/// Legacy snapshots have no revision or verified manifest and are never relabelled
/// as verified merely because a matching catalog ID is published later.
struct OfflineModelInstallation: Codable, Sendable, Equatable {
    let model: LocalModelInfo
    let relativeDirectory: String?
    let integrityVerified: Bool

    func directory(baseDirectory: URL) -> URL {
        if let relativeDirectory {
            return baseDirectory.appendingPathComponent(relativeDirectory, isDirectory: true)
        }
        if let repoID = CHLocalMLXRepoID.from(model.downloadURL) {
            return CHLocalMLXStorage.resolvedDirectory(forRepoID: repoID)
        }
        return baseDirectory.appendingPathComponent("custom", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }
}

enum OfflineModelInstallationError: LocalizedError {
    case invalidRelease
    case invalidPath(String)
    case invalidResponse(Int)
    case verificationFailed(String)
    case incompleteSnapshot
    case runtimeValidationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRelease: "This model has no supported, pinned release manifest. Refresh the model catalog and try again."
        case .invalidPath(let path): "The model manifest contains an invalid file path: \(path)."
        case .invalidResponse(let status): "The model download failed (HTTP \(status))."
        case .verificationFailed(let path): "The downloaded model file failed verification: \(path). Your installed model was kept."
        case .incompleteSnapshot: "The model snapshot is incomplete. Download it again before selecting it."
        case .runtimeValidationTimedOut: "The model did not finish its local compatibility check in time. Your installed model was kept."
        }
    }
}

/// A staged snapshot cannot affect the selected model until its directory and
/// descriptor have both been committed. Tests inject tiny local fixture files.
enum OfflineModelInstaller {
    typealias DownloadFile = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> URL
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void
    typealias SnapshotValidator = @Sendable (URL, LocalModelInfo) async throws -> Void
    typealias CustomDownload = @Sendable (URL) async throws -> URL

    struct Staged: Sendable {
        let directory: URL
        let cleanupDirectory: URL
        let model: LocalModelInfo
        let destinationRelativePath: String
        let integrityVerified: Bool
    }

    struct ValidatedSnapshot: Sendable {
        fileprivate let staged: Staged
    }

    private struct Registry: Codable {
        let schemaVersion: Int
        let legacyMigrationComplete: Bool
        let installations: [String: OfflineModelInstallation]
    }

    static func readRegistry(baseDirectory: URL) -> [String: OfflineModelInstallation] {
        readRegistryDocument(baseDirectory: baseDirectory)?.installations ?? [:]
    }

    static func hasCompletedLegacyMigration(baseDirectory: URL) -> Bool {
        readRegistryDocument(baseDirectory: baseDirectory)?.legacyMigrationComplete == true
    }

    private static func readRegistryDocument(baseDirectory: URL) -> Registry? {
        guard let data = try? Data(contentsOf: registryURL(baseDirectory)) else { return nil }
        let document: Registry
        if let decoded = try? JSONDecoder().decode(Registry.self, from: data), decoded.schemaVersion == 1 {
            document = decoded
        } else if let records = try? JSONDecoder().decode([String: OfflineModelInstallation].self, from: data) {
            document = Registry(schemaVersion: 1, legacyMigrationComplete: false, installations: records)
        } else {
            return nil
        }
        let records = document.installations.filter { id, record in
            id == record.model.id && (record.relativeDirectory.map(isSafeRelativePath) ?? true)
        }
        return Registry(
            schemaVersion: 1,
            legacyMigrationComplete: document.legacyMigrationComplete && records.count == document.installations.count,
            installations: records
        )
    }

    static func writeRegistry(
        _ records: [String: OfflineModelInstallation], baseDirectory: URL,
        legacyMigrationComplete: Bool? = nil
    ) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let document = Registry(
            schemaVersion: 1,
            legacyMigrationComplete: legacyMigrationComplete ?? hasCompletedLegacyMigration(baseDirectory: baseDirectory),
            installations: records
        )
        let data = try JSONEncoder().encode(document)
        try data.write(to: registryURL(baseDirectory), options: .atomic)
    }

    static func registryURL(_ baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent("installed-model-releases.json")
    }

    /// Called once at store startup, before any new task owns a staging directory.
    /// A terminated process cannot finish its catch/defer cleanup.
    static func cleanAbandonedStaging(baseDirectory: URL) throws {
        let staging = baseDirectory.appendingPathComponent("staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
    }

    static func legacyInstallation(_ model: LocalModelInfo, at directory: URL) -> OfflineModelInstallation? {
        guard CHLocalMLXStorage.isSnapshotPresent(at: directory) else { return nil }
        // Inventory records preserve existing vision/custom models as well as
        // text models. The provider-specific preflight controls activation.
        return OfflineModelInstallation(model: model, relativeDirectory: nil, integrityVerified: false)
    }

    static func stage(
        _ model: LocalModelInfo,
        baseDirectory: URL,
        download: DownloadFile = downloadFile,
        progress: @escaping ProgressHandler = { _, _ in }
    ) async throws -> Staged {
        guard let release = model.release,
              release.runtime == "mlx-text", release.status == "active",
              release.minimumRuntimeVersion <= CHOfflineModelCatalog.runtimeVersion,
              release.revision.count == 40, release.revision.allSatisfy({ $0.isHexDigit }),
              release.repoID.split(separator: "/").count == 2,
              isSafeRelativePath(release.repoID), !release.files.isEmpty
        else { throw OfflineModelInstallationError.invalidRelease }
        var paths = Set<String>()
        for file in release.files {
            guard isSafeRelativePath(file.path), paths.insert(file.path).inserted,
                  file.sizeBytes >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit })
            else { throw OfflineModelInstallationError.invalidPath(file.path) }
        }
        let total = release.files.reduce(Int64(0)) { result, file in
            let sum = result.addingReportingOverflow(file.sizeBytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
        guard total < Int64.max else { throw OfflineModelInstallationError.invalidRelease }
        let stage = baseDirectory.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            var received: Int64 = 0
            for file in release.files {
                try Task.checkCancellation()
                let url = URL(string: "https://huggingface.co")!
                    .appendingPathComponent(release.repoID)
                    .appendingPathComponent("resolve")
                    .appendingPathComponent(release.revision)
                    .appendingPathComponent(file.path)
                let receivedBeforeFile = received
                let temporary = try await download(url) { currentBytes in
                    progress(receivedBeforeFile + min(max(0, currentBytes), file.sizeBytes), total)
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try verifyFile(temporary, sizeBytes: file.sizeBytes, sha256: file.sha256, path: file.path)
                let destination = stage.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: destination)
                received += file.sizeBytes
                progress(received, total)
            }
            try validateSnapshot(at: stage, model: model)
            try Task.checkCancellation()
            let modelFolder = SHA256.hash(data: Data(model.id.utf8)).map { String(format: "%02x", $0) }.joined()
            return Staged(
                directory: stage,
                cleanupDirectory: stage,
                model: model,
                destinationRelativePath: "releases/\(modelFolder)/\(release.revision)-\(UUID().uuidString)",
                integrityVerified: true
            )
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// Custom repositories remain unverified, but never download into a path
    /// used by an existing installation or another alias for that repository.
    static func stageCustom(
        _ model: LocalModelInfo, baseDirectory: URL, download: CustomDownload
    ) async throws -> Staged {
        guard model.isCustom, model.release == nil, CHLocalMLXRepoID.from(model.downloadURL) != nil else {
            throw OfflineModelInstallationError.invalidRelease
        }
        let staging = baseDirectory.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let directory = try await download(staging)
            try Task.checkCancellation()
            guard directory.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
                throw OfflineModelInstallationError.invalidPath(directory.lastPathComponent)
            }
            try validateSnapshot(at: directory, model: model)
            let modelFolder = SHA256.hash(data: Data(model.id.utf8)).map { String(format: "%02x", $0) }.joined()
            return Staged(
                directory: directory, cleanupDirectory: staging, model: model,
                destinationRelativePath: "releases/\(modelFolder)/custom-\(UUID().uuidString)",
                integrityVerified: false
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func validateForActivation(_ staged: Staged, using validator: SnapshotValidator) async throws -> ValidatedSnapshot {
        do {
            try Task.checkCancellation()
            try await validator(staged.directory, staged.model)
            try Task.checkCancellation()
            return ValidatedSnapshot(staged: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged.cleanupDirectory)
            throw error
        }
    }

    /// No suspension points: callers verify task ownership before committing.
    /// The old descriptor remains authoritative if directory or registry writes fail.
    static func commit(
        _ validated: ValidatedSnapshot,
        replacing records: [String: OfflineModelInstallation],
        baseDirectory: URL
    ) throws -> [String: OfflineModelInstallation] {
        let staged = validated.staged
        defer { try? FileManager.default.removeItem(at: staged.cleanupDirectory) }
        let destination = baseDirectory.appendingPathComponent(staged.destinationRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged.directory, to: destination)
        var updated = records
        updated[staged.model.id] = OfflineModelInstallation(
            model: staged.model, relativeDirectory: staged.destinationRelativePath, integrityVerified: staged.integrityVerified
        )
        do {
            try writeRegistry(updated, baseDirectory: baseDirectory)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let previous = records[staged.model.id] {
            let previousDirectory = previous.directory(baseDirectory: baseDirectory)
            if !isDirectoryReferenced(previousDirectory, by: updated, baseDirectory: baseDirectory) {
                try? FileManager.default.removeItem(at: previousDirectory)
            }
        }
        return updated
    }

    /// Custom aliases and migrated catalog entries may share one legacy repo
    /// directory. Updating or deleting one entry must keep the others usable.
    static func isDirectoryReferenced(
        _ directory: URL,
        by records: [String: OfflineModelInstallation],
        baseDirectory: URL
    ) -> Bool {
        let path = directory.standardizedFileURL
        return records.values.contains {
            $0.directory(baseDirectory: baseDirectory).standardizedFileURL == path
        }
    }

    static func verifyFile(_ url: URL, sizeBytes: Int64, sha256: String, path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == sizeBytes else {
            throw OfflineModelInstallationError.verificationFailed(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else {
            throw OfflineModelInstallationError.verificationFailed(path)
        }
    }

    static func validateSnapshot(at directory: URL, model: LocalModelInfo) throws {
        if let release = model.release {
            guard release.runtime == "mlx-text",
                  release.minimumRuntimeVersion <= CHOfflineModelCatalog.runtimeVersion else {
                throw OfflineModelInstallationError.invalidRelease
            }
        }
        guard CHLocalMLXStorage.isSnapshotPresent(at: directory),
              let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = config["model_type"] as? String,
              CHOfflineModelCatalog.supportedModelTypes.contains(type),
              model.release.map({ $0.modelType == type }) ?? true
        else { throw OfflineModelInstallationError.incompleteSnapshot }
    }

    static func downloadFile(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ModelFileDownloadProgress(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw OfflineModelInstallationError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return temporary
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

private final class ModelFileDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }
}
