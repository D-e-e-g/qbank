import Foundation

private enum CatalogTable: String, CaseIterable {
    case semesters, courses, courseExams, folders

    func rule(_ row: CombineRow) -> String {
        switch self {
        case .semesters: "ID-1"
        case .courses: row.text("kind") == "course" ? "ID-2" : "ID-3"
        case .courseExams: "ID-4"
        case .folders: "ID-5"
        }
    }

    var fields: [String] {
        switch self {
        case .semesters: ["name", "startsOn", "endsOn", "archivedAt"]
        case .courses: ["semesterId", "code", "title", "sortOrder", "archivedAt", "deletedAt", "deletionId"]
        case .courseExams: ["name", "sortOrder", "linkUrl", "badge", "deletedAt", "deletionId"]
        case .folders: ["name", "courseExamId", "sortOrder", "deletedAt", "deletionId"]
        }
    }

    func protectedFields(_ row: CombineRow) -> [String] {
        switch self {
        case .semesters: []
        case .courses: [row.text("kind") == "course" ? "code" : "title", "semesterId", "deletedAt", "deletionId"]
        case .courseExams: ["name", "deletedAt", "deletionId"]
        case .folders: ["name", "courseExamId", "deletedAt", "deletionId"]
        }
    }

    func name(of row: CombineRow) -> [String]? {
        guard row.text("deletedAt") == nil else { return nil }
        switch self {
        case .semesters: return [String(row.number("number"))]
        case .courses:
            if let semester = row.text("semesterId") { return [semester, (row.text("code") ?? "").lowercased()] }
            return [(row.text("title") ?? "").lowercased()]
        case .courseExams: return [row.text("courseId") ?? "", (row.text("name") ?? "").lowercased()]
        case .folders: return [row.text("courseId") ?? "", row.text("courseExamId") ?? "", (row.text("name") ?? "").lowercased()]
        }
    }
}

extension CombinePlan {
    mutating func combineCatalog() throws {
        for catalog in CatalogTable.allCases {
            let table = catalog.rawValue
            let incoming = phone[table].mapValues { source in
                var row = source
                for (field, parent) in [("semesterId", "semesters"), ("courseId", "courses"), ("courseExamId", "courseExams")] {
                    row[field] = remap(source, field, to: parent)
                }
                return row
            }
            var settled = server[table]
            for id in incoming.keys.sorted() {
                guard let held = settled[id], let row = incoming[id] else { continue }
                settled[id] = settle(held, row, fields: catalog.fields)
                join(table, id, to: id, rule: catalog.rule(row))
            }
            try keepCollidingNames(catalog, in: &settled)
            var named: [[String]: String] = [:]
            for (id, row) in settled {
                if let key = catalog.name(of: row) { named[key] = id }
            }

            // Look up only server rows. Several phone keys can legitimately map to one server
            // key when a newer rename freed a name on the phone.
            for id in incoming.keys.sorted() where server[table][id] == nil {
                guard let row = incoming[id] else { continue }
                if let name = catalog.name(of: row), let target = named[name], let held = settled[target] {
                    settled[target] = settle(held, row, fields: catalog.fields)
                    join(table, id, to: target, rule: catalog.rule(row))
                } else {
                    settled[id] = row
                }
            }
            try appendNewItems(catalog, in: &settled)
            try Self.checkNames(catalog, settled)
            rows[table] = settled
        }
    }

    /// Evaluate renames together so a swap is legal. Restoring an old name can in turn displace
    /// another rename. Each conflicting row can revert at most once.
    private mutating func keepCollidingNames(_ catalog: CatalogTable, in settled: inout CombineTable) throws {
        let held = server[catalog.rawValue]
        var occupancy: [[String]: Set<String>] = [:]
        for (id, row) in settled {
            if let name = catalog.name(of: row) { occupancy[name, default: []].insert(id) }
        }
        var collisions = occupancy.filter { $0.value.count > 1 }.map(\.key)
        var kept: Set<String> = []
        while let name = collisions.popLast() {
            let ids = occupancy[name] ?? []
            guard ids.count > 1 else { continue }
            var reverted = false
            for id in ids {
                guard let original = held[id], catalog.name(of: original) != name, var row = settled[id] else { continue }
                row.copy(catalog.protectedFields(original), from: original)
                settled[id] = row
                occupancy[name]?.remove(id)
                if let old = catalog.name(of: row) {
                    occupancy[old, default: []].insert(id)
                    if occupancy[old, default: []].count > 1 { collisions.append(old) }
                }
                kept.insert(id)
                reverted = true
            }
            guard reverted else { throw BankArchiveError.invalid("two server rows of \(catalog.rawValue) have the same live name.") }
        }
        namesKept += kept.sorted().map { .init(table: catalog.rawValue, id: $0) }
    }

    private static func checkNames(_ catalog: CatalogTable, _ rows: CombineTable) throws {
        var seen: Set<[String]> = []
        for row in rows.values {
            if let key = catalog.name(of: row), !seen.insert(key).inserted {
                throw BankArchiveError.invalid("two rows of \(catalog.rawValue) have the same live name.")
            }
        }
    }

    /// WIN-5. Keep the settled order numbers of shared rows. Place the other rows after
    /// them in their original relative order. Replaying an already settled list is a no-op.
    private func appendNewItems(_ catalog: CatalogTable, in settled: inout CombineTable) throws {
        guard catalog == .courses || catalog == .folders else { return }
        let held = server[catalog.rawValue]
        let paired = Set((aliases[catalog.rawValue] ?? [:]).values)
        let live = settled.filter { _, row in row.text("deletedAt") == nil && (catalog == .folders || row.text("kind") == "topic") }
        let lists = Dictionary(grouping: live.keys) { id in
            [live[id]?.text("courseId") ?? "", live[id]?.text("courseExamId") ?? ""]
        }
        for ids in lists.values {
            guard
                ids.contains(where: { id in
                    guard let previous = held[id], let row = live[id] else { return true }
                    return ["sortOrder", "courseExamId", "deletedAt"].contains { previous[$0] != row[$0] }
                })
            else { continue }
            // Without a shared row the server list supplies the initial order. A list new
            // to the server already has its own order numbers, including any gaps.
            var anchors = ids.filter(paired.contains)
            if anchors.isEmpty { anchors = ids.filter { held[$0] != nil } }
            guard var last = anchors.compactMap({ live[$0]?.number("sortOrder") }).max() else { continue }
            let anchored = Set(anchors)
            let rest = ids.filter { !anchored.contains($0) }.sorted {
                (live[$0]?.number("sortOrder") ?? 0, $0) < (live[$1]?.number("sortOrder") ?? 0, $1)
            }
            for id in rest {
                let order = live[id]?.number("sortOrder") ?? 0
                if order > last {
                    last = order
                } else {
                    guard last < .max else { throw BankArchiveError.invalid("the list has no room for another order number.") }
                    last += 1
                    settled[id]?["sortOrder"] = .integer(last)
                }
            }
        }
    }
}
