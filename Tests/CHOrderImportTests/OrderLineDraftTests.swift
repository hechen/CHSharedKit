import Foundation
import Testing
@testable import CHOrderImport

struct OrderLineDraftTests {
    @Test func amountsParseStrictlyIntoMinorUnits() {
        #expect(OrderImportText.amountCents("49.95", currencyCode: "USD") == 4995)
        #expect(OrderImportText.amountCents("19.99", currencyCode: "USD") == 1999)
        #expect(OrderImportText.amountCents("100", currencyCode: "USD") == 10000)
        #expect(OrderImportText.amountCents(".5", currencyCode: "USD") == 50)
        #expect(OrderImportText.amountCents("1234", currencyCode: "JPY") == 1234)
        #expect(OrderImportText.amountCents("12.5", currencyCode: "JPY") == nil)
        #expect(OrderImportText.amountCents("12.345", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("-5", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("1,000.00", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("1e3", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("9999999999999", currencyCode: "USD") == nil)
        #expect(OrderImportText.amountCents("999999999", currencyCode: "USD") == 99_999_999_900)
    }

    @Test func amountCleaningKeepsSymbolsFromDecidingCurrency() {
        #expect(OrderImportText.cleanAmount("US$1,299.00", currencyCode: "USD") == "1299.00")
        #expect(OrderImportText.cleanAmount("$49.95", currencyCode: "") == "49.95")
        #expect(OrderImportText.cleanAmount("EUR 20,00", currencyCode: "EUR") == "20,00")
        #expect(OrderImportText.cleanAmount("1,23,456.00", currencyCode: "USD") == "1,23,456.00")
        #expect(OrderImportText.cleanAmount("£12.00", currencyCode: "GBP") == "12.00")
    }

    @Test func datesAreNeverGuessed() {
        #expect(OrderImportText.date("2026-09-01T10:00:00Z") != nil)
        #expect(OrderImportText.date("2026-02-30") == nil)
        #expect(OrderImportText.date("September 1, 2026") != nil)
        #expect(OrderImportText.date("Sep 1, 2026") != nil)
        #expect(OrderImportText.date("1/9/2026") == nil)
        #expect(OrderImportText.date("9/1/2026", format: .monthFirst).map(OrderImportText.isoDay) == "2026-09-01")
        #expect(OrderImportText.date("1/9/2026", format: .dayFirst).map(OrderImportText.isoDay) == "2026-09-01")
        #expect(OrderImportText.date("tomorrow") == nil)
    }

    @Test func issuesBlockIncompleteLines() {
        var draft = OrderLineDraft()
        #expect(draft.issue == "Enter an item name up to 200 characters.")
        draft.name = "Jacket"
        #expect(draft.issue == "Choose the purchase currency.")
        draft.currencyCode = "USD"
        #expect(draft.issue == "Enter the price for one item, using a decimal point.")
        draft.amountText = "49.95"
        #expect(draft.issue == "Choose a purchase date.")
        draft.dateText = OrderImportText.isoDay(.now.addingTimeInterval(3 * 86_400))
        #expect(draft.issue == "Choose a purchase date no later than today.")
        draft.dateText = "2026-09-01"
        draft.quantity = 0
        #expect(draft.issue == "Quantity must be between 1 and 100.")
        draft.quantity = 2
        #expect(draft.issue == nil)
        draft.status = "Return complete"
        #expect(draft.needsOwnershipReview)
        #expect(draft.issue == nil, "Ownership is a review warning, not a validation failure")
    }

    @Test func sourceKeysAreStableHashes() {
        let key = OrderImportText.key("amazon|111-1234567-1234567|B012345678")
        #expect(key.count == 64)
        #expect(key == OrderImportText.key("amazon|111-1234567-1234567|B012345678"))
        #expect(key != OrderImportText.key("amazon|111-1234567-1234567|B012345679"))
        var draft = OrderLineDraft(); draft.sourceKey = key
        #expect(draft.sourceKey(forUnit: 3) == key + ":3")
        draft.sourceKey = nil
        #expect(draft.sourceKey(forUnit: 0) == nil)
    }

    @Test func publicURLPolicyRejectsLocalAndCredentialedDestinations() {
        #expect(PublicWebURL.isAllowed(URL(string: "https://m.media-amazon.com/images/a.jpg")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "http://m.media-amazon.com/images/a.jpg")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "https://user:pw@example.com/")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "https://localhost/")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "https://printer.local/")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "https://10.0.0.1/")!))
        #expect(!PublicWebURL.isAllowed(URL(string: "https://example.com:8443/")!))
    }
}
