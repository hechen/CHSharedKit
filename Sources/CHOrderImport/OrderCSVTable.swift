import Foundation

public enum OrderCSVColumn: String, CaseIterable, Identifiable, Sendable {
    case name = "Item name"
    case amount = "Unit price"
    case currency = "Currency"
    case date = "Order date"
    case quantity = "Quantity"
    case order = "Order ID"
    case product = "ASIN / product ID"
    case status = "Status"

    public var id: String { rawValue }

    var aliases: [String] {
        switch self {
        case .name: ["productname", "itemname", "title", "producttitle", "itemdescription", "description", "name"]
        case .amount: ["unitprice", "purchasepriceperunit", "itemprice", "price"]
        case .currency: ["currency", "currencycode", "purchasecurrency"]
        case .date: ["orderdate", "purchasedate", "date"]
        case .quantity: ["quantity", "itemquantity", "qty"]
        case .order: ["orderid", "ordernumber"]
        case .product: ["asin", "productid", "asinisbn"]
        case .status: ["orderstatus", "shipmentstatus", "status"]
        }
    }
}

public enum OrderCSVDateFormat: String, CaseIterable, Identifiable, Sendable {
    case iso = "Year–month–day"
    case monthFirst = "Month/day/year"
    case dayFirst = "Day/month/year"

    public var id: String { rawValue }
}

/// A bounded parser for order-history CSV or TSV exports with Amazon-style headers.
public struct OrderCSVTable: Sendable {
    public var dateFormat: OrderCSVDateFormat = .iso
    public var headers: [String]
    public var rows: [[String]]
    public var mapping: [OrderCSVColumn: Int]

    public init(data: Data) throws {
        guard data.count <= 20_000_000 else { throw OrderImportError.invalid("Choose a CSV smaller than 20 MB.") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw OrderImportError.invalid("Save this spreadsheet as a UTF-8 CSV and try again.")
        }
        var records = try Self.records(text)
        guard !records.isEmpty else { throw OrderImportError.invalid("This CSV is empty.") }
        headers = records.removeFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !headers.isEmpty, headers.count <= 100, !records.isEmpty else {
            throw OrderImportError.invalid("Choose an order CSV with a header row and at least one purchase.")
        }
        let columnCount = headers.count
        guard records.allSatisfy({ $0.count == columnCount }) else {
            throw OrderImportError.invalid("Some CSV rows have a different number of columns. Re-export the file as CSV.")
        }
        rows = records
        mapping = [:]
        for field in OrderCSVColumn.allCases {
            mapping[field] = headers.firstIndex { header in field.aliases.contains(Self.normalized(header)) }
        }
    }

    public func drafts(fallbackCurrency: String) -> [OrderLineDraft] {
        rows.enumerated().map { rowIndex, row in
            func value(_ column: OrderCSVColumn) -> String {
                guard let index = mapping[column], row.indices.contains(index) else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var draft = OrderLineDraft()
            draft.source = "amazon-csv"
            draft.name = String(value(.name).prefix(200))
            draft.originalName = value(.name)
            draft.currencyCode = value(.currency).isEmpty ? fallbackCurrency : value(.currency)
            draft.amountText = OrderImportText.cleanAmount(value(.amount), currencyCode: draft.currencyCode)
            draft.dateText = OrderImportText.date(value(.date), format: dateFormat).map(OrderImportText.isoDay) ?? value(.date)
            let rawQuantity = value(.quantity)
            draft.quantity = rawQuantity.isEmpty ? 1 : (Int(rawQuantity) ?? 0)
            let order = value(.order), product = value(.product), status = value(.status)
            draft.orderID = order
            draft.productID = product
            draft.status = status.isEmpty ? nil : status
            if !order.isEmpty {
                draft.sourceKey = OrderImportText.key("amazon|\(order)|\(product.isEmpty ? draft.name : product)")
            }
            if !product.isEmpty, product.count == 10, product.allSatisfy({ $0.isLetter || $0.isNumber }) {
                draft.productURL = URL(string: "https://www.amazon.com/dp/\(product.uppercased())")
            }
            if draft.quantity > 1 { draft.warnings.append("This row creates \(draft.quantity) separate items at the unit price.") }
            if value(.currency).isEmpty { draft.warnings.append("Currency was missing; confirm the file currency.") }
            if draft.needsOwnershipReview { draft.warnings.append("Order status: \(status). Check whether you still own this item.") }
            if draft.name.isEmpty { draft.warnings.append("Row \(rowIndex + 2) has no item name.") }
            return draft
        }
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func records(_ input: String) throws -> [[String]] {
        let text = input
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let first = text.split(separator: "\n", maxSplits: 1).first ?? ""
        let tabs = first.filter { $0 == "\t" }.count
        let commas = first.filter { $0 == "," }.count
        let semicolons = first.filter { $0 == ";" }.count
        let delimiter: Character = tabs > commas ? "\t" : (semicolons > commas ? ";" : ",")
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false
        let characters = Array(text)
        var index = 0
        var cellLength = 0
        func appendRow() throws {
            row.append(cell); cell = ""; cellLength = 0
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []; closed = false
            if rows.count > 5_001 { throw OrderImportError.invalid("Import up to 5,000 purchase rows at a time.") }
        }
        while index < characters.count {
            let c = characters[index]
            cellLength += 1
            if quoted {
                if c == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { cell.append(c); index += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(c) }
            } else if c == delimiter { row.append(cell); cell = ""; cellLength = 0; closed = false }
            else if c == "\n" { try appendRow() }
            else if c == "\"", cell.isEmpty, !closed { quoted = true }
            else if closed { if !c.isWhitespace { throw OrderImportError.invalid("This CSV has malformed quoted fields.") } }
            else { cell.append(c) }
            guard cellLength <= 20_000, row.count <= 100 else {
                throw OrderImportError.invalid("This CSV contains an oversized field or too many columns.")
            }
            index += 1
        }
        guard !quoted else { throw OrderImportError.invalid("This CSV has an unfinished quoted field.") }
        if !cell.isEmpty || !row.isEmpty { try appendRow() }
        return rows
    }
}
