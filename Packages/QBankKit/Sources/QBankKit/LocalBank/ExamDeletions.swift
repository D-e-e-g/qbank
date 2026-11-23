import Foundation

/// Deleting one of the person's past exams, and Undo. The exam is hidden, never removed, and its
/// answers stay saved but count toward nothing while it is deleted: the progress on the questions
/// answered on it is rebuilt from the other answers, as if those had not been given (the Review
/// list, scores and Wrong questions follow). Undo, within 30 days, rebuilds it again with them, so it
/// is as it was. The Undo window, the `confirm`, the warning's split and the standing it reports are
/// the other deletes' (`DeleteMarks`, `StandingRules`), so a past exam is deleted and brought back the
/// way a set or a folder is.
enum ExamDeletions {
    private static let inProgress = "This exam is still going. Finish or leave it, then delete it."

    /// What deleting the exam would change, the warning to show, and the `confirm` that deletes it.
    static func preview(_ call: BankCall, examID: String) throws -> JSONValue {
        let tx = call.tx
        try ExamStore.settleExpired(call)
        let exam = try ExamStore.asRead(tx, try ExamStore.live(tx, examID), call.now)
        let lineageIDs = try answeredLineages(tx, examID: exam.id)
        let answeredCount = try ExamStore.answeredCounts(tx, [exam.id])[exam.id] ?? 0
        let without = try ProgressRebuild.expected(tx, lineageIDs: lineageIDs, leaveOutExam: exam.id)
        var stored: [String: ProgressRebuild.Line] = [:]
        for chunk in Chunks.of(lineageIDs) {
            for row in try tx.rows("SELECT * FROM question_progress WHERE question_lineage_id IN \(Chunks.marks(chunk))", chunk.map(StoreValue.text)) {
                stored[row.string("question_lineage_id")] = ProgressRebuild.Line(row)
            }
        }
        let changedCount = lineageIDs.count { id in without[id] != nil && stored[id]?.lastAttemptId != without[id]?.lastAttemptId }
        let unansweredCount = lineageIDs.count { without[$0] == nil }

        let inputs = try StandingRules.inputs(tx, courseID: exam.courseId)
        var after = inputs.progress
        for id in lineageIDs { after[id] = without[id]?.progressLine }
        let progress = StandingRules.change(StandingRules.of(inputs.questions, inputs.progress), StandingRules.of(inputs.questions, after))
        let message = message(answered: answeredCount, changed: changedCount, unanswered: unansweredCount, progress: progress)
        return .object([
            "examId": .string(exam.id), "courseId": .string(exam.courseId), "startedAt": .string(exam.startedAt), "finishedAt": .optional(exam.finishedAt),
            "questionCount": .int(exam.questionIds.count), "answeredCount": .int(answeredCount), "changedCount": .int(changedCount),
            "unansweredCount": .int(unansweredCount), "progress": progress, "message": .string(message), "warning": DeleteMarks.warning(message, doomed: "this exam"),
            "refusal": ExamClock.isOpen(exam.status(call.now)) ? .string(inProgress) : .null, "confirm": .string(token(exam)), "undoDays": .int(DeleteMarks.undoDays),
        ])
    }

    /// Deletes the past exam once the person has confirmed it (the preview's `confirm`): it is hidden,
    /// and its answers stop counting toward the progress. An exam still going is refused.
    static func delete(_ call: BankCall, examID: String, confirm: String?) throws {
        let tx = call.tx
        try ExamStore.settleExpired(call)
        let exam = try ExamStore.live(tx, examID)
        if ExamClock.isOpen(exam.status(call.now)) { throw DeleteMarks.refusal(409, "exam_in_progress", inProgress) }
        try DeleteMarks.confirmed(
            confirm, expected: token(exam), name: "This exam", unconfirmed: "Look at what deleting this exam changes and confirm it first.")
        try tx.execute("UPDATE study_session SET deleted_at = ?, deletion_id = ? WHERE id = ?", [.text(call.nowText), .text(call.newID()), .text(exam.id)])
        try ProgressRebuild.rebuild(tx, lineageIDs: try answeredLineages(tx, examID: exam.id))
    }

