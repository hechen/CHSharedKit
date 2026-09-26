#if os(iOS)
import SwiftUI
import CHSharedKit

/// Explainer card shown the first time a user selects "On-Device AI".
/// Tapping "Download Model" triggers the download flow.
public struct OnDeviceLLMOnboardingView: View {
    let model: LocalModelInfo
    let appIdentifier: AppIdentifier
    let onDownload: () -> Void
    let onDismiss: (() -> Void)?

    public init(
        model: LocalModelInfo = LocalModelCatalog.default,
        appIdentifier: AppIdentifier = .distill,
        onDownload: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.appIdentifier = appIdentifier
        self.onDownload = onDownload
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "cpu")
                .font(.system(size: 56))
                .foregroundStyle(.indigo)
                .symbolEffect(.pulse)

            // Title + description
            VStack(spacing: 8) {
                Text(String(localized: "On-Device AI", bundle: .module))
                    .font(.title2.weight(.bold))

                Text(appIdentifier.onboardingBlurb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Feature list
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "wifi.slash", text: String(localized: "Works fully offline", bundle: .module))
                featureRow(icon: "key.slash", text: String(localized: "No API key or account needed", bundle: .module))
                featureRow(icon: "lock.shield", text: String(localized: "Your text never leaves the device", bundle: .module))
                featureRow(icon: "bolt.fill", text: String(localized: "Metal-accelerated on iPhone 16", bundle: .module))
            }
            .padding(.horizontal, 8)

            // Model info card
            VStack(spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(model.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedSize(model.sizeBytes))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(String(localized: "Requires Wi-Fi or cellular. Download once; model persists on device.", bundle: .module))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            // CTA
            VStack(spacing: 10) {
                Button(action: onDownload) {
                    Label(String(localized: "Download Model (\(formattedSize(model.sizeBytes)))", bundle: .module), systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let onDismiss {
                    Button(String(localized: "Not Now", bundle: .module), action: onDismiss)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.indigo)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

#endif
