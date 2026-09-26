import SwiftUI
import CHSharedKit

/// Shows download progress for an on-device model, with pause/resume/cancel and storage reclaim.
public struct LocalModelDownloadView: View {
    let model: LocalModelInfo
    @State private var store = LocalModelStore.shared

    public init(model: LocalModelInfo = LocalModelCatalog.default) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            switch store.downloadState {
            case .idle:
                idleView
            case .downloading(let progress, let received, let total):
                downloadingView(progress: progress, received: received, total: total)
            case .installing:
                installingView
            case .installed:
                installedView
            case .failed(let message):
                failedView(message: message)
            case .paused:
                pausedView
            }
        }
        .animation(.easeInOut, value: store.downloadState)
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.indigo)

            Text(String(localized: "Ready to Download", bundle: .module))
                .font(.headline)

            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.downloadModel(model)
            } label: {
                Label(String(localized: "Download \(formattedSize(model.sizeBytes))", bundle: .module), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func downloadingView(progress: Double, received: Int64, total: Int64) -> some View {
        // 2.5.8: surface stall + retry inline. Without this, a download that
        // hits a 30 s+ silence (HF Hub mid-shard pause, network drop while
        // app foregrounded) shows a frozen 72% with no recovery path —
        // exactly what Chen's iPad screenshot captured.
        let stalled = store.isDownloadStalled
        return VStack(spacing: 14) {
            Image(systemName: stalled ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(stalled ? .orange : .indigo)
                .symbolEffect(.bounce, value: progress)

            Text(stalled ? String(localized: "Download stalled", bundle: .module) : String(localized: "Downloading \(model.displayName)", bundle: .module))
                .font(.headline)

            if stalled {
                Text(String(localized: "No data received in the last 30 seconds. Tap Retry to resume — already-downloaded files are skipped.", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(stalled ? .orange : .indigo)

            HStack {
                Text(formattedSize(received))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "\(Int(progress * 100))%", bundle: .module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stalled ? .orange : .indigo)
                Spacer()
                Text(formattedSize(total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let speed = store.currentDownloadSpeedBytesPerSecond, speed > 0, !stalled {
                Text(String(localized: "\(formattedSize(Int64(speed)))/s", bundle: .module))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                if stalled {
                    Button {
                        store.retryDownload(model)
                    } label: {
                        Label(String(localized: "Retry", bundle: .module), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.regular)
                }
                Button(role: .destructive) {
                    store.cancelDownload()
                } label: {
                    Label(String(localized: "Cancel", bundle: .module), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private var installingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.5)

            Text(String(localized: "Installing…", bundle: .module))
                .font(.headline)

            Text(String(localized: "Moving model to local storage", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var installedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text(String(localized: "Model Installed", bundle: .module))
                .font(.headline)

            Text(String(localized: "\(model.displayName) is ready for offline use.", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            storageRow
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text(String(localized: "Download Failed", bundle: .module))
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.resetDownloadState()
            } label: {
                Label(String(localized: "Try Again", bundle: .module), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var pausedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(String(localized: "Download Paused", bundle: .module))
                .font(.headline)

            if case .paused(let resumeData) = store.downloadState {
                Button {
                    store.resumeDownload(model: model, resumeData: resumeData)
                } label: {
                    Label(String(localized: "Resume", bundle: .module), systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button(role: .destructive) {
                store.resetDownloadState()
            } label: {
                Label(String(localized: "Discard", bundle: .module), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Storage reclaim

    private var storageRow: some View {
        HStack {
            Label(String(localized: "Storage: \(formattedSize(store.totalStorageUsed))", bundle: .module), systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                store.deleteModel(model)
                store.resetDownloadState()
            } label: {
                Text(String(localized: "Remove Model", bundle: .module))
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
