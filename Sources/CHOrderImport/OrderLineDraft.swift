import CryptoKit
import Foundation

public enum OrderImportError: LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// One reviewable purchase line. It is never saved automatically; the host app
/// shows it in a review screen and maps the confirmed values onto its own model.
public struct OrderLineDraft: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id = UUID()
    /// `amazon` for browser reads, `amazon-csv` for order files.
    public var source = "amazon"
    public var orderID = ""
    /// Amazon ASIN or another retailer product identifier. Empty when unknown.
    public var productID = ""
    /// Amazon line identifier, or a `stable:` signature for repeated products.
    public var lineID: String?
    /// Editable, limited to 200 characters.
    public var name = ""
    /// The retailer's full title, kept for notes and undo.
    public var originalName = ""
    /// Unit amount as text using a decimal point, for example `49.95`.
    public var amountText = ""
    public var currencyCode = ""
    /// `yyyy-MM-dd` when the source date was understood; otherwise the raw text.
    public var dateText = ""
    public var quantity = 1
    public var quantityWasInferred = false
    public var imageURL: URL?
    public var status: String?
    public var orderURL: URL?
    public var productURL: URL?
    /// SHA-256 of the source identity. Persist `sourceKey(forUnit:)` per saved unit.
    public var sourceKey: String?
    public var warnings: [String] = []
    public var selected = false

    public init() {}

    /// True when Amazon reports this line as returned, refunded, or cancelled.
    public var needsOwnershipReview: Bool {
        guard let status, !status.isEmpty else { return false }
        return OrderImportText.indicatesReturnOrCancellation(status)
    }

    public var amountCents: Int? {
        OrderImportText.amountCents(amountText, currencyCode: currencyCode)
    }

    public var purchaseDate: Date? { OrderImportText.date(dateText) }

    public var hasValidCurrency: Bool { OrderImportText.isCurrencyCode(currencyCode) }

    /// The first problem that blocks saving, or nil when the line is complete.
    public var issue: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.count > 200 { return "Enter an item name up to 200 characters." }
        if !hasValidCurrency { return "Choose the purchase currency." }
        if amountCents == nil { return "Enter the price for one item, using a decimal point." }
        guard let purchaseDate else { return "Choose a purchase date." }
        let calendar = Calendar.current
        if calendar.startOfDay(for: purchaseDate) > calendar.startOfDay(for: .now) { return "Choose a purchase date no later than today." }
        if !(1...100).contains(quantity) { return "Quantity must be between 1 and 100." }
        return nil
    }

    /// The identity to persist for the `index`-th unit created from this line.
    public func sourceKey(forUnit index: Int) -> String? {
        sourceKey.map { "\($0):\(index)" }
    }
}

/// Text helpers shared by every order source.
public enum OrderImportText {
    public static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func dataKey(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let gregorian = Calendar(identifier: .gregorian)

    /// Strict calendar-day parsing. ISO timestamps keep their written day. Never guesses.
    public static func date(_ value: String, format: OrderCSVDateFormat = .iso) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if format != .iso {
            let parts = text.split(separator: "/")
            guard parts.count == 3, parts[2].count == 4,
                  let a = Int(parts[0]), let b = Int(parts[1]), let year = Int(parts[2]) else { return nil }
            let month = format == .monthFirst ? a : b
            let day = format == .monthFirst ? b : a
            return date(String(format: "%04d-%02d-%02d", year, month, day))
        }
        if text.count >= 10 {
            let prefix = String(text.prefix(10))
            let parts = prefix.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
               let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
                let components = DateComponents(year: year, month: month, day: day)
                guard let date = gregorian.date(from: components),
                      gregorian.dateComponents([.year, .month, .day], from: date) == components else { return nil }
                return date
            }
        }
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.calendar = gregorian
        formatter.isLenient = false
        for pattern in ["MMMM d, yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// `yyyy-MM-dd` in the Gregorian calendar and the current time zone.
    public static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.calendar = gregorian
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Strips a leading ISO code or one currency symbol and US-style thousands
    /// grouping. Symbols never decide the currency; the user confirms an ISO code.
    public static func cleanAmount(_ raw: String, currencyCode: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == "USD", value.hasPrefix("US$") { value.removeFirst(3) }
        if !code.isEmpty, value.uppercased().hasPrefix(code) { value.removeFirst(code.count) }
        value = value.trimmingCharacters(in: .whitespaces)
        if let first = value.first, "$£€¥".contains(first) { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespaces)
        let whole = value.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let groups = whole.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1, (1...3).contains(groups[0].count),
           groups.allSatisfy({ $0.allSatisfy(\.isNumber) }),
           groups.dropFirst().allSatisfy({ $0.count == 3 }) {
            value = value.replacingOccurrences(of: ",", with: "")
        }
        return value
    }

    public static func isCurrencyCode(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 3 && trimmed.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// Minor units for the currency: 0 for yen-style currencies, otherwise 2.
    public static func minorUnits(for currencyCode: String) -> Int {
        switch currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "JPY", "KRW", "VND", "CLP", "ISK", "HUF", "TWD", "PYG", "UGX", "XAF", "XOF": 0
        default: 2
        }
    }

    /// Parses `123` or `123.45` written with a decimal point into minor units.
    /// Rejects negative, non-numeric, over-precise, or absurdly large values.
    public static func amountCents(_ text: String, currencyCode: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !whole.isEmpty || !fraction.isEmpty, whole.count <= 12 else { return nil }
        let minor = minorUnits(for: currencyCode)
        guard fraction.count <= minor else { return nil }
        let wholeValue = whole.isEmpty ? 0 : (Int(whole) ?? -1)
        guard wholeValue >= 0 else { return nil }
        let padded = fraction.padding(toLength: minor, withPad: "0", startingAt: 0)
        let fractionValue = padded.isEmpty ? 0 : (Int(padded) ?? -1)
        guard fractionValue >= 0 else { return nil }
        var scale = 1
        for _ in 0..<minor { scale *= 10 }
        let cents = wholeValue * scale + fractionValue
        guard cents <= 100_000_000_000 else { return nil }
        return cents
    }

    /// Amazon renders status per shipment in the user's language. These stems cover the
    /// English and Spanish storefronts that have been observed; an unrecognized status is
    /// treated as owned, since hiding a purchase is worse than flagging it for review.
    public static func indicatesReturnOrCancellation(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return ["return", "refund", "cancel", "devuelt", "devoluci", "reembols", "cancelad"].contains { lowered.contains($0) }
    }
}
