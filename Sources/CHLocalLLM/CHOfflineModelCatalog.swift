import Foundation
import Combine

/// Metadata describes a downloadable release, never executable runtime code.
public struct LocalModelRelease: Codable, Sendable, Equatable {
    public let repoID: String
    public let revision: String
    public let runtime: String
    public let modelType: String
    public let minimumRuntimeVersion: Int
    public let status: String
    public let files: [File]
    public let recommendations: [String: Recommendation]
    public let licenseName: String?
    public let licenseURL: URL?

    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let sizeBytes: Int64
        public let sha256: String
        public init(path: String, sizeBytes: Int64, sha256: String) {
            self.path = path; self.sizeBytes = sizeBytes; self.sha256 = sha256
        }
    }
    public struct Recommendation: Codable, Sendable, Equatable {
        public let score: Int
        public let reason: String
        /// unverified, passed, or failed; passed requires a recorded evaluation.
        public let verification: String
        public let evidence: String?
        public init(score: Int, reason: String, verification: String, evidence: String? = nil) {
            self.score = score; self.reason = reason
            self.verification = verification; self.evidence = evidence
        }
    }
    public init(repoID: String, revision: String, runtime: String, modelType: String,
                minimumRuntimeVersion: Int, status: String, files: [File],
                recommendations: [String: Recommendation], licenseName: String? = nil, licenseURL: URL? = nil) {
        self.repoID = repoID; self.revision = revision; self.runtime = runtime
        self.modelType = modelType; self.minimumRuntimeVersion = minimumRuntimeVersion
        self.status = status; self.files = files; self.recommendations = recommendations
        self.licenseName = licenseName; self.licenseURL = licenseURL
    }
}

public struct CHOfflineModelCatalogManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    /// Monotonic integer, independent of each model's immutable repository revision.
    public let revision: Int
    public let models: [LocalModelInfo]

    public init(schemaVersion: Int = 1, revision: Int, models: [LocalModelInfo]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.models = models
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else { throw ValidationError.invalid("Unsupported catalog schema") }
        guard revision > 0, models.count <= 256,
              Set(models.map(\.id)).count == models.count else {
            throw ValidationError.invalid("Invalid catalog revision or duplicate model IDs")
        }
        for model in models {
            guard Self.matches(model.id, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"),
                  !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.minRAM_GB > 0, model.sizeBytes > 0, !model.isCustom,
                  let release = model.release,
                  Self.matches(release.repoID, "^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"),
                  model.downloadURL.absoluteString == "https://huggingface.co/\(release.repoID)",
                  Self.matches(release.revision, "^[a-f0-9]{40}$"),
                  !release.runtime.isEmpty, !release.modelType.isEmpty,
                  release.minimumRuntimeVersion > 0,
                  ["active", "retired"].contains(release.status),
                  !release.files.isEmpty, release.files.count <= 512,
                  Set(release.files.map(\.path)).count == release.files.count else {
                throw ValidationError.invalid("Invalid release for \(model.id)")
            }
            if let url = release.licenseURL {
                guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
                    throw ValidationError.invalid("Invalid license URL for \(model.id)")
                }
            }
            if model.license == .other {
                guard !(release.licenseName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                      release.licenseURL != nil, model.requiresAcknowledgment else {
                    throw ValidationError.invalid("Custom licenses require their name, terms URL and acknowledgment")
                }
            }
            var total: Int64 = 0
            for file in release.files {
                guard Self.isSafeRelativePath(file.path), file.sizeBytes > 0,
                      Self.matches(file.sha256, "^[a-f0-9]{64}$") else {
                    throw ValidationError.invalid("Invalid file manifest for \(model.id)")
                }
                let sum = total.addingReportingOverflow(file.sizeBytes)
                guard !sum.overflow else { throw ValidationError.invalid("Model size overflow") }
                total = sum.partialValue
            }
            let paths = Set(release.files.map(\.path))
            guard total == model.sizeBytes, paths.contains("config.json"), paths.contains("tokenizer_config.json"),
                  paths.contains("tokenizer.json") || paths.contains("tokenizer.model"),
                  paths.contains(where: { $0.hasSuffix(".safetensors") }) else {
                throw ValidationError.invalid("Incomplete file manifest for \(model.id)")
            }
            for recommendation in release.recommendations.values {
                guard (0...100).contains(recommendation.score),
                      !recommendation.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ["unverified", "passed", "failed"].contains(recommendation.verification),
                      recommendation.verification != "passed"
                        || !(recommendation.evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                else { throw ValidationError.invalid("Invalid evaluation record for \(model.id)") }
            }
        }
        return self
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy {
            $0 != "." && $0 != ".." && matches(String($0), "^[A-Za-z0-9._-]+$")
        }
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    public enum ValidationError: LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}

/// Locked snapshot serves synchronous legacy catalog callers. Each test can own
/// independent storage so refresh tests never change the user's selected catalog.
final class OfflineModelCatalogStorage: @unchecked Sendable {
    static let shared = OfflineModelCatalogStorage(bundled: loadBundled(), cacheURL: defaultCacheURL)
    private let lock = NSLock()
    private var value: CHOfflineModelCatalogManifest
    let cacheURL: URL

    init(bundled: CHOfflineModelCatalogManifest, cacheURL: URL) {
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL), let cached = try? Self.decode(data),
           cached.revision > bundled.revision {
            value = cached
        } else { value = bundled }
    }
    var snapshot: CHOfflineModelCatalogManifest { lock.withLock { value } }
    func replace(_ manifest: CHOfflineModelCatalogManifest, data: Data) throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        lock.withLock { value = manifest }
    }
    static func decode(_ data: Data) throws -> CHOfflineModelCatalogManifest {
        guard data.count <= 2_000_000 else {
            throw CHOfflineModelCatalogManifest.ValidationError.invalid("Catalog is too large")
        }
        return try JSONDecoder().decode(CHOfflineModelCatalogManifest.self, from: data).validated()
    }
    static func loadBundled() -> CHOfflineModelCatalogManifest {
        guard let url = Bundle.module.url(forResource: "offline-model-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let manifest = try? decode(data) else {
            preconditionFailure("CHLocalLLM bundled offline catalog is missing or invalid")
        }
        return manifest
    }
    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CHSharedKit/offline-model-catalog.json")
    }
}

