import Foundation

/// The rule family for the sets a bank holds: reading the current version of one, bringing back the
/// version a replacement set aside, and a course's terms. Importing a set is `ImportRules`.
enum SetRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/practice-sets/:id", readSet)
        router.post("/api/practice-sets/:id/restore", restore)
        router.get("/api/courses/:id/terms", courseTerms)
    }

    // MARK: Reading a set

    /// The current version of a set, with each question's terms from its own set. Where the person is in the set (its run and sitting) belongs to the answers rule family, so until it exists a set reads as new.
    private static func readSet(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let set = try BankLookup.set(tx, try BankBody.pathID(call))
        if !set.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        let terms = try tx.rows("SELECT key, term, meaning FROM term WHERE set_id = ?", [.text(set.id)])
        var byKey: [String: StoreRow] = [:]
        for term in terms { byKey[term.string("key")] = term }
        let questions = try tx.rows("SELECT * FROM question WHERE set_id = ? ORDER BY position, id", [.text(set.id)]).map { row -> JSONValue in
            let body = try bodyNode(row)
            let termKeys = (try? JSParser.parse(row.string("term_keys")))?.list ?? []
            return .object([
                "id": .string(row.string("id")), "publicId": .string(row.string("public_id")), "position": .int(row.integer("position")),
                "type": .string(try questionType(row)), "topic": .string(row.string("topic")), "cj": .optional(row.text("cj")),
                "stem": .string(row.string("stem")), "ask": .string(row.string("ask")), "rationale": .string(row.string("rationale")),
                "takeaway": .string(row.string("takeaway")), "body": body.json, "table": ImportMedia.readTable(body.record?["table"]),
                "images": .array(ImportMedia.readImages(body.record?["images"])),
                "terms": .array(
                    termKeys.compactMap { $0.text.flatMap { byKey[$0] } }.map {
                        .object(["key": .string($0.string("key")), "term": .string($0.string("term")), "meaning": .string($0.string("meaning"))])
                    }),
            ])
        }
        return .ok(
            .object([
                "id": .string(set.id), "courseId": .string(set.courseId), "title": .string(set.title), "weekLabel": .string(set.weekLabel),
                "folderId": .optional(set.folderId), "kind": .string(set.kind), "questions": .array(questions), "run": .string("new"), "sitting": .null,
            ]))
    }

    private static func bodyNode(_ row: StoreRow) throws -> JSNode {
        guard let body = try? JSParser.parse(row.string("body")) else { throw BankRefusal.failed }
        return body
    }

    private static func questionType(_ row: StoreRow) throws -> String {
        let type = row.string("type")
        guard ImportChecker.typeLabels.contains(where: { $0.type == type }) else { throw BankRefusal.refused(404, "This set could not be read.") }
        return type
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
        return FolderContent.summary(updated, lineage: siblings, questions: questions, ids: questionIds, study: study)
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
