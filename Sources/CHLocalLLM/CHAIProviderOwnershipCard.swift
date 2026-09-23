import SwiftUI
import CHSharedKit

/// 2.16.0: what a Restore tap achieved, so the picker can say so.
///
/// Restore used to report only failures. A successful restore that found
/// nothing new looked identical to a tap that did nothing, which is the
/// classic "I pressed Restore and nothing happened" support request.
public enum CHAIRestoreOutcome: Equatable, Sendable {
    /// The unlock was not active before and is now.
    case restored
    /// The unlock was already active; the restore confirmed it.
    case confirmed
    /// StoreKit answered, but this Apple Account has no purchase to restore.
    case nothingToRestore

    /// Derive the outcome from the unlock state either side of a successful
    /// `restorePurchases()` call. Failures never reach here — they surface
    /// through the picker's existing error row.
    public static func after(wasUnlocked: Bool, isUnlocked: Bool) -> CHAIRestoreOutcome {
        switch (wasUnlocked, isUnlocked) {
        case (false, true): return .restored
        case (true, true):  return .confirmed
        default:            return .nothingToRestore
        }
    }

    /// Whether the outcome is good news. Drives the icon and tint.
    public var isPositive: Bool { self != .nothingToRestore }

    public var message: String {
        switch self {
        case .restored:         return CHAIUnlockStrings.restoredMessage
        case .confirmed:        return CHAIUnlockStrings.confirmedMessage
        case .nothingToRestore: return CHAIUnlockStrings.nothingToRestoreMessage
        }
    }
}

/// 2.16.0: top-of-picker card shown once the user owns the unlock.
///
/// Before 2.16.0 the unlock banner vanished after purchase and Restore
/// collapsed into a caption-size plain link in the Cloud APIs footer, under
/// an explanation of API keys. That filed a purchase action under an
/// unrelated heading, gave it a hit target well under a comfortable size,
/// and left the purchase itself unacknowledged — someone who paid saw only
/// the absence of lock icons. The card states the ownership plainly and
/// carries Restore as a full-size secondary button.
///
/// Like ``CHAIProviderUnlockBanner`` this is a "dumb" view: the parent owns
/// gate observation and restore, this renders its inputs.
public struct CHAIProviderOwnershipCard: View {
    public let productName: String?
    public let isRestoring: Bool
    public let restoreOutcome: CHAIRestoreOutcome?
    public let onRestore: () -> Void

    public init(
        productName: String?,
        isRestoring: Bool,
        restoreOutcome: CHAIRestoreOutcome?,
        onRestore: @escaping () -> Void
    ) {
        self.productName = productName
        self.isRestoring = isRestoring
        self.restoreOutcome = restoreOutcome
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 2.16.1: one row when it fits, the button beneath when it does
            // not. On a phone the side-by-side row wrapped "Restore
            // Purchases" onto two lines and broke the subtitle early; the
            // Mac and iPad have the width for a single row. ViewThatFits
            // measures ideal (unwrapped) widths, so it only takes the row
            // when every line fits whole.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    header
                    Spacer(minLength: 12)
                    restoreButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    header
                    restoreButton
                }
            }

            if let restoreOutcome {
                // Colour carries the signal on the icon only. System green as
                // caption text on the green-tinted fill falls well short of
                // the 4.5:1 contrast small text needs, so the words stay
                // primary.
                Label {
                    Text(restoreOutcome.message)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: restoreOutcome.isPositive
                          ? "checkmark.circle.fill"
                          : "info.circle.fill")
                        .foregroundStyle(restoreOutcome.isPositive ? Color.green : Color.secondary)
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.2), value: restoreOutcome)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(CHAIUnlockStrings.ownedTitle(productName: productName))
                    .font(.headline)
                Text(CHAIUnlockStrings.ownedSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var restoreButton: some View {
        Button(action: onRestore) {
            HStack(spacing: 6) {
                if isRestoring {
                    ProgressView().controlSize(.small)
                }
                Text(CHAIUnlockStrings.restorePurchases)
                    // Never wrap the label; the layout moves the button to
                    // its own line instead.
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(CHAIUnlockStrings.actionControlSize)
        .disabled(isRestoring)
        .accessibilityHint(CHAIUnlockStrings.restoreHint)
    }
}

// MARK: - Strings

/// 2.16.0: strings for the purchase surfaces added in 2.16.0, keyed off the
/// same four locales as ``CHAIProviderUnlockBanner`` (en, zh-Hans, zh-Hant,
/// ja) and following its no-catalog, `Locale`-switch convention.
enum CHAIUnlockStrings {
    private enum Lang { case en, zhHans, zhHant, ja }

    private static var lang: Lang {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh":
            return Locale.current.language.script?.identifier == "Hant" ? .zhHant : .zhHans
        case "ja": return .ja
        default:   return .en
        }
    }

    /// Mac `.regular` buttons render noticeably smaller than their iOS
    /// counterparts, which is how the old Restore ended up hard to hit.
    static var actionControlSize: ControlSize {
        #if os(macOS)
        return .large
        #else
        return .regular
        #endif
    }

    static func ownedTitle(productName: String?) -> String {
        if let productName, !productName.isEmpty {
            switch lang {
            case .zhHans: return "\(productName) · 已解锁"
            case .zhHant: return "\(productName) · 已解鎖"
            case .ja:     return "\(productName) · 購入済み"
            case .en:     return "\(productName) · Unlocked"
            }
        }
        switch lang {
        case .zhHans: return "AI 提供商已解锁"
        case .zhHant: return "AI 供應商已解鎖"
        case .ja:     return "AI プロバイダーは解放済み"
        case .en:     return "AI providers unlocked"
        }
    }

    static var ownedSubtitle: String {
        switch lang {
        case .zhHans: return "所有 AI 提供商均可使用。"
        case .zhHant: return "所有 AI 供應商皆可使用。"
        case .ja:     return "すべての AI プロバイダーを利用できます。"
        case .en:     return "All AI providers are available."
        }
    }

    static var restorePurchases: String {
        switch lang {
        case .zhHans: return "恢复购买"
        case .zhHant: return "恢復購買"
        case .ja:     return "購入を復元"
        case .en:     return "Restore Purchases"
        }
    }

    static var restoreHint: String {
        switch lang {
        case .zhHans: return "重新检查此 Apple 账户的购买记录"
        case .zhHant: return "重新檢查此 Apple 帳號的購買記錄"
        case .ja:     return "この Apple アカウントの購入を再確認します"
        case .en:     return "Checks this Apple Account for previous purchases"
        }
    }

    static var restoredMessage: String {
        switch lang {
        case .zhHans: return "已恢复购买。"
        case .zhHant: return "已恢復購買。"
        case .ja:     return "購入を復元しました。"
        case .en:     return "Purchases restored."
        }
    }

    static var confirmedMessage: String {
        switch lang {
        case .zhHans: return "购买已确认，无需恢复。"
        case .zhHant: return "購買已確認，無需恢復。"
        case .ja:     return "購入を確認しました。復元は不要です。"
        case .en:     return "Your purchase is confirmed. Nothing needed restoring."
        }
    }

    static var nothingToRestoreMessage: String {
        switch lang {
        case .zhHans: return "此 Apple 账户没有可恢复的购买。"
        case .zhHant: return "此 Apple 帳號沒有可恢復的購買。"
        case .ja:     return "この Apple アカウントに復元できる購入はありません。"
        case .en:     return "No previous purchase was found for this Apple Account."
        }
    }
}
