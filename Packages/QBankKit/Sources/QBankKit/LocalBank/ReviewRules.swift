import Foundation

/// The rule family for a course's Review list: reading it, practicing from it and clearing it.
///
/// A question is in Review when its latest answer was not fully right or was a guess, in a practice
/// set the person has not deleted. Clearing the list changes nothing else: every answer and every
/// score stays, and a later answer to a question decides again.
enum ReviewRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/courses/:id/review", list)
        router.get("/api/courses/:id/review/practice", practice)
        router.post("/api/courses/:id/review/clear", clear)
    }

    private static let filters = ["all", "missed", "partial", "guessed"]

    private struct Entry {
        let questionId: String
        let topic: String
        let weekLabel: String
        let folderId: String
        let folderName: String
        let format: String
        let status: String
        let guessed: Bool
        let answeredAt: String
        let setTitle: String

        var json: JSONValue {
            .object([
                "questionId": .string(questionId), "topic": .string(topic), "weekLabel": .string(weekLabel), "folderId": .string(folderId),
                "folderName": .string(folderName), "format": .string(format), "status": .string(status), "guessed": .bool(guessed),
                "answeredAt": .string(answeredAt), "setTitle": .string(setTitle),
            ])
        }

        func matches(_ filter: String) -> Bool {
            switch filter {
            case "missed": status == "incorrect"
            case "partial": status == "partial"
            case "guessed": guessed
            default: true
            }
        }
    }

    private static func filter(_ call: BankCall) throws -> String? {
        guard let value = call.query["filter"] else { return nil }
        guard filters.contains(value) else { throw BankRefusal.invalidRequest }
        return value
    }

    private static func list(_ call: BankCall) throws -> BankAnswer {
        let filter = try filter(call) ?? "all"
        let course = try StudyLookup.course(call.tx, try BankBody.pathID(call))
        let entries = try rows(call.tx, courseID: course.id)
        let counts: [String: JSONValue] = [
            "all": .int(entries.count), "missed": .int(entries.count { $0.status == "incorrect" }),
            "partial": .int(entries.count { $0.status == "partial" }), "guessed": .int(entries.count { $0.guessed }),
        ]
        return .ok(.object(["filter": .string(filter), "counts": .object(counts), "questions": .array(entries.filter { $0.matches(filter) }.map(\.json))]))
    }

    /// The course's Review list: practice questions only, of the sets that were not deleted, newest first.
    private static func rows(_ tx: StoreTransaction, courseID: String) throws -> [Entry] {
        let found = try tx.rows(
            """
            SELECT q.id AS id, q.topic AS topic, q.public_id AS public_id, q.week_label AS week_label, q.type AS type,
                   f.id AS folder_id, f.name AS folder_name, qp.last_status AS last_status, qp.last_guessed AS last_guessed,
                   qp.last_answered_at AS last_answered_at, qp.last_attempt_id AS last_attempt_id
            FROM question q JOIN practice_set ps ON ps.id = q.set_id JOIN folder f ON f.id = ps.folder_id
            JOIN question_progress qp ON qp.question_lineage_id = q.lineage_id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice' AND f.deleted_at IS NULL AND qp.in_review = 1
            ORDER BY q.lineage_id, q.id
            """, [.text(courseID)])
        var list: [Entry] = []
        var seen: Set<String> = []
        for row in found where seen.insert(row.string("id")).inserted {
            let status = row.string("last_status")
            guard ["correct", "partial", "incorrect"].contains(status) else { continue }
            let topic = row.string("topic")
            list.append(
                Entry(
                    questionId: row.string("id"), topic: JS.trim(topic).isEmpty ? row.string("public_id") : topic, weekLabel: row.string("week_label"),
                    folderId: row.string("folder_id"), folderName: row.string("folder_name"), format: label(row.string("type")), status: status,
                    guessed: row.flag("last_guessed"), answeredAt: row.string("last_answered_at"), setTitle: try setTitle(tx, attemptID: row.string("last_attempt_id"))))
        }
        // JavaScript's sort is stable: equal entries stay in the order they were met.
        return list.enumerated().sorted { a, b in
            if a.element.answeredAt != b.element.answeredAt { return a.element.answeredAt > b.element.answeredAt }
            let byTopic = BankText.localeCompare(a.element.topic, b.element.topic)
            return byTopic == 0 ? a.offset < b.offset : byTopic < 0
        }.map(\.element)
    }

    /// Where the answer that put it in Review was given: the exam, or the title of the set it was answered in.
    private static func setTitle(_ tx: StoreTransaction, attemptID: String) throws -> String {
        guard
            let attempt = try tx.rows(
                """
                SELECT ps.title AS title, s.mode AS mode FROM attempt a JOIN question q ON q.id = a.question_id JOIN practice_set ps ON ps.id = q.set_id
                LEFT JOIN study_session s ON s.id = a.study_session_id WHERE a.id = ?
                """, [.text(attemptID)]
            ).first
        else { return "Practice" }
        return attempt.text("mode") == "exam" ? "Exam" : attempt.string("title")
    }

    private static func label(_ type: String) -> String {
        ImportChecker.typeLabels.first { $0.type == type }?.label ?? type
    }

    // MARK: Practicing from the list

    /// The questions of the list that match the filter, in a new shuffled order each time, or the one
    /// question named. It is read the way a practice set is, with the course's id as its own.
    private static func practice(_ call: BankCall) throws -> BankAnswer {
        let filter = try filter(call)
        var named: String?
        if let question = call.query["question"] {
            guard BankBody.isUUID(question) else { throw BankRefusal.invalidRequest }
            named = question
        }
        let course = try StudyLookup.course(call.tx, try BankBody.pathID(call))
        let ids: [String] = try named.map { [$0] } ?? rows(call.tx, courseID: course.id).filter { $0.matches(filter ?? "all") }.map(\.questionId)
        var found: [StoreRow] = []
        for chunk in Chunks.of(ids) {
            found += try call.tx.rows(
                """
                SELECT q.* FROM question q JOIN practice_set ps ON ps.id = q.set_id
                WHERE q.id IN \(Chunks.marks(chunk)) AND ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice'
                ORDER BY q.set_id, q.position, q.id
                """, chunk.map(StoreValue.text) + [.text(course.id)])
        }
        if named != nil && found.isEmpty { throw BankRefusal.study(404, "question_not_found", "That question is not in this course.") }
        let ordered = call.shuffled(found).enumerated().map { index, row in
            StoreRow(columns: row.columns, values: row.values.enumerated().map { row.columns[$0.offset] == "position" ? .integer(Int64(index + 1)) : $0.element })
        }
        return .ok(
            .object([
                "id": .string(course.id), "courseId": .string(course.id), "title": .string(named == nil ? "Review" : "Review question"), "weekLabel": .string(""),
                "folderId": .null, "kind": .string("practice"), "questions": .array(try StudyViews.questions(call.tx, rows: ordered)), "sitting": .null, "run": .string("new"),
            ]))
    }

    // MARK: Clearing

    /// Takes the course's current questions out of Review. The answers stay. Each clear is recorded, so
    /// a later repair does not put the questions back.
    private static func clear(_ call: BankCall) throws -> BankAnswer {
        let confirmed = try BankBody(call.body).bool("confirmed")
        let tx = call.tx
        let course = try StudyLookup.course(tx, try BankBody.pathID(call))
        if !confirmed {
            let count = try tx.value(
                """
                SELECT count(*) FROM question_progress WHERE in_review = 1 AND question_lineage_id IN
                    (SELECT q.lineage_id FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL)
                """, [.text(course.id)])
            var number = 0
            if case .integer(let value)? = count { number = Int(value) }
            throw BankRefusal.study(400, "confirmation_required", "Clear all \(number) \(number == 1 ? "question" : "questions") from this course's Review list?")
        }
        // Every version of the course's sets, so a later Restore does not bring a cleared question back.
        let lineages = try tx.rows(
            """
            SELECT question_lineage_id, last_attempt_id FROM question_progress WHERE in_review = 1 AND question_lineage_id IN
                (SELECT q.lineage_id FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE ps.course_id = ? AND ps.deleted_at IS NULL)
            """, [.text(course.id)])
        guard !lineages.isEmpty else { return .ok(.object(["cleared": .int(0)])) }
        let now = call.nowText
        for row in lineages {
            try tx.execute("UPDATE question_progress SET in_review = 0 WHERE question_lineage_id = ?", [.text(row.string("question_lineage_id"))])
            try tx.execute(
                """
                INSERT INTO review_clear (question_lineage_id, last_attempt_id, cleared_at) VALUES (?, ?, ?)
                ON CONFLICT (question_lineage_id) DO UPDATE SET last_attempt_id = excluded.last_attempt_id, cleared_at = excluded.cleared_at
                """, [.text(row.string("question_lineage_id")), .text(row.string("last_attempt_id")), .text(now)])
        }
        return .ok(.object(["cleared": .int(lineages.count)]))
    }
}

extension BankBody {
    /// A required bool.
    func bool(_ key: String) throws -> Bool {
        guard let value = try optionalBool(key) else { throw BankRefusal.invalidRequest }
        return value
    }
}
