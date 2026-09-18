import Foundation
import Testing
import WebKit
@testable import CHOrderImport

@MainActor struct AmazonOrderImportTests {
    private let orderURL = URL(string: "https://www.amazon.com/your-orders/order-details?orderID=111-1234567-1234567")!

    @Test func importedOrderStatusSurvivesRenamingAndKeepsPartialOrdersVisible() {
        let item = AmazonOrderItem(name: "Long merchandising title", asin: "B012345678", price: "20.00", currency: "USD", quantity: 1, imageURL: "")
        var order = AmazonOrder(id: "111-1234567-1234567", date: "2026-09-01", status: "Delivered", detailsURL: "", items: [item])
        var draft = order.lineDrafts()[0]
        draft.name = "My jacket"
        let persisted = [draft.sourceKey(forUnit: 0)!]
        let index = OrderImportDuplicateIndex(importedSourceKeys: persisted)
        #expect(order.importStatus(using: index).isFullyImported)
        // History pages often omit unit prices. The purchase source key still matches.
        order.items[0].price = ""
        #expect(order.importStatus(using: index).isFullyImported)
        var second = item; second.asin = "B012345679"; second.name = "Belt"
        order.items.append(second)
        let partial = order.importStatus(using: index)
        #expect(partial.importedCount == 1 && partial.purchaseCount == 2 && !partial.isFullyImported)
        order.id = "222-1234567-1234567"
        #expect(order.importStatus(using: index).importedCount == 0)
        order.items = []
        #expect(!order.importStatus(using: index).isFullyImported)
    }

    @Test func duplicateIndexStripsOnlyNumericUnitSuffixes() {
        #expect(OrderImportDuplicateIndex.lineKey(fromPersisted: "abc:12") == "abc")
        #expect(OrderImportDuplicateIndex.lineKey(fromPersisted: "abc") == "abc")
        #expect(OrderImportDuplicateIndex.lineKey(fromPersisted: "abc:") == "abc:")
        #expect(OrderImportDuplicateIndex.lineKey(fromPersisted: "stable:x:1") == "stable:x")
        var draft = OrderLineDraft(); draft.sourceKey = "abc"
        #expect(OrderImportDuplicateIndex(importedSourceKeys: ["abc:0", "abc:1"]).contains(draft))
        #expect(!OrderImportDuplicateIndex(importedSourceKeys: ["abd:0"]).contains(draft))
        draft.sourceKey = nil
        #expect(!OrderImportDuplicateIndex(importedSourceKeys: ["abc:0"]).contains(draft))
    }

    @Test func pageAccessSeparatesVerificationEmptyHistoryAndUnknownLayouts() async throws {
        let page = OrderTestPage()
        let history = AmazonOrderPage.orderHistoryURL
        for html in ["<input type='password'>", "<input id='auth-mfa-otpcode'>", "<input id='captchacharacters'>"] {
            try await page.load(html, at: history)
            #expect(try await AmazonOrderReader.pageAccess(in: page.webView) == .signIn)
        }
        try await page.load("<h1>Verify your account</h1>", at: URL(string: "https://www.amazon.com/ap/signin")!)
        #expect(try await AmazonOrderReader.pageAccess(in: page.webView) == .signIn)
        try await page.load("<h1>No orders in this period</h1>", at: history)
        #expect(try await AmazonOrderReader.pageAccess(in: page.webView) == .empty)
        try await page.load("<h1>Something went wrong</h1>", at: history)
        #expect(try await AmazonOrderReader.pageAccess(in: page.webView) == .orders)
        #expect(try await AmazonOrderReader.orders(in: page.webView).isEmpty)
    }

