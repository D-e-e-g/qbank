import Foundation

/// A practice set's sitting: how far the person has got through the set this time. It is a
/// `study_session` row of mode `practice`, and answers point at it. Nothing here changes an answer,
/// the progress or Review: a sitting only says which answers belong to this time through.
///
/// Questions are matched by lineage, so a replace or a restore keeps the answers to questions that
/// did not change, and a question that changed (a new lineage) is one not answered yet.
enum Sittings {
    struct Sitting {
        let id: String
        let startedAt: String
        let finishedAt: String?
        let endReason: String?
        let seeded: [String]

        init(_ row: StoreRow) {
            id = row.string("id")
            startedAt = row.string("started_at")
            finishedAt = row.text("finished_at")
            endReason = row.text("end_reason")
            seeded = row.text("seeded_question_ids").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        }
    }

    /// What decides a set's sitting.
    struct Standing {
        /// The set's current version, or nil once it was deleted.
        var versionId: String?
        var courseId: String?
        /// The current questions' lineages, in the set's order. Empty once the set was deleted.
        var current: [String] = []
        /// The latest answer to each of those that has one.
        var progress: [String: StoreRow] = [:]
        /// Those answered outside an exam: what a new sitting begins with.
        var practiced: Set<String> = []
        var open: Sitting?
        var lastClosed: Sitting?
        /// The lineages answered in the open sitting itself.
        var own: Set<String> = []
    }

    /// Where the person is in a set.
    /// - new: none of its current questions answered.
    /// - midway: a sitting to continue, open with answers in it, or (with no row yet) the answers practiced.
    /// - restarted: answers, yet opening it starts again at question 1: Start over, or answered only on exams.
    /// - done: every current question answered, by any route, even with a retake open.
    enum Run {
        case new
        case midway(sittingId: String?, answered: Set<String>)
        case restarted(startedOver: Bool)
        case done

        var name: String {
            switch self {
            case .new: "new"
            case .midway: "midway"
            case .restarted: "restarted"
            case .done: "done"
            }
        }
    }

    // MARK: Reading a standing

    /// The standings of these sets, by set lineage. A practice row with no seed list is from before
    /// sittings and is not one.
    static func standings(_ tx: StoreTransaction, lineageIDs: [String]) throws -> [String: Standing] {
        var standings: [String: Standing] = [:]
        let lineages = Array(Set(lineageIDs))
        guard !lineages.isEmpty else { return standings }
        for id in lineages { standings[id] = Standing() }
        var lineageOfVersion: [String: String] = [:]
        for chunk in Chunks.of(lineages) {
            for row in try tx.rows(
                "SELECT id, lineage_id, course_id FROM practice_set WHERE lineage_id IN \(Chunks.marks(chunk)) AND is_current = 1 AND deleted_at IS NULL AND kind = 'practice'",
                chunk.map(StoreValue.text))
            {
                let lineage = row.string("lineage_id")
                standings[lineage]?.versionId = row.string("id")
                standings[lineage]?.courseId = row.string("course_id")
                lineageOfVersion[row.string("id")] = lineage
            }
        }
        var questionLineages: Set<String> = []
        for chunk in Chunks.of(Array(lineageOfVersion.keys).sorted()) {
            for row in try tx.rows(
                "SELECT set_id, lineage_id FROM question WHERE set_id IN \(Chunks.marks(chunk)) ORDER BY position, id", chunk.map(StoreValue.text))
            {
                if let lineage = lineageOfVersion[row.string("set_id")] { standings[lineage]?.current.append(row.string("lineage_id")) }
                questionLineages.insert(row.string("lineage_id"))
            }
        }
        var progress: [String: StoreRow] = [:]
        for chunk in Chunks.of(questionLineages.sorted()) {
            for row in try tx.rows("SELECT * FROM question_progress WHERE question_lineage_id IN \(Chunks.marks(chunk))", chunk.map(StoreValue.text)) {
                progress[row.string("question_lineage_id")] = row
            }
        }
        for lineage in standings.keys {
            for question in standings[lineage]?.current ?? [] { standings[lineage]?.progress[question] = progress[question] }
        }

        var lineageOfOpen: [String: String] = [:]
        for chunk in Chunks.of(lineages) {
            for row in try tx.rows(
                """
                SELECT s.*, ps.lineage_id AS set_lineage_id FROM study_session s JOIN practice_set ps ON ps.id = s.set_id
                WHERE s.mode = 'practice' AND s.seeded_question_ids IS NOT NULL AND s.deleted_at IS NULL AND ps.lineage_id IN \(Chunks.marks(chunk))
                ORDER BY s.started_at, s.id
                """, chunk.map(StoreValue.text))
            {
                let sitting = Sitting(row)
                let lineage = row.string("set_lineage_id")
                if sitting.finishedAt == nil {
                    standings[lineage]?.open = sitting
                    lineageOfOpen[sitting.id] = lineage
                } else {
                    standings[lineage]?.lastClosed = sitting
                }
            }
        }
        for chunk in Chunks.of(lineageOfOpen.keys.sorted()) {
            for row in try tx.rows(
                "SELECT a.study_session_id AS sitting_id, q.lineage_id AS lineage_id FROM attempt a JOIN question q ON q.id = a.question_id WHERE a.study_session_id IN \(Chunks.marks(chunk))",
                chunk.map(StoreValue.text))
            {
                if let lineage = lineageOfOpen[row.string("sitting_id")] { standings[lineage]?.own.insert(row.string("lineage_id")) }
            }
        }

        let seeding = standings.filter { continuesFromPracticed($0.value) }
        let seedable = Set(seeding.values.flatMap { Array($0.progress.keys) })
        var practiced: Set<String> = []
        for chunk in Chunks.of(seedable.sorted()) {
            for row in try tx.rows(
                """
                SELECT DISTINCT q.lineage_id AS lineage_id FROM attempt a JOIN question q ON q.id = a.question_id
                LEFT JOIN study_session s ON s.id = a.study_session_id
                WHERE q.lineage_id IN \(Chunks.marks(chunk)) AND (a.study_session_id IS NULL OR s.mode <> 'exam')
                """, chunk.map(StoreValue.text))
            {
                practiced.insert(row.string("lineage_id"))
            }
        }
        for (lineage, standing) in seeding {
            standings[lineage]?.practiced = Set(standing.progress.keys).intersection(practiced)
        }
        return standings
    }

