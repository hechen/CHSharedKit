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
                bulletRow(
                    icon: "lock.shield.fill",
                    text: Self.localizedPrivacyBullet
                )
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
                .controlSize(.regular)
                .tint(.indigo)
                // 2.7.0: enable the button after 1 s even if the price
                // hasn't loaded — StoreKit's purchase sheet will fetch it.
                .disabled(isPurchasing || (priceLabel == nil && !priceWaitElapsed))

                Button(Self.localizedRestore, action: onRestore)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isPurchasing)
            }

            // 2.6.1: surface the always-free provider so users don't think
            // they're paying for Apple Intelligence (which they aren't —
            // Apple Intelligence is OS-provided and free regardless).
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

    // MARK: - 2.6.1 Localization
    //
    // Lightweight Locale-keyed strings — no .xcstrings catalog or
    // `defaultLocalization` Package change needed. Covers the four target
    // locales Chen named (en / zh-Hans / zh-Hant / ja). Adding more later
    // is a matter of expanding the switch.

    private enum Lang { case en, zhHans, zhHant, ja }
    private static var lang: Lang {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh":
            let script = Locale.current.language.script?.identifier
            return script == "Hant" ? .zhHant : .zhHans
        case "ja": return .ja
        default: return .en
        }
    }

    static var localizedTitle: String {
        switch lang {
        case .zhHans: return "解锁 AI 提供商"
        case .zhHant: return "解鎖 AI 供應商"
        case .ja:     return "AI プロバイダーを解放"
        case .en:     return "Unlock AI providers"
        }
    }

    static var localizedAlwaysFreeCaption: String {
        switch lang {
        case .zhHans: return "Apple Intelligence 始终免费"
        case .zhHant: return "Apple Intelligence 始終免費"
        case .ja:     return "Apple Intelligence は常に無料"
        case .en:     return "Apple Intelligence stays free"
        }
    }

    static var localizedRestore: String {
        switch lang {
        case .zhHans: return "恢复购买"
        case .zhHant: return "恢復購買"
        case .ja:     return "復元"
        case .en:     return "Restore"
        }
    }

    static var localizedProcessing: String {
        switch lang {
        case .zhHans: return "处理中…"
        case .zhHant: return "處理中…"
        case .ja:     return "処理中…"
        case .en:     return "Processing…"
        }
    }

    static var localizedLoading: String {
        switch lang {
        case .zhHans: return "加载中…"
        case .zhHant: return "載入中…"
        case .ja:     return "読み込み中…"
        case .en:     return "Loading…"
        }
    }

    static func localizedUnlockFor(price: String) -> String {
        switch lang {
        case .zhHans: return "以 \(price) 解锁"
        case .zhHant: return "以 \(price) 解鎖"
        case .ja:     return "\(price) で解放"
        case .en:     return "Unlock for \(price)"
        }
    }

    /// 2.7.0: fallback CTA when the price hasn't arrived yet but we don't
    /// want to keep showing "Loading…" past 1 s. StoreKit resolves the
    /// price inside its purchase sheet anyway.
    static var localizedUnlockNoPrice: String {
        switch lang {
        case .zhHans: return "解锁"
        case .zhHant: return "解鎖"
        case .ja:     return "解放"
        case .en:     return "Unlock"
        }
    }

    /// 2.7.0: "Private offline LLMs — no cloud, no rate limits"
    static var localizedPrivacyBullet: String {
        switch lang {
        case .zhHans: return "私密的本地大模型 — 无云端，无次数限制"
        case .zhHant: return "私密的本機大模型 — 無雲端，無次數限制"
        case .ja:     return "プライベートなオンデバイス LLM — クラウドなし、回数制限なし"
        case .en:     return "Private offline LLMs — no cloud, no rate limits"
        }
    }

    /// 2.7.0: "Bring your own keys for cloud providers — you control the cost"
    static var localizedBYOKBullet: String {
        switch lang {
        case .zhHans: return "自带云端 API 密钥 — 您掌控成本"
        case .zhHant: return "自帶雲端 API 金鑰 — 您掌控成本"
        case .ja:     return "自分のクラウド API キーを使用 — コストを自分で管理"
        case .en:     return "Bring your own keys for cloud providers — you control the cost"
        }
    }
}