    @Test func selectionSpansPagesAndRereadingDoesNotDuplicatePurchases() {
        func order(_ id: String, price: String = "$10.00", details: Bool = true) -> AmazonOrder {
            AmazonOrder(id: id, date: "September 1, 2026", status: "Delivered",
                        detailsURL: details ? "https://www.amazon.com/order-details?orderID=\(id)" : "",
                        items: [AmazonOrderItem(name: "Jacket", asin: "B012345678", price: price,
                                                currency: "USD", quantity: 1, imageURL: "")])
        }
        let first = order("111-1234567-1234567"), second = order("222-1234567-1234567")
        var session = AmazonOrderSelection()
        session.merge([first])
        #expect(session.selectedOrders.isEmpty)
        session.toggle(first.id)
        session.merge([second, first, second])
        #expect(session.selectedOrders.map(\.id) == [first.id])
        session.toggle(second.id)
        session.merge([order(first.id, price: "$12.00", details: false)])
        #expect(session.orders.map(\.id) == [first.id, second.id])
        #expect(session.selectedOrders.count == 2)
        #expect(session.orders[0].detailsURL == first.detailsURL)
        let drafts = session.selectedOrders.flatMap { $0.lineDrafts() }
        #expect(drafts.map(\.amountCents) == [1200, 1000])
        #expect(Set(drafts.map(\.sourceKey)).count == 2)
        session.toggle(first.id)
        session.merge([first])
        #expect(session.selectedOrders.map(\.id) == [second.id])
        session.merge([]) // An empty/failed read must not discard previous choices.
        #expect(session.selectedOrders.map(\.id) == [second.id])
        session.toggle("unknown")
        let unavailable = order("333-1234567-1234567", details: false)
        session.merge([unavailable]); session.toggle(unavailable.id)
        #expect(session.selectedOrders.map(\.id) == [second.id])
        session.deselectAll()
        #expect(session.selectedOrders.isEmpty)
    }

    @Test func enhancedHistoryCardsAndPaginationAreReadWithoutRecommendations() async throws {
        let page = OrderTestPage()
        let html = """
        <div class="order-card"><div>Order placed September 1, 2026</div><div>Order # 111-1234567-1234567</div>
        <a href="/your-orders/order-details?orderID=111-1234567-1234567">View order details</a>
        <div class="delivery-box"><span class="delivery-box__primary-text">Delivered</span>
        <div class="yo-enhanced-flex">
        <div class="yo-enhanced-flex-card"><img src="https://m.media-amazon.com/jacket.jpg"><div class="yo-enhanced-title"><a href="/dp/B012345678">Jacket</a></div></div>
        <div class="yo-enhanced-flex-card"><div class="yo-enhanced-title"><a href="/dp/B012345679">Belt</a></div></div>
        <div class="yo-enhanced-flex-card"><div class="yo-enhanced-title"><a href="/dp/B012345670">Socks</a></div></div>
        </div></div></div>
        <div class="yo-enhanced-flex-card"><div class="yo-enhanced-title"><a href="/dp/B012345671">Not purchased</a></div></div>
        <ul class="a-pagination"><li class="a-disabled">Previous</li><li class="a-selected">1</li><li class="a-last"><a href="?startIndex=10">Next</a></li></ul>
        """
        try await page.load(html, at: AmazonOrderPage.orderHistoryURL)
        let orders = try await AmazonOrderReader.orders(in: page.webView)
        #expect(orders.count == 1)
        #expect(orders[0].items.map(\.name) == ["Jacket", "Belt", "Socks"])
        #expect(orders[0].items[0].imageURL == "https://m.media-amazon.com/jacket.jpg")
        #expect(orders[0].items.allSatisfy { $0.price.isEmpty && $0.status == "Delivered" })
        let navigation = try await AmazonOrderReader.pagination(in: page.webView)
        #expect(navigation.next?.absoluteString == "https://www.amazon.com/your-orders/orders?startIndex=10")
        #expect(navigation.previous == nil)
        #expect(navigation.page == "1")
        let drafts = orders[0].lineDrafts()
        #expect(drafts[0].imageURL?.absoluteString == "https://m.media-amazon.com/jacket.jpg")
        #expect(drafts[0].productURL?.absoluteString == "https://www.amazon.com/dp/B012345678")
        #expect(drafts[0].orderURL?.absoluteString == "https://www.amazon.com/your-orders/order-details?orderID=111-1234567-1234567")
        try await page.load(html.replacingOccurrences(of: "?startIndex=10", with: "https://example.com/your-orders/orders"), at: AmazonOrderPage.orderHistoryURL)
        #expect(try await AmazonOrderReader.pagination(in: page.webView).next == nil)
    }

