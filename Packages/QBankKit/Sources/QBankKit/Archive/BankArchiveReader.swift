import Foundation

/// Reads a document into an empty bank: the whole document or nothing.
///
/// Everything the format asks of a reader is checked on the scanned document before the store is
/// opened for writing (`BankArchiveCheck`), so a refused document costs the bank nothing. The write
/// then runs in one transaction that first finds the bank empty and last counts what it stored
/// against the document's own counts; a failure anywhere rolls it all back.
enum BankArchiveReader {
    static func read(_ data: Data, into store: LocalStore) throws -> BankCounts {
        let checked = try BankArchiveCheck.check(try ArchiveScanner.scan(data))
        do {
            return try store.transaction { (transaction) throws -> BankCounts in
                for table in BankArchiveTables.all {
                    guard case .integer(let found)? = try transaction.value("SELECT count(*) FROM \(table.table)") else { throw BankArchiveError.bankNotEmpty }
                    if found > 0 { throw BankArchiveError.bankNotEmpty }
                }
                for (table, rows) in zip(BankArchiveTables.all, checked.rows) {
                    for row in rows { try transaction.execute(table.insert, row) }
                }
                try transaction.execute("DELETE FROM bank_archive")
                if let stamp = checked.stamp {
                    try transaction.execute("INSERT INTO bank_archive (singleton, stamp) VALUES (1, ?)", [.text(stamp)])
                }
                // Comparison 2: what the bank now holds against the document, inside the transaction.
                let stored = try BankArchiveWriter.counts(in: transaction)
                for key in BankArchive.tableKeys where stored[key] != checked.counts[key] {
                    throw BankArchiveError.countsDiffer(table: key, declared: checked.counts[key] ?? 0, found: stored[key] ?? 0)
                }
                return stored
            }
        } catch let error as BankArchiveError {
            throw error
        } catch let error as StoreError {
            throw BankArchiveError.storage(error)
        }
    }
}

/// A document that kept every rule of the format: its counts, and its rows as the store takes them,
/// table by table in the archive's order.
struct CheckedArchive {
    let counts: BankCounts
    let stamp: String?
    let rows: [[[StoreValue]]]
}

/// What a reader checks (`docs/on-phone-bank.md`, "What a reader checks", items 1 to 5), on the
/// scanned document and without touching the store.
enum BankArchiveCheck {
    static func check(_ document: ArchiveDocument) throws -> CheckedArchive {
        // 1. One JSON object, of this format and a version this build implements.
        guard document.root.isObject else { throw BankArchiveError.notAnArchive }
        guard let top = document.root.fields else { throw BankArchiveError.invalid("a field of the document is named twice.") }
        guard top["format"]?.string == BankArchive.format else { throw BankArchiveError.notAnArchive }
        guard let version = top["version"]?.integer else { throw BankArchiveError.invalid("version is missing or is not a whole number.") }
        guard version == Int64(BankArchive.version) else { throw BankArchiveError.unsupportedVersion(Int(clamping: version)) }

        // 2. Every key is there, and the lists hold what the counts say.
        for key in ["exportedAt", "writtenBy", "complete", "counts"] where top[key] == nil { throw BankArchiveError.invalid("\(key) is missing.") }
        guard let exportedAt = top["exportedAt"]?.string, isTime(exportedAt) else { throw BankArchiveError.invalid("exportedAt is not a time.") }
        guard let writtenBy = top["writtenBy"]?.string, writtenBy == "phone" || writtenBy == "server" else { throw BankArchiveError.invalid("writtenBy is neither phone nor server.") }
        guard let complete = top["complete"]?.bool else { throw BankArchiveError.invalid("complete is not true or false.") }
        if let stamp = top["stamp"], stamp.string == nil { throw BankArchiveError.invalid("stamp is not text.") }
        let counts = try declaredCounts(top["counts"])
        var nodes: [[ArchiveNode]] = []
        for table in BankArchiveTables.all {
            guard let node = top[table.key] else { throw BankArchiveError.invalid("\(table.key) is missing.") }
            if table.single {
                guard node.isNull || node.isObject else { throw BankArchiveError.invalid("\(table.key) is neither a row nor null.") }
                nodes.append(node.isNull ? [] : [node])
            } else {
                guard let items = node.items else { throw BankArchiveError.invalid("\(table.key) is not a list.") }
                nodes.append(items)
            }
        }
        for (table, rows) in zip(BankArchiveTables.all, nodes) where counts[table.key] != rows.count {
            throw BankArchiveError.countsDiffer(table: table.key, declared: counts[table.key] ?? 0, found: rows.count)
        }
        // A bank moves only whole.
        guard complete else { throw BankArchiveError.incomplete }

        // 3. Every row has every field with a value of the field's kind.
        var rows: [[[StoreValue]]] = []
        for (table, items) in zip(BankArchiveTables.all, nodes) {
            rows.append(try items.enumerated().map { try row($1, number: $0 + 1, of: table, in: document) })
        }

        // 4 and 5. Keys, references, marks and the server's rules for these tables.
        try ArchiveRules(rows: rows).check()
        return CheckedArchive(counts: counts, stamp: top["stamp"]?.string, rows: rows)
    }