    static func standing(_ tx: StoreTransaction, lineageID: String) throws -> Standing {
        try standings(tx, lineageIDs: [lineageID])[lineageID] ?? Standing()
    }

    /// Every current question has an answer, by any route, as Done on the set row counts it.
    private static func everyQuestionAnswered(_ standing: Standing) -> Bool {
        !standing.current.isEmpty && standing.current.allSatisfy { standing.progress[$0] != nil }
    }

    /// The last sitting ended with Start over, and none is open since.
    private static func startedOver(_ standing: Standing) -> Bool { standing.open == nil && standing.lastClosed?.endReason == "left" }

    /// With no sitting open, a set not finished and not started over continues from what was practiced.
    private static func continuesFromPracticed(_ standing: Standing) -> Bool {
        standing.open == nil && !startedOver(standing) && !everyQuestionAnswered(standing)
    }

    /// The current questions the open sitting has an answer to: what it was seeded with, and its own.
    private static func answeredInOpen(_ standing: Standing, _ open: Sitting) -> Set<String> {
        let seeded = Set(open.seeded)
        return Set(standing.current.filter { standing.own.contains($0) || (seeded.contains($0) && standing.progress[$0] != nil) })
    }

    /// The open sitting has an answer to every current question, so it is over and closes.
    private static func sittingComplete(_ standing: Standing, _ open: Sitting) -> Bool {
        !standing.current.isEmpty && answeredInOpen(standing, open).count == standing.current.count
    }

    /// The run through the set: the one place that decides it. Once every current question has an
    /// answer, by any route, the set is done even with a sitting open (a retake, or a sitting whose
    /// last questions were answered on an exam). A sitting open with something answered and something
    /// left is midway. A set midway with no sitting yet continues from the answers practiced, with no
    /// row until the next answer. Otherwise any answer means it starts again at question 1: after Start
    /// over, after a replace took away what an open sitting had answered, or when only exams answered it.
    static func run(of standing: Standing) -> Run {
        let open = standing.open
        if everyQuestionAnswered(standing) { return .done }
        if let open {
            let answered = answeredInOpen(standing, open)
            if !answered.isEmpty && answered.count < standing.current.count { return .midway(sittingId: open.id, answered: answered) }
        }
        if !standing.current.contains(where: { standing.progress[$0] != nil }) { return .new }
        if open != nil { return .restarted(startedOver: false) }
        if startedOver(standing) { return .restarted(startedOver: true) }
        if !standing.practiced.isEmpty { return .midway(sittingId: nil, answered: standing.practiced) }
        return .restarted(startedOver: false)
    }

