import Foundation

/// A current question of a course with its set, as a delete's warning and an exam's draw see it.
struct StandingQuestion {
    let id: String
    let lineageId: String
    let setId: String
    /// The folder its set is in.
    let folderId: String?
    let publicId: String
    /// For an exam-bank question, the public id of its practice twin.
    let twinOf: String?
    /// For an exam-bank question QBank wrote, the lineage of its practice twin.
    let twinOfLineageId: String?
    /// `practice` or `exam`.
    let kind: String
}

/// The person's progress on one question lineage, as stored.
struct ProgressLine {
    let lastStatus: String
    let lastAnsweredAt: String
    let lastPoints: Int
    let lastMaxPoints: Int
    let inReview: Bool
}

/// Her standing in one course: what the course page and Exam setup count, so a delete's warning can say how it changes.
struct Standing: Equatable {
    var answeredCount = 0
    var fullyRightCount = 0
    var reviewCount = 0
    var points = 0
    var maxPoints = 0
    /// What a Wrong questions only exam over every folder draws from (Exam setup's `wrongCount`, added up).
    var wrongCount = 0
}

/// The standing of a course now and once a delete is done, as the server works it out.
enum StandingRules {
    /// The course's current questions of the sets not deleted (practice and exam bank alike), and the progress on them.
    static func inputs(_ tx: StoreTransaction, courseID: String) throws -> (questions: [StandingQuestion], progress: [String: ProgressLine]) {
        let questions = try tx.rows(
            """
            SELECT q.id AS id, q.lineage_id AS lineage_id, q.set_id AS set_id, ps.folder_id AS folder_id, q.public_id AS public_id,
                   q.twin_of AS twin_of, q.twin_of_lineage_id AS twin_of_lineage_id, ps.kind AS kind
            FROM question q JOIN practice_set ps ON ps.id = q.set_id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL
            ORDER BY ps.id, q.position, q.id
            """, [.text(courseID)]
        ).map {
            StandingQuestion(
                id: $0.string("id"), lineageId: $0.string("lineage_id"), setId: $0.string("set_id"), folderId: $0.text("folder_id"),
                publicId: $0.string("public_id"), twinOf: $0.text("twin_of"), twinOfLineageId: $0.text("twin_of_lineage_id"), kind: $0.string("kind"))
        }
        var progress: [String: ProgressLine] = [:]
        for row in try tx.rows(
            """
            SELECT qp.* FROM question_progress qp
            WHERE qp.question_lineage_id IN (
                SELECT q.lineage_id FROM question q JOIN practice_set ps ON ps.id = q.set_id
                WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL)
            """, [.text(courseID)])
        {
            progress[row.string("question_lineage_id")] = ProgressLine(
                lastStatus: row.string("last_status"), lastAnsweredAt: row.string("last_answered_at"), lastPoints: row.integer("last_points"),
                lastMaxPoints: row.integer("last_max_points"), inReview: row.flag("in_review"))
        }
        return (questions, progress)
    }

    /// Her standing over these questions: the course page's counts over the practice questions, and Exam setup's Wrong questions over every folder's exam pool.
    static func of(_ list: [StandingQuestion], _ progress: [String: ProgressLine]) -> Standing {
        var standing = Standing()
        for question in list where question.kind == "practice" {
            guard let row = progress[question.lineageId] else { continue }
            standing.answeredCount += 1
            standing.points += row.lastPoints
            standing.maxPoints += row.lastMaxPoints
            if row.lastStatus == "correct" { standing.fullyRightCount += 1 }
            if row.inReview { standing.reviewCount += 1 }
        }
        standing.wrongCount = wrongCount(list, progress)
        return standing
    }

    /// Each part of her standing now and once the delete is done, in the shape the previews carry.
    static func change(_ before: Standing, _ after: Standing) -> JSONValue {
        func pair(_ before: Int, _ after: Int) -> JSONValue { .object(["before": .int(before), "after": .int(after)]) }
        return .object([
            "answeredCount": pair(before.answeredCount, after.answeredCount), "fullyRightCount": pair(before.fullyRightCount, after.fullyRightCount),
            "reviewCount": pair(before.reviewCount, after.reviewCount), "points": pair(before.points, after.points),
            "maxPoints": pair(before.maxPoints, after.maxPoints), "wrongCount": pair(before.wrongCount, after.wrongCount),
        ])
    }

    // MARK: Wrong questions

    /// How many questions the folders' exam pools hold as wrong. A folder with an exam bank draws only those questions; a folder without
    /// one draws its practice questions; a question whose set has no folder is in no pool. Wrong means the last answer was not fully right.
    /// An exam-bank question is also wrong while the last answer to its practice twin is not fully right, until she answers the exam
    /// question fully right after that answer.
    private static func wrongCount(_ pool: [StandingQuestion], _ progress: [String: ProgressLine]) -> Int {
        let twin = twinResolver(pool)
        let hasBank = Set(pool.filter { $0.kind == "exam" }.compactMap(\.folderId))
        func notFullyRight(_ lineage: String) -> Bool { progress[lineage].map { $0.lastStatus != "correct" } ?? false }
        var wrong = 0
        for question in pool {
            guard let folder = question.folderId else { continue }
            let source = hasBank.contains(folder) ? "exam" : "practice"
            if question.kind != source { continue }
            if question.kind != "exam" {
                if notFullyRight(question.lineageId) { wrong += 1 }
                continue
            }
            if notFullyRight(question.lineageId) {
                wrong += 1
            } else if let twin = twin(question).flatMap({ progress[$0.lineageId] }), twin.lastStatus != "correct" {
                guard let own = progress[question.lineageId] else {
                    wrong += 1
                    continue
                }
                if time(own.lastAnsweredAt) <= time(twin.lastAnsweredAt) { wrong += 1 }
            }
        }
        return wrong
    }

    /// The practice question an exam question twins, among the pool's: the one practice question of the same folder whose lineage it
    /// names (QBank's own twins), and otherwise the one whose public id it names. Ids repeat across folders and sometimes across
    /// sets, so a name that matches nothing in the folder, or more than one question, links to no twin.
    private static func twinResolver(_ pool: [StandingQuestion]) -> (StandingQuestion) -> StandingQuestion? {
        var byPublicId: [String: [StandingQuestion]] = [:]
        var byLineage: [String: [StandingQuestion]] = [:]
        for question in pool where question.kind == "practice" && question.folderId != nil {
            byPublicId[question.publicId, default: []].append(question)
            byLineage[question.lineageId, default: []].append(question)
        }
        return { question in
            guard question.kind == "exam" else { return nil }
            func inFolder(_ found: [StandingQuestion]?) -> [StandingQuestion] { (found ?? []).filter { $0.folderId == question.folderId } }
            let linked = question.twinOfLineageId.map { inFolder(byLineage[$0]) } ?? []
            if linked.count == 1 { return linked[0] }
            let named = question.twinOf.map { inFolder(byPublicId[$0]) } ?? []
            return named.count == 1 ? named[0] : nil
        }
    }

    private static func time(_ text: String) -> Double { QBankJSON.parseDate(text)?.timeIntervalSince1970 ?? 0 }
}
