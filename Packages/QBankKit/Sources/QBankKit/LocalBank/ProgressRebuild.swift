import Foundation

/// The person's progress as the saved answers give it. A delete of a past exam, and its Undo, rebuild
/// the progress of the questions it was answered on; the warning's standing is `StandingRules`'s.
enum ProgressRebuild {
    /// One question lineage's progress, as a rebuild writes it.
    struct Line: Equatable {
        var lineageId: String
        var attempts: Int
        var correctAttempts: Int
        var lastStatus: String
        var lastGuessed: Bool
        var lastAnsweredAt: String
        var lastPoints: Int
        var lastMaxPoints: Int
        var inReview: Bool
        var lastAttemptId: String

        init(_ row: StoreRow) {
            lineageId = row.string("question_lineage_id")
            attempts = row.integer("attempts")
            correctAttempts = row.integer("correct_attempts")
            lastStatus = row.string("last_status")
            lastGuessed = row.flag("last_guessed")
            lastAnsweredAt = row.string("last_answered_at")
            lastPoints = row.integer("last_points")
            lastMaxPoints = row.integer("last_max_points")
            inReview = row.flag("in_review")
            lastAttemptId = row.string("last_attempt_id")
        }

        /// The same line as the standing and the pools read it.
        var progressLine: ProgressLine {
            ProgressLine(lastStatus: lastStatus, lastAnsweredAt: lastAnsweredAt, lastPoints: lastPoints, lastMaxPoints: lastMaxPoints, inReview: inReview)
        }

        init(first answer: StoreRow, lineageId: String, inReview: Bool) {
            self.lineageId = lineageId
            attempts = 1
            correctAttempts = answer.string("status") == "correct" ? 1 : 0
            lastStatus = answer.string("status")
            lastGuessed = answer.flag("guessed")
            lastAnsweredAt = answer.string("answered_at")
            lastPoints = answer.integer("points")
            lastMaxPoints = answer.integer("max_points")
            self.inReview = inReview
            lastAttemptId = answer.string("id")
        }
    }

    /// Which of two answers is the latest. Live writes and repairs use the same order.
    private static func isLater(_ answeredAt: String, _ attemptId: String, than thenAt: String, _ thenId: String) -> Bool {
        answeredAt != thenAt ? answeredAt > thenAt : attemptId > thenId
    }

    /// The progress these lineages have from the saved answers. The answers of an exam that was
    /// deleted count toward nothing: they are left out, as if never given, until the exam comes back.
    /// `leaveOutExam` leaves one more exam's answers out, for a preview of deleting it.
    static func expected(_ tx: StoreTransaction, lineageIDs: [String], leaveOutExam: String? = nil) throws -> [String: Line] {
        var answers: [StoreRow] = []
        var clears: [String: StoreRow] = [:]
        for chunk in Chunks.of(Array(Set(lineageIDs)).sorted()) {
            let marks = Chunks.marks(chunk)
            let values = chunk.map(StoreValue.text)
            answers += try tx.rows(
                """
                SELECT a.id, q.lineage_id AS lineage_id, a.status, a.guessed, a.answered_at, a.points, a.max_points, ps.kind AS kind,
                       a.study_session_id AS session_id, ss.deleted_at AS session_deleted_at
                FROM attempt a JOIN question q ON q.id = a.question_id JOIN practice_set ps ON ps.id = q.set_id
                LEFT JOIN study_session ss ON ss.id = a.study_session_id WHERE q.lineage_id IN \(marks)
                """, values)
            for clear in try tx.rows("SELECT * FROM review_clear WHERE question_lineage_id IN \(marks)", values) { clears[clear.string("question_lineage_id")] = clear }
        }
        let left = Set(answers.filter { $0.text("session_deleted_at") != nil || (leaveOutExam != nil && $0.text("session_id") == leaveOutExam) }.map { $0.string("id") })
        let ordered = answers.filter { !left.contains($0.string("id")) }.sorted { a, b in
            a.string("answered_at") != b.string("answered_at") ? a.string("answered_at") < b.string("answered_at") : BankText.localeCompare(a.string("id"), b.string("id")) < 0
        }
        var grouped: [String: Line] = [:]
        for answer in ordered {
            let lineage = answer.string("lineage_id")
            let score = ExamScoring.score(of: answer)
            let inReview = answer.string("kind") != "exam" && score.staysInReview(guessed: answer.flag("guessed"))
            guard var line = grouped[lineage] else {
                grouped[lineage] = Line(first: answer, lineageId: lineage, inReview: inReview)
                continue
            }
            line.attempts += 1
            if answer.string("status") == "correct" { line.correctAttempts += 1 }
            if isLater(answer.string("answered_at"), answer.string("id"), than: line.lastAnsweredAt, line.lastAttemptId) {
                line.lastStatus = answer.string("status")
                line.lastGuessed = answer.flag("guessed")
                line.lastAnsweredAt = answer.string("answered_at")
                line.lastPoints = answer.integer("points")
                line.lastMaxPoints = answer.integer("max_points")
                line.inReview = inReview
                line.lastAttemptId = answer.string("id")
            }
            grouped[lineage] = line
        }
        // A clear covers the answer that was latest when it was made; a later answer decides again. When
        // that answer is left out (its exam was deleted), the clear still covers the answers before it.
        for (lineage, clear) in clears {
            guard var line = grouped[lineage] else { continue }
            let covers = clear.string("last_attempt_id") == line.lastAttemptId || (left.contains(clear.string("last_attempt_id")) && clear.string("cleared_at") >= line.lastAnsweredAt)
            if covers {
                line.inReview = false
                grouped[lineage] = line
            }
        }
        return grouped
    }

    /// Rewrites the progress on these lineages from the saved answers: a lineage with no answer left
    /// loses its row.
    static func rebuild(_ tx: StoreTransaction, lineageIDs: [String]) throws {
        let ids = Array(Set(lineageIDs)).sorted()
        if ids.isEmpty { return }
        let expected = try expected(tx, lineageIDs: ids)
        for chunk in Chunks.of(ids) {
            let gone = chunk.filter { expected[$0] == nil }
            if !gone.isEmpty { try tx.execute("DELETE FROM question_progress WHERE question_lineage_id IN \(Chunks.marks(gone))", gone.map(StoreValue.text)) }
        }
        try write(expected, in: tx)
    }

    /// Stores the rebuilt lines. A combine uses this part alone so a line left without a
    /// counting answer retains the progress from before its exam was deleted.
    static func write(_ expected: [String: Line], in tx: StoreTransaction) throws {
        for line in expected.values.sorted(by: { $0.lineageId < $1.lineageId }) {
            try tx.execute(
                """
                INSERT INTO question_progress (question_lineage_id, attempts, correct_attempts, last_status, last_guessed, last_answered_at, last_points, last_max_points, in_review, last_attempt_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (question_lineage_id) DO UPDATE SET attempts = excluded.attempts, correct_attempts = excluded.correct_attempts, last_status = excluded.last_status,
                    last_guessed = excluded.last_guessed, last_answered_at = excluded.last_answered_at, last_points = excluded.last_points,
                    last_max_points = excluded.last_max_points, in_review = excluded.in_review, last_attempt_id = excluded.last_attempt_id
                """,
                [
                    .text(line.lineageId), .integer(Int64(line.attempts)), .integer(Int64(line.correctAttempts)), .text(line.lastStatus), .bool(line.lastGuessed),
                    .text(line.lastAnsweredAt), .integer(Int64(line.lastPoints)), .integer(Int64(line.lastMaxPoints)), .bool(line.inReview), .text(line.lastAttemptId),
                ])
        }
    }
}
