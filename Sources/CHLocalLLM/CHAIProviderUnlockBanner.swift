import SwiftUI
import CHSharedKit

/// 2.6.0: top-of-picker banner shown when IAP gating is active and the user
/// hasn't unlocked. Renders as a "dumb" view — the parent (CHAISettingsContent)
/// owns gate observation, this view is purely a function of its inputs so the
/// preview path stays cheap and the parent controls re-render timing.
///
/// Placement: appears as a `Section` content above the AI Provider list.
/// Hidden entirely once `hasUnlockedProviders` flips true; from 2.16.0 the
/// parent shows ``CHAIProviderOwnershipCard`` in its place.
public struct CHAIProviderUnlockBanner: View {
    public let priceLabel: String?
    public let lockedProviderNames: [String]
    public let showsDownloadableModels: Bool
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
        showsDownloadableModels: Bool = true,
        isPurchasing: Bool,
        pulseTrigger: Int,
        onPurchase: @escaping () -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.priceLabel = priceLabel
        self.lockedProviderNames = lockedProviderNames
        self.showsDownloadableModels = showsDownloadableModels
        self.isPurchasing = isPurchasing
        self.pulseTrigger = pulseTrigger
        self.onPurchase = onPurchase
        self.onRestore = onRestore
    }

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseHighlighted = false
    /// 2.7.0: after 1 s without a price, swap "Loading…" button label for
    /// a generic "Unlock" so the button doesn't look frozen on cold launch
    /// (StoreKit's `Product.products(for:)` typically takes 1–3 s on first
    /// query). Tap still triggers purchase — StoreKit resolves the price
    /// inside its own sheet anyway.
    @State private var priceWaitElapsed: Bool = false
    /// 2.7.0: after 5 s without a price, surface a tiny dot indicator so
    /// users know the kit is still trying to load the price (vs the fall-
    /// back label suggesting a stable state).
    @State private var priceLoadStillPending: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                Text(Self.localizedTitle)
                    .font(.headline)
                Spacer()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // 2.7.0: value-prop bullets between subtitle and CTA.
            VStack(alignment: .leading, spacing: 4) {
                if showsDownloadableModels {
                    bulletRow(
                        icon: "lock.shield.fill",
                        text: Self.localizedPrivacyBullet
                    )
                }
                bulletRow(
                    icon: "key.fill",
                    text: Self.localizedBYOKBullet
                )
            }

            HStack(spacing: 8) {
                Button(action: onPurchase) {
                    HStack(spacing: 6) {
                        if isPurchasing {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(Self.localizedProcessing)
                        } else {
                            Image(systemName: "lock.open.fill")
                            Text(buttonLabel)
                            if priceLoadStillPending && priceLabel == nil {
                                // Tiny dot tells the user we're still trying
                                // to load the price; doesn't block the tap.
                                Text("•")
                                    .font(.caption.weight(.bold))
                                    .opacity(0.7)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(CHAIUnlockStrings.actionControlSize)
                .tint(.indigo)
                // 2.7.0: enable the button after 1 s even if the price
                // hasn't loaded — StoreKit's purchase sheet will fetch it.
                .disabled(isPurchasing || (priceLabel == nil && !priceWaitElapsed))

                Button(Self.localizedRestore, action: onRestore)
                    .buttonStyle(.bordered)
                    .controlSize(CHAIUnlockStrings.actionControlSize)
                    .disabled(isPurchasing)
            }

            // Clarify that this unlock is for third-party providers; a host
            // app may itself be paid, so avoid calling the whole app free.
            Text(Self.localizedAlwaysFreeCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color.indigo.opacity(pulseHighlighted ? 0.16 : 0.08))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.indigo.opacity(pulseHighlighted ? 0.5 : 0.25),
                    lineWidth: pulseHighlighted ? 1.5 : 1
                )
        }
        .scaleEffect(pulseScale)
        .onChange(of: pulseTrigger) { _, _ in
            // Keep the attention pulse inside the List row's clipping mask.
            // Scaling above 1.0 pushed the card beyond that mask and cut off
            // its rounded corners. A brief inward pulse plus tint flash is
            // equally visible without changing the card's outer footprint.
            withAnimation(.easeOut(duration: 0.12)) {
                pulseScale = 0.985
                pulseHighlighted = true
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72).delay(0.12)) {
                pulseScale = 1.0
                pulseHighlighted = false
            }
        }
        .task(id: priceLabel) {
            // 2.7.0: price-wait timer. Re-runs whenever priceLabel changes
            // (Task is cancelled and re-spawned). Timeline:
            //   t=0 ms       priceLabel == nil → button shows "Loading…",
            //                disabled.
            //   t=1000 ms    if still nil, swap label to "Unlock", enable
            //                button (StoreKit will resolve price in its
            //                sheet).
            //   t=5000 ms    if still nil, show subtle "•" indicator next
            //                to "Unlock" so the user sees the kit hasn't
            //                given up.
            // Reset on price arrival.
            priceWaitElapsed = false
            priceLoadStillPending = false
            guard priceLabel == nil else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, priceLabel == nil else { return }
            priceWaitElapsed = true
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, priceLabel == nil else { return }
            priceLoadStillPending = true
        }
    }

    @ViewBuilder
    private func bulletRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.indigo.opacity(0.85))
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let names = lockedProviderNames.isEmpty
            ? Self.localizedTitle  // covers the "all AI providers" fallback
            : lockedProviderNames.joined(separator: " · ")
        if let price = priceLabel {
            return "\(names) · \(price)"
        }
        return names
    }

    private var buttonLabel: String {
        if let price = priceLabel {
            return Self.localizedUnlockFor(price: price)
        }
        // 2.7.0: after 1 s of waiting, swap the dead-looking "Loading…"
        // for a plain "Unlock" — tap still works, StoreKit's sheet
        // resolves the price there.
        if priceWaitElapsed {
            return Self.localizedUnlockNoPrice
        }
        return Self.localizedLoading
    }

    // Package catalogs follow the app language, independently of region.

    static var localizedTitle: String {
        return String(localized: "Unlock AI providers", bundle: .module)
    }

    static var localizedAlwaysFreeCaption: String {
        return String(localized: "Apple Intelligence is included without this unlock", bundle: .module)
    }

    static var localizedRestore: String {
        return String(localized: "Restore", bundle: .module)
    }

    static var localizedProcessing: String {
        return String(localized: "Processing…", bundle: .module)
    }

    static var localizedLoading: String {
        return String(localized: "Loading…", bundle: .module)
    }

    static func localizedUnlockFor(price: String) -> String {
        return String(localized: "Unlock for \(price)", bundle: .module)
    }

    /// 2.7.0: fallback CTA when the price hasn't arrived yet but we don't
    /// want to keep showing "Loading…" past 1 s. StoreKit resolves the
    /// price inside its purchase sheet anyway.
    static var localizedUnlockNoPrice: String {
        return String(localized: "Unlock", bundle: .module)
    }

    /// 2.7.0: "Private offline LLMs — no cloud, no rate limits"
    static var localizedPrivacyBullet: String {
        return String(localized: "Private offline LLMs — no cloud, no rate limits", bundle: .module)
    }

    /// 2.7.0: "Bring your own keys for cloud providers — you control the cost"
    static var localizedBYOKBullet: String {
        return String(localized: "Bring your own keys for cloud providers — you control the cost", bundle: .module)
    }
}
