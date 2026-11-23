import Foundation

/// The rules of the format and of the store's tables that one document can break on its own
/// (`docs/on-phone-bank.md`, "What a reader checks", items 4 and 5), checked on rows already known
/// to hold values of their fields' kinds. Each failure is a sentence naming the table and the row.
struct ArchiveRules {
    let rows: [[[StoreValue]]]

    private var tables: [ArchiveTable] { BankArchiveTables.all }

    func check() throws {
        let keys = try uniqueKeys()
        try references(keys)
        try marks()
        try courses()
        try semesters()
        try folders()
        try terms()
        try answers()
    }

    // MARK: Reading rows

    private func text(_ row: [StoreValue], _ table: ArchiveTable, _ field: String) -> String? {
        guard let index = table.fields.firstIndex(where: { $0.name == field }), case .text(let value) = row[index] else { return nil }
        return value
    }

    private func table(_ key: String) -> (table: ArchiveTable, rows: [[StoreValue]]) {
        let index = tables.firstIndex { $0.key == key } ?? 0
        return (tables[index], rows[index])
    }

    private func name(_ table: ArchiveTable, _ row: [StoreValue]) -> String {
        (table.rowKey.flatMap { text(row, table, $0) }).map { "\(table.key) \($0)" } ?? table.key
    }

    // MARK: Rules

    /// Keys are unique within a table.
    private func uniqueKeys() throws -> [String: Set<String>] {
        var present: [String: Set<String>] = [:]
        for (table, list) in zip(tables, rows) {
            guard let rowKey = table.rowKey else { continue }
            var seen = Set<String>()
            for row in list {
                let key = text(row, table, rowKey) ?? ""
                guard seen.insert(key).inserted else { throw BankArchiveError.invalid("\(table.key): \(rowKey) \(key) is there more than once.") }
            }
            present[table.key] = seen
        }
        return present
    }

    /// The document is closed: every reference names a row of the same document.
    private func references(_ keys: [String: Set<String>]) throws {
        for (table, list) in zip(tables, rows) {
            for row in list {
                for (field, target) in table.references {
                    guard let value = text(row, table, field) else { continue }
                    guard keys[target]?.contains(value) ?? false else {
                        throw BankArchiveError.invalid("\(name(table, row)): \(field) \(value) names no row of \(target) in the archive.")
                    }
                }
            }
        }
    }

    /// A delete marks a row with both marks or neither.
    private func marks() throws {
        for (table, list) in zip(tables, rows) where table.fields.contains(where: { $0.name == "deletedAt" }) {
            for row in list where (text(row, table, "deletedAt") == nil) != (text(row, table, "deletionId") == nil) {
                throw BankArchiveError.invalid("\(name(table, row)): deletedAt and deletionId must both be null or both be set.")
            }
        }
    }

    /// A course is in a semester and a study topic is in none, and a live topic's title is unique ignoring case.
    private func courses() throws {
        let (table, list) = table("courses")
        var topics = Set<String>()
        for row in list {
            let kind = text(row, table, "kind")
            guard (kind == "course") == (text(row, table, "semesterId") != nil) else {
                throw BankArchiveError.invalid("\(name(table, row)): a course has a semester and a study topic has none.")
            }
            if kind == "topic", text(row, table, "deletedAt") == nil {
                let title = (text(row, table, "title") ?? "").lowercased()
                guard topics.insert(title).inserted else { throw BankArchiveError.invalid("courses: two study topics are named \"\(text(row, table, "title") ?? "")\" (names are compared ignoring case).") }
            }
        }
    }

    private func semesters() throws {
        let (table, list) = table("semesters")
        var numbers = Set<Int64>()
        for row in list {
            guard let index = table.fields.firstIndex(where: { $0.name == "number" }), case .integer(let number) = row[index], numbers.insert(number).inserted else {
                throw BankArchiveError.invalid("semesters: a number is there more than once.")
            }
        }
    }

    /// A folder's name is unique in its list (one page's folders, or those on no page), counting each delete apart.
    private func folders() throws {
        let (table, list) = table("folders")
        var seen = Set<[String]>()
        for row in list {
            let list = [text(row, table, "courseId"), text(row, table, "courseExamId"), text(row, table, "name"), text(row, table, "deletionId")].map { $0 ?? "\u{0}" }
            guard seen.insert(list).inserted else {
                throw BankArchiveError.invalid("folders: two folders in one list of course \(list[0]) are named \"\(list[2])\".")
            }
        }
    }

    /// A set's terms name each key once.
    private func terms() throws {
        let (table, list) = table("terms")
        var seen = Set<[String]>()
        for row in list {
            let key = [text(row, table, "setId") ?? "", text(row, table, "key") ?? ""]
            guard seen.insert(key).inserted else { throw BankArchiveError.invalid("terms: set \(key[0]) has the key \"\(key[1])\" more than once.") }
        }
    }

    /// The id the device chose for each answer is unique among answers.
    private func answers() throws {
        let (table, list) = table("attempts")
        var seen = Set<String>()
        for row in list {
            let id = text(row, table, "clientAttemptId") ?? ""
            guard seen.insert(id).inserted else { throw BankArchiveError.invalid("attempts: clientAttemptId \(id) is there more than once.") }
        }
    }
}
