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
        // 2.16.2: fill the row. The single-row variant stretched through its
        // Spacer; the stacked one sized to its content and left the card
        // short of the list's width.
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Package-localized copy for purchase and restore surfaces.
enum CHAIUnlockStrings {

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
            return String(localized: "\(productName) · Unlocked", bundle: .module)
        }
        return String(localized: "AI providers unlocked", bundle: .module)
    }

    static var ownedSubtitle: String {
        return String(localized: "All AI providers are available.", bundle: .module)
    }

    static var restorePurchases: String {
        return String(localized: "Restore Purchases", bundle: .module)
    }

    static var restoreHint: String {
        return String(localized: "Checks this Apple Account for previous purchases", bundle: .module)
    }

    static var restoredMessage: String {
        return String(localized: "Purchases restored.", bundle: .module)
    }

    static var confirmedMessage: String {
        return String(localized: "Your purchase is confirmed. Nothing needed restoring.", bundle: .module)
    }

    static var nothingToRestoreMessage: String {
        return String(localized: "No previous purchase was found for this Apple Account.", bundle: .module)
    }
}
