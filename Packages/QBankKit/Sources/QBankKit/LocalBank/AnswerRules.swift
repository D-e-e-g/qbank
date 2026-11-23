import Foundation

/// The rule family for recording an answer: `POST /api/attempts`.
///
/// An answer is scored on the phone, saved once for each `clientAttemptId`, and counted into the
/// question's progress in the same transaction. Sending the same id again returns the saved answer
/// and counts nothing; sending it with another answer is refused. Progress is only ever added to: a
/// repeat, a retry or an answer that arrives late never lowers it, and what the person last
/// answered is decided by when it was answered, not by when it arrived.
enum AnswerRules {
    static func register(in router: inout BankRouter) {
        router.post("/api/attempts", record)
    }

    private struct Question {
        let id: String
        let lineageId: String
        let type: String
        let body: String
        let courseId: String
        let kind: String
        let setLineageId: String
    }

    private static func record(_ call: BankCall) throws -> BankAnswer {
        let fields = try BankBody(call.body)
        let clientAttemptId = try fields.uuid("clientAttemptId")
        let questionId = try fields.string("questionId")
        if questionId.isEmpty { throw BankRefusal.invalidRequest }
        let guessed = try fields.bool("guessed", default: false)
        let sessionId = try fields.optionalUUID("studySessionId")
        let fromReview = try fields.optionalBool("fromReview") ?? false
        let response = fields.value("response")
        let shuffle = fields.value("shuffle") ?? .null

        let tx = call.tx
        guard let question = try find(tx, questionId) else { throw questionNotFound }
        let scored = try AnswerScoring.score(typeName: question.type, body: question.body, response: response)
        let examOnly = question.kind == "exam"
        if examOnly && sessionId == nil { throw BankRefusal.study(400, "exam_only", "That question is only asked on exams.") }
        let inReview = !examOnly && scored.score.staysInReview(guessed: guessed)

        if let existing = try tx.rows("SELECT * FROM attempt WHERE client_attempt_id = ?", [.text(clientAttemptId)]).first {
            let saved = try replay(
                tx, stored: existing, question: question, scored: scored, sent: Sent(questionId: questionId, sessionId: sessionId, guessed: guessed, response: response ?? .null, shuffle: shuffle))
            return .ok(saved)
        }

        let id = call.newID()
        let answeredAt = call.nowText
        if let sessionId { try checkExamAnswer(call, examID: sessionId, questionID: question.id) }
        let sittingId = sessionId == nil ? try Sittings.sittingForAnswer(call, setLineageID: question.setLineageId, lineageID: question.lineageId, fromReview: fromReview) : nil
        try tx.execute(
            """
            INSERT INTO attempt (id, client_attempt_id, study_session_id, question_id, response, shuffle, status, points, max_points, guessed, answered_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), .text(clientAttemptId), .optional(sessionId ?? sittingId), .text(question.id), .text(Stored.json(response ?? .null)),
                shuffle == .null ? .null : .text(Stored.json(shuffle)), .text(scored.score.status.rawValue), .integer(Int64(scored.score.points)),
                .integer(Int64(scored.score.maxPoints)), .bool(guessed), .text(answeredAt),
            ])
        try writeProgress(tx, lineageID: question.lineageId, attemptID: id, score: scored.score, guessed: guessed, answeredAt: answeredAt, inReview: inReview)
        if let sittingId { try Sittings.finishIfDone(call, sittingID: sittingId, setLineageID: question.setLineageId) }
        try PlaceRules.remember(tx, courseID: question.courseId, at: answeredAt)
        let row = try tx.rows("SELECT * FROM attempt WHERE id = ?", [.text(id)])[0]
        return .created(saved(row, question: question, type: scored.type, inReview: inReview, replayed: false))
    }

    private static let questionNotFound = BankRefusal.study(404, "question_not_found", "That question is not in the bank.")

    private static func find(_ tx: StoreTransaction, _ id: String) throws -> Question? {
        guard BankBody.isAnyUUID(id) else { return nil }
        guard
            let row = try tx.rows(
                """
                SELECT q.id, q.lineage_id, q.type, q.body, ps.course_id, ps.kind, ps.lineage_id AS set_lineage_id
                FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE q.id = ?
                """, [.text(id.lowercased())]
            ).first
        else { return nil }
        return Question(
            id: row.string("id"), lineageId: row.string("lineage_id"), type: row.string("type"), body: row.string("body"),
            courseId: row.string("course_id"), kind: row.string("kind"), setLineageId: row.string("set_lineage_id"))
    }

    // MARK: Repeating an answer

    private struct Sent {
        let questionId: String
        let sessionId: String?
        let guessed: Bool
        let response: JSONValue
        let shuffle: JSONValue
    }

    /// An id already saved: the same answer returns what was saved and counts nothing, another is a conflict.
    private static func replay(_ tx: StoreTransaction, stored: StoreRow, question: Question, scored: AnswerScoring.Result, sent: Sent) throws -> JSONValue {
        // An answer sent with no session joined its set's sitting, so its retry names none either.
        let storedSession = stored.text("study_session_id")
        var inSitting = false
        if sent.sessionId == nil, let storedSession { inSitting = try Sittings.isPractice(tx, storedSession) }
        let session = inSitting ? storedSession : sent.sessionId
        let storedResponse = stored.text("response").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null
        let storedShuffle = stored.text("shuffle").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null
        guard stored.string("question_id") == sent.questionId, storedSession == session, stored.flag("guessed") == sent.guessed,
            Stored.stable(storedResponse) == Stored.stable(sent.response), Stored.stable(storedShuffle) == Stored.stable(sent.shuffle)
        else { throw BankRefusal.study(409, "attempt_conflict", "That attempt id was already saved with a different answer.") }
        let progress = try tx.rows("SELECT in_review FROM question_progress WHERE question_lineage_id = ?", [.text(question.lineageId)]).first
        let inReview = question.kind != "exam" && (progress?.flag("in_review") ?? (stored.flag("guessed") || stored.string("status") != "correct"))
        return saved(stored, question: question, type: scored.type, inReview: inReview, replayed: true)
    }

    private static func saved(_ row: StoreRow, question: Question, type: QuestionType, inReview: Bool, replayed: Bool) -> JSONValue {
        let status = ScoreStatus(rawValue: row.string("status")) ?? .incorrect
        let score = Score(points: row.integer("points"), maxPoints: row.integer("max_points"), status: status, answered: true)
        return .object([
            "clientAttemptId": .string(row.string("client_attempt_id")), "questionId": .string(row.string("question_id")), "courseId": .string(question.courseId),
            "status": .string(status.rawValue), "points": .int(score.points), "maxPoints": .int(score.maxPoints), "guessed": .bool(row.flag("guessed")),
            "answeredAt": .string(row.string("answered_at")), "inReview": .bool(inReview), "label": .string(score.label),
            "pointsText": .optional(score.pointsText(for: type)), "ruleText": .optional(type.scoringRule), "replayed": .bool(replayed),
        ])
    }

    // MARK: Exams

    /// An exam answer is taken only while the exam is open (running, or in its grace), for a question it
    /// drew, and once for each question.
    private static func checkExamAnswer(_ call: BankCall, examID: String, questionID: String) throws {
        let tx = call.tx
        guard let exam = try tx.rows("SELECT * FROM study_session WHERE id = ? AND mode = 'exam' AND deleted_at IS NULL", [.text(examID)]).first else {
            throw BankRefusal.study(404, "exam_not_found", "That exam is not in the app.")
        }
        if !isOpen(exam, now: call.now) { throw BankRefusal.study(409, "exam_finished", "This exam has ended. That answer was not saved.") }
        let drawn = exam.text("question_ids").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        if !drawn.contains(questionID) { throw BankRefusal.study(400, "question_not_in_exam", "That question is not on this exam.") }
        if try !tx.rows("SELECT id FROM attempt WHERE study_session_id = ? AND question_id = ?", [.text(examID), .text(questionID)]).isEmpty {
            throw BankRefusal.study(409, "already_answered", "That question was already answered on this exam.")
        }
    }

    /// Running, or in the grace after its time ran out: it takes an answer. Only its end is stored; the rest is told from the clock.
    static func isOpen(_ exam: StoreRow, now: Date) -> Bool {
        ExamClock.isOpen(ExamRow(exam).status(now))
    }

    // MARK: Progress

    /// Adds one answer to the question's progress. A later answer takes over what was answered last;
    /// an earlier one that arrives after it counts but never takes it back.
    private static func writeProgress(
        _ tx: StoreTransaction, lineageID: String, attemptID: String, score: Score, guessed: Bool, answeredAt: String, inReview: Bool
    ) throws {
        let correct = score.status == .correct ? 1 : 0
        guard let current = try tx.rows("SELECT * FROM question_progress WHERE question_lineage_id = ?", [.text(lineageID)]).first else {
            try tx.execute(
                """
                INSERT INTO question_progress (question_lineage_id, attempts, correct_attempts, last_status, last_guessed, last_answered_at, last_points, last_max_points, in_review, last_attempt_id)
                VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(lineageID), .integer(Int64(correct)), .text(score.status.rawValue), .bool(guessed), .text(answeredAt), .integer(Int64(score.points)),
                    .integer(Int64(score.maxPoints)), .bool(inReview), .text(attemptID),
                ])
            return
        }
        let then = current.string("last_answered_at")
        let newer = answeredAt != then ? answeredAt > then : attemptID > current.string("last_attempt_id")
        try tx.execute(
            """
            UPDATE question_progress SET attempts = ?, correct_attempts = ?, last_status = ?, last_guessed = ?, last_answered_at = ?, last_points = ?,
                last_max_points = ?, in_review = ?, last_attempt_id = ? WHERE question_lineage_id = ?
            """,
            [
                .integer(Int64(current.integer("attempts") + 1)), .integer(Int64(current.integer("correct_attempts") + correct)),
                .text(newer ? score.status.rawValue : current.string("last_status")), .bool(newer ? guessed : current.flag("last_guessed")),
                .text(newer ? answeredAt : then), .integer(Int64(newer ? score.points : current.integer("last_points"))),
                .integer(Int64(newer ? score.maxPoints : current.integer("last_max_points"))), .bool(newer ? inReview : current.flag("in_review")),
                .text(newer ? attemptID : current.string("last_attempt_id")), .text(lineageID),
            ])
    }
}

/// JSON as the store keeps it, and as the server compares two answers.
enum Stored {
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// A text that is the same for two values that are the same whatever the order of their keys.
    static func stable(_ value: JSONValue) -> String {
        switch value {
        case .array(let items): "[" + items.map(stable).joined(separator: ",") + "]"
        case .object(let fields):
            "{" + fields.sorted { BankText.localeCompare($0.key, $1.key) < 0 }.map { json(.string($0.key)) + ":" + stable($0.value) }.joined(separator: ",") + "}"
        default: json(value)
        }
    }
}
