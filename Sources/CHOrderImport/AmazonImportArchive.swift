import Foundation

/// Local recovery of an unfinished Amazon import. Never include it in collection
/// exports or cloud records.
public struct AmazonImportArchive: Codable, Sendable, Equatable {
    public var version = 1
    public var updatedAt = Date.now
    public var orders: [AmazonOrder]
    public var selectedIDs: Set<String>
    public var drafts: [OrderLineDraft]
    public var pageURL: URL?
    public var pagesRead: Set<String>?

    public init(orders: [AmazonOrder], selectedIDs: Set<String>, drafts: [OrderLineDraft], pageURL: URL?) {
        self.orders = orders
        self.selectedIDs = selectedIDs
        self.drafts = drafts
        self.pageURL = pageURL.flatMap(Self.recoveryPage)
    }

    /// Keeps order navigation, never sign-in callbacks or unrelated browsing URLs.
    private static func recoveryPage(_ url: URL) -> URL? {
        guard AmazonOrder.allowedURL(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["/your-orders/orders", "/gp/your-account/order-history",
               "/your-orders/order-details", "/gp/your-account/order-details"].contains(parts.path) else { return nil }
        let allowed = Set(["orderID", "orderFilter", "startIndex", "search"])
        parts.queryItems = parts.queryItems?.filter { allowed.contains($0.name) }
        parts.fragment = nil
        return parts.url
    }

    public var isEmpty: Bool { selectedIDs.isEmpty && drafts.isEmpty }

    public func validated() throws -> Self {
        guard version == 1, orders.count <= 5_000, drafts.count <= 5_000,
              Set(orders.map(\.id)).count == orders.count,
              selectedIDs.isSubset(of: Set(orders.map(\.id))),
              drafts.allSatisfy({ $0.name.count <= 200 && $0.originalName.count <= 2_000 }),
              pageURL == nil || Self.recoveryPage(pageURL!) == pageURL else {
            throw OrderImportError.invalid("This saved Amazon import could not be opened.")
        }
        return self
    }
}

/// Serial, bounded file access with timestamp guards against late autosaves after discard.
public actor AmazonImportArchiveStore {
    public static let shared = AmazonImportArchiveStore()
    private var lastChange: [URL: Date] = [:]

    public init() {}

    public func load(at url: URL, now: Date = .now) throws -> AmazonImportArchive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 40_000_000 else { throw OrderImportError.invalid("This saved Amazon import is too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 40_000_000 else { throw OrderImportError.invalid("This saved Amazon import is too large.") }
        let value = try JSONDecoder().decode(AmazonImportArchive.self, from: data).validated()
        guard now.timeIntervalSince(value.updatedAt) < 7 * 86_400 else {
            try clear(at: url)
            return nil
        }
        return value.isEmpty ? nil : value
    }

    public func save(_ value: AmazonImportArchive, at url: URL) throws {
        guard value.updatedAt >= (lastChange[url] ?? .distantPast) else { return }
        let data = try JSONEncoder().encode(value.validated())
        guard data.count <= 40_000_000 else { throw OrderImportError.invalid("This saved Amazon import is too large.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var localURL = url
        try localURL.setResourceValues(values)
        lastChange[url] = value.updatedAt
    }

    public func clear(at url: URL) throws {
        lastChange[url] = .now
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
