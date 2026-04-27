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
                Text(Self.localizedTitle)
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
                            Text(Self.localizedProcessing)
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
}