    /// Brings back a past exam deleted within 30 days: it is listed again and its answers count again.
    static func undo(_ call: BankCall, examID: String) throws -> JSONValue {
        let tx = call.tx
        let exam = try ExamStore.own(tx, examID)
        guard let deletedAt = exam.deletedAt else { throw DeleteMarks.refusal(409, "not_deleted", "That exam is not deleted.") }
        if DeleteMarks.expired(deletedAt, now: call.now) {
            throw DeleteMarks.refusal(409, "undo_expired", "This exam was deleted more than \(DeleteMarks.undoDays) days ago, so it can't be brought back.")
        }
        try tx.execute("UPDATE study_session SET deleted_at = NULL, deletion_id = NULL WHERE id = ?", [.text(exam.id)])
        try ProgressRebuild.rebuild(tx, lineageIDs: try answeredLineages(tx, examID: exam.id))
        return try ExamViews.summary(tx, try ExamStore.own(tx, exam.id), now: call.now).json
    }

    /// The past exams of a course deleted in the last 30 days, newest first: what Undo can still bring back, as Recently deleted lists them.
    static func recentlyDeleted(_ tx: StoreTransaction, courseID: String, since: String, now: Date) throws -> [JSONValue] {
        let rows = try tx.rows(
            """
            SELECT * FROM study_session WHERE course_id = ? AND mode = 'exam' AND deleted_at IS NOT NULL AND deleted_at > ?
            ORDER BY deleted_at DESC, started_at DESC, id
            """, [.text(courseID), .text(since)]
        ).map(ExamRow.init)
        let summaries = try ExamViews.summaries(tx, rows, folders: try FolderOrder.rows(tx, courseID: courseID), pages: try PageViews.pages(tx, courseID: courseID), now: now)
        return zip(summaries, rows).map { summary, row in
            guard case .object(var fields) = summary.json else { return summary.json }
            fields["deletedAt"] = .string(row.deletedAt ?? "")
            fields["undoUntil"] = .string(DeleteMarks.undoUntil(row.deletedAt ?? ""))
            return .object(fields)
        }
    }

    // MARK: What it names

    /// The question lineages answered on the exam: the progress its delete and Undo rebuild.
    private static func answeredLineages(_ tx: StoreTransaction, examID: String) throws -> [String] {
        let rows = try tx.rows(
            "SELECT DISTINCT q.lineage_id AS lineage_id FROM attempt a JOIN question q ON q.id = a.question_id WHERE a.study_session_id = ? ORDER BY q.lineage_id", [.text(examID)])
        return rows.map { $0.string("lineage_id") }
    }

    /// What the delete would take, which its preview hands out and the delete checks. An ended exam's answers never change, so its id and
    /// end say all its warning said.
    private static func token(_ exam: ExamRow) -> String { DeleteMarks.token(["exam", exam.id, exam.finishedAt]) }

    private static func message(answered: Int, changed: Int, unanswered: Int, progress: JSONValue) -> String {
        var sentences = ["Delete this exam?"]
        if answered == 0 {
            sentences.append("You answered none of its questions, so your progress stays as it is.")
        } else {
            sentences.append("Your \(DeleteMarks.countOf(answered, "answer")) on it \(answered == 1 ? "goes" : "go") with it and \(answered == 1 ? "stops" : "stop") counting toward your progress.")
            var back: [String] = []
            if changed > 0 { back.append("\(DeleteMarks.countOf(changed, "question")) \(changed == 1 ? "goes" : "go") back to your answer before it") }
            if unanswered > 0 { back.append("\(DeleteMarks.countOf(unanswered, "question")) \(unanswered == 1 ? "goes" : "go") back to not answered") }
            if !back.isEmpty { sentences.append("\(back.joined(separator: ", and ")).") }
            if let review = change(progress, "reviewCount"), review.before != review.after {
                sentences.append("Your Review list goes from \(review.before) to \(DeleteMarks.countOf(review.after, "question")).")
            }
            if let wrong = change(progress, "wrongCount"), wrong.before != wrong.after {
                sentences.append("Wrong questions go from \(wrong.before) to \(wrong.after).")
            }
        }
        sentences.append("You can undo this for \(DeleteMarks.undoDays) days.")
        return sentences.joined(separator: " ")
    }

    private static func change(_ progress: JSONValue, _ key: String) -> (before: Int, after: Int)? {
        guard let before = progress[key]?["before"]?.intValue, let after = progress[key]?["after"]?.intValue else { return nil }
        return (before, after)
    }
}
