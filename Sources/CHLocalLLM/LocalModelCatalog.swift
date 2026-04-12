import Foundation

// MARK: - App identifier

/// Identifies which app is using CHLocalLLM, so models can be ranked per-app.
public enum AppIdentifier: String, Sendable {
    case closet, eatwisely, spendwisely, distill, traininsight

    public var displayName: String {
        switch self {
        case .closet: return "Closet"
        case .eatwisely: return "EatWisely"
        case .spendwisely: return "SpendWisely"
        case .distill: return "Distill"
        case .traininsight: return "TrainInsight"
        }
    }
}

// MARK: - Model info

/// A quantized GGUF model available for on-device inference.
public struct LocalModelInfo: Sendable, Identifiable, Equatable {

    // MARK: Stored properties

    public let id: String
    public let displayName: String
    public let description: String
    /// Approximate on-disk file size in bytes.
    public let sizeBytes: Int64
    public let quantization: String
    /// Direct GGUF download URL.
    public let downloadURL: URL
    /// Expected SHA-256 hex digest, or nil to skip verification.
    public let sha256: String?
    /// Minimum device RAM in whole GB required for reliable inference.
    public let minRAM_GB: Int
    /// License governing model use.
    public let license: LicenseType
    /// Quality/speed tier.
    public let quality: QualityTier
    /// If true, show a one-time license acknowledgment before downloading.
    public let requiresAcknowledgment: Bool
    /// Chat template used to format prompts for this model family.
    public let chatTemplate: ChatTemplate

    // MARK: Nested enums

    public enum LicenseType: String, Sendable {
        case apache2 = "Apache 2.0"
        case mit = "MIT"
        case llamaCommunity = "Llama Community"
    }

    public enum QualityTier: String, Sendable {
        case fast = "Fast"
        case balanced = "Balanced"
        case higher = "Higher Quality"
        case highest = "Highest Quality"
    }

    public enum ChatTemplate: String, Sendable {
        case llama3   // Llama 3.x instruct format
        case chatML   // ChatML / Qwen / Phi
        case llama2   // Llama 2 / Mistral
    }

    // MARK: Init

    public init(
        id: String,
        displayName: String,
        description: String,
        sizeBytes: Int64,
        quantization: String,
        downloadURL: URL,
        sha256: String? = nil,
        minRAM_GB: Int,
        license: LicenseType,
        quality: QualityTier,
        requiresAcknowledgment: Bool = false,
        chatTemplate: ChatTemplate
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.minRAM_GB = minRAM_GB
        self.license = license
        self.quality = quality
        self.requiresAcknowledgment = requiresAcknowledgment
        self.chatTemplate = chatTemplate
    }

    // MARK: Per-app recommendation score (higher = better fit)

    public func recommendationScore(for app: AppIdentifier) -> Int {
        switch (app, id) {
        // closet
        case (.closet, "qwen2.5-1.5b-q4km"):  return 10
        case (.closet, "qwen2.5-3b-q4km"):    return 9
        case (.closet, "llama3.2-3b-q4km"):   return 8
        case (.closet, "phi3-mini-4k-q4"):    return 7
        case (.closet, "qwen2.5-0.5b-q4km"):  return 6
        // eatwisely
        case (.eatwisely, "qwen2.5-3b-q4km"):  return 10
        case (.eatwisely, "llama3.2-3b-q4km"): return 9
        case (.eatwisely, "qwen2.5-1.5b-q4km"):return 8
        case (.eatwisely, "phi3-mini-4k-q4"):  return 8   // tie-breaks by size
        case (.eatwisely, "qwen2.5-0.5b-q4km"):return 4
        // spendwisely
        case (.spendwisely, "qwen2.5-1.5b-q4km"): return 10
        case (.spendwisely, "qwen2.5-3b-q4km"):   return 9
        case (.spendwisely, "phi3-mini-4k-q4"):   return 8
        case (.spendwisely, "llama3.2-3b-q4km"):  return 7
        case (.spendwisely, "qwen2.5-0.5b-q4km"): return 7  // tie-breaks by size
        // distill
        case (.distill, "phi3-mini-4k-q4"):    return 10
        case (.distill, "qwen2.5-3b-q4km"):    return 9
        case (.distill, "llama3.2-3b-q4km"):   return 8
        case (.distill, "qwen2.5-1.5b-q4km"):  return 7
        case (.distill, "qwen2.5-0.5b-q4km"):  return 4
        default: return 0
        }
    }

    // MARK: Per-app task hint