    /// For each set lineage, its run and what its row shows of the sitting.
    static func summaries(_ tx: StoreTransaction, lineageIDs: [String]) throws -> [String: (run: String, sitting: JSONValue)] {
        var result: [String: (run: String, sitting: JSONValue)] = [:]
        for (lineage, standing) in try standings(tx, lineageIDs: lineageIDs) {
            let run = run(of: standing)
            if case .midway(_, let answered) = run {
                result[lineage] = (run.name, .object(["answeredCount": .int(answered.count)]))
            } else {
                result[lineage] = (run.name, .null)
            }
        }
        return result
    }

    // MARK: Reading a set's sitting

    /// The run through this set and the sitting that would be continued, with its answers.
    /// `questions` are the set's current questions, in order.
    static func read(_ tx: StoreTransaction, lineageID: String, questions: [StoreRow]) throws -> (run: String, sitting: JSONValue) {
        let standing = try standing(tx, lineageID: lineageID)
        let run = run(of: standing)
        guard case .midway(let sittingId, let answered) = run else { return (run.name, .null) }
        let latest = try latestAnswers(tx, standing: standing, answered: answered)
        let rows = questions.filter { answered.contains($0.string("lineage_id")) }
        let answers = rows.compactMap { question -> JSONValue? in
            guard let attempt = latest[question.string("lineage_id")] else { return nil }
            return answer(attempt, question: question, inReview: standing.progress[question.string("lineage_id")]?.flag("in_review") ?? false)
        }
        return (
            run.name,
            .object([
                "id": .optional(sittingId), "startedAt": .optional(standing.open?.startedAt),
                "answeredQuestionIds": .array(rows.map { .string($0.string("id")) }), "answers": .array(answers),
            ])
        )
    }

    /// The latest answer to each question: within the sitting for the ones answered in it, else the latest anywhere.
    private static func latestAnswers(_ tx: StoreTransaction, standing: Standing, answered: Set<String>) throws -> [String: StoreRow] {
        var latest: [String: StoreRow] = [:]
        if let open = standing.open {
            for row in try tx.rows(
                """
                SELECT a.*, q.lineage_id AS lineage_id FROM attempt a JOIN question q ON q.id = a.question_id
                WHERE a.study_session_id = ? ORDER BY a.answered_at, a.id
                """, [.text(open.id)])
            {
                latest[row.string("lineage_id")] = row
            }
        }
        var lineageOfAttempt: [String: String] = [:]
        for lineage in answered where latest[lineage] == nil {
            if let id = standing.progress[lineage]?.text("last_attempt_id") { lineageOfAttempt[id] = lineage }
        }
        for chunk in Chunks.of(lineageOfAttempt.keys.sorted()) {
            for row in try tx.rows("SELECT * FROM attempt WHERE id IN \(Chunks.marks(chunk))", chunk.map(StoreValue.text)) {
                if let lineage = lineageOfAttempt[row.string("id")] { latest[lineage] = row }
            }
        }
        return latest
    }

    /// One answer of a sitting, as a device needs it to fill in a question already checked.
    private static func answer(_ row: StoreRow, question: StoreRow, inReview: Bool) -> JSONValue {
        let status = ["correct", "partial"].contains(row.string("status")) ? row.string("status") : "incorrect"
        let score = Score(
            points: row.integer("points"), maxPoints: row.integer("max_points"), status: ScoreStatus(rawValue: status) ?? .incorrect, answered: true)
        let type = QuestionType(rawValue: question.string("type"))
        return .object([
            "clientAttemptId": .string(row.string("client_attempt_id")), "questionId": .string(question.string("id")), "status": .string(status),
            "points": .int(score.points), "maxPoints": .int(score.maxPoints), "guessed": .bool(row.flag("guessed")),
            "answeredAt": .string(row.string("answered_at")), "inReview": .bool(inReview), "label": .string(score.label),
            "pointsText": .optional(type.flatMap { score.pointsText(for: $0) }), "ruleText": .optional(type?.scoringRule),
            "response": row.text("response").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null,
            "shuffle": row.text("shuffle").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null,
        ])
    }

