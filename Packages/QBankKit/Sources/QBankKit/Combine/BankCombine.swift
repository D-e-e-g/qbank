import Foundation

/// A combine owns only its two snapshots and a fresh in-memory store. A caller can use the
/// returned archive in either direction. An error produces no archive and cannot switch banks.
public enum BankCombine {
    public struct Result: Sendable {
        public let archive: Data
        public let ledger: Ledger
    }

    public struct Ledger: Codable, Equatable, Sendable {
        public let joins: [Join]
        public let namesKept: [KeptName]
        public let phone: BankSummary
        public let server: BankSummary
        public let inBoth: BankSummary
        public let combined: BankSummary
    }

    /// Keys are archive row keys. "setLineages" records ID-7 separately from version rows.
    public struct Join: Codable, Equatable, Sendable {
        public let table: String
        public let phoneKey: String
        public let serverKey: String
        public let rule: String
    }

    public struct KeptName: Codable, Equatable, Sendable {
        public let table: String
        public let id: String
    }

    public static func combine(phone: Data, server: Data, at date: Date) throws -> Result {
        let incoming = try CombineBank(phone)
        let held = try CombineBank(server)
        guard let stamp = held.stamp else { throw BankArchiveError.invalid("the server bank has no stamp.") }

        var plan = CombinePlan(phone: incoming, server: held, now: date)
        try plan.combineCatalog()
        try plan.combineSets()
        try plan.combineStudy()
        let store = try LocalStore.inMemory()
        try store.transaction { tx in
            try plan.store(in: tx, stamp: stamp)
            try plan.closeCompetingExams(in: tx)
            try plan.rebuildProgress(in: tx)
            try plan.check(in: tx)
        }
        let ledger = try Ledger(
            joins: plan.joins, namesKept: plan.namesKept, phone: incoming.summary, server: held.summary,
            inBoth: plan.sharedSummary(), combined: BankSummary.of(store))
        return try Result(archive: BankArchive.write(from: store, at: date), ledger: ledger)
    }
}

/// All values have already passed the archive reader. JSON fields remain their original UTF-8
/// text, including unknown fields and exact number spellings.
typealias CombineRow = [String: StoreValue]
typealias CombineTable = [String: CombineRow]

extension CombineRow {
    func text(_ key: String) -> String? {
        guard case .text(let text) = self[key] else { return nil }
        return text
    }

    func number(_ key: String) -> Int64 {
        guard case .integer(let number) = self[key] else { return 0 }
        return number
    }

    var changed: String {
        text("updatedAt") ?? text("createdAt") ?? text("importedAt") ?? text("startedAt") ?? ""
    }

    mutating func copy(_ fields: [String], from other: Self) {
        for field in fields { self[field] = other[field] }
    }
}

struct CombineBank {
    let tables: [String: CombineTable]
    let stamp: String?

    init(_ data: Data) throws {
        let document = try ArchiveScanner.scan(data)
        let archive = try BankArchiveCheck.check(document)
        stamp = document.root.fields?["stamp"]?.string
        var tables: [String: CombineTable] = [:]
        for (table, rows) in zip(BankArchiveTables.all, archive.rows) {
            let names = table.fields.map(\.name)
            var keyed: CombineTable = [:]
            for values in rows {
                let row = Dictionary(uniqueKeysWithValues: zip(names, values))
                keyed[table.rowKey.flatMap { row.text($0) } ?? "place"] = row
            }
            tables[table.key] = keyed
        }
        self.tables = tables
    }

    subscript(_ table: String) -> CombineTable { tables[table] ?? [:] }

    // The same visibility as BankSummary.isOpen, before and after matching the two catalogs.
    var openSets: CombineTable {
        self["practiceSets"].filter { _, row in
            guard row["isCurrent"] == .bool(true), row["deletedAt"] == .null,
                let course = row.text("courseId"), self["courses"][course]?["deletedAt"] == .null
            else { return false }
            return row.text("folderId").map { self["folders"][$0]?["deletedAt"] == .null } ?? true
        }
    }

    var summary: BankSummary {
        let sets = openSets
        let questions = self["questions"].values.filter { sets[$0.text("setId") ?? ""] != nil }
        return BankSummary(sets: sets.count, questions: questions.count, answers: self["attempts"].count)
    }
}

struct CombinePlan {
    let phone: CombineBank
    let server: CombineBank
    let now: Date
    var rows: [String: CombineTable]
    var joins: [BankCombine.Join] = []
    var namesKept: [BankCombine.KeptName] = []
    var aliases: [String: [String: String]] = [:]
    var questionLineages: [String: String] = [:]

    init(phone: CombineBank, server: CombineBank, now: Date) {
        self.phone = phone
        self.server = server
        self.now = now
        rows = server.tables
    }

    func target(_ table: String, _ key: String) -> String { aliases[table]?[key] ?? key }

    mutating func join(_ table: String, _ key: String, to result: String, rule: String) {
        aliases[table, default: [:]][key] = result
        joins.append(.init(table: table, phoneKey: key, serverKey: result, rule: rule))
    }

    func remap(_ row: CombineRow, _ field: String, to table: String) -> StoreValue? {
        row.text(field).map { .text(target(table, $0)) } ?? row[field]
    }

    /// Keep the server's immutable fields even when a newer phone row was made under another id.
    func settle(_ held: CombineRow, _ incoming: CombineRow, fields: [String]) -> CombineRow {
        guard incoming.changed > held.changed else { return held }
        var row = held
        row.copy(fields, from: incoming)
        row["updatedAt"] = .text(incoming.changed)
        return row
    }

    /// WIN-15 also covers changes inferred from other rows, such as losing a version or an exam.
    func changeTime(after held: String, proposed: String) throws -> String {
        if proposed > held { return proposed }
        guard let date = QBankJSON.parseDate(held) else { throw BankArchiveError.invalid("a changed row has no valid time.") }
        let at = QBankJSON.formatDate(max(now, date.addingTimeInterval(0.001)))
        guard BankArchiveCheck.isTime(at), at > held else { throw BankArchiveError.invalid("a later change time cannot be represented.") }
        return at
    }

    func sharedSummary() -> BankSummary {
        let open = server.openSets
        let heldSets = Set(open.values.compactMap { $0.text("lineageId") })
        let heldQuestions = Set(server["questions"].values.filter { open[$0.text("setId") ?? ""] != nil }.compactMap { $0.text("lineageId") })
        let incoming = phone.openSets
        let sharedSets = incoming.values.compactMap { row -> String? in
            guard let id = row.text("id"), let lineage = rows["practiceSets"]?[target("practiceSets", id)]?.text("lineageId") else { return nil }
            return heldSets.contains(lineage) ? lineage : nil
        }
        let sharedQuestions = phone["questions"].values.compactMap { row -> String? in
            guard incoming[row.text("setId") ?? ""] != nil, let lineage = row.text("lineageId") else { return nil }
            let mapped = questionLineages[lineage] ?? lineage
            return heldQuestions.contains(mapped) ? mapped : nil
        }
        return BankSummary(sets: Set(sharedSets).count, questions: Set(sharedQuestions).count, answers: aliases["attempts"]?.count ?? 0)
    }
}
