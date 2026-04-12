import Foundation

// MARK: - App identifier

/// Identifies which app is using CHLocalLLM, so models can be ranked per-app.
public enum AppIdentifier: String, Sendable {
    case closet, eatwisely, spendwisely, distill, traininsight, gymlog

    public var displayName: String {
        switch self {
        case .closet: return "Closet"
        case .eatwisely: return "EatWisely"
        case .spendwisely: return "SpendWisely"
        case .distill: return "Distill"
        case .traininsight: return "TrainInsight"
        case .gymlog: return "GymLog"
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
    /// Primary languages the model supports well.
    public let languages: [String]
    /// Short capability highlights shown in the picker.
    public let strengths: [String]
    /// True for models added by the user via URL, false for catalog entries.
    public let isCustom: Bool

    // MARK: Computed metadata

    /// Bucketed size tier derived from sizeBytes.
    public var sizeCategory: SizeCategory {
        switch sizeBytes {
        case ..<600_000_000:              return .tiny
        case 600_000_000..<1_200_000_000: return .small
        case 1_200_000_000..<2_500_000_000: return .medium
        case 2_500_000_000..<4_000_000_000: return .large
        default:                          return .xlarge
        }
    }

    // MARK: Nested enums

    public enum LicenseType: String, Sendable, Codable {
        case apache2 = "Apache 2.0"
        case mit = "MIT"
        case llamaCommunity = "Llama Community"
        case gemma = "Gemma ToU"
    }

    public enum QualityTier: String, Sendable {
        case fast = "Fast"
        case balanced = "Balanced"
        case higher = "Higher Quality"
        case highest = "Highest Quality"
    }

    public enum ChatTemplate: String, Sendable, Codable {
        case llama3   // Llama 3.x instruct format
        case chatML   // ChatML / Qwen / Phi / SmolLM
        case llama2   // Llama 2 / Mistral
        case gemma    // Gemma 2 (<start_of_turn> format)
    }

    public enum SizeCategory: String, Sendable {
        case tiny   = "Tiny"    // < 600 MB
        case small  = "Small"   // 600 MB – 1.2 GB
        case medium = "Medium"  // 1.2 – 2.5 GB
        case large  = "Large"   // 2.5 – 4 GB
        case xlarge = "XL"      // > 4 GB
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
        chatTemplate: ChatTemplate,
        languages: [String] = [],
        strengths: [String] = [],
        isCustom: Bool = false
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
        self.languages = languages
        self.strengths = strengths
        self.isCustom = isCustom
    }

    // MARK: Per-app recommendation score (higher = better fit)

    public func recommendationScore(for app: AppIdentifier) -> Int {
        switch (app, id) {
        // closet
        case (.closet, "phi3.5-mini-q4km"):         return 11
        case (.closet, "qwen2.5-1.5b-q4km"):        return 10
        case (.closet, "smollm2-1.7b-q4km"):        return 9
        case (.closet, "qwen2.5-3b-q4km"):          return 9   // tie-breaks by size
        case (.closet, "gemma2-2b-q4km"):           return 8
        case (.closet, "llama3.2-3b-q4km"):         return 8
        case (.closet, "phi3-mini-4k-q4"):          return 7
        case (.closet, "deepseek-r1-1.5b-q4km"):   return 5
        case (.closet, "qwen2.5-0.5b-q4km"):        return 5
        case (.closet, "llama3.2-1b-q4km"):         return 4
        // eatwisely
        case (.eatwisely, "phi3.5-mini-q4km"):      return 11
        case (.eatwisely, "qwen2.5-3b-q4km"):       return 10
        case (.eatwisely, "llama3.2-3b-q4km"):      return 9
        case (.eatwisely, "deepseek-r1-1.5b-q4km"): return 8
        case (.eatwisely, "qwen2.5-1.5b-q4km"):     return 8
        case (.eatwisely, "phi3-mini-4k-q4"):       return 8
        case (.eatwisely, "gemma2-2b-q4km"):        return 7
        case (.eatwisely, "smollm2-1.7b-q4km"):     return 6
        case (.eatwisely, "llama3.2-1b-q4km"):      return 4
        case (.eatwisely, "qwen2.5-0.5b-q4km"):     return 4
        // spendwisely
        case (.spendwisely, "phi3.5-mini-q4km"):        return 11
        case (.spendwisely, "qwen2.5-1.5b-q4km"):       return 10
        case (.spendwisely, "deepseek-r1-1.5b-q4km"):  return 9
        case (.spendwisely, "qwen2.5-3b-q4km"):         return 9
        case (.spendwisely, "phi3-mini-4k-q4"):         return 8
        case (.spendwisely, "llama3.2-3b-q4km"):        return 7
        case (.spendwisely, "gemma2-2b-q4km"):          return 6
        case (.spendwisely, "smollm2-1.7b-q4km"):       return 6
        case (.spendwisely, "qwen2.5-0.5b-q4km"):       return 5
        case (.spendwisely, "llama3.2-1b-q4km"):        return 4
        // distill
        case (.distill, "phi3.5-mini-q4km"):        return 11
        case (.distill, "deepseek-r1-1.5b-q4km"):  return 9
        case (.distill, "phi3-mini-4k-q4"):         return 9
        case (.distill, "qwen2.5-3b-q4km"):         return 8
        case (.distill, "llama3.2-3b-q4km"):        return 7
        case (.distill, "gemma2-2b-q4km"):          return 6
        case (.distill, "smollm2-1.7b-q4km"):       return 6
        case (.distill, "qwen2.5-1.5b-q4km"):       return 5
        case (.distill, "llama3.2-1b-q4km"):        return 4
        case (.distill, "qwen2.5-0.5b-q4km"):       return 3
        // traininsight
        case (.traininsight, "phi3.5-mini-q4km"):       return 11
        case (.traininsight, "phi3-mini-4k-q4"):        return 9
        case (.traininsight, "deepseek-r1-1.5b-q4km"): return 9
        case (.traininsight, "qwen2.5-3b-q4km"):        return 8
        case (.traininsight, "llama3.2-3b-q4km"):       return 7
        case (.traininsight, "gemma2-2b-q4km"):         return 7
        case (.traininsight, "qwen2.5-1.5b-q4km"):      return 6
        case (.traininsight, "smollm2-1.7b-q4km"):      return 5
        case (.traininsight, "llama3.2-1b-q4km"):       return 5
        case (.traininsight, "qwen2.5-0.5b-q4km"):      return 3
        // gymlog
        case (.gymlog, "phi3.5-mini-q4km"):         return 11
        case (.gymlog, "qwen2.5-3b-q4km"):          return 10
        case (.gymlog, "llama3.2-3b-q4km"):         return 9
        case (.gymlog, "phi3-mini-4k-q4"):          return 8
        case (.gymlog, "deepseek-r1-1.5b-q4km"):   return 7
        case (.gymlog, "gemma2-2b-q4km"):           return 7
        case (.gymlog, "qwen2.5-1.5b-q4km"):        return 6
        case (.gymlog, "smollm2-1.7b-q4km"):        return 5
        case (.gymlog, "llama3.2-1b-q4km"):         return 4
        case (.gymlog, "qwen2.5-0.5b-q4km"):        return 4
        default: return 0
        }
    }

    // MARK: Per-app task hint

    public func taskHint(for app: AppIdentifier) -> String {
        switch (app, id) {
        // distill
        case (.distill, "phi3.5-mini-q4km"):       return "Best reasoning for article summaries — top pick"
        case (.distill, "deepseek-r1-1.5b-q4km"):  return "Chain-of-thought reasoning for complex articles"
        case (.distill, "phi3-mini-4k-q4"):        return "Strong article summaries and reasoning"
        case (.distill, "qwen2.5-3b-q4km"):        return "Balanced article summarization"
        case (.distill, "llama3.2-3b-q4km"):       return "Good for long-form article analysis"
        case (.distill, "gemma2-2b-q4km"):         return "Balanced summaries with good comprehension"
        case (.distill, "smollm2-1.7b-q4km"):      return "Fast lightweight summaries"
        case (.distill, "qwen2.5-1.5b-q4km"):      return "Fast summarization, lighter quality"
        case (.distill, "llama3.2-1b-q4km"):       return "Quick summaries, limited depth"
        case (.distill, "qwen2.5-0.5b-q4km"):      return "Too small for quality summaries"
        // closet
        case (.closet, "phi3.5-mini-q4km"):        return "Strong reasoning for outfit suggestions and style advice"
        case (.closet, "qwen2.5-1.5b-q4km"):       return "Best for fast product categorization"
        case (.closet, "smollm2-1.7b-q4km"):       return "Efficient item tagging and categorization"
        case (.closet, "qwen2.5-3b-q4km"):         return "Best for detailed outfit suggestions"
        case (.closet, "gemma2-2b-q4km"):          return "Excellent categorization and brand detection"
        case (.closet, "llama3.2-3b-q4km"):        return "Strong general categorization"
        case (.closet, "phi3-mini-4k-q4"):         return "Great for style reasoning"
        case (.closet, "deepseek-r1-1.5b-q4km"):   return "Overkill for categorization tasks"
        case (.closet, "qwen2.5-0.5b-q4km"):       return "Good for quick item tagging"
        case (.closet, "llama3.2-1b-q4km"):        return "Basic item tagging only"
        // eatwisely
        case (.eatwisely, "phi3.5-mini-q4km"):     return "Best for complex nutritional analysis and meal planning"
        case (.eatwisely, "qwen2.5-3b-q4km"):      return "Best for daily summaries and insights"
        case (.eatwisely, "llama3.2-3b-q4km"):     return "Strong for nutritional analysis"
        case (.eatwisely, "deepseek-r1-1.5b-q4km"): return "Good reasoning for macro tracking and diet insights"
        case (.eatwisely, "qwen2.5-1.5b-q4km"):    return "Good for quick dietary checks"
        case (.eatwisely, "phi3-mini-4k-q4"):      return "Great for meal planning reasoning"
        case (.eatwisely, "gemma2-2b-q4km"):       return "Solid nutrition analysis and food categorization"
        case (.eatwisely, "smollm2-1.7b-q4km"):    return "Fast nutritional checks, lighter depth"
        case (.eatwisely, "llama3.2-1b-q4km"):     return "Quick food logging, limited nutritional depth"
        case (.eatwisely, "qwen2.5-0.5b-q4km"):    return "Limited — better options available"
        // spendwisely
        case (.spendwisely, "phi3.5-mini-q4km"):      return "Best reasoning for spending pattern analysis"
        case (.spendwisely, "qwen2.5-1.5b-q4km"):     return "Best for transaction categorization"
        case (.spendwisely, "deepseek-r1-1.5b-q4km"): return "Strong for financial reasoning and budget analysis"
        case (.spendwisely, "qwen2.5-3b-q4km"):       return "Best for spending insight narratives"
        case (.spendwisely, "phi3-mini-4k-q4"):       return "Great for financial reasoning"
        case (.spendwisely, "llama3.2-3b-q4km"):      return "Good for budget analysis"
        case (.spendwisely, "gemma2-2b-q4km"):        return "Good transaction categorization and insights"
        case (.spendwisely, "smollm2-1.7b-q4km"):     return "Fast transaction tagging, lighter analysis"
        case (.spendwisely, "qwen2.5-0.5b-q4km"):     return "Good for simple transaction tagging"
        case (.spendwisely, "llama3.2-1b-q4km"):      return "Basic transaction categorization only"
        // traininsight
        case (.traininsight, "phi3.5-mini-q4km"):      return "Best reasoning for training plan generation"
        case (.traininsight, "phi3-mini-4k-q4"):       return "Strong reasoning for training plan analysis"
        case (.traininsight, "deepseek-r1-1.5b-q4km"): return "Strong chain-of-thought for training analysis"
        case (.traininsight, "qwen2.5-3b-q4km"):       return "Strong for detailed workout analysis"
        case (.traininsight, "llama3.2-3b-q4km"):      return "Good for training insights and advice"
        case (.traininsight, "gemma2-2b-q4km"):        return "Good balance of quality and speed for daily readiness"
        case (.traininsight, "qwen2.5-1.5b-q4km"):     return "Fast readiness checks, lighter quality"
        case (.traininsight, "smollm2-1.7b-q4km"):     return "Fast and lightweight for simple workout logging"
        case (.traininsight, "llama3.2-1b-q4km"):      return "Ultra-fast readiness checks, basic quality"
        case (.traininsight, "qwen2.5-0.5b-q4km"):     return "Too small for quality training advice"
        // gymlog
        case (.gymlog, "phi3.5-mini-q4km"):        return "Best for coaching advice, plateau detection, and training summaries"
        case (.gymlog, "qwen2.5-3b-q4km"):         return "Best for workout suggestions and weekly summaries"
        case (.gymlog, "llama3.2-3b-q4km"):        return "Great for form tips and training analysis"
        case (.gymlog, "phi3-mini-4k-q4"):         return "Best reasoning for plateau detection and coaching"
        case (.gymlog, "deepseek-r1-1.5b-q4km"):   return "Strong reasoning for form analysis and fatigue detection"
        case (.gymlog, "gemma2-2b-q4km"):          return "Good for workout suggestions and progress tracking"
        case (.gymlog, "qwen2.5-1.5b-q4km"):       return "Fast workout suggestions, lighter quality"
        case (.gymlog, "smollm2-1.7b-q4km"):       return "Quick workout logging, lighter coaching quality"
        case (.gymlog, "llama3.2-1b-q4km"):        return "Fast logging suggestions, limited coaching depth"
        case (.gymlog, "qwen2.5-0.5b-q4km"):       return "Limited — better options available for coaching"
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
        description: "Alibaba Qwen 2.5 0.5B Instruct · Q4_K_M · ~400 MB",
        sizeBytes: 397_506_000,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        minRAM_GB: 1,
        license: .apache2,
        quality: .fast,
        chatTemplate: .chatML,
        languages: ["English", "Chinese", "French", "Spanish"],
        strengths: ["Ultra-fast inference", "Very low memory (400 MB)"]
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
        chatTemplate: .chatML,
        languages: ["English", "Chinese", "French", "Spanish", "Arabic"],
        strengths: ["Fast inference", "Balanced quality", "Low memory"]
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
        chatTemplate: .chatML,
        languages: ["English", "Chinese", "French", "Spanish", "Arabic", "Japanese"],
        strengths: ["Strong reasoning", "Multilingual", "Efficient inference"]
    )

    // MARK: Llama 3.2 family (Meta Llama Community License)

    public static let llama3_2_1B = LocalModelInfo(
        id: "llama3.2-1b-q4km",
        displayName: "Llama 3.2 1B",
        description: "Meta Llama 3.2 1B Instruct · Q4_K_M · ~770 MB · iPhone 12+",
        sizeBytes: 807_694_464,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
        minRAM_GB: 3,
        license: .llamaCommunity,
        quality: .fast,
        requiresAcknowledgment: true,
        chatTemplate: .llama3,
        languages: ["English", "German", "French", "Italian", "Spanish"],
        strengths: ["Ultra-fast inference", "Very low memory (770 MB)", "Good for quick tasks"]
    )

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
        chatTemplate: .llama3,
        languages: ["English", "German", "French", "Italian", "Spanish", "Hindi", "Portuguese"],
        strengths: ["Strong reasoning", "Long context", "Good instruction following"]
    )

    // MARK: Phi family (MIT)

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
        chatTemplate: .chatML,
        languages: ["English"],
        strengths: ["Strong reasoning", "Efficient inference", "Good at math & coding"]
    )

    public static let phi3_5Mini = LocalModelInfo(
        id: "phi3.5-mini-q4km",
        displayName: "Phi-3.5 Mini",
        description: "Microsoft Phi-3.5 Mini Instruct · Q4_K_M · ~2.2 GB · iPhone 14+",
        sizeBytes: 2_393_232_672,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf")!,
        minRAM_GB: 6,
        license: .mit,
        quality: .highest,
        chatTemplate: .chatML,
        languages: ["English"],
        strengths: ["Best-in-class reasoning", "Excellent instruction following", "Strong math & coding"]
    )

    // MARK: Gemma 2 (Google Gemma ToU)

    public static let gemma2_2B = LocalModelInfo(
        id: "gemma2-2b-q4km",
        displayName: "Gemma 2 2B",
        description: "Google Gemma 2 2B Instruct · Q4_K_M · ~1.6 GB · iPhone 13+",
        sizeBytes: 1_708_582_752,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf")!,
        minRAM_GB: 5,
        license: .gemma,
        quality: .higher,
        requiresAcknowledgment: false,
        chatTemplate: .gemma,
        languages: ["English"],
        strengths: ["Strong quality for size", "Good at classification", "Efficient"]
    )

    // MARK: SmolLM2 (Apache 2.0)

    public static let smolLM2_1_7B = LocalModelInfo(
        id: "smollm2-1.7b-q4km",
        displayName: "SmolLM2 1.7B",
        description: "HuggingFace SmolLM2 1.7B Instruct · Q4_K_M · ~1.0 GB · iPhone 12+",
        sizeBytes: 1_055_609_536,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/smollm2-1.7b-instruct-q4_k_m.gguf")!,
        minRAM_GB: 4,
        license: .apache2,
        quality: .balanced,
        chatTemplate: .chatML,
        languages: ["English"],
        strengths: ["Fast inference", "Efficient", "Good for structured tasks"]
    )

    // MARK: DeepSeek-R1 Distill (MIT)

    public static let deepSeekR1_1_5B = LocalModelInfo(
        id: "deepseek-r1-1.5b-q4km",
        displayName: "DeepSeek-R1 1.5B",
        description: "DeepSeek-R1 Distill Qwen 1.5B · Q4_K_M · ~1.0 GB · iPhone 12+",
        sizeBytes: 1_117_320_800,
        quantization: "Q4_K_M",
        downloadURL: URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf")!,
        minRAM_GB: 4,
        license: .mit,
        quality: .higher,
        chatTemplate: .chatML,
        languages: ["English", "Chinese"],
        strengths: ["Chain-of-thought reasoning", "Problem solving", "Analytical tasks"]
    )

    // MARK: Registry

    public static let all: [LocalModelInfo] = [
        qwen2_5_0_5B,
        qwen2_5_1_5B,
        qwen2_5_3B,
        llama3_2_1B,
        llama3_2_3B,
        phi3Mini4k,
        phi3_5Mini,
        gemma2_2B,
        smolLM2_1_7B,
        deepSeekR1_1_5B,
    ]

    /// Default model for new installs: Qwen 2.5 1.5B (Apache 2.0, ~900 MB, fast).
    public static let `default`: LocalModelInfo = qwen2_5_1_5B
}
