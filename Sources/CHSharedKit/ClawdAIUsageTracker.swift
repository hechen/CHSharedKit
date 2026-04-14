import Foundation
import SwiftUI

/// Tracks AI API usage: requests, tokens, estimated cost
@MainActor
public final class ClawdAIUsageTracker: ObservableObject {
    public static let shared = ClawdAIUsageTracker()
    
    // MARK: - Published Stats
    
    @Published public private(set) var totalRequests: Int = 0
    @Published public private(set) var totalInputTokens: Int = 0
    @Published public private(set) var totalOutputTokens: Int = 0
    @Published public private(set) var totalImageTokens: Int = 0
    @Published public private(set) var requestHistory: [ClawdAIRequestLog] = []
    
    // Persisted via UserDefaults
    private let defaults = UserDefaults.standard
    
    private init() {
        loadStats()
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
    
    public static let pricing: [String: ModelPricing] = [
        // OpenAI
        "gpt-4o":       ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.00, imageInputPerMillion: 2.50),
        "gpt-4o-mini":  ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, imageInputPerMillion: 0.15),
        "gpt-4-turbo":  ModelPricing(inputPerMillion: 10.00, outputPerMillion: 30.00, imageInputPerMillion: 10.00),
        "gpt-4.1":      ModelPricing(inputPerMillion: 2.00, outputPerMillion: 8.00, imageInputPerMillion: 2.00),
        "gpt-4.1-mini": ModelPricing(inputPerMillion: 0.40, outputPerMillion: 1.60, imageInputPerMillion: 0.40),
        "gpt-4.1-nano": ModelPricing(inputPerMillion: 0.10, outputPerMillion: 0.40, imageInputPerMillion: 0.10),
        // Claude
        "claude-sonnet-4-20250514": ModelPricing(inputPerMillion: 3.00, outputPerMillion: 15.00, imageInputPerMillion: 3.00),
        "claude-opus-4-20250514":   ModelPricing(inputPerMillion: 15.00, outputPerMillion: 75.00, imageInputPerMillion: 15.00),
        "claude-haiku-3-5-20241022": ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.00, imageInputPerMillion: 0.80),
        // Apple Intelligence is free
        "apple-intelligence": ModelPricing(inputPerMillion: 0, outputPerMillion: 0, imageInputPerMillion: 0),
    ]
    
    // MARK: - Log a Request
    
    @discardableResult
    public func logRequest(provider: String, model: String, inputTokens: Int, outputTokens: Int, imageTokens: Int = 0, isVision: Bool = false) -> Double {
        let pricing = Self.pricing[model] ?? ModelPricing(inputPerMillion: 5.0, outputPerMillion: 15.0, imageInputPerMillion: 5.0)
        
        let cost = Double(inputTokens) * pricing.inputPerToken +
                   Double(outputTokens) * pricing.outputPerToken +
                   Double(imageTokens) * pricing.imagePerToken
        
        let log = ClawdAIRequestLog(
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
           let history = try? JSONDecoder().decode([ClawdAIRequestLog].self, from: data) {
            requestHistory = history
        }
    }
}

// MARK: - Request Log

public struct ClawdAIRequestLog: Identifiable, Codable, Sendable {
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
}