    @Test func spanishHistoryAndReorderedRepeatedProductsKeepIdentity() async throws {
        let page = OrderTestPage()
        func html(_ reverse: Bool) -> String {
            let rows = ["Jacket black", "Jacket navy"].enumerated().map { index, name in
                "<div class='yo-enhanced-flex-card'><div class='yo-enhanced-title'><a href='/dp/B012345678'>\(name)</a></div><span class='unit-price'>US$\(index + 20).00</span><span data-component='quantity'>Cantidad: 2</span></div>"
            }
            return "<div class='order-card'><span>Pedido realizado 1 de septiembre de 2026</span> <span>111-1234567-1234567</span> <a href='/your-orders/order-details?orderID=111-1234567-1234567'>Detalles</a><div class='delivery-box'><span class='delivery-box__primary-text'>Reembolso emitido</span>\((reverse ? rows.reversed() : rows).joined())</div></div>"
        }
        try await page.load(html(false), at: orderURL)
        let first = try #require(await AmazonOrderReader.orders(in: page.webView).first)
        try await page.load(html(true), at: orderURL)
        let second = try #require(await AmazonOrderReader.orders(in: page.webView).first)
        #expect(first.date == "2026-09-01")
        #expect(first.items.allSatisfy { $0.quantity == 2 && $0.quantityWasInferred == false })
        #expect(Set(first.lineDrafts().map(\.sourceKey)) == Set(second.lineDrafts().map(\.sourceKey)))
        #expect(first.lineDrafts().allSatisfy { $0.needsOwnershipReview })
        #expect(first.lineDrafts()[0].amountCents == 2000 && first.lineDrafts()[0].currencyCode == "USD")
    }

    @Test func orderIsReturnedOrCancelledOnlyWhenEveryLineIs() {
        func item(_ status: String?) -> AmazonOrderItem {
            var item = AmazonOrderItem(name: "Jacket", asin: "B012345678", price: "20.00", currency: "USD", quantity: 1, imageURL: "")
            item.status = status; return item
        }
        func order(_ items: [AmazonOrderItem]) -> AmazonOrder {
            AmazonOrder(id: "111-1234567-1234567", date: "2026-09-01", status: "", detailsURL: "", items: items)
        }
        for status in ["Return complete", "Refund issued", "Cancelled", "Returned", "Reembolso emitido", "Devuelto", "Cancelado"] {
            #expect(order([item(status)]).isReturnedOrCancelled, "\(status)")
        }
        for status in ["Delivered", "Arriving tomorrow", "Shipped", "Entregado"] {
            #expect(!order([item(status)]).isReturnedOrCancelled, "\(status)")
        }
        #expect(!order([item(nil)]).isReturnedOrCancelled)
        #expect(!order([item("")]).isReturnedOrCancelled)
        #expect(!order([item("Delivered"), item("Return complete")]).isReturnedOrCancelled)
        #expect(order([item("Cancelled"), item("Refund issued")]).isReturnedOrCancelled)
        #expect(!order([]).isReturnedOrCancelled)
    }

