import SwiftUI
import CHSharedKit

// MARK: - Host-sold unlock (2.19.17)

/// Opens the host app's own purchase screen for the AI unlock.
///
/// An app whose unlock covers more than AI (Closet Pro also lifts an item
/// limit) sells it on its own screen. Two pitches for one product, one of
/// them describing only the AI half, read as two purchases.
public struct CHAIUnlockAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    public init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction() {
        handler()
    }
}

private struct CHAIUnlockActionKey: EnvironmentKey {
    static let defaultValue: CHAIUnlockAction? = nil
}

public extension EnvironmentValues {
    /// The host's purchase screen for the AI unlock, when it sells the
    /// unlock itself. nil (the default) keeps the kit's banner and
    /// ownership card. Set it with ``SwiftUI/View/chAIUnlockAction(_:)``.
    var chAIUnlockAction: CHAIUnlockAction? {
        get { self[CHAIUnlockActionKey.self] }
        set { self[CHAIUnlockActionKey.self] = newValue }
    }
}

public extension View {
    /// 2.19.17: the host app sells the unlock on its own screen.
    /// ``CHAIProviderPickerView`` and ``CHAISettingsContent`` then show a
    /// one-line row in place of the unlock banner, open `action` from that
    /// row and from any locked provider, and leave out the ownership card
    /// once the unlock is owned, since the host's screen shows it and keeps
    /// Restore.
    ///
    /// ```swift
    /// CHAIProviderPickerView(appIdentifier: .closet)
    ///     .chAIUnlockAction { showingClosetPro = true }
    /// ```
    ///
    /// Apps that never call this keep the banner and the ownership card.
    func chAIUnlockAction(_ action: (@MainActor @Sendable () -> Void)?) -> some View {
        environment(\.chAIUnlockAction, action.map(CHAIUnlockAction.init))
    }
}

/// The unlock banner's stand-in when the host sells the unlock itself:
/// which providers are locked, what unlocks them, and a way to the host's
/// purchase screen. Price, Restore and the pitch live on that screen.
struct CHAIHostUnlockRow: View {
    let productName: String?
    let lockedProviderNames: [String]
    let action: CHAIUnlockAction

    @Environment(\.chAIAccentColor) private var hostAccent
    private var accent: Color { CHAIProviderUnlockBanner.resolvedAccent(hostAccent) }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(lockedProviderNames: lockedProviderNames, productName: productName))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = Self.subtitle(lockedProviderNames: lockedProviderNames, productName: productName) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(Self.localizedLearnMore)
                    .foregroundStyle(accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chAIHostUnlockRow")
    }

    /// The locked providers by name ("Claude, Grok, and OpenAI"). Without
    /// names the row says what unlocks them instead.
    static func title(lockedProviderNames: [String], productName: String?) -> String {
        guard !lockedProviderNames.isEmpty else { return includedWith(productName) }
        return lockedProviderNames.formatted(.list(type: .and))
    }

    static func subtitle(lockedProviderNames: [String], productName: String?) -> String? {
        lockedProviderNames.isEmpty ? nil : includedWith(productName)
    }

    private static func includedWith(_ productName: String?) -> String {
        if let productName, !productName.isEmpty {
            return String(localized: "Included with \(productName)", bundle: .module)
        }
        return String(localized: "Requires a purchase", bundle: .module)
    }

    static var localizedLearnMore: String {
        String(localized: "Learn More", bundle: .module)
    }
}