    private static func declaredCounts(_ node: ArchiveNode?) throws -> BankCounts {
        guard let fields = node?.fields else { throw BankArchiveError.invalid("counts is not an object.") }
        var values: [String: Int] = [:]
        for key in BankArchive.tableKeys {
            guard let count = fields[key]?.integer, count >= 0 else { throw BankArchiveError.invalid("counts.\(key) is missing or is not a whole number.") }
            values[key] = Int(clamping: count)
        }
        guard let counts = BankCounts(values) else { throw BankArchiveError.invalid("counts is not the twelve tables' counts.") }
        return counts
    }

    private static func row(_ node: ArchiveNode, number: Int, of table: ArchiveTable, in document: ArchiveDocument) throws -> [StoreValue] {
        guard let fields = node.fields else { throw BankArchiveError.invalid("\(table.key) row \(number) is not an object, or names a field twice.") }
        return try table.fields.map { field in
            guard let value = fields[field.name] else {
                if field.optional { return .null }
                throw BankArchiveError.invalid("\(table.key) row \(number) has no \(field.name).")
            }
            guard let stored = storeValue(value, field, in: document) else {
                throw BankArchiveError.invalid("\(table.key) row \(number): \(field.name) is not \(field.nullable ? "null or " : "")\(ArchiveKindText.article(field.kind)).")
            }
            return stored
        }
    }

    /// The value as the store takes it, or nil when it is not of the field's kind.
    private static func storeValue(_ node: ArchiveNode, _ field: ArchiveField, in document: ArchiveDocument) -> StoreValue? {
        if node.isNull {
            // `StoreValue` reads a nil literal as SQL NULL, so a refusal is spelled `Optional.none`.
            guard field.nullable else { return Optional<StoreValue>.none }
            return StoreValue.null
        }
        switch field.kind {
        case .id: return node.string.flatMap { isID($0) ? .text($0) : nil }
        case .time: return node.string.flatMap { isTime($0) ? .text($0) : nil }
        case .date: return node.string.flatMap { isDate($0) ? .text($0) : nil }
        case .text: return node.string.map(StoreValue.text)
        case .int(let range):
            guard let number = node.integer, range?.contains(number) ?? true else { return nil }
            return .integer(number)
        case .bool: return node.bool.map(StoreValue.bool)
        case .json(let shape):
            switch shape {
            case .any: break
            case .object: if !node.isObject { return nil }
            case .array: if !node.isArray { return nil }
            }
            return .text(document.text(of: node))
        case .choice(let words): return node.string.flatMap { words.contains($0) ? .text($0) : nil }
        }
    }

    // MARK: Kinds

    /// A lowercase UUID, `8-4-4-4-12`.
    static func isID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if byte != UInt8(ascii: "-") { return false }
            } else if !((UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)) {
                return false
            }
        }
        return true
    }

    /// `YYYY-MM-DDTHH:MM:SS.sssZ`, a real moment.
    static func isTime(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 24, bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "."), bytes[23] == UInt8(ascii: "Z"),
            isDate(String(decoding: bytes[0..<10], as: UTF8.self))
        else { return false }
        func number(_ range: Range<Int>) -> Int? { digits(bytes[range]) }
        guard let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19), number(20..<23) != nil else { return false }
        return hour < 24 && minute < 60 && second < 60
    }

    /// `YYYY-MM-DD`, a real day.
    static func isDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
            let year = digits(bytes[0..<4]), let month = digits(bytes[5..<7]), let day = digits(bytes[8..<10]), (1...12).contains(month)
        else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...days).contains(day)
    }

    private static func digits(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in bytes {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}

enum ArchiveKindText {
    static func article(_ kind: ArchiveKind) -> String {
        switch kind {
        case .id: return "a lowercase UUID"
        case .time: return "a time such as 2026-11-22T14:37:05.123Z"
        case .date: return "a date such as 2026-11-22"
        case .text: return "text"
        case .int(let range):
            guard let range else { return "a whole number" }
            return range.upperBound == Int64.max ? "a whole number of at least \(range.lowerBound)" : "a whole number from \(range.lowerBound) to \(range.upperBound)"
        case .bool: return "true or false"
        case .json(let shape): return shape == .object ? "an object" : shape == .array ? "a list" : "a value"
        case .choice(let words): return "one of \(words.joined(separator: ", "))"
        }
    }
}
