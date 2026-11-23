import Foundation

/// A course's folders as the screens read them: in the course's order, each with its sets.
///
/// What an answer adds to a set (its run and sitting) belongs to the answers rule family; until
/// that family exists a set reads as not started, and its answered counts come from the progress
/// rows the store holds.
struct FolderContent {
    struct Folder {
        let row: FolderRow
        let sets: [JSONValue]
        let setCount: Int
        let examBankCount: Int
        let examSets: [JSONValue]

        var json: JSONValue {
            .object([
                "id": .string(row.id), "name": .string(row.name), "examPageId": .optional(row.courseExamId), "sortOrder": .int(row.sortOrder),
                "sets": .array(sets), "examBankCount": .int(examBankCount), "examSets": .array(examSets),
            ])
        }
    }

    let folders: [Folder]
    /// Questions of the sets in force, by set.
    let questionCounts: [String: Int]
    /// Every current set that has a folder.
    let currentSets: [SetRow]

    static func load(_ tx: StoreTransaction, courseID: String) throws -> FolderContent {
        let rows = try FolderOrder.rows(tx, courseID: courseID)
        let setRows = try tx.rows("SELECT * FROM practice_set WHERE course_id = ? AND deleted_at IS NULL", [.text(courseID)]).map(SetRow.init)
        let current = setRows.filter { $0.isCurrent && $0.folderId != nil }
        let currentIDs = Set(current.map(\.id))
        let questionCounts = try counts(tx, courseID: courseID, setIds: currentIDs)
        let ids = try questionIDs(tx, courseID: courseID, setIds: Set(current.filter { $0.kind == "practice" }.map(\.id)))
        let study = try progress(tx, courseID: courseID, setIds: currentIDs)
        var byLineage: [String: [SetRow]] = [:]
        for set in setRows { byLineage[set.lineageId, default: []].append(set) }

        let folders = rows.map { folder -> Folder in
            let practice = current.filter { $0.kind == "practice" && $0.folderId == folder.id }
            let exam = current.filter { $0.kind == "exam" && $0.folderId == folder.id }
            let sorted = practice.sorted { BankText.localeCompare($0.title, $1.title) < 0 }.map { set in
                summary(set, lineage: byLineage[set.lineageId] ?? [set], questions: questionCounts[set.id] ?? 0, ids: ids[set.id] ?? [], study: study[set.id])
            }
            let examSorted = exam.sorted { BankText.localeCompare($0.title, $1.title) < 0 }
            return Folder(
                row: folder, sets: sorted, setCount: sorted.count,
                examBankCount: exam.reduce(0) { $0 + (questionCounts[$1.id] ?? 0) },
                examSets: examSorted.map {
                    .object(["id": .string($0.id), "title": .string($0.title), "questionCount": .int(questionCounts[$0.id] ?? 0), "importedByAgent": .null])
                })
        }
        return FolderContent(folders: folders, questionCounts: questionCounts, currentSets: current)
    }

    /// One folder of the course, as the course shows it.
    static func view(_ tx: StoreTransaction, courseID: String, folderID: String) throws -> JSONValue {
        guard let folder = try load(tx, courseID: courseID).folders.first(where: { $0.row.id == folderID }) else { throw BankRefusal.failed }
        return folder.json
    }

    /// Legacy weeks: the folders that hold sets, by name, so two folders of one name read as one week.
    var weeks: [JSONValue] {
        var order: [String] = []
        var groups: [String: (sets: [JSONValue], bank: Int)] = [:]
        for folder in folders where folder.setCount > 0 || folder.examBankCount > 0 {
            if var week = groups[folder.row.name] {
                week.sets += folder.sets
                week.bank += folder.examBankCount
                groups[folder.row.name] = week
            } else {
                order.append(folder.row.name)
                groups[folder.row.name] = (folder.sets, folder.examBankCount)
            }
        }
        return order.sorted(by: { BankText.compareWeeks($0, $1) < 0 }).map { name in
            let week = groups[name] ?? ([], 0)
            let sets = week.sets.sorted { BankText.localeCompare($0["title"]?.stringValue ?? "", $1["title"]?.stringValue ?? "") < 0 }
            return .object(["label": .string(name), "sets": .array(sets), "examBankCount": .int(week.bank)])
        }
    }

    // MARK: Sets