    // MARK: Writing a sitting

    /// The sitting a practice answer joins, opening one if it should. It runs before the progress is
    /// written, so the seed is what the person had before this answer.
    ///
    /// It joins the sitting open when it arrives, whenever it was given. With none open, it opens one
    /// with what was already practiced of the set; or, when the set begins again, with nothing, and then
    /// only for the set's first question, where a runner starts. An answer from Review, or one still on
    /// its way after Start over, opens none. Either way the answer is saved and counts toward progress.
    static func sittingForAnswer(_ call: BankCall, setLineageID: String, lineageID: String, fromReview: Bool) throws -> String? {
        let tx = call.tx
        var standing = try standing(tx, lineageID: setLineageID)
        if let open = standing.open {
            if !sittingComplete(standing, open) { return open.id }
            // A replace took away the questions it was waiting on.
            try close(tx, open.id, reason: "finished", at: call.nowText)
            standing.lastClosed = open
            standing.open = nil
        }
        guard let versionId = standing.versionId, let courseId = standing.courseId, !fromReview else { return nil }
        let run = run(of: standing)
        var fromTheStart = false
        var seeded: [String] = []
        switch run {
        case .done: fromTheStart = true
        case .restarted(let startedOver): fromTheStart = startedOver
        case .midway(_, let answered): seeded = standing.current.filter { answered.contains($0) }
        case .new: break
        }
        if fromTheStart && standing.current.first != lineageID { return nil }
        return try open(call, versionID: versionId, courseID: courseId, seeded: seeded)
    }

    /// Closes the sitting once it has an answer to every current question. Runs after the answer is saved.
    static func finishIfDone(_ call: BankCall, sittingID: String, setLineageID: String) throws {
        let standing = try standing(call.tx, lineageID: setLineageID)
        if let open = standing.open, open.id == sittingID, sittingComplete(standing, open) {
            try close(call.tx, sittingID, reason: "finished", at: call.nowText)
        }
    }

    /// Start over: ends the sitting that would be continued, so the set opens at question 1. Every
    /// answer stays. A set with no row yet gets a closed one, so the answers it continued from are not
    /// picked up again. Says whether there was anything to end.
    static func end(_ call: BankCall, setLineageID: String) throws -> Bool {
        let standing = try standing(call.tx, lineageID: setLineageID)
        if let open = standing.open {
            try close(call.tx, open.id, reason: "left", at: call.nowText)
            return true
        }
        guard case .midway(_, let answered) = run(of: standing), let versionId = standing.versionId, let courseId = standing.courseId else { return false }
        let id = try open(call, versionID: versionId, courseID: courseId, seeded: standing.current.filter { answered.contains($0) })
        try close(call.tx, id, reason: "left", at: call.nowText)
        return true
    }

    private static func open(_ call: BankCall, versionID: String, courseID: String, seeded: [String]) throws -> String {
        let id = call.newID()
        // Its questions are the set's current ones, whatever they become, so it keeps no list of its own.
        try call.tx.execute(
            """
            INSERT INTO study_session (id, course_id, mode, set_id, question_ids, seeded_question_ids, started_at, exam_pool)
            VALUES (?, ?, 'practice', ?, '[]', ?, ?, 'all')
            """, [.text(id), .text(courseID), .text(versionID), .text(JS.stringify(.array(seeded.map(JSNode.string)))), .text(call.nowText)])
        return id
    }

    private static func close(_ tx: StoreTransaction, _ id: String, reason: String, at time: String) throws {
        try tx.execute("UPDATE study_session SET finished_at = ?, end_reason = ? WHERE id = ?", [.text(time), .text(reason), .text(id)])
    }

    /// Whether a study session is a practice sitting, for telling a retry of an answer it took from a changed one.
    static func isPractice(_ tx: StoreTransaction, _ id: String) throws -> Bool {
        try tx.rows("SELECT mode FROM study_session WHERE id = ?", [.text(id)]).first?.text("mode") == "practice"
    }
}

/// A list too long for one statement is read in pieces.
enum Chunks {
    static func of<Item>(_ items: [Item], size: Int = 400) -> [[Item]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// `(?, ?, ?)` for that many values.
    static func marks<Item>(_ items: [Item]) -> String { "(" + Array(repeating: "?", count: items.count).joined(separator: ", ") + ")" }
}
