import Foundation

/// Children of an independently imported file must pair in both directions. A repeated position
/// or term key makes the match ambiguous, even if the two sets happen to have equal counts.
private struct FileContents {
    struct Question {
        let id: String
        let hash: String
    }

    var questions: [Int64: Question] = [:]
    var terms: [String: String] = [:]
    var ambiguous = false

    static func index(_ bank: CombineBank) -> [String: Self] {
        var result: [String: Self] = [:]
        for (id, row) in bank["questions"] {
            guard let set = row.text("setId"), let hash = row.text("contentHash") else { continue }
            let question = Question(id: id, hash: hash)
            if result[set, default: Self()].questions.updateValue(question, forKey: row.number("position")) != nil { result[set]?.ambiguous = true }
        }
        for (id, row) in bank["terms"] {
            guard let set = row.text("setId"), let key = row.text("key") else { continue }
            if result[set, default: Self()].terms.updateValue(id, forKey: key) != nil { result[set]?.ambiguous = true }
        }
        return result
    }

    func matches(_ other: Self) -> Bool {
        !ambiguous && !other.ambiguous && terms.keys == other.terms.keys && questions.count == other.questions.count
            && questions.allSatisfy { position, question in other.questions[position]?.hash == question.hash }
    }
}

extension CombinePlan {
    mutating func combineSets() throws {
        let held = server["practiceSets"]
        let incoming = phone["practiceSets"].mapValues { source in
            var row = source
            row["courseId"] = remap(row, "courseId", to: "courses")
            row["folderId"] = remap(row, "folderId", to: "folders")
            return row
        }
        for id in incoming.keys.sorted() where held[id] != nil { join("practiceSets", id, to: id, rule: "ID-6") }
        let heldVersions = Dictionary(grouping: held.values, by: { $0.text("lineageId") ?? "" })
        let versions = Dictionary(grouping: incoming.values, by: { $0.text("lineageId") ?? "" })
        for lineage in versions.keys.sorted() where heldVersions[lineage] != nil {
            join("setLineages", lineage, to: lineage, rule: "ID-7")
        }
        try pairImports(incoming, held: held, versions: versions, heldVersions: heldVersions)

        let fields = ["folderId", "weekLabel", "isCurrent", "replacedAt", "deletedAt", "deletionId"]
        for (id, row) in incoming {
            let key = target("practiceSets", id)
            rows["practiceSets", default: [:]][key] = held[key].map { settle($0, row, fields: fields) } ?? row
        }
        try settleVersions(incoming: incoming, held: held)
        try combineContents()
    }

    private mutating func pairImports(_ incoming: CombineTable, held: CombineTable, versions: [String: [CombineRow]], heldVersions: [String: [CombineRow]]) throws {
        func fileKey(_ row: CombineRow) -> [String] {
            [row.text("fileHash") ?? "", row.text("kind") ?? "", row.text("courseId") ?? "", row.text("folderId") ?? ""]
        }
        let heldFiles = Dictionary(grouping: held.values.filter { $0["deletedAt"] == .null }, by: fileKey)
        let files = Dictionary(grouping: incoming.values.filter { $0["deletedAt"] == .null }, by: fileKey)
        let onPhone = FileContents.index(phone)
        let onServer = FileContents.index(server)
        for (id, row) in incoming.sorted(by: { $0.key < $1.key }) {
            let file = fileKey(row)
            guard held[id] == nil, row["deletedAt"] == .null, files[file]?.count == 1, let candidates = heldFiles[file], candidates.count == 1,
                let peer = candidates.first, let peerID = peer.text("id"), incoming[peerID] == nil,
                let lineage = row.text("lineageId"), let other = peer.text("lineageId"),
                versions[lineage]?.count == 1, heldVersions[other]?.count == 1, heldVersions[lineage] == nil, versions[other] == nil
            else { continue }
            let local = onPhone[id] ?? FileContents()
            let remote = onServer[peerID] ?? FileContents()
            guard local.matches(remote) else { continue }
            join("practiceSets", id, to: peerID, rule: "ID-8")
            for key in local.questions.keys.sorted() {
                if let a = local.questions[key], let b = remote.questions[key] { try pairChild("questions", a.id, b.id, rule: "ID-10") }
            }
            for key in local.terms.keys.sorted() {
                if let a = local.terms[key], let b = remote.terms[key] { try pairChild("terms", a, b, rule: "ID-12") }
            }
        }
    }

    private mutating func pairChild(_ table: String, _ a: String, _ b: String, rule: String) throws {
        if a == b { return }  // Its id takes priority when the children are copied.
        guard server[table][a] == nil, phone[table][b] == nil else { throw BankArchiveError.invalid("the two identities of a \(table) row disagree.") }
        join(table, a, to: b, rule: rule)
    }

