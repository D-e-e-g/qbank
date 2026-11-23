import Foundation

/// Deleting an exam page (a study page, in a topic), and Undo. A delete marks only the page's own row
/// and hides nothing else: its folders keep naming it and read as on no page meanwhile, so they stay in
/// the course, and Undo puts them back on it.
enum PageDeleteRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/course-exams/:id/delete-preview", preview)
        router.delete("/api/course-exams/:id", delete)
        router.post("/api/course-exams/:id/undo-delete", undo)
    }

    /// What deleting one page takes: the page alone. Its folders are named, as they will show under Folders.
    private struct Plan {
        let page: PageRow
        /// Its folders, in the person's order.
        let folders: [FolderRow]
        /// The sentence refusing the delete now, or nil: a folder of its name is in the Folders list already.
        let refusal: String?
        let confirm: String
    }

    private static func planOf(_ tx: StoreTransaction, _ id: String) throws -> Plan {
        let page = try BankLookup.page(tx, id)
        let rows = try FolderOrder.rows(tx, courseID: page.courseId)
        let own = rows.filter { $0.courseExamId == page.id }
        let loose = rows.filter { $0.courseExamId == nil }
        var refusal: String?
        for folder in own {
            guard let clash = loose.first(where: { BankText.sameName($0.name, folder.name) }) else { continue }
            let course = try tx.rows("SELECT * FROM course WHERE id = ?", [.text(page.courseId)]).first.map(CourseRow.init)
            refusal = "\(course?.sentenceName ?? "This course") already has a folder named \(clash.name) in its Folders list. Rename one of them before deleting \(page.name)."
            break
        }
        return Plan(page: page, folders: own, refusal: refusal, confirm: DeleteMarks.token(["exam-page", page.id, page.name], own.map { "\($0.id):\($0.name)" }))
    }

    /// What deleting the page would take (the page alone), the warning to show, and the `confirm` that deletes exactly that.
    private static func preview(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try planOf(tx, try BankBody.pathID(call))
        let page = plan.page
        let inputs = try StandingRules.inputs(tx, courseID: page.courseId)
        let folderIDs = Set(plan.folders.map(\.id))
        let sets = try tx.rows("SELECT id, folder_id FROM practice_set WHERE course_id = ? AND is_current = 1 AND deleted_at IS NULL", [.text(page.courseId)])
            .filter { $0.text("folder_id").map(folderIDs.contains) ?? false }
        let own = inputs.questions.filter { $0.folderId.map(folderIDs.contains) ?? false }
        let pastExams = try pastExamCount(tx, courseID: page.courseId, pageID: page.id, pages: try livePages(tx, courseID: page.courseId), now: call.now)
        let folders = plan.folders.map { folder -> JSONValue in
            .object([
                "id": .string(folder.id), "name": .string(folder.name), "setCount": .int(sets.filter { $0.text("folder_id") == folder.id }.count),
                "questionCount": .int(own.filter { $0.folderId == folder.id }.count),
            ])
        }
        // Nothing she answered is in the page itself, so her standing is the same before and after.
        let standing = StandingRules.of(inputs.questions, inputs.progress)
        let text = warningText(page.name, folders: plan.folders.map(\.name), pastExams: pastExams)
        return .ok(
            .object([
                "examPageId": .string(page.id), "courseId": .string(page.courseId), "name": .string(page.name), "folders": .array(folders),
                "pastExamCount": .int(pastExams), "folderCount": .int(plan.folders.count), "setCount": .int(sets.count),
                "questionCount": .int(own.filter { $0.kind == "practice" }.count), "examQuestionCount": .int(own.filter { $0.kind == "exam" }.count),
                "answeredCount": .int(own.filter { inputs.progress[$0.lineageId] != nil }.count), "progress": StandingRules.change(standing, standing),
                "message": .string(text), "warning": DeleteMarks.warning(text, doomed: page.name), "refusal": .optional(plan.refusal),
                "confirm": .string(plan.confirm), "undoDays": .int(DeleteMarks.undoDays),
            ]))
    }

    /// Deletes an exam page, once the person has confirmed it. Only the page's own row is marked: no folder, set, question, answer or past
    /// exam is written. Without `confirm`, only a page with no folders goes. Refused while one of its folders has the name of a folder
    /// already in the Folders list, where they would show, or when it changed since the preview.
    private static func delete(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try planOf(tx, try BankBody.pathID(call))
        if let refusal = plan.refusal { throw BankRefusal.refused(409, refusal) }
        let confirm = call.query["confirm"]
        if confirm != nil || !plan.folders.isEmpty {
            let n = plan.folders.count
            let unconfirmed =
                "\(plan.page.name) still has \(DeleteMarks.countOf(n, "folder")). Deleting it puts \(n == 1 ? "that folder" : "them") under Folders, so look at what changes and confirm it first."
            try DeleteMarks.confirmed(confirm, expected: plan.confirm, name: plan.page.name, unconfirmed: unconfirmed)
        }
        try tx.execute(
            "UPDATE course_exam SET deleted_at = ?, deletion_id = ? WHERE id = ? AND deleted_at IS NULL", [.text(call.nowText), .text(call.newID()), .text(plan.page.id)])
        return BankAnswer(status: 204, body: nil)
    }

    /// Brings back an exam page deleted, as it was, within 30 days: in its place among the course's pages, with the folders still naming
    /// it back on it in their order. A folder put on another page meanwhile stays there. Answers the page.
    private static func undo(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let row = try deletedPage(tx, try BankBody.pathID(call))
        if let refusal = try undoRefusal(tx, row, now: call.now) { throw refusal }
        try tx.execute("UPDATE course_exam SET deleted_at = NULL, deletion_id = NULL WHERE id = ?", [.text(row.id)])
        return .ok(try PageViews.find(tx, courseID: row.courseId, id: row.id))
    }

    /// An exam page deleted.
    static func deletedPage(_ tx: StoreTransaction, _ id: String) throws -> PageRow {
        guard let row = try tx.rows("SELECT * FROM course_exam WHERE id = ?", [.text(id)]).first else { throw BankRefusal.refused(404, "That page is not in the app.") }
        let page = PageRow(row)
        if page.deletedAt == nil { throw BankRefusal.refused(409, "\(page.name) is not deleted.") }
        return page
    }

    /// Why Undo cannot bring this exam page back now, or nil: too late, or the course has a page of its name now.
    static func undoRefusal(_ tx: StoreTransaction, _ row: PageRow, now: Date) throws -> BankRefusal? {
        if DeleteMarks.expired(row.deletedAt, now: now) {
            return DeleteMarks.refusal(409, "undo_expired", "\(row.name) was deleted more than \(DeleteMarks.undoDays) days ago, so it can't be brought back.")
        }
        let pages = try FolderOrder.pages(tx, courseID: row.courseId).filter { $0.deletedAt == nil }
        guard let clash = pages.first(where: { BankText.sameName($0.name, row.name) }) else { return nil }
        return BankRefusal.refused(409, "This course already has a page named \(clash.name). Rename one of them, then bring this one back.")
    }

    private static func warningText(_ name: String, folders: [String], pastExams: Int) -> String {
        var sentences = ["Delete \(name)?"]
        if folders.isEmpty {
            sentences.append("It has no folders.")
        } else if folders.count == 1 {
            sentences.append("Its folder \(BankText.list(folders)) stays, with its sets and your progress, under Folders.")
        } else {
            sentences.append("Its \(folders.count) folders stay, with their sets and your progress, under Folders: \(BankText.list(folders)).")
        }
        if pastExams > 0 { sentences.append("Your \(DeleteMarks.countOf(pastExams, "past exam")) over it \(pastExams == 1 ? "stays" : "stay").") }
        sentences.append("You can undo this for \(DeleteMarks.undoDays) days.")
        return sentences.joined(separator: " ")
    }

    // MARK: Past exams over a page

    /// A page as Exam setup places past exams on it: its folders' ids and names.
    struct PlacedPage {
        let id: String
        let folderIDs: [String]
        let weekLabels: [String]
    }

    /// The course's pages not deleted, each with its folders in the person's order.
    static func livePages(_ tx: StoreTransaction, courseID: String) throws -> [PlacedPage] {
        try PageViews.pages(tx, courseID: courseID).map { PlacedPage(id: $0.row.id, folderIDs: $0.folders.map(\.id), weekLabels: $0.folders.map(\.name)) }
    }

    /// How many of her ended exams in the course, not deleted, belong to the page among `pages`, as Exam setup places them: by the
    /// folders each was over that are still in the course, or for an exam from before folders, by the weeks it was over.
    static func pastExamCount(_ tx: StoreTransaction, courseID: String, pageID: String, pages: [PlacedPage], now: Date) throws -> Int {
        let live = Set(try FolderOrder.rows(tx, courseID: courseID).map(\.id))
        return try PastExams.all(tx, courseID: courseID).filter { !AnswerRules.isOpen($0.row, now: now) }.filter { exam in
            if let ids = exam.folderIDs { return pageOf(folderIDs: ids.filter(live.contains), weeks: nil, pages) == pageID }
            return pageOf(folderIDs: nil, weeks: exam.weeks, pages) == pageID
        }.count
    }

    /// The page a sitting belongs to: the one holding every folder it was over. An exam from before folders names weeks instead. Nil when no page does.
    private static func pageOf(folderIDs: [String]?, weeks: [String]?, _ pages: [PlacedPage]) -> String? {
        if let folderIDs {
            if folderIDs.isEmpty { return nil }
            return pages.first { page in folderIDs.allSatisfy(page.folderIDs.contains) }?.id
        }
        let names = weeks ?? []
        if names.isEmpty { return nil }
        return pages.first { page in names.allSatisfy(page.weekLabels.contains) }?.id
    }
}

