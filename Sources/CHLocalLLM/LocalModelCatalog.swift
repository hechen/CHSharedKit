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

    // MARK: Default

    /// Llama 3.2 3B Instruct Q4_K_M — ~1.9 GB, high quality, Metal-accelerated.
    /// Default for iPhone 16 and newer (6 GB RAM).
    public static let llama3_2_3B = LocalModelInfo(
        id: "llama3.2-3b-q4km",
        displayName: "Llama 3.2 3B",
        description: "Meta Llama 3.2 3B Instruct · Q4_K_M · ~1.9 GB",
        fileSizeBytes: 1_928_454_432,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        sha256: nil, // TODO: pin checksum after first successful download
        minimumRAMBytes: 3 * 1_073_741_824,
        chatTemplate: .llama3
    )

    // MARK: Fallback (smaller RAM devices)

    /// Qwen 2.5 1.5B Instruct Q4_K_M — ~0.9 GB, fast, good multilingual.
    public static let qwen2_5_1_5B = LocalModelInfo(
        id: "qwen2.5-1.5b-q4km",
        displayName: "Qwen 2.5 1.5B",
        description: "Alibaba Qwen 2.5 1.5B Instruct · Q4_K_M · ~0.9 GB",
        fileSizeBytes: 935_329_504,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        sha256: nil,
        minimumRAMBytes: 2 * 1_073_741_824,
        chatTemplate: .chatML
    )

    // MARK: All models

    public static let all: [LocalModelInfo] = [llama3_2_3B, qwen2_5_1_5B]

    /// The recommended default. Apps may override this.
    public static let `default`: LocalModelInfo = llama3_2_3B
}
