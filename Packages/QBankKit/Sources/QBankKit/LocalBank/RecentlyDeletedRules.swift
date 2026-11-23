import Foundation

/// What was deleted in a course in the last 30 days, newest first: everything Undo can still bring
/// back. Its exam pages, folders and sets come from here; her past exams she deleted are the exam
/// family's, which fills `exams` in.
enum RecentlyDeletedRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/courses/:id/deleted", read)
    }

    private static func read(_ call: BankCall) throws -> BankAnswer {
        let tx = call.tx
        let course = try StudyLookup.course(tx, try BankBody.pathID(call))
        let since = DeleteMarks.since(call.now)
        let folders = try deletedFolders(tx, courseID: course.id, since: since, now: call.now)
        let sets = try deletedSets(tx, courseID: course.id, since: since, now: call.now)
        let withFolder = Set(folders.map(\.deletion))
        return .ok(
            .object([
                "undoDays": .int(DeleteMarks.undoDays), "examPages": .array(try deletedPages(tx, courseID: course.id, since: since, now: call.now)),
                "folders": .array(try folders.map { folder in try folderJSON(tx, folder, sets: sets.filter { $0.deletion == folder.deletion }, now: call.now) }),
                "sets": .array(try sets.filter { !withFolder.contains($0.deletion) }.map { try setJSON(tx, $0, now: call.now) }), "exams": .array(try ExamDeletions.recentlyDeleted(tx, courseID: course.id, since: since, now: call.now)),
            ]))
    }

    /// Newest first, then by name.
    private static func newestFirst(_ deletedAt: String?, _ name: String, _ otherAt: String?, _ other: String) -> Bool {
        if deletedAt != otherAt { return (deletedAt ?? "") > (otherAt ?? "") }
        return BankText.localeCompare(name, other) < 0
    }

    // MARK: Pages

    private static func deletedPages(_ tx: StoreTransaction, courseID: String, since: String, now: Date) throws -> [JSONValue] {
        let rows = try tx.rows("SELECT * FROM course_exam WHERE course_id = ? AND deleted_at IS NOT NULL AND deleted_at > ?", [.text(courseID), .text(since)])
            .map(PageRow.init).sorted { newestFirst($0.deletedAt, $0.name, $1.deletedAt, $1.name) }
        if rows.isEmpty { return [] }
        let live = try PageDeleteRules.livePages(tx, courseID: courseID)
        var list: [JSONValue] = []
        for row in rows {
            let own = try foldersNaming(tx, pageID: row.id)
            // Where her past exams go once it is back: the pages there are now, and this one in its place.
            let order = try FolderOrder.pages(tx, courseID: courseID)
            let back = PageDeleteRules.PlacedPage(id: row.id, folderIDs: own.map(\.id), weekLabels: own.map(\.name))
            let pages = (live + [back]).enumerated().sorted { a, b in
                let (left, right) = (order.first { $0.id == a.element.id }?.sortOrder ?? 0, order.first { $0.id == b.element.id }?.sortOrder ?? 0)
                return left == right ? a.offset < b.offset : left < right
            }.map(\.element)
            let past = try PageDeleteRules.pastExamCount(tx, courseID: courseID, pageID: row.id, pages: pages, now: now)
            list.append(
                .object([
                    "id": .string(row.id), "name": .string(row.name), "badge": .optional(row.badge),
                    "folders": .array(own.map { .object(["id": .string($0.id), "name": .string($0.name)]) }), "pastExamCount": .int(past),
                    "deletedAt": .string(row.deletedAt ?? ""), "undoUntil": .string(DeleteMarks.undoUntil(row.deletedAt ?? "")),
                    "undoRefusal": .optional(try PageDeleteRules.undoRefusal(tx, row, now: now)?.message), "deletedByAgent": .null,
                ]))
        }
        return list
    }

    /// The folders not deleted whose row names this page, in its order: the ones Undo puts back on it.
    private static func foldersNaming(_ tx: StoreTransaction, pageID: String) throws -> [FolderRow] {
        try tx.rows("SELECT * FROM folder WHERE course_exam_id = ? AND deleted_at IS NULL", [.text(pageID)]).map(FolderRow.init).sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            let byWeek = BankText.compareWeeks(a.name, b.name)
            return byWeek != 0 ? byWeek < 0 : BankText.localeCompare(a.id, b.id) < 0
        }
    }

    // MARK: Folders and sets

    private struct DeletedFolder {
        let row: FolderRow
        let deletion: String
    }

    private struct DeletedSet {
        let row: SetRow
        let deletion: String
        let questionCount: Int
    }

    private static func deletedFolders(_ tx: StoreTransaction, courseID: String, since: String, now: Date) throws -> [DeletedFolder] {
        let rows = try tx.rows("SELECT * FROM folder WHERE course_id = ? AND deleted_at IS NOT NULL AND deleted_at > ?", [.text(courseID), .text(since)])
        return try rows.map { stored in
            DeletedFolder(row: try SetDeleteRules.listed(tx, stored), deletion: stored.string("deletion_id"))
        }.sorted { newestFirst($0.row.deletedAt, $0.row.name, $1.row.deletedAt, $1.row.name) }
    }

    private static func deletedSets(_ tx: StoreTransaction, courseID: String, since: String, now: Date) throws -> [DeletedSet] {
        let rows = try tx.rows(
            "SELECT * FROM practice_set WHERE course_id = ? AND is_current = 1 AND deleted_at IS NOT NULL AND deleted_at > ?", [.text(courseID), .text(since)])
        let counts = Dictionary(
            uniqueKeysWithValues: try tx.rows(
                "SELECT set_id, count(*) AS n FROM question WHERE set_id IN (SELECT id FROM practice_set WHERE course_id = ?) GROUP BY set_id", [.text(courseID)]
            ).map { ($0.string("set_id"), $0.integer("n")) })
        return rows.map { DeletedSet(row: SetRow($0), deletion: $0.string("deletion_id"), questionCount: counts[$0.string("id")] ?? 0) }
            .sorted { newestFirst($0.row.deletedAt, $0.row.title, $1.row.deletedAt, $1.row.title) }
    }

    private static func brief(_ set: DeletedSet) -> JSONValue {
        .object(["id": .string(set.row.id), "title": .string(set.row.title), "kind": .string(set.row.kind), "questionCount": .int(set.questionCount)])
    }

    private static func folderJSON(_ tx: StoreTransaction, _ folder: DeletedFolder, sets: [DeletedSet], now: Date) throws -> JSONValue {
        let ordered = sets.sorted { a, b in a.row.kind == b.row.kind ? BankText.localeCompare(a.row.title, b.row.title) < 0 : a.row.kind == "practice" }
        let deletedAt = folder.row.deletedAt ?? ""
        return .object([
            "id": .string(folder.row.id), "name": .string(folder.row.name), "examPageId": .optional(folder.row.courseExamId), "sets": .array(ordered.map(brief)),
            "deletedAt": .string(deletedAt), "undoUntil": .string(DeleteMarks.undoUntil(deletedAt)),
            "undoRefusal": .optional(try SetDeleteRules.folderUndoRefusal(tx, folder.row, now: now)?.message), "deletedByAgent": .null,
        ])
    }

    private static func setJSON(_ tx: StoreTransaction, _ set: DeletedSet, now: Date) throws -> JSONValue {
        let stored = try tx.rows("SELECT * FROM practice_set WHERE id = ?", [.text(set.row.id)]).first
        let folderName = try set.row.folderId.flatMap { try tx.rows("SELECT name FROM folder WHERE id = ?", [.text($0)]).first }?.string("name") ?? ""
        let deletedAt = set.row.deletedAt ?? ""
        guard let stored else { throw BankRefusal.failed }
        return .object([
            "id": .string(set.row.id), "title": .string(set.row.title), "kind": .string(set.row.kind), "questionCount": .int(set.questionCount),
            "folderId": .optional(set.row.folderId), "folderName": .string(folderName), "deletedAt": .string(deletedAt),
            "undoUntil": .string(DeleteMarks.undoUntil(deletedAt)), "undoRefusal": .optional(try SetDeleteRules.setUndoRefusal(tx, stored, now: now)?.message),
            "deletedByAgent": .null,
        ])
    }
}
