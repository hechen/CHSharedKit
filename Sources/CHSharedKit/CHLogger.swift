import Foundation
import OSLog

public enum CHLogLevel: Int, Comparable, Codable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    public static func < (lhs: CHLogLevel, rhs: CHLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CHLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: CHLogLevel
    public let category: String
    public let message: String
    public let details: String?

    public init(level: CHLogLevel, category: String, message: String, details: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }
}

@MainActor
public final class CHLogger: ObservableObject {
    @Published public private(set) var entries: [CHLogEntry] = []

    private let subsystem: String
    private let maxEntries: Int
    private let persistURL: URL
    private let logger: Logger

    public init(subsystem: String, category: String = "CHLogger", persistFileName: String = "clawd-logs.json", maxEntries: Int = 2000) {
        self.subsystem = subsystem
        self.maxEntries = maxEntries
        self.logger = Logger(subsystem: subsystem, category: category)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.persistURL = docs.appendingPathComponent(persistFileName)
        loadFromDisk()
    }

    public func log(_ level: CHLogLevel, category: String, message: String, details: String? = nil) {
        let entry = CHLogEntry(level: level, category: category, message: message, details: details)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let text = "[\(category)] \(message)\(details.map { " | \($0)" } ?? "")"
        switch level {
        case .debug: logger.debug("\(text)")
        case .info: logger.info("\(text)")
        case .warning: logger.warning("\(text)")
        case .error: logger.error("\(text)")
        }

        saveToDisk()
    }

    public func debug(_ category: String, _ message: String, details: String? = nil) { log(.debug, category: category, message: message, details: details) }
    public func info(_ category: String, _ message: String, details: String? = nil) { log(.info, category: category, message: message, details: details) }
    public func warning(_ category: String, _ message: String, details: String? = nil) { log(.warning, category: category, message: message, details: details) }
    public func error(_ category: String, _ message: String, details: String? = nil) { log(.error, category: category, message: message, details: details) }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: persistURL)
    }

    public func exportText() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.map { e in
            "\(df.string(from: e.timestamp)) \(e.level.label) [\(e.category)] \(e.message)\(e.details.map { " | \($0)" } ?? "")"
        }.joined(separator: "\n")
    }

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(Array(entries.suffix(500))) {
            try? data.write(to: persistURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([CHLogEntry].self, from: data) else { return }
        entries = saved
    }
}
