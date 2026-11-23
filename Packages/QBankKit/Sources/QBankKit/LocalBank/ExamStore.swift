import Foundation

/// An exam as the store keeps it: a `study_session` row of mode `exam`.
struct ExamRow {
    let id: String
    let courseId: String
    /// The questions it drew, in the order served.
    let questionIds: [String]
    /// The names of the folders it was over, as they were when it started.
    let weeks: [String]?
    let folderIds: [String]?
    let pool: String
    let practiceWeeks: [String]?
    let limitSeconds: Int?
    let startedAt: String
    var finishedAt: String?
    var endReason: String?
    var score: JSONValue?
    let deletedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        courseId = row.string("course_id")
        questionIds = Self.strings(row, "question_ids") ?? []
        weeks = Self.strings(row, "exam_weeks")
        folderIds = Self.strings(row, "exam_folder_ids")
        pool = row.string("exam_pool") == "wrong" ? "wrong" : "all"
        practiceWeeks = Self.strings(row, "exam_practice_weeks")
        limitSeconds = row.int("time_limit_seconds")
        startedAt = row.string("started_at")
        finishedAt = row.text("finished_at")
        endReason = row.text("end_reason")
        score = row.text("score").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        deletedAt = row.text("deleted_at")
    }

    private static func strings(_ row: StoreRow, _ column: String) -> [String]? {
        row.text(column).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    /// When its time runs out, in milliseconds since 1970.
    var endsAt: Int { ExamClock.endsAt(startedAt: startedAt, limitSeconds: limitSeconds) }

    func status(_ now: Date) -> ExamClock.Status {
        ExamClock.status(startedAt: startedAt, limitSeconds: limitSeconds, finishedAt: finishedAt, now: now)
    }
}

/// The exams of the bank: finding them, ending them and recording the end of the ones whose time is up.
enum ExamStore {
    static let notFound = BankRefusal.study(404, "exam_not_found", "That exam is not in the app.")

    /// One exam, deleted or not.
    static func own(_ tx: StoreTransaction, _ id: String) throws -> ExamRow {
        guard let row = try tx.rows("SELECT * FROM study_session WHERE id = ? AND mode = 'exam'", [.text(id)]).first else { throw notFound }
        let exam = ExamRow(row)
        // An exam of a course that was deleted is not in the app until Undo brings the course back.
        if try !BankLookup.live(tx, exam.courseId) { throw notFound }
        return exam
    }

    /// One exam that was not deleted.
    static func live(_ tx: StoreTransaction, _ id: String) throws -> ExamRow {
        let exam = try own(tx, id)
        if exam.deletedAt != nil { throw BankRefusal.study(404, "exam_not_found", "That exam was deleted.") }
        return exam
    }

    /// The exams that have not ended and were not deleted, newest first: running, in their grace, or
    /// with their time up and their end not recorded yet.
    static func open(_ tx: StoreTransaction) throws -> [ExamRow] {
        try tx.rows("SELECT * FROM study_session WHERE mode = 'exam' AND finished_at IS NULL AND deleted_at IS NULL ORDER BY started_at DESC, id").map(ExamRow.init)
    }

    /// Records the end of the exams whose time is up, so a closed app still ends on time. One in its
    /// grace is left open, so no read can cut off an answer still on its way.
    static func settleExpired(_ call: BankCall) throws {
        for exam in try open(call.tx) where exam.status(call.now) == .expired { try close(call, exam, reason: "timeout") }
    }

    /// Scores the exam from the saved answers and marks it ended.
    static func close(_ call: BankCall, _ exam: ExamRow, reason: String) throws {
        let ending = try ending(of: exam, reason: reason, call.tx, call.now)
        try call.tx.execute(
            "UPDATE study_session SET finished_at = ?, end_reason = ?, score = ? WHERE id = ?",
            [.text(ending.finishedAt), .text(ending.endReason), .text(Stored.json(ending.score)), .text(exam.id)])
    }

    /// What ending an exam that has not ended records: when, how, and its score from the saved answers.
    /// Once its time has run out, the end is a timeout at the moment time ran out, whatever was asked.
    static func ending(of exam: ExamRow, reason: String, _ tx: StoreTransaction, _ now: Date) throws -> (finishedAt: String, endReason: String, score: JSONValue) {
        let timedOut = exam.status(now) != .running
        let finishedAt = ExamClock.text(milliseconds: timedOut ? exam.endsAt : ExamClock.milliseconds(now))
        let result = try ExamScoring.score(exam, served: try served(tx, exam), answers: try answers(tx, exam.id), finishedAt: finishedAt, folders: [])
        return (finishedAt, timedOut ? "timeout" : reason, result.stored)
    }

    /// The exam as every reader is shown it at `now`. One whose time is up reads as ended whether or
    /// not its end is recorded yet, with the end that recording it stores, worked out from the saved
    /// answers, which can no longer change. Nothing is written.
    static func asRead(_ tx: StoreTransaction, _ exam: ExamRow, _ now: Date) throws -> ExamRow {
        guard exam.status(now) == .expired else { return exam }
        var read = exam
        let ending = try ending(of: exam, reason: "timeout", tx, now)
        read.finishedAt = ending.finishedAt
        read.endReason = ending.endReason
        read.score = ending.score
        return read
    }

    // MARK: Questions and answers

    /// An exam's questions in the order they were served, which of them came from an exam bank, and
    /// the folder each one's set is in now. A replaced set's old version is still read.
    struct Served {
        var rows: [StoreRow] = []
        var bank: Set<String> = []
        var folderOf: [String: String] = [:]
    }

    static func served(_ tx: StoreTransaction, _ exam: ExamRow) throws -> Served {
        var found: [String: StoreRow] = [:]
        for chunk in Chunks.of(exam.questionIds) {
            for row in try tx.rows(
                """
                SELECT q.*, ps.kind AS set_kind, ps.folder_id AS set_folder_id
                FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE q.id IN \(Chunks.marks(chunk))
                """, chunk.map(StoreValue.text))
            {
                found[row.string("id")] = row
            }
        }
        var served = Served()
        for id in exam.questionIds {
            guard let row = found[id] else { continue }
            served.rows.append(row)
            if row.string("set_kind") == "exam" { served.bank.insert(id) }
            if let folder = row.text("set_folder_id") { served.folderOf[id] = folder }
        }
        return served
    }

    /// The answers saved on the exam, in the order they were answered.
    static func answers(_ tx: StoreTransaction, _ examID: String) throws -> [StoreRow] {
        try tx.rows("SELECT * FROM attempt WHERE study_session_id = ? ORDER BY answered_at, rowid", [.text(examID)])
    }

    /// How many answers each of these exams holds.
    static func answeredCounts(_ tx: StoreTransaction, _ examIDs: [String]) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for chunk in Chunks.of(examIDs) {
            for row in try tx.rows(
                "SELECT study_session_id, count(*) AS n FROM attempt WHERE study_session_id IN \(Chunks.marks(chunk)) GROUP BY study_session_id", chunk.map(StoreValue.text))
            {
                counts[row.string("study_session_id")] = row.integer("n")
            }
        }
        return counts
    }
}
