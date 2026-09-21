import Foundation
import CryptoKit
import Testing
@testable import CHLocalLLM

@Suite("Pinned offline model installation")
struct OfflineModelInstallationTests {
    @Test("Verified files stage separately and atomically publish an exact descriptor")
    func stagedInstallation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let model = fixtureModel(files: files)
        let recorder = URLRecorder()
        let staged = try await OfflineModelInstaller.stage(model, baseDirectory: root, download: { url, progress in
            await recorder.append(url)
            let data = try #require(files[url.lastPathComponent])
            progress(Int64(data.count))
            return try temporaryFile(data, in: root)
        })
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root).isEmpty)
        let validated = try await OfflineModelInstaller.validateForActivation(staged) { _, _ in }
        let records = try OfflineModelInstaller.commit(validated, replacing: [:], baseDirectory: root)
        let installed = try #require(records[model.id])
        #expect(installed.integrityVerified)
        #expect(installed.model == model)
        #expect(installed.directory(baseDirectory: root).path.contains(try #require(model.release).revision))
        #expect(!FileManager.default.fileExists(atPath: staged.directory.path))
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root) == records)
        let urls = await recorder.urls
        #expect(urls.count == files.count)
        #expect(urls.allSatisfy { $0.path.contains("/resolve/" + String(repeating: "a", count: 40) + "/") })
    }

    @Test("A failed update preserves the prior release metadata and bytes")
    func failedUpdatePreservesInstalledRelease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let original = fixtureModel(files: files)
        let oldStage = try await OfflineModelInstaller.stage(original, baseDirectory: root, download: { url, _ in
            try temporaryFile(try #require(files[url.lastPathComponent]), in: root)
        })
        let validated = try await OfflineModelInstaller.validateForActivation(oldStage) { _, _ in }
        let oldRecords = try OfflineModelInstaller.commit(validated, replacing: [:], baseDirectory: root)
        let oldDirectory = try #require(oldRecords[original.id]).directory(baseDirectory: root)
        let newer = fixtureModel(files: files, revision: String(repeating: "b", count: 40))
        await #expect(throws: OfflineModelInstallationError.self) {
            _ = try await OfflineModelInstaller.stage(newer, baseDirectory: root, download: { url, _ in
                var data = try #require(files[url.lastPathComponent])
                if url.lastPathComponent == "model.safetensors" { data[0] ^= 1 }
                return try temporaryFile(data, in: root)
            })
        }
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root) == oldRecords)
        #expect(try Data(contentsOf: oldDirectory.appendingPathComponent("model.safetensors")) == files["model.safetensors"])
        let staging = root.appendingPathComponent("staging")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test("Runtime validation failure preserves the working installation")
    func runtimeFailurePreservesWorkingModel() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let original = fixtureModel(files: files)
        let oldStage = try await OfflineModelInstaller.stage(original, baseDirectory: root, download: { url, _ in
            try temporaryFile(try #require(files[url.lastPathComponent]), in: root)
        })
        let validated = try await OfflineModelInstaller.validateForActivation(oldStage) { _, _ in }
        let records = try OfflineModelInstaller.commit(validated, replacing: [:], baseDirectory: root)
        let newer = fixtureModel(files: files, revision: String(repeating: "c", count: 40))
        let replacement = try await OfflineModelInstaller.stage(newer, baseDirectory: root, download: { url, _ in
            try temporaryFile(try #require(files[url.lastPathComponent]), in: root)
        })
        await #expect(throws: OfflineModelInstallationError.self) {
            _ = try await OfflineModelInstaller.validateForActivation(replacement) { _, _ in
                throw OfflineModelInstallationError.incompleteSnapshot
            }
        }
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root) == records)
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: try #require(records[original.id]).directory(baseDirectory: root)))
        #expect(!FileManager.default.fileExists(atPath: replacement.directory.path))
    }

    @Test("Cancellation after a downloader returns cannot install its snapshot")
    func cancelledDownloadDoesNotPublish() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let model = fixtureModel(files: files)
        let gate = DownloadGate()
        let task = Task {
            try await OfflineModelInstaller.stage(model, baseDirectory: root, download: { url, _ in
                await gate.wait()
                // Simulates a network adapter completing after cancellation.
                return try temporaryFile(try #require(files[url.lastPathComponent]), in: root)
            })
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    @Test("Updating a legacy repo keeps files still used by an installed alias")
    func updatePreservesSharedLegacyDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let original = fixtureModel(files: files, pinned: false)
        let alias = fixtureModel(files: files, id: "custom-alias", pinned: false, isCustom: true)
        let sharedRelativePath = "models/example/model"
        let sharedDirectory = root.appendingPathComponent(sharedRelativePath)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try write(files, to: sharedDirectory)
        let records = [
            original.id: OfflineModelInstallation(model: original, relativeDirectory: sharedRelativePath, integrityVerified: false),
            alias.id: OfflineModelInstallation(model: alias, relativeDirectory: sharedRelativePath, integrityVerified: false)
        ]
        try OfflineModelInstaller.writeRegistry(records, baseDirectory: root)
        let replacement = fixtureModel(files: files, revision: String(repeating: "d", count: 40))
        let staged = try await OfflineModelInstaller.stage(replacement, baseDirectory: root, download: { url, _ in
            try temporaryFile(try #require(files[url.lastPathComponent]), in: root)
        })
        let validated = try await OfflineModelInstaller.validateForActivation(staged) { _, _ in }
        let updated = try OfflineModelInstaller.commit(validated, replacing: records, baseDirectory: root)
        #expect(updated[alias.id] == records[alias.id])
        #expect(updated[original.id]?.model == replacement)
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: sharedDirectory))
        #expect(try Data(contentsOf: sharedDirectory.appendingPathComponent("model.safetensors")) == files["model.safetensors"])
        #expect(OfflineModelInstaller.isDirectoryReferenced(sharedDirectory, by: updated, baseDirectory: root))
        var withoutAlias = updated
        withoutAlias.removeValue(forKey: alias.id)
        #expect(!OfflineModelInstaller.isDirectoryReferenced(sharedDirectory, by: withoutAlias, baseDirectory: root))
    }

    @Test("Retired and unsupported releases are rejected before downloading")
    func rejectsIncompatibleRelease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = URLRecorder()
        for model in [
            fixtureModel(files: fixtureFiles(), status: "retired"),
            fixtureModel(files: fixtureFiles(), minimumRuntimeVersion: 999)
        ] {
            await #expect(throws: OfflineModelInstallationError.self) {
                _ = try await OfflineModelInstaller.stage(model, baseDirectory: root, download: { url, _ in
                    await recorder.append(url)
                    return try temporaryFile(Data(), in: root)
                })
            }
        }
        #expect(await recorder.urls.isEmpty)
    }

    @Test("Legacy snapshots require tokenizers and every indexed weight shard")
    func legacyCompleteness() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = fixtureFiles()
        files.removeValue(forKey: "tokenizer.json")
        try write(files, to: root)
        #expect(!CHLocalMLXStorage.isSnapshotPresent(at: root))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: root))
        try Data(#"{"weight_map":{"a":"model.safetensors","b":"missing.safetensors"}}"#.utf8)
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))
        #expect(!CHLocalMLXStorage.isSnapshotPresent(at: root))
    }

    @Test("Custom vision snapshots cannot activate through the text provider")
    func rejectsVisionSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = fixtureFiles()
        files["config.json"] = Data(#"{"model_type":"qwen2_vl"}"#.utf8)
        try write(files, to: root)
        #expect(throws: OfflineModelInstallationError.self) {
            try OfflineModelInstaller.validateSnapshot(at: root, model: LocalModelCatalog.qwen2VL_2B)
        }
        let inventory = try #require(OfflineModelInstaller.legacyInstallation(LocalModelCatalog.qwen2VL_2B, at: root))
        #expect(inventory.model.id == LocalModelCatalog.qwen2VL_2B.id)
        #expect(!inventory.integrityVerified)
        #expect(inventory.model.release == nil)
    }

    @Test("Startup removes abandoned staging without touching installed releases")
    func cleansAbandonedStaging() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        for path in ["staging/interrupted-a", "staging/interrupted-b/models/example/model", "releases/working"] {
            let directory = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(files, to: directory)
        }
        let model = fixtureModel(files: files)
        let records = [model.id: OfflineModelInstallation(model: model, relativeDirectory: "releases/working", integrityVerified: true)]
        try OfflineModelInstaller.writeRegistry(records, baseDirectory: root)
        try OfflineModelInstaller.cleanAbandonedStaging(baseDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("staging").path))
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root) == records)
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: root.appendingPathComponent("releases/working")))
        try OfflineModelInstaller.cleanAbandonedStaging(baseDirectory: root)
    }

    @Test("Custom downloads cannot overwrite an existing alias for the same repository")
    func customDownloadUsesIndependentSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let original = fixtureModel(files: files, pinned: false)
        let legacyPath = "models/example/model"
        let legacyDirectory = root.appendingPathComponent(legacyPath)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try write(files, to: legacyDirectory)
        let records = [original.id: OfflineModelInstallation(model: original, relativeDirectory: legacyPath, integrityVerified: false)]
        try OfflineModelInstaller.writeRegistry(records, baseDirectory: root)
        let custom = fixtureModel(files: files, id: "custom-alias", pinned: false, isCustom: true)
        let staged = try await OfflineModelInstaller.stageCustom(custom, baseDirectory: root) { staging in
            let directory = staging.appendingPathComponent(legacyPath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var downloaded = files
            downloaded["model.safetensors"] = Data("new custom bytes".utf8)
            try write(downloaded, to: directory)
            return directory
        }
        let validated = try await OfflineModelInstaller.validateForActivation(staged) { _, _ in }
        let updated = try OfflineModelInstaller.commit(validated, replacing: records, baseDirectory: root)
        let installedCustom = try #require(updated[custom.id])
        #expect(updated[original.id] == records[original.id])
        #expect(!installedCustom.integrityVerified)
        #expect(installedCustom.model.release == nil)
        #expect(installedCustom.directory(baseDirectory: root) != legacyDirectory)
        #expect(try Data(contentsOf: legacyDirectory.appendingPathComponent("model.safetensors")) == files["model.safetensors"])
        #expect(try Data(contentsOf: installedCustom.directory(baseDirectory: root).appendingPathComponent("model.safetensors")) == Data("new custom bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.cleanupDirectory.path))
    }

    @Test("Failed custom downloads remove only their staging files")
    func failedCustomDownloadPreservesRegistry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = fixtureFiles()
        let model = fixtureModel(files: files, id: "custom-alias", pinned: false, isCustom: true)
        await #expect(throws: OfflineModelInstallationError.self) {
            _ = try await OfflineModelInstaller.stageCustom(model, baseDirectory: root) { staging in
                try Data("partial weights".utf8).write(to: staging.appendingPathComponent("model.safetensors"))
                throw OfflineModelInstallationError.incompleteSnapshot
            }
        }
        #expect(OfflineModelInstaller.readRegistry(baseDirectory: root).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    @Test("Registry retains removed metadata and distinguishes unverified legacy files")
    func independentInstalledMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LocalModelCatalog.qwen2_5_1_5B
        let installed = OfflineModelInstallation(model: legacy, relativeDirectory: nil, integrityVerified: false)
        try OfflineModelInstaller.writeRegistry([legacy.id: installed], baseDirectory: root)
        let recovered = try #require(OfflineModelInstaller.readRegistry(baseDirectory: root)[legacy.id])
        #expect(recovered.model == legacy)
        #expect(recovered.model.release == nil)
        #expect(!recovered.integrityVerified)
    }

    @Test("Deleting a shared legacy entry does not migrate it back on relaunch")
    @MainActor
    func deletedAliasDoesNotRemigrate() throws {
        let root = try temporaryDirectory()
        let oldBase = CHLocalMLXStorage.baseDirectory
        let oldLegacy = CHLocalMLXStorage.legacyBaseDirectories
        let suiteName = "offline-install-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            CHLocalMLXStorage.baseDirectory = oldBase
            CHLocalMLXStorage.legacyBaseDirectories = oldLegacy
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        CHLocalMLXStorage.baseDirectory = root
        CHLocalMLXStorage.legacyBaseDirectories = []
        let original = LocalModelCatalog.qwen2_5_1_5B
        let repoID = try #require(CHLocalMLXRepoID.from(original.downloadURL))
        let directory = CHLocalMLXStorage.localDirectory(forRepoID: repoID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(fixtureFiles(), to: directory)
        let alias = CustomModelEntry(id: "custom-alias", displayName: "Alias", downloadURL: original.downloadURL,
            sizeBytes: original.sizeBytes, chatTemplate: original.chatTemplate)
        defaults.set(try JSONEncoder().encode([alias]), forKey: "chlocallm.customModels")
        let store = LocalModelStore(defaults: defaults)
        #expect(store.installedModel(forID: original.id) != nil)
        #expect(store.installedModel(forID: alias.id) != nil)
        #expect(OfflineModelInstaller.hasCompletedLegacyMigration(baseDirectory: root))
        store.deleteModel(original)
        #expect(store.installedModel(forID: original.id) == nil)
        #expect(CHLocalMLXStorage.isSnapshotPresent(at: directory))
        let relaunched = LocalModelStore(defaults: defaults)
        #expect(relaunched.installedModel(forID: original.id) == nil)
        #expect(relaunched.installedModel(forID: alias.id) != nil)
    }

    @Test("Missing or corrupt registry cannot retain a stale migration marker")
    func invalidRegistryAllowsMigration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try OfflineModelInstaller.writeRegistry([:], baseDirectory: root, legacyMigrationComplete: true)
        #expect(OfflineModelInstaller.hasCompletedLegacyMigration(baseDirectory: root))
        try Data("corrupt registry".utf8).write(to: OfflineModelInstaller.registryURL(root))
        #expect(!OfflineModelInstaller.hasCompletedLegacyMigration(baseDirectory: root))
        try FileManager.default.removeItem(at: OfflineModelInstaller.registryURL(root))
        #expect(!OfflineModelInstaller.hasCompletedLegacyMigration(baseDirectory: root))
        let relocated = root.appendingPathComponent("new-storage")
        #expect(!OfflineModelInstaller.hasCompletedLegacyMigration(baseDirectory: relocated))
    }

    @Test("Hugging Face URL parsing rejects lookalike hosts")
    func repoURLValidation() {
        #expect(CHLocalMLXRepoID.from(URL(string: "https://huggingface.co/org/model")!) == "org/model")
        #expect(CHLocalMLXRepoID.from(URL(string: "https://huggingface.co.attacker.example/org/model")!) == nil)
        #expect(CHLocalMLXRepoID.from(URL(string: "http://huggingface.co/org/model")!) == nil)
    }
}

