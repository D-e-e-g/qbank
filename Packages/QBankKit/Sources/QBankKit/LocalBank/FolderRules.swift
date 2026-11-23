import Foundation

/// The rule family for a course's folders: making, renaming, putting on a page, moving a set to
/// one, and ordering. A folder is a row with its own id, so two pages can each have a First Pass,
/// a rename is one update, and every version of a set stays in its folder.
enum FolderRules {
    static func register(in router: inout BankRouter) {
        router.post("/api/courses/:id/folders", createFolder)
        router.patch("/api/folders/:id", updateFolder)
        router.post("/api/practice-sets/:id/move", moveSet)
        router.put("/api/courses/:id/folder-order", orderFolders)
    }

    /// Makes an empty folder at the end of its list: the page's, or the course's Folders list.
    private static func createFolder(_ call: BankCall) throws -> BankAnswer {
        let courseID = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let nameText = try body.string("name")
        let pageID = try body.nullableUUID("examPageId")
        let tx = call.tx
        let course = try BankLookup.course(tx, courseID)
        let name = try BankText.required(nameText, "Folder name", 80)
        let page: PageRow? = if case .value(let id) = pageID { try pageOf(tx, courseID, id) } else { nil }
        let list = try FolderOrder.rows(tx, courseID: courseID).filter { $0.courseExamId == page?.id }
        try assertNameFree(list, name, label(course, page), except: nil)
        let id = call.newID()
        try tx.execute(
            "INSERT INTO folder (id, course_id, name, course_exam_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id), .text(courseID), .text(name), .optional(page?.id), .integer(Int64(endOf(list))), .text(call.nowText)])
        return .created(try FolderContent.view(tx, courseID: courseID, folderID: id))
    }

    /// Renames a folder, puts it on a page or takes it off one. A rename changes the one name, so
    /// every version of its sets, past exams over it, and its page follow. A folder that changes
    /// list goes to the end of its new list.
    private static func updateFolder(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let newName = try body.optionalString("name")
        let newPage = try body.nullableUUID("examPageId")
        let tx = call.tx
        let current = try BankLookup.folder(tx, id)
        let course = try BankLookup.course(tx, current.courseId)
        let rows = try FolderOrder.rows(tx, courseID: current.courseId)
        let folder = rows.first { $0.id == id } ?? current
        let name = try newName.map { try BankText.required($0, "Folder name", 80) } ?? folder.name
        let pageID: String? =
            switch newPage {
            case .absent: folder.courseExamId
            case .null: nil
            case .value(let value): value
            }
        let page = try pageID.map { try pageOf(tx, current.courseId, $0) }
        let list = rows.filter { $0.courseExamId == page?.id }
        try assertNameFree(list, name, label(course, page), except: id)
        let moved = folder.courseExamId != page?.id
        if name != folder.name {
            try pinPastExams(tx, courseID: current.courseId, oldName: folder.name)
            try renameLabels(tx, folderID: id, from: folder.name, to: name)
        }
        if moved {
            try tx.execute(
                "UPDATE folder SET name = ?, course_exam_id = ?, sort_order = ? WHERE id = ?",
                [.text(name), .optional(page?.id), .integer(Int64(endOf(list))), .text(id)])
        } else {
            try tx.execute("UPDATE folder SET name = ? WHERE id = ?", [.text(name), .text(id)])
        }
        return .ok(try FolderContent.view(tx, courseID: current.courseId, folderID: id))
    }

    /// Moves a set, every version of it, to a folder of its course or to a new folder at the end
    /// of the Folders list. Answers and progress follow the set. Answers the folder it is in now.
    private static func moveSet(_ call: BankCall) throws -> BankAnswer {
        let setID = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let folderID = try body.optionalUUID("folderId")
        let newName = try body.optionalString("newFolderName")
        let tx = call.tx
        let set = try BankLookup.set(tx, setID)
        if !set.isCurrent { throw BankRefusal.refused(404, "That set is not the current version.") }
        if folderID != nil && newName != nil { throw BankRefusal.refused(400, "Choose a folder or a new folder name, not both.") }
        if folderID == nil && newName == nil { throw BankRefusal.refused(400, "Choose a folder to move it to.") }
        let course = try BankLookup.course(tx, set.courseId)
        let rows = try FolderOrder.rows(tx, courseID: set.courseId)
        let target: FolderRow
        if let folderID {
            guard let found = rows.first(where: { $0.id == folderID }) else { throw BankRefusal.refused(400, "That folder is not in this course.") }
            target = found
        } else {
            let name = try BankText.required(newName ?? "", "Folder name", 80)
            let loose = rows.filter { $0.courseExamId == nil }
            try assertNameFree(loose, name, label(course, nil), except: nil)
            let id = call.newID()
            try tx.execute(
                "INSERT INTO folder (id, course_id, name, course_exam_id, sort_order, created_at) VALUES (?, ?, ?, NULL, ?, ?)",
                [.text(id), .text(course.id), .text(name), .integer(Int64(endOf(loose))), .text(call.nowText)])
            target = try BankLookup.folder(tx, id)
        }
        try fileLineage(tx, lineageID: set.lineageId, into: target)
        return .ok(try FolderContent.view(tx, courseID: set.courseId, folderID: target.id))
    }

    /// Saves the order of one list of folders (a page's, or the Folders list with a null page) and answers that list.
    private static func orderFolders(_ call: BankCall) throws -> BankAnswer {
        let courseID = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let pageID = try body.requiredNullableUUID("examPageId")
        let ids = try body.uuids("folderIds", max: 500)
        let tx = call.tx
        _ = try BankLookup.course(tx, courseID)
        if let pageID { _ = try pageOf(tx, courseID, pageID) }
        let list = try FolderOrder.rows(tx, courseID: courseID).filter { $0.courseExamId == pageID }
        let held = Set(list.map(\.id))
        let sent = Set(ids)
        if sent.count != ids.count || sent.count != held.count || !ids.allSatisfy(held.contains) {
            throw BankRefusal.refused(409, "The folders changed since this list was shown. Reload and try again.")
        }
        for (index, id) in ids.enumerated() {
            try tx.execute("UPDATE folder SET sort_order = ? WHERE id = ?", [.integer(Int64(index + 1)), .text(id)])
        }
        let views = try FolderContent.load(tx, courseID: courseID).folders
        return .ok(.object(["folders": .array(ids.flatMap { id in views.filter { $0.row.id == id }.map(\.json) })]))
    }

    // MARK: Rules shared with pages

    /// A page of the course that has not been deleted, for a folder to go on.
    static func pageOf(_ tx: StoreTransaction, _ courseID: String, _ id: String) throws -> PageRow {
        guard let row = try tx.rows("SELECT * FROM course_exam WHERE id = ? AND course_id = ? AND deleted_at IS NULL", [.text(id), .text(courseID)]).first else {
            throw BankRefusal.refused(400, "That page is not in this course.")
        }
        return PageRow(row)
    }

    /// Refuses a name another folder of the list already has, ignoring case.
    static func assertNameFree(_ list: [FolderRow], _ name: String, _ label: String, except id: String?) throws {
        if let clash = list.first(where: { $0.id != id && BankText.sameName($0.name, name) }) {
            throw BankRefusal.refused(409, "\(label) already has a folder named \(clash.name).")
        }
    }

    /// A list as a refusal names it: the page, or the course for its Folders list.
    static func label(_ course: CourseRow, _ page: PageRow?) -> String { page?.name ?? course.sentenceName }

    static func endOf(_ list: [FolderRow]) -> Int { (list.map(\.sortOrder).max() ?? 0) + 1 }

    // MARK: Legacy labels

    /// Puts every version of a set in the folder. Each version's week label becomes the folder's
    /// name, and so does the week of each of its questions that carried the set's.
    private static func fileLineage(_ tx: StoreTransaction, lineageID: String, into folder: FolderRow) throws {
        for version in try tx.rows("SELECT * FROM practice_set WHERE lineage_id = ?", [.text(lineageID)]).map(SetRow.init) where version.weekLabel != folder.name {
            try tx.execute("UPDATE question SET week_label = ? WHERE set_id = ? AND week_label = ?", [.text(folder.name), .text(version.id), .text(version.weekLabel)])
        }
        try tx.execute("UPDATE practice_set SET folder_id = ?, week_label = ? WHERE lineage_id = ?", [.text(folder.id), .text(folder.name), .text(lineageID)])
    }

    /// A rename's legacy labels: every version of the folder's sets, and their questions that carried the old name.
    private static func renameLabels(_ tx: StoreTransaction, folderID: String, from: String, to: String) throws {
        for set in try tx.rows("SELECT id FROM practice_set WHERE folder_id = ?", [.text(folderID)]) {
            let id = StoreValue.text(set.string("id"))
            try tx.execute("UPDATE practice_set SET week_label = ? WHERE id = ?", [.text(to), id])
            try tx.execute("UPDATE question SET week_label = ? WHERE set_id = ? AND week_label = ?", [.text(to), id, .text(from)])
        }
    }

    /// Before a rename: exams from before folders name weeks, not folders, so the ones over this
    /// name are pinned to the folders their weeks name now, and keep their page after it.
    private static func pinPastExams(_ tx: StoreTransaction, courseID: String, oldName: String) throws {
        let sittings = try tx.rows(
            "SELECT id, exam_weeks FROM study_session WHERE course_id = ? AND mode = 'exam' AND exam_folder_ids IS NULL AND exam_weeks IS NOT NULL", [.text(courseID)]
        ).compactMap { row -> (id: String, weeks: [String])? in
            guard let weeks = try? JSONDecoder().decode([String].self, from: Data(row.string("exam_weeks").utf8)), weeks.contains(oldName) else { return nil }
            return (row.string("id"), weeks)
        }
        if sittings.isEmpty { return }
        let rows = try FolderOrder.rows(tx, courseID: courseID)
        let pages = try PageViews.pages(tx, courseID: courseID)
        for sitting in sittings {
            let pageID = pages.first { page in sitting.weeks.allSatisfy { week in page.folders.contains { $0.name == week } } }?.row.id
            var ids: [String] = []
            for week in sitting.weeks {
                let named = rows.filter { $0.name == week }
                let row = pageID.flatMap { page in named.first { $0.courseExamId == page } } ?? (named.count == 1 ? named[0] : nil)
                if let row { ids.append(row.id) }
            }
            if ids.count == sitting.weeks.count {
                let text = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
                try tx.execute("UPDATE study_session SET exam_folder_ids = ? WHERE id = ?", [.text(text), .text(sitting.id)])
            }
        }
    }
}
