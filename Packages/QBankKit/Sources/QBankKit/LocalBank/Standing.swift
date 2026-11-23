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
        standing.wrongCount = ExamPools.folderPools(list, progress: progress).values.reduce(0) { $0 + $1.wrong.count }
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
}
