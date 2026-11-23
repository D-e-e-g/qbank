import Foundation

/// Deleting a set or a folder with every set in it, and Undo. A delete hides rows and never removes
/// one: it marks the set's every version (a folder: the folder and every version of its sets) with the
/// time and one delete id, every read leaves marked rows out, and Undo clears exactly that delete's
/// marks for 30 days. A deleted set's answers stay saved and count toward nothing while it is deleted,
/// because every count reads only the sets not deleted; Undo makes them count again as they were.
enum SetDeleteRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/practice-sets/:id/delete-preview", previewSet)
        router.delete("/api/practice-sets/:id", deleteSet)
        router.post("/api/practice-sets/:id/undo-delete", undoSet)
        router.get("/api/folders/:id/delete-preview", previewFolder)
        router.delete("/api/folders/:id", deleteFolder)
        router.post("/api/folders/:id/undo-delete", undoFolder)
    }

    // MARK: Sets

    /// What deleting one set takes: its every version, in its folder.
    private struct SetPlan {
        let set: SetRow
        let versions: [SetRow]
        let folder: FolderRow
        let confirm: String
    }

    private static func setPlan(_ tx: StoreTransaction, _ id: String) throws -> SetPlan {
        let set = try BankLookup.set(tx, id)
        if !set.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        guard let folderID = set.folderId else { throw BankRefusal.failed }
        let folder = try BankLookup.folder(tx, folderID)
        let versions = try tx.rows("SELECT * FROM practice_set WHERE lineage_id = ? AND deleted_at IS NULL", [.text(set.lineageId)]).map(SetRow.init)
        let confirm = DeleteMarks.token(["set", set.lineageId, set.id, set.title, folder.id], DeleteMarks.sorted(versions.map(\.id)))
        return SetPlan(set: set, versions: versions, folder: folder, confirm: confirm)
    }

    /// What deleting the set would take, the warning to show, and the `confirm` that deletes exactly that.
    private static func previewSet(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try setPlan(tx, try BankBody.pathID(call))
        let (set, folder) = (plan.set, plan.folder)
        let inputs = try StandingRules.inputs(tx, courseID: set.courseId)
        let gone = Set(plan.versions.map(\.id))
        let own = inputs.questions.filter { $0.setId == set.id }
        let answered = own.filter { inputs.progress[$0.lineageId] != nil }.count
        let review = own.filter { $0.kind == "practice" && inputs.progress[$0.lineageId]?.inReview == true }.count
        // An exam set is the folder's exam bank; without its last one, exams over the folder ask its practice questions.
        let lastBank = set.kind == "exam" && !inputs.questions.contains { $0.kind == "exam" && $0.folderId == folder.id && !gone.contains($0.setId) }
        let before = StandingRules.of(inputs.questions, inputs.progress)
        let after = StandingRules.of(inputs.questions.filter { !gone.contains($0.setId) }, inputs.progress)
        let message = setMessage(
            set, folder, questionCount: own.count, versionCount: plan.versions.count, answered: answered, review: review, lastBank: lastBank)
        return .ok(
            .object([
                "setId": .string(set.id), "title": .string(set.title), "kind": .string(set.kind), "folderId": .string(folder.id),
                "folderName": .string(folder.name), "examPageId": .optional(folder.courseExamId), "questionCount": .int(own.count),
                "versionCount": .int(plan.versions.count), "answeredCount": .int(answered), "reviewCount": .int(review),
                "progress": StandingRules.change(before, after), "message": .string(message),
                "warning": DeleteMarks.warning(message, doomed: set.title),
                "refusal": .optional(try inUse(tx, courseID: set.courseId, rows: plan.versions, folder: nil, now: call.now)),
                "confirm": .string(plan.confirm), "undoDays": .int(DeleteMarks.undoDays),
            ]))
    }

    /// Deletes a set, every version of it, once the person has confirmed what goes (the preview's `confirm`). Refused while an exam in
    /// progress uses it, or when it changed since the preview.
    private static func deleteSet(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try setPlan(tx, try BankBody.pathID(call))
        if let refusal = try inUse(tx, courseID: plan.set.courseId, rows: plan.versions, folder: nil, now: call.now) {
            throw DeleteMarks.refusal(409, "in_use", refusal)
        }
        try DeleteMarks.confirmed(call.query["confirm"], expected: plan.confirm, name: plan.set.title)
        try tx.execute(
            "UPDATE practice_set SET deleted_at = ?, deletion_id = ? WHERE lineage_id = ? AND deleted_at IS NULL",
            [.text(call.nowText), .text(call.newID()), .text(plan.set.lineageId)])
        return BankAnswer(status: 204, body: nil)
    }

    /// Brings back a set deleted on its own, every version as it was, within 30 days. Answers its folder.
    private static func undoSet(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let row = try deletedSet(tx, try BankBody.pathID(call))
        if let refusal = try setUndoRefusal(tx, row, now: call.now) { throw refusal }
        guard let deletionID = row.text("deletion_id"), let folderID = row.text("folder_id") else { throw BankRefusal.failed }
        try tx.execute("UPDATE practice_set SET deleted_at = NULL, deletion_id = NULL WHERE deletion_id = ?", [.text(deletionID)])
        return .ok(try FolderContent.view(tx, courseID: row.string("course_id"), folderID: folderID))
    }

    /// A set deleted, as Undo finds it by the id of any of its versions.
    private static func deletedSet(_ tx: StoreTransaction, _ id: String) throws -> StoreRow {
        guard let row = try tx.rows("SELECT * FROM practice_set WHERE id = ?", [.text(id)]).first else { throw BankRefusal.refused(404, "That set is not in the app.") }
        if row.text("deleted_at") == nil { throw BankRefusal.refused(409, "That set is not deleted.") }
        return row
    }

    /// Why Undo cannot bring this set back now, or nil: too late, it went with its folder, or its folder is deleted.
    static func setUndoRefusal(_ tx: StoreTransaction, _ row: StoreRow, now: Date) throws -> BankRefusal? {
        let title = try currentTitle(tx, row)
        if DeleteMarks.expired(row.text("deleted_at"), now: now) {
            return DeleteMarks.refusal(409, "undo_expired", "\(title) was deleted more than \(DeleteMarks.undoDays) days ago, so it can't be brought back.")
        }
        if let deletion = row.text("deletion_id"), let with = try tx.rows("SELECT name FROM folder WHERE deletion_id = ?", [.text(deletion)]).first {
            return BankRefusal.refused(409, "\(title) went with its folder \(with.string("name")). Bring the folder back to bring it back.")
        }
        if let folderID = row.text("folder_id"), let folder = try tx.rows("SELECT name, deleted_at FROM folder WHERE id = ?", [.text(folderID)]).first,
            folder.text("deleted_at") != nil
        {
            return BankRefusal.refused(409, "Its folder \(folder.string("name")) is deleted. Bring the folder back first.")
        }
        return nil
    }

    /// The title of the current version of a deleted set's lineage (a lineage always has one), or of the row itself.
    private static func currentTitle(_ tx: StoreTransaction, _ row: StoreRow) throws -> String {
        if row.flag("is_current") { return row.string("title") }
        let current = try tx.rows("SELECT title FROM practice_set WHERE lineage_id = ? AND is_current = 1", [.text(row.string("lineage_id"))]).first
        return current?.string("title") ?? row.string("title")
    }

    private static func setMessage(
        _ set: SetRow, _ folder: FolderRow, questionCount: Int, versionCount: Int, answered: Int, review: Int, lastBank: Bool
    ) -> String {
        let go = questionCount == 1 ? "goes" : "go"
        var sentences: [String] = []
        if set.kind == "exam" {
            sentences.append("Delete \(set.title) from \(folder.name)'s exam bank?")
            sentences.append(
                lastBank
                    ? "Its \(DeleteMarks.countOf(questionCount, "question")) \(go) with it, and exams over \(folder.name) go back to asking its practice questions."
                    : "Its \(DeleteMarks.countOf(questionCount, "question")) \(go) with it, and exams over \(folder.name) stop asking \(questionCount == 1 ? "it" : "them").")
            if answered > 0 { sentences.append("You have answered \(answered) of them on exams: those answers stop counting toward Wrong questions.") }
        } else {
            sentences.append("Delete \(set.title)?")
            let earlier = versionCount - 1
            let also = earlier > 0 ? ", and so \(earlier == 1 ? "does its earlier version" : "do its \(earlier) earlier versions")" : ""
            sentences.append("Its \(DeleteMarks.countOf(questionCount, "question")) \(go) with it\(also).")
            if answered > 0 {
                let leave = review > 0 ? ", and \(DeleteMarks.countOf(review, "question")) \(review == 1 ? "leaves" : "leave") your Review list" : ""
                sentences.append("You have answered \(answered) of them: those answers stop counting toward your progress\(leave).")
            }
        }
        sentences.append("You can undo this for \(DeleteMarks.undoDays) days.")
        return sentences.joined(separator: " ")
    }

    // MARK: Folders

    /// What deleting one folder takes: it and every version of its sets.
    private struct FolderPlan {
        let folder: FolderRow
        let pageName: String?
        /// Every version of every set in it that has not been deleted.
        let rows: [SetRow]
        /// Their current versions: practice sets, then exam sets, each by title.
        let current: [SetRow]
        let confirm: String
    }

    private static func folderPlan(_ tx: StoreTransaction, _ id: String) throws -> FolderPlan {
        let folder = try BankLookup.folder(tx, id)
        let rows = try tx.rows("SELECT * FROM practice_set WHERE folder_id = ? AND deleted_at IS NULL", [.text(id)]).map(SetRow.init)
        let current = rows.filter(\.isCurrent).sorted { a, b in
            a.kind == b.kind ? BankText.localeCompare(a.title, b.title) < 0 : a.kind == "practice"
        }
        let page = try folder.courseExamId.flatMap { try tx.rows("SELECT name FROM course_exam WHERE id = ? AND deleted_at IS NULL", [.text($0)]).first }
        let sets = DeleteMarks.sorted(rows.map { "\($0.id):\($0.isCurrent):\($0.title)" })
        let confirm = DeleteMarks.token(["folder", folder.id, folder.name, folder.courseExamId], sets)
        return FolderPlan(folder: folder, pageName: page?.string("name"), rows: rows, current: current, confirm: confirm)
    }

    /// What deleting the folder would take, the warning to show, and the `confirm` that deletes exactly that.
    private static func previewFolder(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try folderPlan(tx, try BankBody.pathID(call))
        let folder = plan.folder
        let inputs = try StandingRules.inputs(tx, courseID: folder.courseId)
        let gone = Set(plan.rows.map(\.id))
        let own = inputs.questions.filter { gone.contains($0.setId) }
        let sets = plan.current.map { set -> (set: SetRow, questions: Int, answered: Int) in
            let mine = inputs.questions.filter { $0.setId == set.id }
            return (set, mine.count, mine.filter { inputs.progress[$0.lineageId] != nil }.count)
        }
        let answered = own.filter { inputs.progress[$0.lineageId] != nil }.count
        let review = own.filter { $0.kind == "practice" && inputs.progress[$0.lineageId]?.inReview == true }.count
        let pastExams = try PastExams.over(tx, courseID: folder.courseId, folderID: folder.id)
        let before = StandingRules.of(inputs.questions, inputs.progress)
        let after = StandingRules.of(inputs.questions.filter { !gone.contains($0.setId) }, inputs.progress)
        let message = folderMessage(
            folder.name, plan.pageName, titles: sets.map(\.set.title), questions: own.count, answered: answered, review: review, pastExams: pastExams)
        return .ok(
            .object([
                "folderId": .string(folder.id), "name": .string(folder.name), "examPageId": .optional(folder.courseExamId),
                "examPageName": .optional(plan.pageName),
                "sets": .array(
                    sets.map {
                        .object([
                            "id": .string($0.set.id), "title": .string($0.set.title), "kind": .string($0.set.kind), "questionCount": .int($0.questions),
                            "answeredCount": .int($0.answered),
                        ])
                    }),
                "setCount": .int(sets.count), "questionCount": .int(own.count), "answeredCount": .int(answered), "reviewCount": .int(review),
                "pastExamCount": .int(pastExams), "progress": StandingRules.change(before, after), "message": .string(message),
                "warning": DeleteMarks.warning(message, doomed: folder.name),
                "refusal": .optional(try inUse(tx, courseID: folder.courseId, rows: plan.rows, folder: folder, now: call.now)),
                "confirm": .string(plan.confirm), "undoDays": .int(DeleteMarks.undoDays),
            ]))
    }

    /// Deletes a folder and every version of its sets, once the person has confirmed what goes. Without `confirm`, only a folder that holds no set goes.
    private static func deleteFolder(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let plan = try folderPlan(tx, try BankBody.pathID(call))
        let confirm = call.query["confirm"]
        if let refusal = try inUse(tx, courseID: plan.folder.courseId, rows: plan.rows, folder: plan.folder, now: call.now) {
            throw DeleteMarks.refusal(409, "in_use", refusal)
        }
        if confirm != nil || !plan.rows.isEmpty {
            let sets = plan.current.count
            let unconfirmed =
                "\(plan.folder.name) still has \(DeleteMarks.countOf(sets, "set")). Deleting it deletes \(sets == 1 ? "that set" : "them") too, so look at what goes and confirm it first."
            try DeleteMarks.confirmed(confirm, expected: plan.confirm, name: plan.folder.name, unconfirmed: unconfirmed)
        }
        let (at, deletion) = (StoreValue.text(call.nowText), StoreValue.text(call.newID()))
        try tx.execute("UPDATE folder SET deleted_at = ?, deletion_id = ? WHERE id = ?", [at, deletion, .text(plan.folder.id)])
        for row in plan.rows { try tx.execute("UPDATE practice_set SET deleted_at = ?, deletion_id = ? WHERE id = ?", [at, deletion, .text(row.id)]) }
        return BankAnswer(status: 204, body: nil)
    }

    /// Brings back a folder deleted and the sets that went with it, as they were, within 30 days: on its page if that page is still there,
    /// else in the course's Folders list. Answers the folder.
    private static func undoFolder(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let id = try BankBody.pathID(call)
        let row = try deletedFolder(tx, id)
        if let refusal = try folderUndoRefusal(tx, row, now: call.now) { throw refusal }
        guard let deletionID = try tx.rows("SELECT deletion_id FROM folder WHERE id = ?", [.text(id)]).first?.text("deletion_id") else { throw BankRefusal.failed }
        try tx.execute("UPDATE folder SET deleted_at = NULL, deletion_id = NULL WHERE id = ?", [.text(id)])
        try tx.execute("UPDATE practice_set SET deleted_at = NULL, deletion_id = NULL WHERE deletion_id = ?", [.text(deletionID)])
        return .ok(try FolderContent.view(tx, courseID: row.courseId, folderID: id))
    }

    /// A folder deleted, as reads show it: on no page while its page is deleted too.
    static func deletedFolder(_ tx: StoreTransaction, _ id: String) throws -> FolderRow {
        guard let stored = try tx.rows("SELECT * FROM folder WHERE id = ?", [.text(id)]).first else { throw BankRefusal.refused(404, "That folder is not in the app.") }
        if stored.text("deleted_at") == nil { throw BankRefusal.refused(409, "That folder is not deleted.") }
        return try listed(tx, stored)
    }

    /// A folder row as every read shows it: on no page while its page is deleted.
    static func listed(_ tx: StoreTransaction, _ stored: StoreRow) throws -> FolderRow {
        var row = FolderRow(stored)
        if let page = row.courseExamId, try tx.rows("SELECT id FROM course_exam WHERE id = ? AND deleted_at IS NULL", [.text(page)]).isEmpty { row.courseExamId = nil }
        return row
    }

    /// Why Undo cannot bring this folder back now, or nil: too late, or its list has a folder of its name now.
    static func folderUndoRefusal(_ tx: StoreTransaction, _ row: FolderRow, now: Date) throws -> BankRefusal? {
        if DeleteMarks.expired(row.deletedAt, now: now) {
            return DeleteMarks.refusal(409, "undo_expired", "\(row.name) was deleted more than \(DeleteMarks.undoDays) days ago, so it can't be brought back.")
        }
        let list = try FolderOrder.rows(tx, courseID: row.courseId).filter { $0.courseExamId == row.courseExamId }
        guard let clash = list.first(where: { BankText.sameName($0.name, row.name) }) else { return nil }
        let page = try row.courseExamId.flatMap { try tx.rows("SELECT name FROM course_exam WHERE id = ? AND deleted_at IS NULL", [.text($0)]).first }
        let course = try tx.rows("SELECT * FROM course WHERE id = ?", [.text(row.courseId)]).first.map(CourseRow.init)
        let label = page?.string("name") ?? course?.sentenceName ?? "This course"
        return BankRefusal.refused(409, "\(label) already has a folder named \(clash.name). Rename one of them, then bring this one back.")
    }

    private static func folderMessage(_ name: String, _ page: String?, titles: [String], questions: Int, answered: Int, review: Int, pastExams: Int) -> String {
        var sentences = ["Delete \(name)?"]
        if titles.isEmpty {
            sentences.append("It has no sets.")
        } else {
            let count = titles.count
            sentences.append(
                "\(count == 1 ? "Its set goes" : "Its \(count) sets go") with it: \(BankText.list(titles)), \(DeleteMarks.countOf(questions, "question")) in all.")
            if answered > 0 {
                let leave = review > 0 ? ", and \(DeleteMarks.countOf(review, "question")) \(review == 1 ? "leaves" : "leave") your Review list" : ""
                sentences.append("You have answered \(answered) of them: those answers stop counting toward your progress\(leave).")
            }
        }
        if let page { sentences.append("It comes off \(page).") }
        if pastExams > 0 { sentences.append("Your \(DeleteMarks.countOf(pastExams, "past exam")) over it \(pastExams == 1 ? "stays" : "stay").") }
        sentences.append("You can undo this for \(DeleteMarks.undoDays) days.")
        return sentences.joined(separator: " ")
    }

    // MARK: In use

    /// The sentence refusing to delete these sets now, or nil: an exam in progress that asks their questions finishes first. `folder`
    /// names the folder being deleted, when it is one.
    private static func inUse(_ tx: StoreTransaction, courseID: String, rows: [SetRow], folder: FolderRow?, now: Date) throws -> String? {
        let setIDs = Set(rows.map(\.id))
        if setIDs.isEmpty { return nil }
        func title(of setID: String) -> String {
            let row = rows.first { $0.id == setID }
            return rows.first { $0.lineageId == row?.lineageId && $0.isCurrent }?.title ?? row?.title ?? ""
        }
        var asked = Set<String>()
        for exam in try PastExams.open(tx, courseID: courseID, now: now) {
            asked.formUnion((exam.text("question_ids").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []).filter(DeleteMarks.isUUID))
        }
        if asked.isEmpty { return nil }
        let ids = setIDs.sorted()
        let hit = try tx.rows("SELECT id, set_id FROM question WHERE set_id IN (\(DeleteMarks.placeholders(ids.count))) ORDER BY set_id, position, id", ids.map { .text($0) })
            .first { asked.contains($0.string("id")) }
        guard let hit else { return nil }
        return "An exam in progress asks questions from \(folder?.name ?? title(of: hit.string("set_id"))). Finish or leave that exam first."
    }
}
