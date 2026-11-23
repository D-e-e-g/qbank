import Foundation

/// The rule family for the sets a bank holds: reading the current version of one, starting it over,
/// bringing back the version a replacement set aside, and a course's terms. Importing a set is `ImportRules`.
enum SetRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/practice-sets/:id", readSet)
        router.post("/api/practice-sets/:id/restore", restore)
        router.post("/api/practice-sets/:id/start-over", startOver)
        router.get("/api/courses/:id/terms", courseTerms)
    }

    // MARK: Reading a set

    /// The current version of a set, with each question's terms from its own set, and where the
    /// person is in it: its run and the sitting that would be continued.
    private static func readSet(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let set = try BankLookup.set(tx, try BankBody.pathID(call))
        if !set.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        let rows = try tx.rows("SELECT * FROM question WHERE set_id = ? ORDER BY position, id", [.text(set.id)])
        let questions = try StudyViews.questions(tx, rows: rows)
        let study = set.kind == "practice" ? try Sittings.read(tx, lineageID: set.lineageId, questions: rows) : (run: "new", sitting: JSONValue.null)
        return .ok(
            .object([
                "id": .string(set.id), "courseId": .string(set.courseId), "title": .string(set.title), "weekLabel": .string(set.weekLabel),
                "folderId": .optional(set.folderId), "kind": .string(set.kind), "questions": .array(questions), "run": .string(study.run), "sitting": study.sitting,
            ]))
    }

    /// Start over: the sitting that would be continued ends, every answer stays, and the set opens at question 1.
    private static func startOver(_ call: BankCall) throws -> BankAnswer {
        let set = try BankLookup.set(call.tx, try BankBody.pathID(call))
        if !set.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        if set.kind != "practice" { throw BankRefusal.refused(404, "That set is not in the app.") }
        return .ok(.object(["ended": .bool(try Sittings.end(call, setLineageID: set.lineageId))]))
    }

    // MARK: Restore

    /// Brings back the version the current one replaced, the newest of the earlier versions. The version that was current stays, as an earlier one: restoring again goes back to it.
    private static func restore(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let current = try BankLookup.set(tx, try BankBody.pathID(call))
        if !current.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        let lineage = try tx.rows("SELECT * FROM practice_set WHERE lineage_id = ?", [.text(current.lineageId)]).map(SetRow.init)
        let earlier = lineage.filter { $0.id != current.id && !$0.isCurrent }
        guard let target = earlier.max(by: { ($0.replacedAt ?? "") < ($1.replacedAt ?? "") }) else {
            throw BankRefusal.refused(400, "This set has no previous version to restore.")
        }
        let now = call.nowText
        try tx.execute("UPDATE practice_set SET is_current = 0, replaced_at = ? WHERE id = ?", [.text(now), .text(current.id)])
        try tx.execute("UPDATE practice_set SET is_current = 1, replaced_at = NULL WHERE id = ?", [.text(target.id)])
        // Every version is in the set's folder already; an older one's legacy label may predate a rename.
        if target.weekLabel != current.weekLabel, let folderId = current.folderId {
            try FolderRules.fileLineage(tx, lineageID: target.lineageId, into: try BankLookup.folder(tx, folderId))
        }
        return .ok(try summary(tx, setID: target.id))
    }

    /// One set as a list of its folder shows it.
    private static func summary(_ tx: StoreTransaction, setID: String) throws -> JSONValue {
        let updated = try BankLookup.set(tx, setID)
        let siblings = try tx.rows("SELECT * FROM practice_set WHERE lineage_id = ?", [.text(updated.lineageId)]).map(SetRow.init)
        let ids: Set<String> = [updated.id]
        let questions = try FolderContent.counts(tx, courseID: updated.courseId, setIds: ids)[updated.id] ?? 0
        let questionIds = try FolderContent.questionIDs(tx, courseID: updated.courseId, setIds: ids)[updated.id] ?? []
        let study = try FolderContent.progress(tx, courseID: updated.courseId, setIds: ids)[updated.id]
        let run = updated.kind == "practice" ? try Sittings.summaries(tx, lineageIDs: [updated.lineageId])[updated.lineageId] : nil
        return FolderContent.summary(updated, lineage: siblings, questions: questions, ids: questionIds, study: study, run: run)
    }

    // MARK: Terms

    /// The terms of the sets in force, one row for each key: its newest definition. In the language order of the term.
    private static func courseTerms(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let courseID = try BankBody.pathID(call)
        _ = try BankLookup.course(tx, courseID)
        let rows = try tx.rows(
            """
            SELECT t.key AS key, t.term AS term, t.meaning AS meaning, f.id AS folder_id, f.name AS folder_name, ps.title AS set_title
            FROM term t JOIN practice_set ps ON ps.id = t.set_id JOIN folder f ON f.id = ps.folder_id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice' AND f.deleted_at IS NULL
            ORDER BY ps.imported_at DESC, ps.id DESC
            """, [.text(courseID)])
        var seen: Set<String> = []
        var newest: [StoreRow] = []
        for row in rows where seen.insert(row.string("key")).inserted { newest.append(row) }
        // JavaScript's sort is stable: terms that compare equal stay in the order they were met.
        let sorted = newest.enumerated().sorted { a, b in
            let order = BankText.localeCompare(a.element.string("term"), b.element.string("term"))
            return order == 0 ? a.offset < b.offset : order < 0
        }.map(\.element)
        return .ok(
            .object([
                "terms": .array(
                    sorted.map {
                        .object([
                            "key": .string($0.string("key")), "term": .string($0.string("term")), "meaning": .string($0.string("meaning")),
                            "weekLabel": .string($0.string("folder_name")), "folderId": .string($0.string("folder_id")),
                            "folderName": .string($0.string("folder_name")), "setTitle": .string($0.string("set_title")),
                        ])
                    })
            ]))
    }
}
