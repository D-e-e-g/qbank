import Foundation

/// Writes the bank as a document, in the order the format asks writers for: the header keys, then
/// the tables as listed, rows by key ascending, one row to a line, so two archives of one bank
/// compare by eye. A json field is its stored text, unchanged.
enum BankArchiveWriter {
    static func write(from store: LocalStore, at date: Date) throws -> Data {
        let text = try store.read { (transaction) throws -> String in
            var lists: [(table: ArchiveTable, rows: [StoreRow])] = []
            for table in BankArchiveTables.all {
                lists.append((table, try transaction.rows(table.select)))
            }
            var out = "{\n"
            out += "  \"format\": \(quote(BankArchive.format)),\n"
            out += "  \"version\": \(BankArchive.version),\n"
            out += "  \"exportedAt\": \(quote(QBankJSON.formatDate(date))),\n"
            out += "  \"writtenBy\": \"phone\",\n"
            out += "  \"complete\": true,\n"
            out += "  \"counts\": { " + lists.map { "\(quote($0.table.key)): \($0.rows.count)" }.joined(separator: ", ") + " },\n"
            for (index, list) in lists.enumerated() {
                let tail = index == lists.count - 1 ? "\n" : ",\n"
                if list.table.single {
                    out += "  \(quote(list.table.key)): \(try list.rows.first.map { try object($0, of: list.table) } ?? "null")\(tail)"
                } else if list.rows.isEmpty {
                    out += "  \(quote(list.table.key)): []\(tail)"
                } else {
                    out += "  \(quote(list.table.key)): [\n"
                    out += try list.rows.map { "    " + (try object($0, of: list.table)) }.joined(separator: ",\n")
                    out += "\n  ]\(tail)"
                }
            }
            return out + "}\n"
        }
        return Data(text.utf8)
    }

    /// The rows of each table now in the bank, counted by query.
    static func counts(in transaction: StoreTransaction) throws -> BankCounts {
        var values: [String: Int] = [:]
        for table in BankArchiveTables.all {
            guard case .integer(let count)? = try transaction.value("SELECT count(*) FROM \(table.table)") else { throw StoreError.unsupportedValue(column: table.table) }
            values[table.key] = Int(count)
        }
        guard let counts = BankCounts(values) else { throw StoreError.unsupportedValue(column: "count") }
        return counts
    }

    private static func object(_ row: StoreRow, of table: ArchiveTable) throws -> String {
        let members = try table.fields.map { "\(quote($0.name)): \(try literal(row[$0.column], $0, in: table))" }
        return "{ " + members.joined(separator: ", ") + " }"
    }

    /// One stored value as JSON of its field's kind. Every column is typed and checked by the store,
    /// so a value of another kind is a damaged file, not a document to write.
    private static func literal(_ value: StoreValue, _ field: ArchiveField, in table: ArchiveTable) throws -> String {
        switch (value, field.kind) {
        case (.null, _) where field.nullable: return "null"
        case (.text(let text), .json): return text
        case (.text(let text), .id), (.text(let text), .time), (.text(let text), .date), (.text(let text), .text), (.text(let text), .choice): return quote(text)
        case (.integer(let number), .int): return String(number)
        case (.integer(let number), .bool) where number == 0 || number == 1: return number == 1 ? "true" : "false"
        default: throw StoreError.unsupportedValue(column: "\(table.table).\(field.column)")
        }
    }

    /// A string as JSON: quotes, backslashes and control characters escaped, everything else as it is.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