    private mutating func settleVersions(incoming: CombineTable, held: CombineTable) throws {
        // Choose between the two current versions using their original times, before any
        // inferred move or demotion is stamped. A tied decision belongs to the server.
        var currents: [String: (id: String, time: String)] = [:]
        var contenders: [String: Set<String>] = [:]
        for (sets, fromPhone) in [(held, false), (incoming, true)] {
            var seen: Set<String> = []
            for (id, row) in sets where row["isCurrent"] == .bool(true) {
                let key = fromPhone ? target("practiceSets", id) : id
                guard let lineage = rows["practiceSets"]?[key]?.text("lineageId"), seen.insert(lineage).inserted else {
                    throw BankArchiveError.invalid("one set lineage has two current versions on the same side.")
                }
                contenders[lineage, default: []].insert(key)
                if currents[lineage].map({ row.changed > $0.time }) ?? true { currents[lineage] = (key, row.changed) }
            }
        }
        var folderNames: [String: Set<String>] = [:]
        for (id, row) in server["folders"] {
            if let name = row.text("name") { folderNames[id, default: []].insert(name) }
        }
        for (id, row) in phone["folders"] {
            if let name = row.text("name") { folderNames[target("folders", id), default: []].insert(name) }
        }
        let groups = Dictionary(grouping: (rows["practiceSets"] ?? [:]).values, by: { $0.text("lineageId") ?? "" })
        for (lineage, versions) in groups {
            guard let winner = currents[lineage], let current = rows["practiceSets"]?[winner.id] else {
                throw BankArchiveError.invalid("a set lineage has no current version.")
            }
            let lastReplaced = versions.compactMap { $0.text("replacedAt") }.max()
            for var row in versions {
                guard let id = row.text("id") else { continue }
                if row["folderId"] != current["folderId"] {
                    row.copy(["folderId", "weekLabel"], from: current)
                }
                if let folder = row.text("folderId"), let label = row.text("weekLabel"), folderNames[folder]?.contains(label) == true {
                    row["weekLabel"] = rows["folders"]?[folder]?["name"]
                }
                if id == winner.id {
                    row["isCurrent"] = .bool(true)
                    row["replacedAt"] = .null
                } else if contenders[lineage]?.contains(id) == true, row["isCurrent"] == .bool(true) {
                    row["isCurrent"] = .bool(false)
                    // Restore selects the greatest replacedAt. Give the displaced current a
                    // unique latest time even if both replacements happened in one millisecond.
                    row["replacedAt"] = try .text(lastReplaced.map { try changeTime(after: $0, proposed: winner.time) } ?? winner.time)
                }
                rows["practiceSets"]?[id] = row
            }
        }
    }

    private mutating func combineContents() throws {
        // Filing a set updates only questions that inherited its week label. Preserve an
        // explicit question week, including when a different version won the move.
        func week(_ question: CombineRow, source: CombineRow?, final: CombineRow?) -> StoreValue? {
            guard let source, let final, question["weekLabel"] == source["weekLabel"] else { return question["weekLabel"] }
            return final["weekLabel"]
        }
        for (id, source) in server["questions"] {
            let set = source.text("setId") ?? ""
            let label = week(source, source: server["practiceSets"][set], final: rows["practiceSets"]?[set])
            rows["questions"]?[id]?["weekLabel"] = label
        }
        for (table, rule) in [("questions", "ID-9"), ("terms", "ID-11")] {
            for (id, source) in phone[table].sorted(by: { $0.key < $1.key }) {
                let key = target(table, id)
                var row = source
                row["setId"] = remap(source, "setId", to: "practiceSets")
                let set = row.text("setId") ?? ""
                let originalSet = phone["practiceSets"][source.text("setId") ?? ""]
                if table == "questions" { row["weekLabel"] = week(source, source: originalSet, final: rows["practiceSets"]?[set]) }
                if let held = rows[table]?[key], server[table][key] != nil {
                    if key == id { join(table, id, to: key, rule: rule) }
                    guard held.text("setId") == set else { throw BankArchiveError.invalid("a \(table) row belongs to two set versions.") }
                    row = held
                    if table == "questions" {
                        let a = source.text("lineageId") ?? ""
                        let b = held.text("lineageId") ?? ""
                        if let existing = questionLineages[a], existing != b { throw BankArchiveError.invalid("a question lineage has two targets.") }
                        questionLineages[a] = b
                        if let local = originalSet, let remote = server["practiceSets"][set], local.changed > remote.changed {
                            row["weekLabel"] = week(source, source: local, final: rows["practiceSets"]?[set])
                        }
                    }
                } else if server["practiceSets"][set] != nil {
                    throw BankArchiveError.invalid("a new \(table) row belongs to a set version already on the server.")
                }
                rows[table, default: [:]][key] = row
            }
        }
        for (id, source) in phone["questions"] where server["questions"][target("questions", id)] == nil {
            for field in ["lineageId", "twinOfLineageId"] {
                if let lineage = source.text(field), let mapped = questionLineages[lineage] { rows["questions"]?[id]?[field] = .text(mapped) }
            }
        }
    }
}
