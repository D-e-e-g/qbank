import Foundation

extension CombinePlan {
    /// Insert final rows into an empty store, in dependency order. This also lets two live
    /// folders swap names without a transient uniqueness violation.
    func store(in tx: StoreTransaction, stamp: String) throws {
        let changedQuestionSets = Set(
            (rows["questions"] ?? [:]).compactMap { id, row -> String? in
                guard let held = server["questions"][id], held["weekLabel"] != row["weekLabel"] else { return nil }
                return row.text("setId")
            })
        for table in BankArchiveTables.all {
            for (id, var row) in (rows[table.key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                if let held = server[table.key][id], table.fields.contains(where: { $0.name == "updatedAt" }),
                    row != held || (table.key == "practiceSets" && changedQuestionSets.contains(id))
                {
                    row["updatedAt"] = try .text(changeTime(after: held.changed, proposed: row.changed))
                }
                try tx.execute(table.insert, table.fields.map { row[$0.name] ?? .null })
            }
        }
        try tx.execute("INSERT INTO bank_archive (singleton, stamp) VALUES (1, ?)", [.text(stamp)])
    }

    /// The same causes as a server combine: a new answer or progress row, a changed clear,
    /// or an answer in a sitting whose delete mark changed.
    private func affectedProgress() -> Set<String> {
        var affected = Set((rows["questionProgress"] ?? [:]).keys).subtracting(server["questionProgress"].keys)
        for (lineage, clear) in rows["reviewClears"] ?? [:] where clear != server["reviewClears"][lineage] { affected.insert(lineage) }
        let remarked = Set(
            (rows["studySessions"] ?? [:]).compactMap { id, row in
                server["studySessions"][id].map { $0["deletedAt"] != row["deletedAt"] } == true ? id : nil
            })
        for (id, row) in rows["attempts"] ?? [:] where server["attempts"][id] == nil || remarked.contains(row.text("studySessionId") ?? "") {
            if let question = row.text("questionId"), let lineage = rows["questions"]?[question]?.text("lineageId") { affected.insert(lineage) }
        }
        return affected
    }

    func rebuildAndCheck(in tx: StoreTransaction) throws {
        let lineages = try tx.rows("SELECT DISTINCT lineage_id FROM question").map { $0.string("lineage_id") }
        let expected = try ProgressRebuild.expected(tx, lineageIDs: lineages)
        let affected = affectedProgress()
        try ProgressRebuild.write(expected.filter { affected.contains($0.key) }, in: tx)

        // A and B are measured on the stored result, against the original inputs and actual
        // joins. A missing progress row or an accidental extra row also fails these checks.
        let counts = try BankArchiveWriter.counts(in: tx)
        for table in BankArchiveTables.all {
            let key = table.rowKey.map(table.column(of:)) ?? "'place'"
            let stored = Set(try tx.rows("SELECT \(key) AS key FROM \(table.table)").map { $0.string("key") })
            let held = server[table.key]
            let incoming = phone[table.key]
            let matches = aliases[table.key] ?? [:]
            guard held.keys.allSatisfy(stored.contains),
                incoming.keys.allSatisfy({ source in
                    let lineageKey = table.key == "reviewClears" || table.key == "questionProgress"
                    let key = lineageKey ? (questionLineages[source] ?? source) : (matches[source] ?? source)
                    return stored.contains(key)
                }),
                matches.allSatisfy({ incoming[$0.key] != nil && held[$0.value] != nil }),
                counts[table.key] == held.count + incoming.count - matches.count
            else { throw BankArchiveError.invalid("the combined \(table.key) do not account for both banks.") }
        }
        // C. The engine may keep an old line when every answer belonged to a deleted exam.
        // Every line with a counting answer must agree in every field with the engine.
        let progress = try tx.rows("SELECT * FROM question_progress").map(ProgressRebuild.Line.init)
        let stored = Dictionary(uniqueKeysWithValues: progress.map { ($0.lineageId, $0) })
        guard expected.allSatisfy({ stored[$0.key] == $0.value }) else {
            throw BankArchiveError.invalid("the stored progress differs from the saved answers.")
        }
    }
}
