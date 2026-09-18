import Foundation

public struct AmazonOrderItem: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var asin: String
    public var price: String
    public var currency: String
    public var quantity: Int
    public var imageURL: String
    public var status: String?
    public var lineID: String?
    public var quantityWasInferred: Bool?

    public init(name: String, asin: String, price: String, currency: String, quantity: Int, imageURL: String,
                status: String? = nil, lineID: String? = nil, quantityWasInferred: Bool? = nil) {
        self.name = name
        self.asin = asin
        self.price = price
        self.currency = currency
        self.quantity = quantity
        self.imageURL = imageURL
        self.status = status
        self.lineID = lineID
        self.quantityWasInferred = quantityWasInferred
    }
}

public struct AmazonOrder: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var date: String
    public var status: String
    public var detailsURL: String
    public var items: [AmazonOrderItem]

    public init(id: String, date: String, status: String, detailsURL: String, items: [AmazonOrderItem]) {
        self.id = id
        self.date = date
        self.status = status
        self.detailsURL = detailsURL
        self.items = items
    }

    /// True when every purchase line in the order carries a return, refund, or cancellation
    /// status. A partially returned order stays selectable; its returned line is flagged
    /// during review instead.
    public var isReturnedOrCancelled: Bool {
        !items.isEmpty && items.allSatisfy { item in
            guard let status = item.status, !status.isEmpty else { return false }
            return OrderImportText.indicatesReturnOrCancellation(status)
        }
    }

    /// Only hide an order when every exposed purchase line is a confirmed duplicate.
    /// An empty or unrecognized order stays visible so the user can inspect it.
    public func importStatus(using index: OrderImportDuplicateIndex) -> AmazonOrderImportStatus {
        let lines = lineDrafts()
        return AmazonOrderImportStatus(
            purchaseCount: lines.count,
            importedCount: lines.filter { index.contains($0) }.count
        )
    }

    /// The reviewable lines for this order. Nothing is selected by default.
    public func lineDrafts() -> [OrderLineDraft] {
        items.map { item in
            var draft = OrderLineDraft()
            draft.source = "amazon"
            draft.orderID = id
            draft.productID = item.asin
            draft.lineID = item.lineID.flatMap { $0.isEmpty ? nil : $0 }
            draft.originalName = item.name
            draft.name = String(item.name.prefix(200))
            draft.currencyCode = item.currency
            draft.amountText = OrderImportText.cleanAmount(item.price, currencyCode: item.currency)
            draft.dateText = OrderImportText.date(date).map(OrderImportText.isoDay) ?? date
            draft.quantity = item.quantity
            draft.quantityWasInferred = item.quantityWasInferred == true
            draft.status = item.status?.isEmpty == false ? item.status : (status.isEmpty ? nil : status)
            let identity = item.asin.isEmpty ? draft.name : item.asin
            let line = draft.lineID.map { "|\($0)" } ?? ""
            draft.sourceKey = OrderImportText.key("amazon|\(id)|\(identity)\(line)")
            draft.orderURL = sanitizedDetailsURL
            if !item.asin.isEmpty {
                draft.productURL = URL(string: "https://www.amazon.com/dp/\(item.asin)")
            }
            draft.imageURL = URL(string: item.imageURL).flatMap { PublicWebURL.isAllowed($0) ? $0 : nil }
            if let itemStatus = item.status, !itemStatus.isEmpty { draft.warnings.append("Item status: \(itemStatus)") }
            if draft.quantityWasInferred { draft.warnings.append("Amazon did not show a quantity. Confirm the suggested quantity of one.") }
            if draft.needsOwnershipReview { draft.warnings.append("This purchase may have been returned, refunded, or cancelled. Confirm that you still own it.") }
            if draft.amountText.isEmpty { draft.warnings.append("Amazon did not expose a unit price. Enter the amount paid; the order total has not been substituted.") }
            if draft.currencyCode.isEmpty { draft.warnings.append("Confirm the currency shown on your order.") }
            if draft.quantity > 1 { draft.warnings.append("This creates \(draft.quantity) separate items at the unit price.") }
            return draft
        }
    }

    /// The verified order destination without browser tracking parameters.
    public var sanitizedDetailsURL: URL? {
        guard let url = URL(string: detailsURL), Self.allowedURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.localizedCaseInsensitiveContains("order-details"),
              let orderID = components.queryItems?.first(where: { $0.name.lowercased() == "orderid" })?.value,
              !id.isEmpty, orderID == id else { return nil }
        components.queryItems = [URLQueryItem(name: "orderID", value: id)]
        components.fragment = nil
        return components.url
    }

    /// HTTPS on `amazon.com` or a subdomain only.
    public static func allowedURL(_ url: URL) -> Bool {
        guard PublicWebURL.isAllowed(url), let host = url.host?.lowercased() else { return false }
        return host == "amazon.com" || host.hasSuffix(".amazon.com")
    }
}