/// Refreshes metadata only. Model downloads and installed records belong to
/// LocalModelStore and cannot be changed by a catalog refresh.
@MainActor
public final class CHOfflineModelCatalog: ObservableObject {
    public static let shared = CHOfflineModelCatalog(storage: .shared)
    nonisolated public static let defaultRemoteURL = URL(string:
        "https://raw.githubusercontent.com/hechen/ai-model-catalog/main/offline-model-catalog.json")!
    nonisolated public static let runtimeVersion = 1
    /// Mirrors MLXLLM 3.31.3's text registry. A model still has to pass load and
    /// generation checks; architecture registration alone is not qualification.
    nonisolated public static let supportedModelTypes: Set<String> = [
        "mistral", "llama", "phi", "phi3", "phimoe", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "gemma4", "gemma4_text", "qwen2", "qwen3", "qwen3_moe", "qwen3_next", "qwen3_5", "qwen3_5_moe",
        "qwen3_5_text", "minicpm", "starcoder2", "cohere", "openelm", "internlm2", "deepseek_v3", "granite",
        "granitemoehybrid", "mimo", "mimo_v2_flash", "minimax", "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5", "lfm2", "baichuan_m1", "exaone4",
        "gpt_oss", "lille-130m", "olmoe", "olmo2", "olmo3", "bailing_moe", "lfm2_moe", "nanochat",
        "nemotron_h", "afmoe", "jamba_3b", "mistral3", "apertus"
    ]
    @Published public private(set) var revision: Int
    @Published public private(set) var lastRefreshError: String?
    @Published public private(set) var isRefreshing = false
    private var hasRefreshed = false
    private let storage: OfflineModelCatalogStorage

    init(storage: OfflineModelCatalogStorage) { self.storage = storage; revision = storage.snapshot.revision }
    nonisolated public static var snapshot: CHOfflineModelCatalogManifest { OfflineModelCatalogStorage.shared.snapshot }
    var manifest: CHOfflineModelCatalogManifest { storage.snapshot }

    nonisolated public static func compatibilityIssue(for model: LocalModelInfo) -> String? {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst) || arch(x86_64)
        return String(localized: "On-device models require a supported Apple Silicon device.", bundle: .module)
        #else
        guard let release = model.release else {
            return LocalModelCatalog.isVisionCapable(model.id)
                ? String(localized: "This model requires image-model support.", bundle: .module) : nil
        }
        if release.status == "retired" { return String(localized: "This model is no longer offered for download.", bundle: .module) }
        if release.minimumRuntimeVersion > runtimeVersion { return String(localized: "Update the app to use this model.", bundle: .module) }
        if release.runtime != "mlx-text" || !supportedModelTypes.contains(release.modelType) {
            return String(localized: "This model isn't supported by this version of the app.", bundle: .module)
        }
        return nil
        #endif
    }

    public func refreshIfNeeded(from url: URL = defaultRemoteURL, session: URLSession = .shared) async {
        guard !hasRefreshed else { return }
        hasRefreshed = true
        await refresh(from: url, session: session)
    }
    public func refresh(from url: URL = defaultRemoteURL, session: URLSession = .shared) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard url.scheme == "https", url.user == nil, url.password == nil else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https" else { throw URLError(.badServerResponse) }
            let incoming = try OfflineModelCatalogStorage.decode(data)
            let current = storage.snapshot
            if incoming.revision < current.revision { lastRefreshError = nil; return }
            if incoming.revision == current.revision {
                guard incoming == current else {
                    throw CHOfflineModelCatalogManifest.ValidationError.invalid("Catalog content changed without a new revision")
                }
                lastRefreshError = nil
                return
            }
            try storage.replace(incoming, data: data)
            revision = incoming.revision
            lastRefreshError = nil
        } catch { lastRefreshError = error.localizedDescription }
    }
}
