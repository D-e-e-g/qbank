import Foundation

/// A course's numbers on its card: what is in it and how far the person has got.
struct CourseCounts {
    var questionCount = 0
    /// Legacy: how many folder names hold practice sets.
    var weekCount = 0
    var folderCount = 0
    var reviewCount = 0
    var answeredCount = 0
    var fullyRightCount = 0
    var points = 0
    var maxPoints = 0
}

/// The catalog as the screens read it: semesters with their courses, and the study topics.
enum CatalogViews {
    /// Every course's numbers. Practice questions of the sets in force (current, not deleted, in a
    /// folder that is not deleted); progress over those questions only.
    static func counts(_ tx: StoreTransaction) throws -> [String: CourseCounts] {
        var counts: [String: CourseCounts] = [:]
        for row in try tx.rows(
            """
            SELECT ps.course_id AS course_id, count(q.id) AS questions, count(DISTINCT f.name) AS weeks
            FROM practice_set ps JOIN folder f ON f.id = ps.folder_id LEFT JOIN question q ON q.set_id = ps.id
            WHERE ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice' AND f.deleted_at IS NULL
            GROUP BY ps.course_id
            """)
        {
            counts[row.string("course_id"), default: CourseCounts()].questionCount = row.integer("questions")
            counts[row.string("course_id"), default: CourseCounts()].weekCount = row.integer("weeks")
        }
        for row in try tx.rows("SELECT course_id, count(*) AS n FROM folder WHERE deleted_at IS NULL GROUP BY course_id") {
            counts[row.string("course_id"), default: CourseCounts()].folderCount = row.integer("n")
        }
        for row in try tx.rows(
            """
            SELECT ps.course_id AS course_id, count(*) AS answered,
                   sum(CASE WHEN qp.last_status = 'correct' THEN 1 ELSE 0 END) AS right_count,
                   sum(qp.in_review) AS in_review, sum(qp.last_points) AS points, sum(qp.last_max_points) AS max_points
            FROM question q JOIN practice_set ps ON ps.id = q.set_id
            JOIN question_progress qp ON qp.question_lineage_id = q.lineage_id
            WHERE ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice'
            GROUP BY ps.course_id
            """)
        {
            var entry = counts[row.string("course_id"), default: CourseCounts()]
            entry.answeredCount = row.integer("answered")
            entry.fullyRightCount = row.integer("right_count")
            entry.reviewCount = row.integer("in_review")
            entry.points = row.integer("points")
            entry.maxPoints = row.integer("max_points")
            counts[row.string("course_id")] = entry
        }
        return counts
    }

    static func card(_ course: CourseRow, _ counts: CourseCounts) -> JSONValue {
        .object([
            "id": .string(course.id), "kind": .string(course.kind), "code": .string(course.code), "title": .string(course.title),
            "sortOrder": .int(course.sortOrder), "archivedAt": .optional(course.archivedAt),
            "questionCount": .int(counts.questionCount), "weekCount": .int(counts.weekCount), "folderCount": .int(counts.folderCount),
            "reviewCount": .int(counts.reviewCount), "answeredCount": .int(counts.answeredCount), "fullyRightCount": .int(counts.fullyRightCount),
            "points": .int(counts.points), "maxPoints": .int(counts.maxPoints),
        ])
    }

    /// The card of a course or topic as the catalog lists it now.
    static func card(_ tx: StoreTransaction, courseID: String) throws -> JSONValue {
        let course = try BankLookup.course(tx, courseID)
        return card(course, try counts(tx)[courseID] ?? CourseCounts())
    }

    /// A card with nothing in it yet, for a course or topic just made.
    static func emptyCard(_ course: CourseRow) -> JSONValue { card(course, CourseCounts()) }

    /// The semesters with their courses (in order, courses by their sort order and code), and the topics.
    static func catalog(_ tx: StoreTransaction) throws -> (semesters: [JSONValue], topics: [JSONValue]) {
        let counts = try counts(tx)
        let courses = try tx.rows("SELECT * FROM course WHERE kind = 'course' AND deleted_at IS NULL ORDER BY sort_order, code").map(CourseRow.init)
        let topics = try tx.rows("SELECT * FROM course WHERE kind = 'topic' AND deleted_at IS NULL ORDER BY sort_order, title").map(CourseRow.init)
        let semesters = try tx.rows("SELECT * FROM semester ORDER BY number").map { row -> JSONValue in
            let semester = SemesterRow(row)
            let own = courses.filter { $0.semesterId == semester.id }.map { card($0, counts[$0.id] ?? CourseCounts()) }
            return record(semester, courses: own)
        }
        return (semesters, topics.map { card($0, counts[$0.id] ?? CourseCounts()) })
    }

    static func record(_ semester: SemesterRow, courses: [JSONValue]) -> JSONValue {
        .object([
            "id": .string(semester.id), "number": .int(semester.number), "name": .string(semester.name),
            "startsOn": .optional(semester.startsOn), "endsOn": .optional(semester.endsOn), "archivedAt": .optional(semester.archivedAt),
            "courses": .array(courses),
        ])
    }

    /// One semester as the catalog lists it now.
    static func semester(_ tx: StoreTransaction, id: String) throws -> JSONValue {
        let semester = try BankLookup.semester(tx, id)
        let counts = try counts(tx)
        let courses = try tx.rows("SELECT * FROM course WHERE kind = 'course' AND deleted_at IS NULL AND semester_id = ? ORDER BY sort_order, code", [.text(id)])
            .map(CourseRow.init).map { card($0, counts[$0.id] ?? CourseCounts()) }
        return record(semester, courses: courses)
    }
}
