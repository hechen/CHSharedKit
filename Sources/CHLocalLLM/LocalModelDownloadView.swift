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

            Text("Ready to Download")
                .font(.headline)

            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.downloadModel(model)
            } label: {
                Label("Download \(formattedSize(model.fileSizeBytes))", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func downloadingView(progress: Double, received: Int64, total: Int64) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.indigo)
                .symbolEffect(.bounce, value: progress)

            Text("Downloading \(model.displayName)")
                .font(.headline)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.indigo)

            HStack {
                Text(formattedSize(received))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Text(formattedSize(total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                store.cancelDownload()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var installingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Installing…")
                .font(.headline)

            Text("Moving model to local storage")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var installedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Model Installed")
                .font(.headline)

            Text("\(model.displayName) is ready for offline use.")
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

            Text("Download Failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.resetDownloadState()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
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

            Text("Download Paused")
                .font(.headline)

            if case .paused(let resumeData) = store.downloadState {
                Button {
                    store.resumeDownload(model: model, resumeData: resumeData)
                } label: {
                    Label("Resume", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button(role: .destructive) {
                store.resetDownloadState()
            } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Storage reclaim

    private var storageRow: some View {
        HStack {
            Label("Storage: \(formattedSize(store.totalStorageUsed))", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                store.deleteModel(model)
                store.resetDownloadState()
            } label: {
                Text("Remove Model")
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
