import SwiftUI
import CHSharedKit

/// 2.6.0: top-of-picker banner shown when IAP gating is active and the user
/// hasn't unlocked. Renders as a "dumb" view — the parent (CHAISettingsContent)
/// owns gate observation, this view is purely a function of its inputs so the
/// preview path stays cheap and the parent controls re-render timing.
///
/// Placement: appears as a `Section` content above the AI Provider list.
/// Hidden entirely once `hasUnlockedProviders` flips true; the parent
/// switches to a small "Restore Purchases" link in the section footer.
public struct CHAIProviderUnlockBanner: View {
    public let priceLabel: String?
    public let lockedProviderNames: [String]
    public let isPurchasing: Bool
    public let onPurchase: () -> Void
    public let onRestore: () -> Void

    /// Pulse trigger (incremented when a locked-row tap should draw the
    /// user's eye to the banner). The banner watches this and animates a
    /// brief scale + tint flash on increment.
    public let pulseTrigger: Int

    public init(
        priceLabel: String?,
        lockedProviderNames: [String],
        isPurchasing: Bool,
        pulseTrigger: Int,
        onPurchase: @escaping () -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.priceLabel = priceLabel
        self.lockedProviderNames = lockedProviderNames
        self.isPurchasing = isPurchasing
        self.pulseTrigger = pulseTrigger
        self.onPurchase = onPurchase
        self.onRestore = onRestore
    }

    @State private var pulseScale: CGFloat = 1.0

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                Text("Unlock all AI providers")
                    .font(.headline)
                Spacer()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: onPurchase) {
                    HStack {
                        if isPurchasing {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Processing…")
                        } else {
                            Image(systemName: "lock.open.fill")
                            Text(buttonLabel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.indigo)
                .disabled(priceLabel == nil || isPurchasing)

                Button("Restore", action: onRestore)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isPurchasing)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.indigo.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.indigo.opacity(0.25), lineWidth: 1)
                )
        )
        .scaleEffect(pulseScale)
        .onChange(of: pulseTrigger) { _, _ in
            // Quick scale-up-then-down attention pulse when the user taps a
            // locked row. Spring out, spring back.
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                pulseScale = 1.04
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.18)) {
                pulseScale = 1.0
            }
        }
    }

    private var subtitle: String {
        let names = lockedProviderNames.isEmpty
            ? "all AI providers"
            : lockedProviderNames.joined(separator: " · ")
        if let price = priceLabel {
            return "\(names) · \(price) one-time"
        }
        return names
    }

    private var buttonLabel: String {
        if let price = priceLabel {
            return "Unlock for \(price)"
        }
        return "Loading…"
    }
}
