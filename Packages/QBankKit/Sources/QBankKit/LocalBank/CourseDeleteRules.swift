import Foundation

/// Deleting a course or study topic, and Undo. A delete marks only the course's own row: every read
/// reaches what is in it through the course, so all of it is hidden at once, and Undo brings it back whole.
enum CourseDeleteRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/courses/:id/delete-preview", preview)
        router.delete("/api/courses/:id", delete)
        router.post("/api/courses/:id/undo-delete", undo)
        router.get("/api/deleted-courses", deletedCourses)
    }

    /// What deleting one course takes: it, and the folders and set versions in it that have not been deleted.
    private struct Plan {
        let course: CourseRow
        let folderIDs: [String]
        let pageCount: Int
        let rows: [SetRow]
        let confirm: String
    }

    private static func planOf(_ tx: StoreTransaction, _ id: String) throws -> Plan {
        let course = try BankLookup.course(tx, id)
        let folderIDs = try tx.rows("SELECT id FROM folder WHERE course_id = ? AND deleted_at IS NULL", [.text(id)]).map { $0.string("id") }
        let pageCount = try tx.rows("SELECT count(*) AS n FROM course_exam WHERE course_id = ? AND deleted_at IS NULL", [.text(id)]).first?.integer("n") ?? 0
        let rows = try tx.rows("SELECT * FROM practice_set WHERE course_id = ? AND deleted_at IS NULL", [.text(id)]).map(SetRow.init)
        let sets = DeleteMarks.sorted(rows.map { "\($0.id):\($0.isCurrent):\($0.title)" })
        let confirm = DeleteMarks.token(["course", course.id, course.kind, course.code, course.title], DeleteMarks.sorted(folderIDs) + sets)
        return Plan(course: course, folderIDs: folderIDs, pageCount: pageCount, rows: rows, confirm: confirm)
    }

    /// What deleting the course or topic would take, the warning to show, and the `confirm` that deletes exactly that.
    private static func preview(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try planOf(tx, try BankBody.pathID(call))
        let course = plan.course
        let inputs = try StandingRules.inputs(tx, courseID: course.id)
        let standing = StandingRules.of(inputs.questions, inputs.progress)
        let questions = inputs.questions.filter { $0.kind == "practice" }.count
        let pastExams = try PastExams.all(tx, courseID: course.id).count
        let name = course.sentenceName
        let message = "Delete \(questions == 0 ? name : "\(name) and its \(DeleteMarks.countOf(questions, "question"))")? You can bring it back for \(DeleteMarks.undoDays) days."
        return .ok(
            .object([
                "courseId": .string(course.id), "kind": .string(course.kind), "code": .string(course.code), "title": .string(course.title),
                "semester": try semester(tx, course), "folderCount": .int(plan.folderIDs.count), "examPageCount": .int(plan.pageCount),
                "setCount": .int(plan.rows.filter(\.isCurrent).count), "questionCount": .int(questions),
                "examQuestionCount": .int(inputs.questions.count - questions), "answeredCount": .int(standing.answeredCount),
                "reviewCount": .int(standing.reviewCount), "pastExamCount": .int(pastExams), "message": .string(message),
                "warning": DeleteMarks.warning(message, doomed: name), "refusal": .optional(try inUse(tx, course, now: call.now)),
                "confirm": .string(plan.confirm), "undoDays": .int(DeleteMarks.undoDays),
            ]))
    }

    /// Deletes a course or topic, once the person has confirmed what goes. Only its own row is marked: its folders, pages, sets, answers
    /// and past exams are not written, and are hidden because the course is. Refused while an exam in it is in progress, or when it
    /// changed since the preview.
    private static func delete(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try planOf(tx, try BankBody.pathID(call))
        if let refusal = try inUse(tx, plan.course, now: call.now) { throw DeleteMarks.refusal(409, "in_use", refusal) }
        try DeleteMarks.confirmed(call.query["confirm"], expected: plan.confirm, name: plan.course.sentenceName)
        try tx.execute(
            "UPDATE course SET deleted_at = ?, deletion_id = ? WHERE id = ? AND deleted_at IS NULL", [.text(call.nowText), .text(call.newID()), .text(plan.course.id)])
        return BankAnswer(status: 204, body: nil)
    }

    /// Brings back a course or topic deleted, whole, within 30 days. Answers its card.
    private static func undo(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let row = try deletedCourse(tx, try BankBody.pathID(call))
        if let refusal = try undoRefusal(tx, row, now: call.now) { throw refusal }
        try tx.execute("UPDATE course SET deleted_at = NULL, deletion_id = NULL WHERE id = ?", [.text(row.id)])
        return .ok(try CatalogViews.card(tx, courseID: row.id))
    }

    /// The courses and topics deleted in the last 30 days, newest first: what Undo can bring back.
    private static func deletedCourses(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let rows = try tx.rows("SELECT * FROM course WHERE deleted_at IS NOT NULL AND deleted_at > ?", [.text(DeleteMarks.since(call.now))])
            .map(CourseRow.init).sorted { a, b in
                if a.deletedAt != b.deletedAt { return (a.deletedAt ?? "") > (b.deletedAt ?? "") }
                return BankText.localeCompare(a.title, b.title) < 0
            }
        var list: [JSONValue] = []
        for row in rows {
            let questions =
                try tx.rows(
                    """
                    SELECT count(*) AS n FROM question q JOIN practice_set ps ON ps.id = q.set_id
                    WHERE ps.course_id = ? AND ps.is_current = 1 AND ps.deleted_at IS NULL AND ps.kind = 'practice'
                    """, [.text(row.id)]
                ).first?.integer("n") ?? 0
            let deletedAt = row.deletedAt ?? ""
            list.append(
                .object([
                    "id": .string(row.id), "kind": .string(row.kind), "code": .string(row.code), "title": .string(row.title),
                    "semester": try semester(tx, row), "questionCount": .int(questions), "deletedAt": .string(deletedAt),
                    "undoUntil": .string(DeleteMarks.undoUntil(deletedAt)), "undoRefusal": .optional(try undoRefusal(tx, row, now: call.now)?.message),
                    "deletedByAgent": .null,
                ]))
        }
        return .ok(.object(["undoDays": .int(DeleteMarks.undoDays), "courses": .array(list)]))
    }

    /// A course or topic deleted.
    private static func deletedCourse(_ tx: StoreTransaction, _ id: String) throws -> CourseRow {
        guard let row = try tx.rows("SELECT * FROM course WHERE id = ?", [.text(id)]).first else { throw BankRefusal.refused(404, "That course is not in the app.") }
        let course = CourseRow(row)
        if course.deletedAt == nil { throw BankRefusal.refused(409, "\(course.sentenceName) is not deleted.") }
        return course
    }

    /// Why Undo cannot bring this course back now, or nil: too late, or its code or name is taken now.
    static func undoRefusal(_ tx: StoreTransaction, _ row: CourseRow, now: Date) throws -> BankRefusal? {
        let name = row.sentenceName
        if DeleteMarks.expired(row.deletedAt, now: now) {
            return DeleteMarks.refusal(409, "undo_expired", "\(name) was deleted more than \(DeleteMarks.undoDays) days ago, so it can't be brought back.")
        }
        if row.kind == "topic" {
            let topics = try tx.rows("SELECT title FROM course WHERE kind = 'topic' AND deleted_at IS NULL").map { $0.string("title") }
            guard let clash = topics.first(where: { BankText.sameName($0, row.title) }) else { return nil }
            return BankRefusal.refused(409, "You already have a topic named \(clash). Rename one of them, then bring this one back.")
        }
        guard let semesterID = row.semesterId else { return nil }
        let clash = try tx.rows(
            "SELECT c.code AS code, s.name AS semester FROM course c JOIN semester s ON s.id = c.semester_id WHERE c.semester_id = ? AND c.deleted_at IS NULL",
            [.text(semesterID)]
        ).first { BankText.sameName($0.string("code"), row.code) }
        guard let clash else { return nil }
        return BankRefusal.refused(409, "\(clash.string("semester")) already has a course with the code \(clash.string("code")). Rename one of them, then bring this one back.")
    }

    /// The sentence refusing to delete the course now, or nil: an exam in progress in it finishes first.
    private static func inUse(_ tx: StoreTransaction, _ course: CourseRow, now: Date) throws -> String? {
        try PastExams.open(tx, courseID: course.id, now: now).isEmpty ? nil : "An exam in \(course.sentenceName) is still going. Finish or leave that exam first."
    }

    /// A course's semester as a delete names it: its id, number and name. Nil for a topic.
    static func semester(_ tx: StoreTransaction, _ course: CourseRow) throws -> JSONValue {
        guard let id = course.semesterId, let row = try tx.rows("SELECT * FROM semester WHERE id = ?", [.text(id)]).first else { return .null }
        let semester = SemesterRow(row)
        return .object(["id": .string(semester.id), "number": .int(semester.number), "name": .string(semester.name)])
    }
}
