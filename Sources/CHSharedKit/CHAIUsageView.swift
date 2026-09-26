import SwiftUI

/// Shows AI API usage stats: requests, tokens, estimated cost.
/// Embed this in your app's settings to show usage/cost tracking.
public struct CHAIUsageView: View {
    @Environment(\.theme) private var theme
    @StateObject private var tracker = CHAIUsageTracker.shared
    @State private var showResetConfirmation = false

    public init() {}

    public var body: some View {
        List {
            // Overview cards
            Section(String(localized: "Overview", bundle: .module)) {
                HStack {
                    StatTile(title: String(localized: "Today", bundle: .module), value: "\(tracker.todayRequests)", subtitle: formatCost(tracker.todayCost), color: theme.accent)
                    StatTile(title: String(localized: "This Month", bundle: .module), value: formatCost(tracker.thisMonthCost), subtitle: String(localized: "\(tracker.requestHistory.count) requests", bundle: .module), color: theme.accentSecondary)
                    StatTile(title: String(localized: "All Time", bundle: .module), value: formatCost(tracker.totalEstimatedCost), subtitle: String(localized: "\(tracker.totalRequests) requests", bundle: .module), color: theme.textPrimary)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Token breakdown
            Section(String(localized: "Token Usage", bundle: .module)) {
                TokenRow(label: String(localized: "Input Tokens", bundle: .module), count: tracker.totalInputTokens, icon: "arrow.up.circle", color: theme.accent)
                TokenRow(label: String(localized: "Output Tokens", bundle: .module), count: tracker.totalOutputTokens, icon: "arrow.down.circle", color: theme.accentSecondary)
                if tracker.totalImageTokens > 0 {
                    TokenRow(label: String(localized: "Image Tokens", bundle: .module), count: tracker.totalImageTokens, icon: "photo.circle", color: theme.warning)
                }
                TokenRow(label: String(localized: "Total Tokens", bundle: .module), count: tracker.totalTokens, icon: "sum", color: theme.textPrimary)
            }

            // Recent requests
            if !tracker.requestHistory.isEmpty {
                Section(String(localized: "Recent Requests", bundle: .module)) {
                    ForEach(tracker.requestHistory.prefix(20)) { log in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(log.provider.capitalized)
                                        .font(.subheadline.bold())
                                    if log.isVision {
                                        Image(systemName: "camera.fill")
                                            .font(.caption2)
                                            .foregroundStyle(theme.warning)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(log.model)
                                        .font(.caption)
                                        .foregroundStyle(theme.textSecondary)
                                    Text(String(localized: "\(log.inputTokens + log.outputTokens) tokens", bundle: .module))
                                        .font(.caption)
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                Text(formatCost(log.estimatedCost))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(theme.textSecondary)
                                Text(log.date.formatted(.dateTime.hour().minute()))
                                    .font(.caption2)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Pricing reference
            Section {
                NavigationLink(String(localized: "Model Pricing Reference", bundle: .module)) {
                    CHAIPricingView()
                }
            }

            // Reset
            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label(String(localized: "Reset Usage Stats", bundle: .module), systemImage: "trash")
                }
            }
        }
        .tint(theme.accent)
        .themedListBackground()
        .themedNavigationBar()
        .navigationTitle(String(localized: "AI Usage", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(String(localized: "Reset all usage stats?", bundle: .module), isPresented: $showResetConfirmation) {
            Button(String(localized: "Reset", bundle: .module), role: .destructive) { tracker.resetStats() }
        }
    }

    private func formatCost(_ cost: Double) -> String {
        let digits = cost < 0.01 ? 4 : cost < 1 ? 3 : 2
        return cost.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

// MARK: - Supporting Views

struct StatTile: View {
    @Environment(\.theme) private var theme

    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TokenRow: View {
    @Environment(\.theme) private var theme

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
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        else if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Pricing Reference

public struct CHAIPricingView: View {
    @Environment(\.theme) private var theme
    @StateObject private var modelCatalog = CHAICloudModelCatalog.shared

    public init() {}

    public var body: some View {
        let _ = modelCatalog.revision

        List {
            ForEach(CHAICloudModelCatalog.snapshot.providers) { provider in
                Section(provider.displayName ?? (provider.id == "openai" ? "OpenAI" : provider.id == "claude" ? "Anthropic Claude" : provider.id)) {
                    ForEach(provider.models) { model in
                        PricingRow(model: model.id, input: model.inputPerMillion, output: model.outputPerMillion)
                    }
                }
            }

            Section("Apple Intelligence") {
                HStack {
                    Text(String(localized: "On-device", bundle: .module))
                        .font(.subheadline.bold())
                    Spacer()
                    Text(String(localized: "Free", bundle: .module))
                        .font(.subheadline)
                        .foregroundStyle(theme.success)
                }
            }

            Section {
                Text(String(localized: "Prices are per 1M tokens. Vision requests use additional tokens for image processing. Costs are estimates and may differ from your actual bill.", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .tint(theme.accent)
        .themedListBackground()
        .themedNavigationBar()
        .navigationTitle(String(localized: "Pricing", bundle: .module))
        .task { await modelCatalog.refreshIfNeeded() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func models(for providerID: String) -> [CHAICloudModelCatalogManifest.Model] {
        CHAICloudModelCatalog.snapshot.provider(id: providerID)?.models ?? []
    }
}

struct PricingRow: View {
    @Environment(\.theme) private var theme

    let model: String
    let input: Double
    let output: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model)
                .font(.subheadline.bold())
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text(String(localized: "In:", bundle: .module)).font(.caption).foregroundStyle(theme.textSecondary)
                    Text(String(format: "$%.2f/1M", input)).font(.caption.monospacedDigit())
                }
                HStack(spacing: 4) {
                    Text(String(localized: "Out:", bundle: .module)).font(.caption).foregroundStyle(theme.textSecondary)
                    Text(String(format: "$%.2f/1M", output)).font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
