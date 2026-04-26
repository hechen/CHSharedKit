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

/// A quantized on-device model available for inference.
///
/// 2.5.0: The catalog now lists MLX-format Hugging Face repos (e.g.
/// `mlx-community/Qwen2.5-3B-Instruct-4bit`) instead of single-file GGUF
/// downloads. The struct shape is unchanged so existing UI keeps compiling:
///
/// - `downloadURL` carries the Hugging Face repo's homepage URL
///   (e.g. `https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit`).
///   Internally `LocalModelStore` extracts the `org/name` repo id via
///   ``CHLocalMLXRepoID/from(_:)`` and feeds it to `HubApi.snapshot(...)`.
/// - `chatTemplate` is retained for source compatibility but is no longer
///   used at inference time — MLX applies the model's tokenizer template
///   automatically via swift-transformers.
/// - `sizeBytes` is the approximate on-disk total of `.safetensors` + `.json`
///   files in the repo snapshot.
public struct LocalModelInfo: Sendable, Identifiable, Equatable {

    // MARK: Stored properties

    public let id: String
    public let displayName: String
    public let description: String
    /// Approximate on-disk total in bytes (sum of safetensors + JSON files).
    public let sizeBytes: Int64
    public let quantization: String
    /// Hugging Face repo homepage URL. Use ``CHLocalMLXRepoID/from(_:)`` to
    /// extract the `org/name` repo id for `HubApi` calls.
    public let downloadURL: URL
    /// Expected SHA-256 hex digest. Always nil for MLX repos (Hub manages
    /// integrity per-file via ETags); retained for API parity with 2.4.x.
    public let sha256: String?
    /// Minimum device RAM in whole GB required for reliable inference.
    public let minRAM_GB: Int
    /// License governing model use.
    public let license: LicenseType
    /// Quality/speed tier.
    public let quality: QualityTier
    /// If true, show a one-time license acknowledgment before downloading.
    public let requiresAcknowledgment: Bool
    /// Chat template family, retained for source compat. Not used by MLX
    /// inference — the tokenizer applies the template automatically.
    public let chatTemplate: ChatTemplate
    /// Primary languages the model supports well.
    public let languages: [String]
    /// Short capability highlights shown in the picker.
    public let strengths: [String]
    /// True for models added by the user via URL, false for catalog entries.
    public let isCustom: Bool

    // MARK: Computed metadata

