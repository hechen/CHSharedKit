import Foundation
import SwiftUI

/// A versioned, remotely refreshable catalog for cloud AI model pickers.
///
/// The package ships a known-good JSON fallback. A validated remote copy is
/// cached in Library/Caches and becomes the startup catalog on later launches.
/// Routine model, pricing, and retirement updates therefore do not require a
/// CHSharedKit or consumer-app release.
public struct CHAICloudModelCatalogManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: String
    public let providers: [Provider]

    public struct Provider: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let recommendedModelID: String
        public let migrationFallbackModelID: String
        public let retiredModelIDs: [String]
        public let models: [Model]
        /// Optional executable descriptor. Older SDKs ignore these fields.
        public var displayName: String? = nil
        public var api: API? = nil
        public var apiKeyURL: URL? = nil
        public var privacyPolicyURL: URL? = nil
    }

    public struct API: Codable, Sendable, Equatable {
        /// Unknown formats are retained as data but never registered for dispatch.
        public let format: String
        public let baseURL: URL
        public let tokenLimitParameter: String

        public var isSupported: Bool {
            format == "openai-chat-completions"
                && ["max_tokens", "max_completion_tokens"].contains(tokenLimitParameter)
        }

        public static func isSafeURL(_ url: URL) -> Bool {
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            return c.scheme == "https" && !(c.host?.isEmpty ?? true)
                && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
        }
    }

    public struct Model: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        public let imageInputPerMillion: Double
        public var capabilities: [String]? = nil
    }

    public func provider(id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else { throw ValidationError.unsupportedSchema(schemaVersion) }
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyRevision
        }
        guard Set(providers.map(\.id)).count == providers.count else {
            throw ValidationError.duplicateProvider
        }
        for provider in providers {
            guard !provider.id.isEmpty else { throw ValidationError.invalidProvider(provider.id) }
            if let api = provider.api {
                guard !["openai", "claude", "custom", "apple-intelligence", "on-device-llm", "on-device-vlm"].contains(provider.id),
                      provider.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                      !(provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                      API.isSafeURL(api.baseURL),
                      [provider.apiKeyURL, provider.privacyPolicyURL].compactMap({ $0 }).allSatisfy(API.isSafeURL)
                else { throw ValidationError.invalidProvider(provider.id) }
            }
            guard !provider.models.isEmpty else { throw ValidationError.emptyProvider(provider.id) }
            let ids = provider.models.map(\.id)
            guard Set(ids).count == ids.count else { throw ValidationError.duplicateModel(provider.id) }
            guard ids.contains(provider.recommendedModelID) else {
                throw ValidationError.missingRecommendedModel(provider.id)
            }
            guard ids.contains(provider.migrationFallbackModelID) else {
                throw ValidationError.missingMigrationFallback(provider.id)
            }
            guard provider.models.allSatisfy({ model in
                !model.id.isEmpty && !model.name.isEmpty &&
                model.inputPerMillion >= 0 && model.outputPerMillion >= 0 &&
                model.imageInputPerMillion >= 0
            }) else {
                throw ValidationError.invalidModel(provider.id)
            }
        }
        return self
    }

    public enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int), emptyRevision, duplicateProvider
        case invalidProvider(String), emptyProvider(String), duplicateModel(String), invalidModel(String)
        case missingRecommendedModel(String), missingMigrationFallback(String)
    }
}

private final class CHAICloudModelCatalogStorage: @unchecked Sendable {
    static let shared = CHAICloudModelCatalogStorage()

    private let lock = NSLock()
    private var value: CHAICloudModelCatalogManifest

    private init() {
        let bundled = Self.loadBundled()
        if let cached = Self.loadCached(), cached.revision >= bundled.revision {
            value = cached
        } else {
            value = bundled
        }
    }

    var snapshot: CHAICloudModelCatalogManifest {
        lock.withLock { value }
    }

    func replace(with manifest: CHAICloudModelCatalogManifest) {
        lock.withLock { value = manifest }
    }

    static func decode(_ data: Data) throws -> CHAICloudModelCatalogManifest {
        try JSONDecoder().decode(CHAICloudModelCatalogManifest.self, from: data).validated()
    }

    static func loadBundled() -> CHAICloudModelCatalogManifest {
        guard let url = Bundle.module.url(forResource: "cloud-model-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? decode(data) else {
            preconditionFailure("CHSharedKit bundled cloud-model-catalog.json is missing or invalid")
        }
        return manifest
    }

    static func loadCached() -> CHAICloudModelCatalogManifest? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decode(data)
    }

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CHSharedKit", directoryHint: .isDirectory)
            .appending(path: "cloud-model-catalog.json", directoryHint: .notDirectory)
    }

    static func persist(_ data: Data) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }
}

/// Observable refresh coordinator. Embed `shared` in settings UI or call
/// `refreshIfNeeded()` from an app launch task.
@MainActor
public final class CHAICloudModelCatalog: ObservableObject {
    public static let shared = CHAICloudModelCatalog()
    public static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/hechen/ai-model-catalog/main/cloud-model-catalog.json"
    )!

    @Published public private(set) var revision: String
    @Published public private(set) var lastRefreshError: String?

    private var hasRefreshed = false

    private init() {
        revision = CHAICloudModelCatalogStorage.shared.snapshot.revision
    }

    public nonisolated static var snapshot: CHAICloudModelCatalogManifest {
        CHAICloudModelCatalogStorage.shared.snapshot
    }

    public func refreshIfNeeded(
        from url: URL = defaultRemoteURL,
        session: URLSession = .shared
    ) async {
        guard !hasRefreshed else { return }
        hasRefreshed = true
        await refresh(from: url, session: session)
    }

    public func refresh(
        from url: URL = defaultRemoteURL,
        session: URLSession = .shared
    ) async {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .useProtocolCachePolicy
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let manifest = try CHAICloudModelCatalogStorage.decode(data)
            // A CDN or URL cache may still serve the previous release. Never
            // replace a newer bundled/cached catalog with that stale response.
            guard manifest.revision >= CHAICloudModelCatalogStorage.shared.snapshot.revision else {
                lastRefreshError = nil
                return
            }
            try CHAICloudModelCatalogStorage.persist(data)
            CHAICloudModelCatalogStorage.shared.replace(with: manifest)
            CHAIManager.shared.synchronizeCatalogProviders(manifest)
            revision = manifest.revision
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }
}
