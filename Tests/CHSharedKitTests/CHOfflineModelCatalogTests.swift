import Foundation
import Testing
@testable import CHLocalLLM

@Suite("Remote offline model catalog")
struct CHOfflineModelCatalogTests {
    private func bundled() throws -> CHOfflineModelCatalogManifest {
        try OfflineModelCatalogStorage.loadBundled().validated()
    }
    private func data(revision: Int = 2, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let encoded = try JSONEncoder().encode(bundled())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["revision"] = revision
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func changeFirstModel(_ object: inout [String: Any], _ mutate: (inout [String: Any]) -> Void) {
        var models = object["models"] as! [[String: Any]]
        mutate(&models[0]); object["models"] = models
    }
    private func changeFirstRelease(_ object: inout [String: Any], _ mutate: (inout [String: Any]) -> Void) {
        changeFirstModel(&object) { model in
            var release = model["release"] as! [String: Any]
            mutate(&release); model["release"] = release
        }
    }

    @Test func bundledReleasesArePinnedAndHonest() throws {
        let manifest = try bundled()
        #expect(!manifest.models.isEmpty)
        #expect(manifest.models.contains { $0.release?.status == "active" })
        #expect(manifest.models.allSatisfy { $0.release?.revision.count == 40 })
        let restricted = try #require(manifest.models.first { $0.id == "qwen2.5-3b-q4km" })
        #expect(restricted.license == .qwenResearch)
        #expect(restricted.release?.status == "retired")
        #expect(LocalModelCatalog.default.id != restricted.id)
        #expect(!manifest.models.contains { $0.id == "qwen2-vl-2b-q4" || $0.id == "smollm2-1.7b-q4km" })
    }

    @Test(arguments: ["../weights.safetensors", "/weights.safetensors", "a//b", "a/../b", "a\\b", "a%2fb", "a\n"])
    func rejectsUnsafePaths(path: String) throws {
        let bytes = try data { object in
            changeFirstRelease(&object) { release in
                var files = release["files"] as! [[String: Any]]
                files[0]["path"] = path; release["files"] = files
            }
        }
        #expect(throws: (any Error).self) { try OfflineModelCatalogStorage.decode(bytes) }
    }

    @Test func rejectsUnpinnedOrIncompleteReleaseAndFalseQualification() throws {
        for field in ["revision", "files", "recommendations", "minimumRuntimeVersion", "tokenizerConfig"] {
            let bytes = try data { object in
                changeFirstRelease(&object) { release in
                    switch field {
                    case "revision": release[field] = "main"
                    case "files": release[field] = []
                    case "minimumRuntimeVersion": release[field] = 0
                    case "tokenizerConfig":
                        var files = release["files"] as! [[String: Any]]
                        let index = files.firstIndex { $0["path"] as? String == "tokenizer_config.json" }!
                        files[index]["path"] = "unrelated.json"
                        release["files"] = files
                    default: release[field] = ["liftcoach": ["score": 10, "reason": "Test", "verification": "passed"]]
                    }
                }
            }
            #expect(throws: (any Error).self) { try OfflineModelCatalogStorage.decode(bytes) }
        }
        let spoof = try data { object in
            changeFirstModel(&object) { $0["downloadURL"] = "https://huggingface.co.evil.test/model" }
        }
        #expect(throws: (any Error).self) { try OfflineModelCatalogStorage.decode(spoof) }
        let wrongSize = try data { object in changeFirstModel(&object) { $0["sizeBytes"] = 1 } }
        #expect(throws: (any Error).self) { try OfflineModelCatalogStorage.decode(wrongSize) }
    }

    @Test func unknownRuntimeIsDataButCannotBeSelected() throws {
        let bytes = try data { object in changeFirstRelease(&object) { $0["runtime"] = "future-runtime" } }
        let manifest = try OfflineModelCatalogStorage.decode(bytes)
        #expect(CHOfflineModelCatalog.compatibilityIssue(for: manifest.models[0]) != nil)
        let vision = try data { object in changeFirstRelease(&object) { $0["modelType"] = "qwen2_vl" } }
        #expect(CHOfflineModelCatalog.compatibilityIssue(for: try OfflineModelCatalogStorage.decode(vision).models[0]) != nil)
    }

    @Test @MainActor func refreshCachesMetadataWithoutChangingSelection() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let storage = OfflineModelCatalogStorage(bundled: try bundled(), cacheURL: cache)
        let catalog = CHOfflineModelCatalog(storage: storage)
        let initialGlobal = CHOfflineModelCatalog.snapshot
        let incoming = try data(revision: 10) { object in
            // A new remotely listed ID needs no compile-time enum case.
            changeFirstModel(&object) { $0["id"] = "new-remote-model"; $0["displayName"] = "New remote model" }
        }
        let (session, url) = OfflineCatalogTestProtocol.session(data: incoming)
        defer { session.invalidateAndCancel() }
        await catalog.refresh(from: url, session: session)
        #expect(catalog.revision == 10)
        #expect(catalog.lastRefreshError == nil)
        #expect(catalog.manifest.models[0].id == "new-remote-model")
        #expect(CHOfflineModelCatalog.snapshot == initialGlobal)
        let reopened = OfflineModelCatalogStorage(bundled: try bundled(), cacheURL: cache)
        #expect(reopened.snapshot == catalog.manifest)

        let (staleSession, staleURL) = OfflineCatalogTestProtocol.session(data: try data(revision: 2))
        defer { staleSession.invalidateAndCancel() }
        await catalog.refresh(from: staleURL, session: staleSession)
        #expect(catalog.revision == 10)

        let (badSession, badURL) = OfflineCatalogTestProtocol.session(data: Data("not JSON".utf8))
        defer { badSession.invalidateAndCancel() }
        await catalog.refresh(from: badURL, session: badSession)
        #expect(catalog.lastRefreshError != nil)
        #expect(catalog.revision == 10)
        #expect(reopened.snapshot == catalog.manifest)
    }

    @Test @MainActor func failedHTTPAndSameRevisionMutationKeepWorkingCatalog() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let catalog = CHOfflineModelCatalog(storage: OfflineModelCatalogStorage(bundled: try bundled(), cacheURL: cache))
        let initial = catalog.manifest
        let changed = try data(revision: initial.revision) { object in
            changeFirstModel(&object) { $0["displayName"] = "Changed without revision" }
        }
        let (session, url) = OfflineCatalogTestProtocol.session(data: changed)
        defer { session.invalidateAndCancel() }
        await catalog.refresh(from: url, session: session)
        #expect(catalog.lastRefreshError != nil)
        #expect(catalog.manifest == initial)
        let (failed, unavailable) = OfflineCatalogTestProtocol.session(data: changed, status: 503)
        defer { failed.invalidateAndCancel() }
        await catalog.refresh(from: unavailable, session: failed)
        #expect(catalog.lastRefreshError != nil)
        #expect(catalog.manifest == initial)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}

private final class OfflineCatalogTestProtocol: URLProtocol, @unchecked Sendable {
    private final class Responses: @unchecked Sendable {
        let lock = NSLock()
        var values: [URL: (Data, Int)] = [:]
    }
    private static let responses = Responses()
    static func session(data: Data, status: Int = 200) -> (URLSession, URL) {
        let url = URL(string: "https://offline-catalog.test/\(UUID().uuidString).json")!
        responses.lock.withLock { responses.values[url] = (data, status) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return (URLSession(configuration: config), url)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "offline-catalog.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let (data, status) = Self.responses.lock.withLock({ Self.responses.values.removeValue(forKey: url) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