/// Her exams in a course, as a delete's warning reads them.
enum PastExams {
    struct Exam {
        let row: StoreRow
        /// The folders it was over, or nil for an exam from before folders.
        let folderIDs: [String]?
        let weeks: [String]?
    }

    /// Her exams in the course that are not deleted, running or ended.
    static func all(_ tx: StoreTransaction, courseID: String) throws -> [Exam] {
        try tx.rows("SELECT * FROM study_session WHERE course_id = ? AND mode = 'exam' AND deleted_at IS NULL", [.text(courseID)]).map { row in
            Exam(row: row, folderIDs: list(row.text("exam_folder_ids")), weeks: list(row.text("exam_weeks")))
        }
    }

    /// The exams still open in the course: running, or in their grace, with no end recorded.
    static func open(_ tx: StoreTransaction, courseID: String, now: Date) throws -> [StoreRow] {
        try tx.rows(
            "SELECT * FROM study_session WHERE course_id = ? AND mode = 'exam' AND finished_at IS NULL AND deleted_at IS NULL", [.text(courseID)]
        ).filter { AnswerRules.isOpen($0, now: now) }
    }

    /// How many of her exams in the course, not deleted, were over the folder.
    static func over(_ tx: StoreTransaction, courseID: String, folderID: String) throws -> Int {
        try all(tx, courseID: courseID).filter { $0.folderIDs?.contains(folderID) ?? false }.count
    }

    private static func list(_ text: String?) -> [String]? { text.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } }
}
