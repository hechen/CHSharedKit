import Foundation
import Testing
@testable import CHOrderImport

struct OrderCSVTableTests {
    @Test func amazonStyleHeadersMapAndRowsBecomeDrafts() throws {
        let csv = """
        Order Date,Order ID,Title,ASIN/ISBN,Item Quantity,Purchase Price Per Unit,Currency,Order Status
        2026-09-01T12:00:00Z,111-1234567-1234567,"Wool overcoat, navy",B012345678,2,$49.95,USD,Shipped
        2026-08-15,222-1234567-1234567,Returned keyboard,B012345679,1,39.00,USD,Refund issued
        """
        let table = try OrderCSVTable(data: Data(csv.utf8))
        #expect(table.mapping[.name] == 2 && table.mapping[.product] == 3 && table.mapping[.amount] == 5)
        let drafts = table.drafts(fallbackCurrency: "EUR")
        #expect(drafts.count == 2)
        #expect(drafts[0].name == "Wool overcoat, navy")
        #expect(drafts[0].amountCents == 4995 && drafts[0].currencyCode == "USD")
        #expect(drafts[0].dateText == "2026-09-01" && drafts[0].quantity == 2)
        #expect(drafts[0].productURL?.absoluteString == "https://www.amazon.com/dp/B012345678")
        #expect(drafts[0].sourceKey == OrderImportText.key("amazon|111-1234567-1234567|B012345678"))
        #expect(drafts[0].source == "amazon-csv" && drafts[0].issue == nil)
        #expect(drafts[1].needsOwnershipReview)
        #expect(drafts[1].warnings.contains { $0.hasPrefix("Order status: Refund issued") })
    }

    @Test func missingCurrencyFallsBackAndMissingOrderHasNoKey() throws {
        let csv = "Item name;Unit price;Order date\nJacket;20.00;2026-09-01\n"
        let table = try OrderCSVTable(data: Data(csv.utf8))
        let drafts = table.drafts(fallbackCurrency: "GBP")
        #expect(drafts.count == 1)
        #expect(drafts[0].currencyCode == "GBP" && drafts[0].sourceKey == nil)
        #expect(drafts[0].warnings.contains("Currency was missing; confirm the file currency."))
    }

    @Test func malformedInputIsRejectedWithClearMessages() {
        #expect(throws: OrderImportError.self) { try OrderCSVTable(data: Data()) }
        #expect(throws: OrderImportError.self) { try OrderCSVTable(data: Data("Item name,Unit price\n".utf8)) }
        #expect(throws: OrderImportError.self) { try OrderCSVTable(data: Data("a,b\n1,2,3\n".utf8)) }
        #expect(throws: OrderImportError.self) { try OrderCSVTable(data: Data("a,b\n\"unfinished,2\n".utf8)) }
        #expect(throws: OrderImportError.self) { try OrderCSVTable(data: Data("a,b\n\"x\"y,2\n".utf8)) }
    }

    @Test func dayFirstDatesUseTheChosenFormat() throws {
        var table = try OrderCSVTable(data: Data("Item name,Unit price,Order date,Order ID\nJacket,20.00,01/09/2026,111\n".utf8))
        #expect(table.drafts(fallbackCurrency: "USD")[0].purchaseDate == nil)
        table.dateFormat = .dayFirst
        #expect(table.drafts(fallbackCurrency: "USD")[0].dateText == "2026-09-01")
    }
}