    @Test func recoveryRoundTripExpiryDiscardAndMalformedArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let repository = AmazonImportArchiveStore()
        let order = AmazonOrder(id: "111-1234567-1234567", date: "September 1, 2026", status: "Delivered", detailsURL: orderURL.absoluteString,
            items: [AmazonOrderItem(name: "Jacket", asin: "B012345678", price: "$49.95", currency: "USD", quantity: 1, imageURL: "")])
        var draft = order.lineDrafts()[0]; draft.name = "Reviewed jacket"; draft.selected = true
        var archive = AmazonImportArchive(orders: [order], selectedIDs: [order.id], drafts: [draft], pageURL: orderURL)
        archive.pagesRead = [order.id]
        try await repository.save(archive, at: url)
        let restored = try #require(try await repository.load(at: url))
        #expect(restored.drafts == [draft] && restored.selectedIDs == [order.id] && restored.pagesRead == [order.id])
        #expect(AmazonImportArchive(orders: [], selectedIDs: [], drafts: [], pageURL: URL(string: "https://www.amazon.com/ap/signin?token=private")).pageURL == nil)
        #expect(AmazonImportArchive(orders: [], selectedIDs: [], drafts: [], pageURL: URL(string: orderURL.absoluteString + "&ref_=tracking#fragment")).pageURL == orderURL)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try await repository.clear(at: url)
        try await repository.save(archive, at: url) // A queued stale autosave cannot resurrect discarded progress.
        #expect(try await repository.load(at: url) == nil)
        var later = archive; later.updatedAt = .now.addingTimeInterval(1)
        try await repository.save(later, at: url)
        #expect(try await repository.load(at: url, now: later.updatedAt.addingTimeInterval(8 * 86_400)) == nil)
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await repository.load(at: url) }
        var invalid = archive; invalid.selectedIDs = ["missing"]
        #expect(throws: OrderImportError.self) { try invalid.validated() }
    }

    @Test(arguments: ["", "https://example.com/order-details?orderID=111-1234567-1234567",
                      "https://www.amazon.com/your-orders/order-details?orderID=222-1234567-1234567",
                      "https://www.amazon.com/your-orders/orders?orderID=111-1234567-1234567"])
    func unavailableOrMismatchedOrderLinkIsDropped(detailsURL: String) throws {
        let order = AmazonOrder(id: "111-1234567-1234567", date: "September 1, 2026", status: "Delivered",
                                detailsURL: detailsURL,
                                items: [AmazonOrderItem(name: "Jacket", asin: "B012345678", price: "$49.95",
                                                        currency: "USD", quantity: 1, imageURL: "")])
        let draft = try #require(order.lineDrafts().first)
        #expect(draft.orderURL == nil)
        #expect(draft.issue == nil)
    }

    // Synthetic values in the structural containers observed on Amazon.com, including duplicate
    // accessible/visual prices and separate shipment statuses within the same order.
    private var html: String {
        """
        <html><body><div id="orderDetails">
        <span data-component="orderDate">September 1, 2026</span>
        <span data-component="orderId">111-1234567-1234567</span>
        <div data-component="orderSummary">Grand total $109.90</div>
        <div data-component="shipments">
          <div data-component="shipmentsLeftGrid">
            <div data-component="shipmentStatus"><span>Delivered September 2</span></div>
            <div data-component="purchasedItems"><div class="a-fixed-left-grid">
              <div data-component="itemTitle"><a href="/dp/B012345678">Wool overcoat</a></div>
              <div data-component="unitPrice"><span class="a-offscreen">$49.95</span><span aria-hidden="true">$49.95</span></div>
              <div data-component="quantity">Quantity: 2</div>
              <div data-component="itemImage"><img src="https://m.media-amazon.com/coat.jpg"></div>
            </div></div>
          </div>
          <div data-component="shipmentsLeftGrid">
            <div data-component="shipmentStatus"><span>Return complete</span><span>Refund issued</span></div>
            <div data-component="purchasedItems"><div class="a-fixed-left-grid">
              <div data-component="itemTitle"><a href="/dp/B012345679">Returned keyboard</a></div>
              <div data-component="unitPrice"><span class="a-offscreen">$39.00</span><span aria-hidden="true">$39.00</span></div>
            </div></div>
          </div>
        </div></div>
        <div data-component="personalization"><a href="/dp/B012345670">Unpurchased recommendation</a><span>$999.00</span></div>
        </body></html>
        """
    }

    @Test func renderedDetailKeepsPricesStatusesAndRecommendationsSeparate() async throws {
        let page = OrderTestPage()
        try await page.load(html, at: orderURL)
        let orders = try await AmazonOrderReader.orders(in: page.webView)
        let order = try #require(orders.first)
        #expect(orders.count == 1 && order.items.count == 2)
        #expect(order.items[0].price == "$49.95" && order.items[0].quantity == 2)
        #expect(order.items[0].status == "Delivered September 2")
        #expect(order.items[1].status == "Return complete")
        let drafts = order.lineDrafts()
        #expect(drafts[0].amountText == "49.95" && drafts[0].dateText == "2026-09-01")
        #expect(drafts[0].amountCents == 4995)
        #expect(drafts.allSatisfy { !$0.selected })
        #expect(drafts[1].warnings.contains("Item status: Return complete"))
        #expect(drafts[1].needsOwnershipReview && !drafts[0].needsOwnershipReview)
        #expect(drafts[0].sourceKey(forUnit: 1) == drafts[0].sourceKey! + ":1")
        let detail = try await AmazonOrderReader.orderDetail(order, in: page.webView)
        #expect(detail.items.count == 2 && detail.items[0].price == "$49.95")
    }

    @Test func selectedDetailResponseUsesDetachedDOMAndSameOriginSession() async throws {
        let page = OrderTestPage()
        try await page.load("<html><body>Order history</body></html>", at: AmazonOrderPage.orderHistoryURL)
        let encodedHTML = String(data: try JSONEncoder().encode(html), encoding: .utf8)!
        let encodedURL = String(data: try JSONEncoder().encode(orderURL.absoluteString), encoding: .utf8)!
        _ = try await page.evaluate("""
        window.fetch = async (url, options) => {
          if(url !== \(encodedURL) || options.credentials !== 'same-origin') throw new Error('Unexpected request');
          const response = new Response(\(encodedHTML));
          return {ok:true,url,body:response.body};
        }; 'ready';
        """)
        let stub = AmazonOrder(id: "111-1234567-1234567", date: "", status: "", detailsURL: orderURL.absoluteString, items: [])
        let order = try await AmazonOrderReader.orderDetail(stub, in: page.webView)
        #expect(order.items.count == 2 && order.items[0].price == "$49.95")
        #expect(order.items[1].status == "Return complete" && order.date == "September 1, 2026")
    }

    @Test func cancellingConcurrentDetailRequestsAbortsEveryRequest() async throws {
        let page = OrderTestPage()
        try await page.load("<html><body>Order history</body></html>", at: AmazonOrderPage.orderHistoryURL)
        _ = try await page.evaluate("""
        globalThis.abortedCount = 0; globalThis.peakRequests = 0;
        window.fetch = (url, options) => new Promise((resolve, reject) => {
          globalThis.peakRequests = Math.max(globalThis.peakRequests, globalThis.chOrderRequests.size);
          options.signal.addEventListener('abort', () => {
            globalThis.abortedCount++; reject(new DOMException('Cancelled', 'AbortError'));
          });
          if(globalThis.chOrderRequests.size === 2) {
            setTimeout(() => globalThis.chOrderRequests.forEach(c => c.abort()), 10);
          }
        }); 'ready';
        """)
        @MainActor func rejected(_ id: String) async -> Bool {
            let stub = AmazonOrder(id: id, date: "", status: "", detailsURL: "https://www.amazon.com/gp/your-account/order-details?orderID=" + id, items: [])
            do { _ = try await AmazonOrderReader.orderDetail(stub, in: page.webView); return false }
            catch { return true }
        }
        async let first = rejected("111-1234567-1234567")
        async let second = rejected("222-1234567-1234567")
        let results = await (first, second)
        #expect(results.0 && results.1)
        #expect(try await page.evaluate("String(globalThis.peakRequests)") == "2")
        #expect(try await page.evaluate("String(globalThis.abortedCount)") == "2")
        #expect(try await page.evaluate("String(globalThis.chOrderRequests.size)") == "0")
    }

    @Test func historyDoesNotUseOrderTotalsAndUnavailableDetailsStayUnavailable() async throws {
        let page = OrderTestPage()
        let history = """
        <div class="order-card"><div>Order placed September 1, 2026</div><div>Order # 111-1234567-1234567</div>
        <div>Total $150.00</div><div class="delivery-box"><span class="delivery-box__primary-text">Cancelled</span>
        <div class="item-box"><div class="yohtmlc-product-title"><a href="/dp/B012345678">Jacket</a></div></div></div></div>
        <aside><a href="/dp/B012345670">Unpurchased recommendation</a></aside>
        """
        try await page.load(history, at: AmazonOrderPage.orderHistoryURL)
        let orders = try await AmazonOrderReader.orders(in: page.webView)
        let order = try #require(orders.first)
        #expect(orders.count == 1 && order.items.count == 1)
        #expect(order.detailsURL.isEmpty && order.items[0].price.isEmpty)
        #expect(order.items[0].status == "Cancelled")
        #expect(order.lineDrafts()[0].issue != nil)
        var selection = AmazonOrderSelection(); selection.merge(orders); selection.toggle(order.id)
        #expect(selection.selectedOrders.isEmpty)
    }

    @Test func repeatedProductsAndWrongOrderCannotSilentlyMerge() async throws {
        let page = OrderTestPage()
        try await page.load(html.replacingOccurrences(of: "B012345679", with: "B012345678"), at: orderURL)
        let orders = try await AmazonOrderReader.orders(in: page.webView)
        let drafts = try #require(orders.first).lineDrafts()
        #expect(drafts.count == 2 && drafts[0].sourceKey != drafts[1].sourceKey)
        let wrong = AmazonOrder(id: "111-0000000-0000000", date: "", status: "", detailsURL: orderURL.absoluteString, items: [])
        await #expect(throws: (any Error).self) { try await AmazonOrderReader.orderDetail(wrong, in: page.webView) }
        #expect(!AmazonOrder.allowedURL(URL(string: "https://amazon.com.example.org/orders")!))
        #expect(!AmazonOrder.allowedURL(URL(string: "http://www.amazon.com/orders")!))
        #expect(AmazonOrder.allowedURL(URL(string: "https://www.amazon.com/your-orders/orders")!))
    }
}

@MainActor private final class OrderTestPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, any Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ html: String, at url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error); loaded = nil
    }

    func evaluate(_ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return value as? String ?? ""
    }
}
