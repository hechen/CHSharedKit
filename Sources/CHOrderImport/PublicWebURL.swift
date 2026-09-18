import Foundation

/// Public HTTPS destinations only. Keeps an order importer from becoming a
/// local-network client or following credentialed links.
public enum PublicWebURL {
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.absoluteString.count <= 8192, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              host != "localhost", host != "localhost." else { return false }
        // Public DNS names only.
        return host.contains(where: { $0.isLetter }) && !host.hasSuffix(".")
    }
}