private func fixtureFiles() -> [String: Data] {
    ["config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
     "tokenizer.json": Data("{}".utf8), "tokenizer_config.json": Data("{}".utf8),
     "model.safetensors": Data("tiny test fixture".utf8)]
}

private func fixtureModel(
    files: [String: Data], revision: String = String(repeating: "a", count: 40),
    status: String = "active", minimumRuntimeVersion: Int = 1, id: String = "fixture",
    pinned: Bool = true, isCustom: Bool = false
) -> LocalModelInfo {
    let manifest = files.sorted { $0.key < $1.key }.map { path, data in
        LocalModelRelease.File(path: path, sizeBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    return LocalModelInfo(
        id: id, displayName: "Fixture", description: "Local fixture", sizeBytes: Int64(files.values.reduce(0) { $0 + $1.count }),
        quantization: "test", downloadURL: URL(string: "https://huggingface.co/example/model")!, minRAM_GB: 1,
        license: .apache2, quality: .fast, chatTemplate: .chatML, isCustom: isCustom,
        release: pinned ? .init(repoID: "example/model", revision: revision, runtime: "mlx-text", modelType: "qwen2",
            minimumRuntimeVersion: minimumRuntimeVersion, status: status, files: manifest, recommendations: [:]) : nil
    )
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-install-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func temporaryFile(_ data: Data, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
}

private func write(_ files: [String: Data], to root: URL) throws {
    for (path, data) in files { try data.write(to: root.appendingPathComponent(path)) }
}

private actor URLRecorder {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private actor DownloadGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }
    func waitUntilStarted() async {
        if waiting != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}