    public var sizeCategory: SizeCategory {
        switch sizeBytes {
        case ..<600_000_000:                  return .tiny
        case 600_000_000..<1_200_000_000:     return .small
        case 1_200_000_000..<2_500_000_000:   return .medium
        case 2_500_000_000..<4_000_000_000:   return .large
        default:                              return .xlarge
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
        case llama3
        case chatML
        case llama2
        case gemma
    }

    public enum SizeCategory: String, Sendable {
        case tiny   = "Tiny"
        case small  = "Small"
        case medium = "Medium"
        case large  = "Large"
        case xlarge = "XL"
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
        case (.closet, "qwen2.5-3b-q4km"):          return 9
        case (.closet, "gemma2-2b-q4km"):           return 8
        case (.closet, "llama3.2-3b-q4km"):         return 8
        case (.closet, "phi3-mini-4k-q4"):          return 7
        case (.closet, "deepseek-r1-1.5b-q4km"):    return 5
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
        case (.spendwisely, "phi3.5-mini-q4km"):       return 11
        case (.spendwisely, "qwen2.5-1.5b-q4km"):      return 10
        case (.spendwisely, "deepseek-r1-1.5b-q4km"):  return 9
        case (.spendwisely, "qwen2.5-3b-q4km"):        return 9
        case (.spendwisely, "phi3-mini-4k-q4"):        return 8
        case (.spendwisely, "llama3.2-3b-q4km"):       return 7
        case (.spendwisely, "gemma2-2b-q4km"):         return 6
        case (.spendwisely, "smollm2-1.7b-q4km"):      return 6
        case (.spendwisely, "qwen2.5-0.5b-q4km"):      return 5
        case (.spendwisely, "llama3.2-1b-q4km"):       return 4
        // distill
        case (.distill, "phi3.5-mini-q4km"):        return 11
        case (.distill, "deepseek-r1-1.5b-q4km"):   return 9
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
        case (.traininsight, "deepseek-r1-1.5b-q4km"):  return 9
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
        case (.gymlog, "deepseek-r1-1.5b-q4km"):    return 7
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

// MARK: - Catalog (MLX-format)

/// 2.5.0: catalog entries are MLX-quantized Hugging Face repos. The `id`
/// nicknames are preserved from the 2.4.x GGUF catalog so existing
/// `recommendationScore(for:)` / `taskHint(for:)` switches and any persisted
/// user selection (`activeModelID` in UserDefaults) continue to resolve.
public enum LocalModelCatalog {

    private static func huggingFaceURL(_ repoID: String) -> URL {
        URL(string: "https://huggingface.co/\(repoID)")!
    }

    // MARK: Qwen 2.5 family (Apache 2.0)

    public static let qwen2_5_0_5B = LocalModelInfo(
        id: "qwen2.5-0.5b-q4km",
        displayName: "Qwen 2.5 0.5B",
        description: "Alibaba Qwen 2.5 0.5B Instruct · MLX 4-bit · ~280 MB",
        sizeBytes: 280_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
        minRAM_GB: 1,
        license: .apache2,
        quality: .fast,
        chatTemplate: .chatML,
        languages: ["English", "Chinese", "French", "Spanish"],
        strengths: ["Ultra-fast inference", "Very low memory (280 MB)"]
    )

    public static let qwen2_5_1_5B = LocalModelInfo(
        id: "qwen2.5-1.5b-q4km",
        displayName: "Qwen 2.5 1.5B",
        description: "Alibaba Qwen 2.5 1.5B Instruct · MLX 4-bit · ~860 MB · iPhone 12+",
        sizeBytes: 860_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Qwen2.5-1.5B-Instruct-4bit"),
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
        description: "Alibaba Qwen 2.5 3B Instruct · MLX 4-bit · ~1.7 GB · iPhone 12+",
        sizeBytes: 1_700_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Qwen2.5-3B-Instruct-4bit"),
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
        description: "Meta Llama 3.2 1B Instruct · MLX 4-bit · ~700 MB · iPhone 12+",
        sizeBytes: 700_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Llama-3.2-1B-Instruct-4bit"),
        minRAM_GB: 3,
        license: .llamaCommunity,
        quality: .fast,
        requiresAcknowledgment: true,
        chatTemplate: .llama3,
        languages: ["English", "German", "French", "Italian", "Spanish"],
        strengths: ["Ultra-fast inference", "Very low memory (700 MB)", "Good for quick tasks"]
    )

    public static let llama3_2_3B = LocalModelInfo(
        id: "llama3.2-3b-q4km",
        displayName: "Llama 3.2 3B",
        description: "Meta Llama 3.2 3B Instruct · MLX 4-bit · ~1.8 GB · iPhone 14+",
        sizeBytes: 1_800_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Llama-3.2-3B-Instruct-4bit"),
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
        description: "Microsoft Phi-3 Mini 4k Instruct · MLX 4-bit · ~2.3 GB · iPhone 14+",
        sizeBytes: 2_300_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Phi-3-mini-4k-instruct-4bit"),
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
        description: "Microsoft Phi-3.5 Mini Instruct · MLX 4-bit · ~2.2 GB · iPhone 14+",
        sizeBytes: 2_200_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Phi-3.5-mini-instruct-4bit"),
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
        description: "Google Gemma 2 2B Instruct · MLX 4-bit · ~1.5 GB · iPhone 13+",
        sizeBytes: 1_500_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/gemma-2-2b-it-4bit"),
        minRAM_GB: 5,
        license: .gemma,
        quality: .higher,
        chatTemplate: .gemma,
        languages: ["English"],
        strengths: ["Strong quality for size", "Good at classification", "Efficient"]
    )

    // MARK: SmolLM2 (Apache 2.0)

    public static let smolLM2_1_7B = LocalModelInfo(
        id: "smollm2-1.7b-q4km",
        displayName: "SmolLM2 1.7B",
        description: "HuggingFace SmolLM2 1.7B Instruct · MLX 4-bit · ~1.0 GB · iPhone 12+",
        sizeBytes: 1_000_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/SmolLM2-1.7B-Instruct-4bit"),
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
        description: "DeepSeek-R1 Distill Qwen 1.5B · MLX 4-bit · ~1.0 GB · iPhone 12+",
        sizeBytes: 1_000_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit"),
        minRAM_GB: 4,
        license: .mit,
        quality: .higher,
        chatTemplate: .chatML,
        languages: ["English", "Chinese"],
        strengths: ["Chain-of-thought reasoning", "Problem solving", "Analytical tasks"]
    )

    // MARK: Qwen2-VL (Vision)

    /// Vision-language model — used by ``CHLocalVLMProvider``. Apache 2.0.
    public static let qwen2VL_2B = LocalModelInfo(
        id: "qwen2-vl-2b-q4",
        displayName: "Qwen2-VL 2B (Vision)",
        description: "Alibaba Qwen2-VL 2B Instruct · MLX 4-bit · ~1.5 GB · iPhone 14+",
        sizeBytes: 1_500_000_000,
        quantization: "MLX-4bit",
        downloadURL: huggingFaceURL("mlx-community/Qwen2-VL-2B-Instruct-4bit"),
        minRAM_GB: 6,
        license: .apache2,
        quality: .higher,
        chatTemplate: .chatML,
        languages: ["English", "Chinese"],
        strengths: ["Image understanding", "Visual Q&A", "Multilingual captions"]
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
        qwen2VL_2B,
    ]

    /// Default model for new installs (per 2.5.0 spec): Qwen 2.5 3B Instruct (4-bit).
    public static let `default`: LocalModelInfo = qwen2_5_3B

    /// True for catalog entries that can accept image input via ``CHLocalVLMProvider``.
    public static func isVisionCapable(_ id: String) -> Bool {
        switch id {
        case "qwen2-vl-2b-q4": return true
        default: return false
        }
    }
}
