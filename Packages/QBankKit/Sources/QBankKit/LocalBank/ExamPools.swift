import Foundation

/// A current question of a course, as an exam's draw sees it.
struct PoolQuestion {
    let id: String
    let lineageId: String
    /// The folder its set is in: an exam over the folder draws from its sets.
    let folderId: String?
    let publicId: String
    /// For an exam-bank question, the public id of its practice twin.
    let twinOf: String?
    /// For an exam-bank question QBank wrote, the lineage of its practice twin.
    let twinOfLineageId: String?
    let kind: String
}

/// The latest answer to one question lineage.
struct LastAnswer {
    let status: String
    let answeredAt: String
}

/// What an exam over one folder draws from.
struct FolderPool {
    let folderId: String
    /// `exam` when the folder has an exam bank, which its exams use instead of its practice questions.
    let source: String
    /// Every question an exam over the folder can draw.
    var all: [String] = []
    /// The ones last answered not fully right: what a wrong-questions exam draws.
    var wrong: [String] = []

    func questions(_ pool: String) -> [String] { pool == "wrong" ? wrong : all }
}

/// The questions an exam draws from, as the server's pool reads them.
enum ExamPools {
    /// The course's current questions, practice and exam bank alike, of the sets that were not deleted.
    static func courseQuestions(_ tx: StoreTransaction, courseID: String) throws -> [PoolQuestion] {
        try tx.rows(
            """
            SELECT q.id, q.lineage_id, ps.folder_id, q.public_id, q.twin_of, q.twin_of_lineage_id, ps.kind
            FROM question q JOIN practice_set ps ON ps.id = q.set_id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL
            ORDER BY ps.id, q.position, q.id
            """, [.text(courseID)]
        ).map {
            PoolQuestion(
                id: $0.string("id"), lineageId: $0.string("lineage_id"), folderId: $0.text("folder_id"), publicId: $0.string("public_id"), twinOf: $0.text("twin_of"),
                twinOfLineageId: $0.text("twin_of_lineage_id"), kind: $0.string("kind"))
        }
    }

    /// The latest answer to each of these question lineages that has one.
    static func lastAnswers(_ tx: StoreTransaction, lineageIDs: [String]) throws -> [String: LastAnswer] {
        var answers: [String: LastAnswer] = [:]
        for chunk in Chunks.of(Array(Set(lineageIDs)).sorted()) {
            for row in try tx.rows(
                "SELECT question_lineage_id, last_status, last_answered_at FROM question_progress WHERE question_lineage_id IN \(Chunks.marks(chunk))",
                chunk.map(StoreValue.text))
            {
                answers[row.string("question_lineage_id")] = LastAnswer(status: row.string("last_status"), answeredAt: row.string("last_answered_at"))
            }
        }
        return answers
    }

    /// Each folder's exam pool, keyed by folder id: the questions of the sets in it. A folder with an
    /// exam bank draws only those questions; a folder without one draws its practice questions. A
    /// question whose set has no folder yet is in no pool.
    ///
    /// Wrong means the last answer was not fully right. An exam-bank question is also wrong while the
    /// last answer to its practice twin is not fully right, until the exam question is answered fully
    /// right after that answer. Without `answers`, nothing is wrong.
    static func folderPools(_ pool: [PoolQuestion], answers: [String: LastAnswer] = [:]) -> [String: FolderPool] {
        let twinOf = twinResolver(pool)
        let hasBank = Set(pool.compactMap { $0.kind == "exam" ? $0.folderId : nil })
        var folders: [String: FolderPool] = [:]
        for question in pool {
            guard let folderId = question.folderId else { continue }
            let source = hasBank.contains(folderId) ? "exam" : "practice"
            if question.kind != source { continue }
            var folder = folders[folderId] ?? FolderPool(folderId: folderId, source: source)
            folder.all.append(question.id)
            let wrong =
                question.kind == "exam"
                ? examQuestionWrong(own: answers[question.lineageId], twin: twinOf(question).flatMap { answers[$0.lineageId] }) : notFullyRight(answers[question.lineageId])
            if wrong { folder.wrong.append(question.id) }
            folders[folderId] = folder
        }
        return folders
    }

    private static func examQuestionWrong(own: LastAnswer?, twin: LastAnswer?) -> Bool {
        if notFullyRight(own) { return true }
        guard let twin, twin.status != "correct" else { return false }
        guard let own else { return true }
        guard let ownTime = ExamClock.milliseconds(own.answeredAt), let twinTime = ExamClock.milliseconds(twin.answeredAt) else { return false }
        return ownTime <= twinTime
    }

    /// Finds the practice question an exam question twins, among the pool's: the one practice question
    /// of the same folder whose lineage it names (QBank's own twins), and otherwise the one whose
    /// public id it names in `twinOf`. Ids repeat across folders and sometimes across sets, so a name
    /// that matches nothing in the folder, or more than one question, links to no twin.
    static func twinResolver(_ pool: [PoolQuestion]) -> (PoolQuestion) -> PoolQuestion? {
        var byPublicId: [String: [PoolQuestion]] = [:]
        var byLineage: [String: [PoolQuestion]] = [:]
        for question in pool where question.kind == "practice" && question.folderId != nil {
            byPublicId[question.publicId, default: []].append(question)
            byLineage[question.lineageId, default: []].append(question)
        }
        return { question in
            guard question.kind == "exam" else { return nil }
            let inFolder = { (found: [PoolQuestion]?) in (found ?? []).filter { $0.folderId == question.folderId } }
            let linked = question.twinOfLineageId.map { inFolder(byLineage[$0]) } ?? []
            if linked.count == 1 { return linked[0] }
            let named = question.twinOf.map { inFolder(byPublicId[$0]) } ?? []
            return named.count == 1 ? named[0] : nil
        }
    }

    /// True when this is the last answer and it was not fully right: what a wrong-questions exam asks again.
    static func notFullyRight(_ answer: LastAnswer?) -> Bool {
        answer.map { $0.status != "correct" } ?? false
    }
}
