// CHLocalMLXSupport.swift
// Shared helpers for the MLX-backed on-device providers in CHSharedKit 2.5.0.
//
// Centralizes:
//   - The HubApi instance pointed at our shared App Group / App Support directory.
//   - Catalyst / unsupported-platform detection so providers can short-circuit
//     before calling into MLX (which would crash on Metal-less Catalyst builds).
//   - The cold-start latency estimate so UI can show a "this may take a moment"
//     spinner before the first prompt of a freshly loaded model.
//   - Registration helpers that gate `CHAIManager.registerProvider(...)` on
//     "is at least one MLX model installed" so apps don't expose an on-device
//     row in their picker that would just throw on first tap.

import Foundation
import CHSharedKit

#if canImport(Hub)
import Hub
#endif

// MARK: - Platform support

public enum CHLocalMLXPlatform {
    /// True when MLX inference can run on this binary.
    /// MLX requires a Metal-capable Apple Silicon GPU, which Mac Catalyst does not expose.
    public static var isSupported: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return true
        #endif
    }

    /// Throws ``CHAIError.unsupportedPlatform`` when MLX cannot run on this binary.
    public static func requireSupported() throws {
        if !isSupported { throw CHAIError.unsupportedPlatform }
    }
}

// MARK: - Cold-start latency estimate

/// Rough estimate of how long the first call to a freshly loaded model will
/// take. Driven by quantization + parameter count; surface this to UI so the
/// first-token spinner doesn't look like a hang.
public enum CHLocalMLXColdStart {
    /// Returns the cold-start estimate (in seconds) for a model whose on-disk
    /// size is `bytes`. The model load itself dominates first-call latency on
    /// MLX (weights mmap + Metal compile), so we map size → seconds with a
    /// floor for tiny models.
    public static func estimate(forBytes bytes: Int64) -> TimeInterval {
        let gb = Double(bytes) / 1_073_741_824
        // Empirically: ~3 s per GB on M1, ~1.5 s per GB on M3+. Use a
        // conservative midpoint and clamp to a 1.5 s floor so callers always
        // show *some* spinner.
        return max(1.5, gb * 2.5)
    }
}

// MARK: - Repo-id helpers

/// MLX models are addressed by Hugging Face repo id (e.g. `mlx-community/Qwen2.5-3B-Instruct-4bit`).
/// `LocalModelInfo.downloadURL` carries the repo's HF homepage URL for backwards
/// compatibility with the existing `LocalModelInfo` shape — these helpers extract
/// the repo id back out for `Hub.Repo` / `ModelConfiguration` use.
public enum CHLocalMLXRepoID {
    /// Extracts the `org/name` repo id from a `huggingface.co/...` URL.
    /// Returns nil if the URL is not a Hugging Face repo URL.
    public static func from(_ url: URL) -> String? {
        guard let host = url.host, host.contains("huggingface.co") else { return nil }
        // Strip leading "/", drop trailing path components like /resolve/.../file.
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        // Stop at "resolve", "blob", "tree" — those are the file-view paths.
        let stopWords: Set<String> = ["resolve", "blob", "tree", "raw"]
        var idParts: [String] = []
        for part in parts {
            if stopWords.contains(part) { break }
            idParts.append(part)
        }
        guard idParts.count >= 2 else { return nil }
        return idParts.prefix(2).joined(separator: "/")
    }
}

// MARK: - Storage

/// The on-disk root for MLX model snapshots. The effective layout is:
///
///   <baseDirectory>/models/<repo-id>/
///
/// where `<repo-id>` is e.g. `mlx-community/Qwen2.5-3B-Instruct-4bit`. The
/// `models/` segment is appended by `HubApi` itself; we configure
/// `HubApi.downloadBase = baseDirectory` so the spec-stated path
/// `Application Support/CHSharedKit/models/` is materialized.
///
/// Apps that share an App Group can replace `baseDirectory` with the group
/// container's URL on first use.
public enum CHLocalMLXStorage {
    nonisolated(unsafe) public static var baseDirectory: URL = defaultBase()

    private static func defaultBase() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("CHSharedKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local directory for a Hugging Face model repo, regardless of whether
    /// it has been downloaded yet.
    public static func localDirectory(forRepoID repoID: String) -> URL {
        baseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    #if canImport(Hub)
    /// HubApi instance pointed at the shared models directory so all
    /// CHLocalLLM-aware code downloads to the same place.
    public static func hubApi() -> HubApi {
        HubApi(downloadBase: baseDirectory)
    }
    #endif
}

// MARK: - Provider registration helpers

/// Registers a default on-device LLM provider with `CHAIManager` if at least one
/// MLX model is installed. Returns the registered provider, or nil if no model
/// is installed (in which case nothing was registered and the picker should
/// hide the on-device row).
@MainActor
@discardableResult
public func registerOnDeviceLLMProvider() -> CHLocalLLMProvider? {
    let installed = LocalModelStore.shared.installedModels
    guard let model = installed.first(where: { $0.id == LocalModelCatalog.default.id })
            ?? installed.first else { return nil }
    let provider = CHLocalLLMProvider(
        modelURL: LocalModelStore.shared.modelURL(for: model),
        modelInfo: model
    )
    CHAIManager.shared.registerProvider(provider)
    return provider
}

/// Registers a default on-device VLM provider with `CHAIManager` if at least one
/// vision-capable MLX model is installed.
@MainActor
@discardableResult
public func registerOnDeviceVLMProvider() -> CHLocalVLMProvider? {
    let installed = LocalModelStore.shared.installedModels
        .filter { LocalModelCatalog.isVisionCapable($0.id) }
    guard let model = installed.first else { return nil }
    let provider = CHLocalVLMProvider(
        modelURL: LocalModelStore.shared.modelURL(for: model),
        modelInfo: model
    )
    CHAIManager.shared.registerProvider(provider)
    return provider
}
