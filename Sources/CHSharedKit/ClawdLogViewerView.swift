import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct ClawdLogViewerView: View {
    @ObservedObject var logger: ClawdLogger
    @State private var search = ""

    public init(logger: ClawdLogger) {
        self.logger = logger
    }

    var filtered: [ClawdLogEntry] {
        guard !search.isEmpty else { return logger.entries }
        return logger.entries.filter {
            $0.message.localizedCaseInsensitiveContains(search) ||
            ($0.details?.localizedCaseInsensitiveContains(search) ?? false) ||
            $0.category.localizedCaseInsensitiveContains(search)
        }
    }

    public var body: some View {
        List(filtered.reversed()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.level.label).font(.caption2.bold())
                    Text(entry.category).font(.caption2).foregroundStyle(.blue)
                    Spacer()
                    Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                Text(entry.message).font(.caption)
                if let details = entry.details {
                    Text(details).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search, prompt: "Search logs")
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Copy All") {
#if canImport(UIKit)
                        UIPasteboard.general.string = logger.exportText()
#endif
                    }
                    Button("Clear", role: .destructive) { logger.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
