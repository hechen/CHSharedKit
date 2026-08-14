import Foundation
import SwiftUI

/// Tracks AI API usage: requests, tokens, estimated cost
@MainActor
public final class CHAIUsageTracker: ObservableObject {
    public static let shared = CHAIUsageTracker()
    
    // MARK: - Published Stats
    
    @Published public private(set) var totalRequests: Int = 0
    @Published public private(set) var totalInputTokens: Int = 0
    @Published public private(set) var totalOutputTokens: Int = 0
    @Published public private(set) var totalImageTokens: Int = 0
    @Published public private(set) var requestHistory: [CHAIRequestLog] = []
    
    // Persisted via UserDefaults
    private let defaults = UserDefaults.standard
    
    private init() {
        loadStats()
        migrateFreeProviderHistoryIfNeeded()
    }
    
    // MARK: - Pricing (per 1M tokens, updated periodically)
    
    public struct ModelPricing: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        public let imageInputPerMillion: Double // for vision requests
        
        public var inputPerToken: Double { inputPerMillion / 1_000_000 }
        public var outputPerToken: Double { outputPerMillion / 1_000_000 }
        public var imagePerToken: Double { imageInputPerMillion / 1_000_000 }
        
        public init(inputPerMillion: Double, outputPerMillion: Double, imageInputPerMillion: Double) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.imageInputPerMillion = imageInputPerMillion
        }
    }
    
    private static let bundledPricing: [String: ModelPricing] = [
        // OpenAI — standard processing, August 2026
        "gpt-5.6-sol":   ModelPricing(inputPerMillion: 5.00, outputPerMillion: 30.00, imageInputPerMillion: 5.00),
        "gpt-5.6-terra": ModelPricing(inputPerMillion: 2.00, outputPerMillion: 12.00, imageInputPerMillion: 2.00),
        "gpt-5.6-luna":  ModelPricing(inputPerMillion: 0.20, outputPerMillion: 1.20, imageInputPerMillion: 0.20),
        "gpt-5.5-pro":  ModelPricing(inputPerMillion: 30.00, outputPerMillion: 180.00, imageInputPerMillion: 30.00),
        "gpt-5.5":      ModelPricing(inputPerMillion: 5.00,  outputPerMillion: 30.00, imageInputPerMillion: 5.00),
        "gpt-5.4":      ModelPricing(inputPerMillion: 2.50,  outputPerMillion: 15.00, imageInputPerMillion: 2.50),
        "gpt-5.4-mini": ModelPricing(inputPerMillion: 0.75,  outputPerMillion: 4.50,  imageInputPerMillion: 0.75),
        "gpt-5.4-nano": ModelPricing(inputPerMillion: 0.20,  outputPerMillion: 1.25,  imageInputPerMillion: 0.20),
        "gpt-5.3":      ModelPricing(inputPerMillion: 1.50,  outputPerMillion: 6.00,  imageInputPerMillion: 1.50),
        "gpt-5":        ModelPricing(inputPerMillion: 2.00,  outputPerMillion: 8.00,  imageInputPerMillion: 2.00),
        // OpenAI — retired identifiers kept so historical request-log
        // entries still cost-out correctly in the Usage view. The picker
        // no longer offers them; `CHAIModelMigration` rewrites stored
        // defaults forward on first launch of 2.8.2.
        "gpt-4o":       ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.00, imageInputPerMillion: 2.50),
        "gpt-4o-mini":  ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, imageInputPerMillion: 0.15),
        "gpt-4-turbo":  ModelPricing(inputPerMillion: 10.00, outputPerMillion: 30.00, imageInputPerMillion: 10.00),
        "gpt-4.1":      ModelPricing(inputPerMillion: 2.00, outputPerMillion: 8.00, imageInputPerMillion: 2.00),
        "gpt-4.1-mini": ModelPricing(inputPerMillion: 0.40, outputPerMillion: 1.60, imageInputPerMillion: 0.40),
        "gpt-4.1-nano": ModelPricing(inputPerMillion: 0.10, outputPerMillion: 0.40, imageInputPerMillion: 0.10),
        // Claude — standard first-party API pricing, August 2026.
        // Sonnet 5 uses introductory pricing through August 31, 2026.
        "claude-fable-5":  ModelPricing(inputPerMillion: 10.00, outputPerMillion: 50.00, imageInputPerMillion: 10.00),
        "claude-opus-5": ModelPricing(inputPerMillion: 5.00, outputPerMillion: 25.00, imageInputPerMillion: 5.00),
        "claude-opus-4-8": ModelPricing(inputPerMillion: 5.00, outputPerMillion: 25.00, imageInputPerMillion: 5.00),
        "claude-sonnet-5": ModelPricing(inputPerMillion: 2.00, outputPerMillion: 10.00, imageInputPerMillion: 2.00),
        "claude-haiku-4-5": ModelPricing(inputPerMillion: 1.00, outputPerMillion: 5.00, imageInputPerMillion: 1.00),
        "claude-opus-4-7": ModelPricing(inputPerMillion: 5.00, outputPerMillion: 25.00, imageInputPerMillion: 5.00),
        "claude-opus-4-6": ModelPricing(inputPerMillion: 5.00, outputPerMillion: 25.00, imageInputPerMillion: 5.00),
        "claude-sonnet-4-6": ModelPricing(inputPerMillion: 3.00, outputPerMillion: 15.00, imageInputPerMillion: 3.00),
        "claude-sonnet-4-20250514": ModelPricing(inputPerMillion: 3.00, outputPerMillion: 15.00, imageInputPerMillion: 3.00),
        "claude-opus-4-20250514":   ModelPricing(inputPerMillion: 15.00, outputPerMillion: 75.00, imageInputPerMillion: 15.00),
        "claude-haiku-3-5-20241022": ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.00, imageInputPerMillion: 0.80),
        // Apple Intelligence is free
        "apple-intelligence": ModelPricing(inputPerMillion: 0, outputPerMillion: 0, imageInputPerMillion: 0),
    ]

    /// Current pricing from the validated catalog, merged over bundled
    /// historical prices so old usage records can always be costed.
    public static var pricing: [String: ModelPricing] {
        var result = bundledPricing
        for provider in CHAICloudModelCatalog.snapshot.providers {
            for model in provider.models {
                result[model.id] = ModelPricing(
                    inputPerMillion: model.inputPerMillion,
                    outputPerMillion: model.outputPerMillion,
                    imageInputPerMillion: model.imageInputPerMillion
                )
            }
        }
        return result
    }
    
    // MARK: - Log a Request
    
    @discardableResult
    public func logRequest(provider: String, model: String, inputTokens: Int, outputTokens: Int, imageTokens: Int = 0, isVision: Bool = false) -> Double {
        let pricing = pricingForLog(provider: provider, model: model)
        
        let cost = Double(inputTokens) * pricing.inputPerToken +
                   Double(outputTokens) * pricing.outputPerToken +
                   Double(imageTokens) * pricing.imagePerToken
        
        let log = CHAIRequestLog(
            date: .now,
            provider: provider,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            imageTokens: imageTokens,
            estimatedCost: cost,
            isVision: isVision
        )
        
        totalRequests += 1
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        totalImageTokens += imageTokens
        requestHistory.insert(log, at: 0)
        
        // Keep only last 100 entries
        if requestHistory.count > 100 {
            requestHistory = Array(requestHistory.prefix(100))
        }
        
        saveStats()
        return cost
    }
    
    // MARK: - Computed
    
    public var totalTokens: Int { totalInputTokens + totalOutputTokens + totalImageTokens }
    
    public var totalEstimatedCost: Double {
        requestHistory.reduce(0) { $0 + $1.estimatedCost }
    }
    
    public var todayRequests: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return requestHistory.filter { $0.date >= start }.count
    }
    
    public var todayCost: Double {
        let start = Calendar.current.startOfDay(for: .now)
        return requestHistory.filter { $0.date >= start }.reduce(0) { $0 + $1.estimatedCost }
    }
    
    public var thisMonthCost: Double {
        let components = Calendar.current.dateComponents([.year, .month], from: .now)
        guard let start = Calendar.current.date(from: components) else { return 0 }
        return requestHistory.filter { $0.date >= start }.reduce(0) { $0 + $1.estimatedCost }
    }
    
    // MARK: - Reset
    
    public func resetStats() {
        totalRequests = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        totalImageTokens = 0
        requestHistory.removeAll()
        saveStats()
    }
    
    // MARK: - Persistence
    
    private func saveStats() {
        defaults.set(totalRequests, forKey: "clawd_ai_total_requests")
        defaults.set(totalInputTokens, forKey: "clawd_ai_total_input_tokens")
        defaults.set(totalOutputTokens, forKey: "clawd_ai_total_output_tokens")
        defaults.set(totalImageTokens, forKey: "clawd_ai_total_image_tokens")
        
        if let data = try? JSONEncoder().encode(requestHistory) {
            defaults.set(data, forKey: "clawd_ai_request_history")
        }
    }
    
    private func loadStats() {
        totalRequests = defaults.integer(forKey: "clawd_ai_total_requests")
        totalInputTokens = defaults.integer(forKey: "clawd_ai_total_input_tokens")
        totalOutputTokens = defaults.integer(forKey: "clawd_ai_total_output_tokens")
        totalImageTokens = defaults.integer(forKey: "clawd_ai_total_image_tokens")
        
        if let data = defaults.data(forKey: "clawd_ai_request_history"),
           let history = try? JSONDecoder().decode([CHAIRequestLog].self, from: data) {
            requestHistory = history
        }
    }

    private func migrateFreeProviderHistoryIfNeeded() {
        let migrationKey = "clawd_ai_free_provider_history_migrated_v2"

        var didChangeHistory = false
        requestHistory = requestHistory.map { log in
            let shouldBeFree = pricingForLog(provider: log.provider, model: log.model).inputPerMillion == 0 &&
                pricingForLog(provider: log.provider, model: log.model).outputPerMillion == 0 &&
                pricingForLog(provider: log.provider, model: log.model).imageInputPerMillion == 0
            guard shouldBeFree, log.estimatedCost != 0 else {
                return log
            }
            didChangeHistory = true
            return log.withEstimatedCost(0)
        }

        let recalculatedCost = requestHistory.reduce(0) { $0 + $1.estimatedCost }
        let storedCost = defaults.double(forKey: "clawd_ai_total_estimated_cost_legacy")

        if didChangeHistory || storedCost != recalculatedCost || !defaults.bool(forKey: migrationKey) {
            defaults.set(recalculatedCost, forKey: "clawd_ai_total_estimated_cost_legacy")
            defaults.set(true, forKey: migrationKey)
            saveStats()
        }
    }

    private func pricingForLog(provider: String, model: String) -> ModelPricing {
        if let pricing = Self.pricing[model] {
            return pricing
        }

        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let freeMarkers = [
            "apple-intelligence",
            "on-device",
            "on device",
            "on-device-llm",
            "local-llm",
            "local llm",
            "offline"
        ]

        if freeMarkers.contains(where: { normalizedProvider.contains($0) || normalizedModel.contains($0) }) {
            return ModelPricing(inputPerMillion: 0, outputPerMillion: 0, imageInputPerMillion: 0)
        }

        return ModelPricing(inputPerMillion: 5.0, outputPerMillion: 15.0, imageInputPerMillion: 5.0)
    }
}

// MARK: - Request Log

public struct CHAIRequestLog: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let imageTokens: Int
    public let estimatedCost: Double
    public let isVision: Bool
    
    public init(date: Date, provider: String, model: String, inputTokens: Int, outputTokens: Int, imageTokens: Int, estimatedCost: Double, isVision: Bool) {
        self.id = UUID()
        self.date = date
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.imageTokens = imageTokens
        self.estimatedCost = estimatedCost
        self.isVision = isVision
    }

    private init(id: UUID, date: Date, provider: String, model: String, inputTokens: Int, outputTokens: Int, imageTokens: Int, estimatedCost: Double, isVision: Bool) {
        self.id = id
        self.date = date
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.imageTokens = imageTokens
        self.estimatedCost = estimatedCost
        self.isVision = isVision
    }

    func withEstimatedCost(_ estimatedCost: Double) -> Self {
        Self(
            id: id,
            date: date,
            provider: provider,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            imageTokens: imageTokens,
            estimatedCost: estimatedCost,
            isVision: isVision
        )
    }
}
