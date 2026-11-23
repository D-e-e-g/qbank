import Foundation

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
    /// Each folder's exam pool, keyed by folder id: the questions of the sets in it. A folder with an
    /// exam bank draws only those questions; a folder without one draws its practice questions. A
    /// question whose set has no folder yet is in no pool.
    ///
    /// Wrong means the last answer was not fully right. An exam-bank question is also wrong while the
    /// last answer to its practice twin is not fully right, until the exam question is answered fully
    /// right after that answer. Without `progress`, nothing is wrong. This is the one place the pools and Wrong questions are worked out:
    /// the course's counts and every delete's warning take their wrong count from it.
    static func folderPools(_ pool: [StandingQuestion], progress: [String: ProgressLine] = [:]) -> [String: FolderPool] {
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
                ? examQuestionWrong(own: progress[question.lineageId], twin: twinOf(question).flatMap { progress[$0.lineageId] }) : notFullyRight(progress[question.lineageId])
            if wrong { folder.wrong.append(question.id) }
            folders[folderId] = folder
        }
        return folders
    }

    private static func examQuestionWrong(own: ProgressLine?, twin: ProgressLine?) -> Bool {
        if notFullyRight(own) { return true }
        guard let twin, twin.lastStatus != "correct" else { return false }
        guard let own else { return true }
        guard let ownTime = ExamClock.milliseconds(own.lastAnsweredAt), let twinTime = ExamClock.milliseconds(twin.lastAnsweredAt) else { return false }
        return ownTime <= twinTime
    }

    /// Finds the practice question an exam question twins, among the pool's: the one practice question
    /// of the same folder whose lineage it names (QBank's own twins), and otherwise the one whose
    /// public id it names in `twinOf`. Ids repeat across folders and sometimes across sets, so a name
    /// that matches nothing in the folder, or more than one question, links to no twin.
    private static func twinResolver(_ pool: [StandingQuestion]) -> (StandingQuestion) -> StandingQuestion? {
        var byPublicId: [String: [StandingQuestion]] = [:]
        var byLineage: [String: [StandingQuestion]] = [:]
        for question in pool where question.kind == "practice" && question.folderId != nil {
            byPublicId[question.publicId, default: []].append(question)
            byLineage[question.lineageId, default: []].append(question)
        }
        return { question in
            guard question.kind == "exam" else { return nil }
            let inFolder = { (found: [StandingQuestion]?) in (found ?? []).filter { $0.folderId == question.folderId } }
            let linked = question.twinOfLineageId.map { inFolder(byLineage[$0]) } ?? []
            if linked.count == 1 { return linked[0] }
            let named = question.twinOf.map { inFolder(byPublicId[$0]) } ?? []
            return named.count == 1 ? named[0] : nil
        }
    }

    /// True when this is the last answer and it was not fully right: what a wrong-questions exam asks again.
    private static func notFullyRight(_ answer: ProgressLine?) -> Bool {
        answer.map { $0.lastStatus != "correct" } ?? false
    }
}