public struct AmazonOrderImportStatus: Sendable, Equatable {
    public let purchaseCount: Int
    public let importedCount: Int

    public init(purchaseCount: Int, importedCount: Int) {
        self.purchaseCount = purchaseCount
        self.importedCount = importedCount
    }

    public var isFullyImported: Bool { purchaseCount > 0 && importedCount == purchaseCount }
}

/// One browsing session. Re-reading a page refreshes its orders without clearing
/// choices made on another page or adding the same order twice.
public struct AmazonOrderSelection: Sendable, Equatable {
    public private(set) var orders: [AmazonOrder] = []
    public private(set) var selectedIDs: Set<String> = []

    public init() {}

    public var selectedOrders: [AmazonOrder] {
        orders.filter { selectedIDs.contains($0.id) }
    }

    public mutating func merge(_ page: [AmazonOrder]) {
        var indices = Dictionary(uniqueKeysWithValues: orders.enumerated().map { ($0.element.id, $0.offset) })
        for var order in page where !order.id.isEmpty {
            if let index = indices[order.id] {
                // Some history layouts omit the link supplied by a previous page.
                if order.detailsURL.isEmpty { order.detailsURL = orders[index].detailsURL }
                orders[index] = order
            } else {
                indices[order.id] = orders.count
                orders.append(order)
            }
        }
    }

    /// Selecting requires a details link so the purchase lines can be read.
    public mutating func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else if let order = orders.first(where: { $0.id == id }), !order.detailsURL.isEmpty {
            selectedIDs.insert(id)
        }
    }

    public mutating func deselectAll() { selectedIDs.removeAll() }
}

public struct AmazonOrderPagination: Decodable, Sendable, Equatable {
    public var previous: URL?
    public var next: URL?
    public var page: String

    public init(previous: URL? = nil, next: URL? = nil, page: String = "") {
        self.previous = previous
        self.next = next
        self.page = page
    }
}

public enum AmazonOrderPageAccess: String, Sendable, Equatable {
    /// Amazon is asking the user to sign in, verify, or solve a challenge.
    case signIn
    /// A recognized order-history page with no orders for the period.
    case empty
    /// Any other page: read it and let the result decide.
    case orders
}

#if canImport(WebKit)
import WebKit

/// Runs the page scripts inside a host-owned `WKWebView` with bounded payloads.
@MainActor
public enum AmazonOrderReader {
    public static let maximumPayloadBytes = 500_000

    public static func pageAccess(in webView: WKWebView) async throws -> AmazonOrderPageAccess {
        let value = try await webView.evaluateJavaScript(AmazonOrderPage.accessScript, in: nil, contentWorld: .defaultClient)
        return (value as? String).flatMap(AmazonOrderPageAccess.init(rawValue:)) ?? .orders
    }

    public static func orders(in webView: WKWebView) async throws -> [AmazonOrder] {
        let value = try await webView.evaluateJavaScript(AmazonOrderPage.listScript, in: nil, contentWorld: .defaultClient)
        guard let json = value as? String, json.utf8.count <= maximumPayloadBytes else {
            throw OrderImportError.invalid("This order page could not be read.")
        }
        return try JSONDecoder().decode([AmazonOrder].self, from: Data(json.utf8))
    }

    public static func pagination(in webView: WKWebView) async throws -> AmazonOrderPagination {
        let value = try await webView.evaluateJavaScript(AmazonOrderPage.navigationScript, in: nil, contentWorld: .defaultClient)
        guard let json = value as? String, json.utf8.count <= maximumPayloadBytes else {
            throw OrderImportError.invalid("This order page could not be read.")
        }
        return try JSONDecoder().decode(AmazonOrderPagination.self, from: Data(json.utf8))
    }

    /// Reads the purchase lines of one order through its details page.
    public static func orderDetail(_ order: AmazonOrder, in webView: WKWebView) async throws -> AmazonOrder {
        guard let url = URL(string: order.detailsURL), AmazonOrder.allowedURL(url) else {
            throw OrderImportError.invalid("Open order \(order.id) in Amazon and try again.")
        }
        let value = try await webView.callAsyncJavaScript(
            AmazonOrderPage.detailScript,
            arguments: ["url": url.absoluteString, "orderID": order.id],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let json = value as? String, json.utf8.count <= maximumPayloadBytes else {
            throw OrderImportError.invalid("Order \(order.id) could not be read.")
        }
        var detailed = try JSONDecoder().decode(AmazonOrder.self, from: Data(json.utf8))
        if detailed.date.isEmpty { detailed.date = order.date }
        if detailed.status.isEmpty { detailed.status = order.status }
        guard !detailed.items.isEmpty else {
            throw OrderImportError.invalid("Amazon did not expose the items for order \(order.id). Open its details and try again.")
        }
        return detailed
    }
}
#endif