    public func taskHint(for app: AppIdentifier) -> String {
        switch (app, id) {
        // distill
        case (.distill, "phi3-mini-4k-q4"):    return "Best for article summaries and reasoning"
        case (.distill, "qwen2.5-3b-q4km"):    return "Balanced article summarization"
        case (.distill, "llama3.2-3b-q4km"):   return "Good for long-form article analysis"
        case (.distill, "qwen2.5-1.5b-q4km"):  return "Fast summarization, lighter quality"
        case (.distill, "qwen2.5-0.5b-q4km"):  return "Too small for quality summaries"
        // closet
        case (.closet, "qwen2.5-1.5b-q4km"):   return "Best for fast product categorization"
        case (.closet, "qwen2.5-3b-q4km"):     return "Best for detailed outfit suggestions"
        case (.closet, "llama3.2-3b-q4km"):    return "Strong general categorization"
        case (.closet, "phi3-mini-4k-q4"):     return "Great for style reasoning"
        case (.closet, "qwen2.5-0.5b-q4km"):   return "Good for quick item tagging"
        // eatwisely
        case (.eatwisely, "qwen2.5-3b-q4km"):   return "Best for daily summaries and insights"
        case (.eatwisely, "llama3.2-3b-q4km"):  return "Strong for nutritional analysis"
        case (.eatwisely, "qwen2.5-1.5b-q4km"): return "Good for quick dietary checks"
        case (.eatwisely, "phi3-mini-4k-q4"):   return "Great for meal planning reasoning"
        case (.eatwisely, "qwen2.5-0.5b-q4km"): return "Limited — better options available"
        // spendwisely
        case (.spendwisely, "qwen2.5-1.5b-q4km"): return "Best for transaction categorization"
        case (.spendwisely, "qwen2.5-3b-q4km"):   return "Best for spending insight narratives"
        case (.spendwisely, "phi3-mini-4k-q4"):   return "Great for financial reasoning"
        case (.spendwisely, "llama3.2-3b-q4km"):  return "Good for budget analysis"
        case (.spendwisely, "qwen2.5-0.5b-q4km"): return "Good for simple transaction tagging"
        default: return description
        }
    }
}

// MARK: - Catalog

public enum LocalModelCatalog {

    // MARK: Qwen 2.5 family (Apache 2.0)

    public static let qwen2_5_0_5B = LocalModelInfo(
        id: "qwen2.5-0.5b-q4km",
        displayName: "Qwen 2.5 0.5B",
        description: "Alibaba Qwen 2.5 0.5B Instruct · Q4_K_M · ~400 MB · Works on any iPhone",
        sizeBytes: 397_506_000,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        minRAM_GB: 1,
        license: .apache2,
        quality: .fast,
        chatTemplate: .chatML
    )

    public static let qwen2_5_1_5B = LocalModelInfo(
        id: "qwen2.5-1.5b-q4km",
        displayName: "Qwen 2.5 1.5B",
        description: "Alibaba Qwen 2.5 1.5B Instruct · Q4_K_M · ~900 MB · iPhone 12+",
        sizeBytes: 935_329_504,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        minRAM_GB: 4,
        license: .apache2,
        quality: .balanced,
        chatTemplate: .chatML
    )

    public static let qwen2_5_3B = LocalModelInfo(
        id: "qwen2.5-3b-q4km",
        displayName: "Qwen 2.5 3B",
        description: "Alibaba Qwen 2.5 3B Instruct · Q4_K_M · ~1.9 GB · iPhone 14+",
        sizeBytes: 1_918_999_648,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        minRAM_GB: 6,
        license: .apache2,
        quality: .higher,
        chatTemplate: .chatML
    )

    // MARK: Llama 3.2 (Meta Llama Community License)

    public static let llama3_2_3B = LocalModelInfo(
        id: "llama3.2-3b-q4km",
        displayName: "Llama 3.2 3B",
        description: "Meta Llama 3.2 3B Instruct · Q4_K_M · ~1.9 GB · iPhone 14+",
        sizeBytes: 1_928_454_432,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        minRAM_GB: 6,
        license: .llamaCommunity,
        quality: .higher,
        requiresAcknowledgment: true,
        chatTemplate: .llama3
    )

    // MARK: Phi-3 Mini (MIT)

    public static let phi3Mini4k = LocalModelInfo(
        id: "phi3-mini-4k-q4",
        displayName: "Phi-3 Mini",
        description: "Microsoft Phi-3 Mini 4k Instruct · Q4 · ~2.3 GB · iPhone 14+",
        sizeBytes: 2_300_000_000,
        quantization: "Q4",
        downloadURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf")!,
        minRAM_GB: 6,
        license: .mit,
        quality: .highest,
        chatTemplate: .chatML
    )

    // MARK: Registry

    public static let all: [LocalModelInfo] = [
        qwen2_5_0_5B,
        qwen2_5_1_5B,
        qwen2_5_3B,
        llama3_2_3B,
        phi3Mini4k
    ]

    /// Default model for new installs: Qwen 2.5 1.5B (Apache 2.0, ~900 MB, fast).
    public static let `default`: LocalModelInfo = qwen2_5_1_5B
}
