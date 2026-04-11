import Foundation

// MARK: - Model info

/// A quantized GGUF model available for on-device inference.
public struct LocalModelInfo: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String
    /// On-disk file size in bytes (approximate).
    public let fileSizeBytes: Int64
    public let quantization: String
    /// Direct GGUF download URL (HuggingFace or similar CDN).
    public let downloadURL: URL
    /// Expected SHA-256 hex digest of the downloaded file, or nil to skip check.
    public let sha256: String?
    /// Minimum device RAM in bytes needed for reliable inference.
    public let minimumRAMBytes: Int64
    /// Chat template used to format prompts for this model family.
    public let chatTemplate: ChatTemplate

    public enum ChatTemplate: String, Sendable {
        case llama3   // Llama 3.x instruct format
        case chatML   // ChatML / Qwen / Phi
        case llama2   // Llama 2 / Mistral
    }

    public init(
        id: String,
        displayName: String,
        description: String,
        fileSizeBytes: Int64,
        quantization: String,
        downloadURL: URL,
        sha256: String? = nil,
        minimumRAMBytes: Int64,
        chatTemplate: ChatTemplate
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.fileSizeBytes = fileSizeBytes
        self.quantization = quantization
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.minimumRAMBytes = minimumRAMBytes
        self.chatTemplate = chatTemplate
    }
}

// MARK: - Catalog

/// Static catalog of supported on-device models.
public enum LocalModelCatalog {

    // MARK: Qwen 2.5 family (Apache 2.0, default)

    /// Qwen 2.5 0.5B Instruct Q4_K_M — ~400 MB, lightest, good for low-RAM devices.
    public static let qwen2_5_0_5B = LocalModelInfo(
        id: "qwen2.5-0.5b-q4km",
        displayName: "Qwen 2.5 0.5B",
        description: "Alibaba Qwen 2.5 0.5B Instruct · Q4_K_M · ~400 MB · Fastest",
        fileSizeBytes: 397_505_952,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        sha256: nil,
        minimumRAMBytes: 1 * 1_073_741_824,
        chatTemplate: .chatML
    )

    /// Qwen 2.5 1.5B Instruct Q4_K_M — ~900 MB, fast, Apache 2.0. Default model.
    public static let qwen2_5_1_5B = LocalModelInfo(
        id: "qwen2.5-1.5b-q4km",
        displayName: "Qwen 2.5 1.5B",
        description: "Alibaba Qwen 2.5 1.5B Instruct · Q4_K_M · ~900 MB · Recommended",
        fileSizeBytes: 935_329_504,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        sha256: nil,
        minimumRAMBytes: 2 * 1_073_741_824,
        chatTemplate: .chatML
    )

    /// Qwen 2.5 3B Instruct Q4_K_M — ~1.9 GB, higher quality, Apache 2.0.
    public static let qwen2_5_3B = LocalModelInfo(
        id: "qwen2.5-3b-q4km",
        displayName: "Qwen 2.5 3B",
        description: "Alibaba Qwen 2.5 3B Instruct · Q4_K_M · ~1.9 GB · Higher quality",
        fileSizeBytes: 1_918_999_648,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        sha256: nil,
        minimumRAMBytes: 3 * 1_073_741_824,
        chatTemplate: .chatML
    )

    // MARK: Llama 3.2 (higher quality alternative)

    /// Llama 3.2 3B Instruct Q4_K_M — ~1.9 GB, high quality, Meta Llama license.
    public static let llama3_2_3B = LocalModelInfo(
        id: "llama3.2-3b-q4km",
        displayName: "Llama 3.2 3B",
        description: "Meta Llama 3.2 3B Instruct · Q4_K_M · ~1.9 GB · Higher quality",
        fileSizeBytes: 1_928_454_432,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        sha256: nil,
        minimumRAMBytes: 3 * 1_073_741_824,
        chatTemplate: .llama3
    )

    // MARK: All models + default

    public static let all: [LocalModelInfo] = [qwen2_5_0_5B, qwen2_5_1_5B, qwen2_5_3B, llama3_2_3B]

    /// Default model: Qwen 2.5 1.5B Q4_K_M — ~900 MB, Apache 2.0, fast on all iPhones.
    public static let `default`: LocalModelInfo = qwen2_5_1_5B
}