    private static func summary(_ set: SetRow, lineage: [SetRow], questions: Int, ids: [String], study: SetProgress?) -> JSONValue {
        let others = lineage.filter { $0.id != set.id }
        let newest = lineage.allSatisfy { $0.importedAt <= set.importedAt }
        let status = others.isEmpty ? "imported" : (newest ? "replaced" : "restored")
        let switchedAt = others.compactMap(\.replacedAt).max()
        let activeSince = status == "restored" ? (switchedAt ?? set.importedAt) : set.importedAt
        return .object([
            "id": .string(set.id), "title": .string(set.title), "description": .string(set.description), "questionCount": .int(questions),
            "importedAt": .string(set.importedAt), "activeSince": .string(activeSince), "status": .string(status), "canRestore": .bool(!others.isEmpty),
            "answeredCount": .int(study?.answered ?? 0), "fullyRightCount": .int(study?.fullyRight ?? 0), "lastAnsweredAt": .optional(study?.lastAnsweredAt),
            "run": .string("new"), "sitting": .null, "questionIds": .array(ids.map(JSONValue.string)), "importedByAgent": .null,
        ])
    }

    struct SetProgress {
        var answered = 0
        var fullyRight = 0
        var lastAnsweredAt: String?
    }

    private static func counts(_ tx: StoreTransaction, courseID: String, setIds: Set<String>) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try tx.rows(
            "SELECT q.set_id AS set_id, count(*) AS n FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE ps.course_id = ? GROUP BY q.set_id",
            [.text(courseID)]) where setIds.contains(row.string("set_id"))
        {
            counts[row.string("set_id")] = row.integer("n")
        }
        return counts
    }

    private static func questionIDs(_ tx: StoreTransaction, courseID: String, setIds: Set<String>) throws -> [String: [String]] {
        var ids: [String: [String]] = [:]
        for row in try tx.rows(
            "SELECT q.id AS id, q.set_id AS set_id FROM question q JOIN practice_set ps ON ps.id = q.set_id WHERE ps.course_id = ? ORDER BY q.position, q.id",
            [.text(courseID)]) where setIds.contains(row.string("set_id"))
        {
            ids[row.string("set_id"), default: []].append(row.string("id"))
        }
        return ids
    }

    private static func progress(_ tx: StoreTransaction, courseID: String, setIds: Set<String>) throws -> [String: SetProgress] {
        var result: [String: SetProgress] = [:]
        for row in try tx.rows(
            """
            SELECT q.set_id AS set_id, qp.last_status AS status, qp.last_answered_at AS answered_at
            FROM question q JOIN practice_set ps ON ps.id = q.set_id JOIN question_progress qp ON qp.question_lineage_id = q.lineage_id
            WHERE ps.course_id = ?
            """, [.text(courseID)]) where setIds.contains(row.string("set_id"))
        {
            var entry = result[row.string("set_id"), default: SetProgress()]
            entry.answered += 1
            if row.string("status") == "correct" { entry.fullyRight += 1 }
            let answeredAt = row.string("answered_at")
            if entry.lastAnsweredAt == nil || answeredAt > (entry.lastAnsweredAt ?? "") { entry.lastAnsweredAt = answeredAt }
            result[row.string("set_id")] = entry
        }
        return result
    }
}

/// The order a course's folders are read in: each exam page's folders, pages in the order they were
/// added, then the Folders list; each list in the person's order. A folder on a page that is
/// deleted reads as on no page, after the folders there, until Undo.
enum FolderOrder {
    static func rows(_ tx: StoreTransaction, courseID: String) throws -> [FolderRow] {
        inCourseOrder(try live(tx, courseID: courseID), try pages(tx, courseID: courseID))
    }

    static func live(_ tx: StoreTransaction, courseID: String) throws -> [FolderRow] {
        try tx.rows("SELECT * FROM folder WHERE course_id = ? AND deleted_at IS NULL", [.text(courseID)]).map(FolderRow.init)
    }

    /// The course's pages in the order they were added, deleted ones too.
    static func pages(_ tx: StoreTransaction, courseID: String) throws -> [PageRow] {
        try tx.rows("SELECT * FROM course_exam WHERE course_id = ? ORDER BY sort_order, created_at", [.text(courseID)]).map(PageRow.init)
    }

    static func inCourseOrder(_ rows: [FolderRow], _ pages: [PageRow]) -> [FolderRow] {
        let live = pages.filter { $0.deletedAt == nil }
        let deleted = pages.filter { $0.deletedAt != nil }
        var rank: [String: Int] = [:]
        for (index, page) in live.enumerated() { rank[page.id] = index }
        for (index, page) in deleted.enumerated() { rank[page.id] = live.count + 1 + index }
        let livePages = Set(live.map(\.id))
        func listRank(_ row: FolderRow) -> Int { row.courseExamId.map { rank[$0] ?? live.count } ?? live.count }
        return
            rows
            .sorted { a, b in
                if listRank(a) != listRank(b) { return listRank(a) < listRank(b) }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                let byWeek = BankText.compareWeeks(a.name, b.name)
                if byWeek != 0 { return byWeek < 0 }
                return BankText.localeCompare(a.id, b.id) < 0
            }
            .map { row in
                var shown = row
                if let page = row.courseExamId, !livePages.contains(page) { shown.courseExamId = nil }
                return shown
            }
    }
}
