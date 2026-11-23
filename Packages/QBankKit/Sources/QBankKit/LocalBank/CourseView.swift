import Foundation

/// `GET /api/courses/{id}`: a course or topic with its folders, pages and the person's progress.
enum CourseView {
    static func load(_ tx: StoreTransaction, courseID: String) throws -> JSONValue {
        let course = try BankLookup.course(tx, courseID)
        let semester = try course.semesterId.map { try BankLookup.semester(tx, $0) }
        let content = try FolderContent.load(tx, courseID: courseID)
        let counts = try CatalogViews.counts(tx, courseID: courseID)[courseID] ?? CourseCounts()
        let pool = try examPool(tx, courseID: courseID, folders: content.folders.map(\.row))
        let weeks = content.weeks
        return .object([
            "id": .string(course.id), "kind": .string(course.kind), "code": .string(course.code), "title": .string(course.title),
            "archivedAt": .optional(course.archivedAt),
            "semester": semester.map { .object(["id": .string($0.id), "number": .int($0.number), "name": .string($0.name)]) } ?? .null,
            "questionCount": .int(content.currentSets.filter { $0.kind == "practice" }.reduce(0) { $0 + (content.questionCounts[$1.id] ?? 0) }),
            "examQuestionCount": .int(pool),
            "examTimeLimitSeconds": .int(examTimeLimitSeconds(poolSize: pool)),
            "weekCount": .int(weeks.filter { ($0["sets"]?.arrayValue?.isEmpty ?? true) == false }.count),
            "folderCount": .int(content.folders.count),
            "termCount": .int(try termCount(tx, courseID: courseID)),
            "reviewCount": .int(counts.reviewCount), "answeredCount": .int(counts.answeredCount), "fullyRightCount": .int(counts.fullyRightCount),
            "points": .int(counts.points), "maxPoints": .int(counts.maxPoints),
            "weeks": .array(weeks),
            "folders": .array(content.folders.map(\.json)),
            "exams": .array(try PageViews.list(tx, courseID: courseID)),
        ])
    }

    /// How many questions an exam over every folder draws from: each folder's exam bank, or its
    /// practice questions when it has none.
    private static func examPool(_ tx: StoreTransaction, courseID: String, folders: [FolderRow]) throws -> Int {
        let rows = try tx.rows(
            """
            SELECT ps.folder_id AS folder_id, ps.kind AS kind, count(q.id) AS n
            FROM practice_set ps JOIN question q ON q.set_id = ps.id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.folder_id IS NOT NULL
            GROUP BY ps.folder_id, ps.kind
            """, [.text(courseID)])
        let hasBank = Set(rows.filter { $0.string("kind") == "exam" }.map { $0.string("folder_id") })
        return folders.reduce(0) { total, folder in
            let source = hasBank.contains(folder.id) ? "exam" : "practice"
            return total + rows.filter { $0.string("folder_id") == folder.id && $0.string("kind") == source }.reduce(0) { $0 + $1.integer("n") }
        }
    }

    /// The time an exam over that many questions gets.
    static func examTimeLimitSeconds(poolSize: Int) -> Int { ExamPlanner.plan([ExamPlanner.Pool(label: "", questionCount: poolSize)]).timeLimitSeconds }

    /// The terms of the sets in force, each key once.
    private static func termCount(_ tx: StoreTransaction, courseID: String) throws -> Int {
        let value = try tx.value(
            """
            SELECT count(DISTINCT t.key) FROM term t JOIN practice_set ps ON ps.id = t.set_id JOIN folder f ON f.id = ps.folder_id
            WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice' AND f.deleted_at IS NULL
            """, [.text(courseID)])
        if case .integer(let count)? = value { return Int(count) }
        return 0
    }
}
