import SwiftUI

/// Shows AI API usage stats: requests, tokens, estimated cost.
/// Embed this in your app's settings to show usage/cost tracking.
public struct ClawdAIUsageView: View {
    @StateObject private var tracker = ClawdAIUsageTracker.shared
    @State private var showResetConfirmation = false

    public init() {}

    public var body: some View {
        List {
            // Overview cards
            Section("Overview") {
                HStack {
                    StatTile(title: "Today", value: "\(tracker.todayRequests)", subtitle: formatCost(tracker.todayCost), color: .blue)
                    StatTile(title: "This Month", value: formatCost(tracker.thisMonthCost), subtitle: "\(tracker.requestHistory.count) requests", color: .green)
                    StatTile(title: "All Time", value: formatCost(tracker.totalEstimatedCost), subtitle: "\(tracker.totalRequests) requests", color: .purple)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Token breakdown
            Section("Token Usage") {
                TokenRow(label: "Input Tokens", count: tracker.totalInputTokens, icon: "arrow.up.circle", color: .blue)
                TokenRow(label: "Output Tokens", count: tracker.totalOutputTokens, icon: "arrow.down.circle", color: .green)
                if tracker.totalImageTokens > 0 {
                    TokenRow(label: "Image Tokens", count: tracker.totalImageTokens, icon: "photo.circle", color: .orange)
                }
                TokenRow(label: "Total Tokens", count: tracker.totalTokens, icon: "sum", color: .primary)
            }

            // Recent requests
            if !tracker.requestHistory.isEmpty {
                Section("Recent Requests") {
                    ForEach(tracker.requestHistory.prefix(20)) { log in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(log.provider.capitalized)
                                        .font(.subheadline.bold())
                                    if log.isVision {
                                        Image(systemName: "camera.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(log.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(log.inputTokens + log.outputTokens) tokens")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                Text(formatCost(log.estimatedCost))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(log.date.formatted(.dateTime.hour().minute()))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Pricing reference
            Section {
                NavigationLink("Model Pricing Reference") {
                    ClawdAIPricingView()
                }
            }

            // Reset
            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Usage Stats", systemImage: "trash")
                }
            }
        }
        .navigationTitle("AI Usage")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Reset all usage stats?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { tracker.resetStats() }
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return String(format: "$%.4f", cost) }
        else if cost < 1 { return String(format: "$%.3f", cost) }
        else { return String(format: "$%.2f", cost) }
    }
}

// MARK: - Supporting Views

struct StatTile: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TokenRow: View {
    let label: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(formatTokens(count))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        else if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Pricing Reference

public struct ClawdAIPricingView: View {
    public init() {}

    public var body: some View {
        List {
            Section("OpenAI") {
                PricingRow(model: "gpt-4o", input: 2.50, output: 10.00)
                PricingRow(model: "gpt-4o-mini", input: 0.15, output: 0.60)
                PricingRow(model: "gpt-4.1", input: 2.00, output: 8.00)
                PricingRow(model: "gpt-4.1-mini", input: 0.40, output: 1.60)
                PricingRow(model: "gpt-4.1-nano", input: 0.10, output: 0.40)
            }

            Section("Anthropic Claude") {
                PricingRow(model: "claude-sonnet-4", input: 3.00, output: 15.00)
                PricingRow(model: "claude-opus-4", input: 15.00, output: 75.00)
                PricingRow(model: "claude-haiku-3.5", input: 0.80, output: 4.00)
            }

            Section("Apple Intelligence") {
                HStack {
                    Text("On-device")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Free")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("Prices are per 1M tokens. Vision requests use additional tokens for image processing. Costs are estimates and may differ from your actual bill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Pricing")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct PricingRow: View {
    let model: String
    let input: Double
    let output: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model)
                .font(.subheadline.bold())
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("In:").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f/1M", input)).font(.caption.monospacedDigit())
                }
                HStack(spacing: 4) {
                    Text("Out:").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f/1M", output)).font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
