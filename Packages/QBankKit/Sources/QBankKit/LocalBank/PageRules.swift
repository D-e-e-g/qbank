import Foundation

/// The rule family for a course's exam pages (the app's course exams): a page is a name, an
/// optional primer link and badge, and the folders on it.
enum PageRules {
    private static let badges: Set<String> = ["exam", "concept", "study"]

    static func register(in router: inout BankRouter) {
        router.post("/api/courses/:id/course-exams", createPage)
        router.put("/api/course-exams/:id", updatePage)
    }

    private struct Input {
        let name: String
        let folderIDs: [String]?
        let weekLabels: [String]?
        /// Left out, a page keeps its link; null takes it off.
        let linkUrl: BankBody.Patch<String>
        let badge: BankBody.Patch<String>

        init(_ call: BankCall) throws {
            let body = try BankBody(call.body)
            name = try body.string("name")
            folderIDs = try body.optionalUUIDs("folderIds", max: 200)
            weekLabels = try body.optionalStrings("weekLabels", max: 200)
            linkUrl = try body.nullableString("linkUrl")
            let badge = try body.nullableString("badge")
            if case .value(let value) = badge, !PageRules.badges.contains(value) { throw BankRefusal.invalidRequest }
            self.badge = badge
        }
    }

    private static func createPage(_ call: BankCall) throws -> BankAnswer {
        let courseID = try BankBody.pathID(call)
        let input = try Input(call)
        let tx = call.tx
        _ = try BankLookup.course(tx, courseID)
        let id = call.newID()
        let name = try pageName(tx, courseID, except: id, input.name)
        let link = try linkValue(input.linkUrl, keeping: nil)
        let sortOrder = try next(tx, courseID)
        let badge: String? = if case .value(let value) = input.badge { value } else { nil }
        try tx.execute(
            "INSERT INTO course_exam (id, course_id, name, sort_order, link_url, badge, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(id), .text(courseID), .text(name), .integer(Int64(sortOrder)), .optional(link), .optional(badge), .text(call.nowText)])
        try place(tx, courseID: courseID, page: (id, name), input, isNew: true)
        return .created(try PageViews.find(tx, courseID: courseID, id: id))
    }

    private static func updatePage(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        let input = try Input(call)
        let tx = call.tx
        let page = try BankLookup.page(tx, id)
        let name = try pageName(tx, page.courseId, except: id, input.name)
        let link = try linkValue(input.linkUrl, keeping: page.linkUrl)
        let badge: String? =
            switch input.badge {
            case .absent: page.badge
            case .null: nil
            case .value(let value): value
            }
        try tx.execute("UPDATE course_exam SET name = ?, link_url = ?, badge = ? WHERE id = ?", [.text(name), .optional(link), .optional(badge), .text(id)])
        try place(tx, courseID: page.courseId, page: (id, name), input, isNew: false)
        return .ok(try PageViews.find(tx, courseID: page.courseId, id: id))
    }

    /// An exam page's name, refused when another page of the course has it.
    private static func pageName(_ tx: StoreTransaction, _ courseID: String, except id: String, _ value: String) throws -> String {
        let name = try BankText.required(value, "Page name", 80)
        let others = try FolderOrder.pages(tx, courseID: courseID).filter { $0.deletedAt == nil && $0.id != id }
        if others.contains(where: { BankText.sameName($0.name, name) }) { throw BankRefusal.refused(409, "This course already has a page named \(name).") }
        return name
    }

    private static func linkValue(_ patch: BankBody.Patch<String>, keeping current: String?) throws -> String? {
        switch patch {
        case .absent: current
        case .null: nil
        case .value(let text): try PageLink.normalized(text)
        }
    }

    /// The page after the others added, deleted ones counted.
    private static func next(_ tx: StoreTransaction, _ courseID: String) throws -> Int {
        guard case .integer(let top)? = try tx.value("SELECT max(sort_order) FROM course_exam WHERE course_id = ?", [.text(courseID)]) else { return 1 }
        return Int(top) + 1
    }

    /// Sets a page's folders: `folderIds` become its folders in the order sent; legacy `weekLabels`
    /// name them, in week order; with neither, a new page is empty and an existing one keeps its
    /// folders. Folders taken off go to the end of the Folders list.
    private static func place(_ tx: StoreTransaction, courseID: String, page: (id: String, name: String), _ input: Input, isNew: Bool) throws {
        if input.folderIDs != nil && input.weekLabels != nil { throw BankRefusal.refused(400, "Send folderIds or weekLabels, not both.") }
        if input.folderIDs == nil && input.weekLabels == nil && !isNew { return }
        let course = try BankLookup.course(tx, courseID)
        let rows = try FolderOrder.rows(tx, courseID: courseID)
        let pages = try FolderOrder.pages(tx, courseID: courseID).filter { $0.deletedAt == nil }
        let target = try input.weekLabels.map { try byLabels(rows, page.id, $0) } ?? byIDs(rows, input.folderIDs ?? [])

        let elsewhere = target.filter { $0.courseExamId != nil && $0.courseExamId != page.id }
        if !elsewhere.isEmpty {
            var names: [String] = []
            var labels: [String: [String]] = [:]
            for row in elsewhere {
                let name = pages.first { $0.id == row.courseExamId }?.name ?? "another page"
                if labels[name] == nil { names.append(name) }
                labels[name, default: []].append(row.name)
            }
            throw BankRefusal.refused(409, names.map { name in "\(BankText.list(labels[name] ?? [])) \((labels[name] ?? []).count == 1 ? "is" : "are") in \(name)." }.joined(separator: " "))
        }
        for (index, row) in target.enumerated() {
            if let clash = target.prefix(index).first(where: { BankText.sameName($0.name, row.name) }) {
                throw BankRefusal.refused(409, "\(page.name) already has a folder named \(clash.name).")
            }
        }
        let keep = Set(target.map(\.id))
        let leaving = rows.filter { $0.courseExamId == page.id && !keep.contains($0.id) }
        let loose = rows.filter { $0.courseExamId == nil && !keep.contains($0.id) }
        for row in leaving { try FolderRules.assertNameFree(loose, row.name, FolderRules.label(course, nil), except: row.id) }
        var nextSort = FolderRules.endOf(loose)
        for row in leaving {
            try tx.execute("UPDATE folder SET course_exam_id = NULL, sort_order = ? WHERE id = ?", [.integer(Int64(nextSort)), .text(row.id)])
            nextSort += 1
        }
        for (index, row) in target.enumerated() {
            try tx.execute("UPDATE folder SET course_exam_id = ?, sort_order = ? WHERE id = ?", [.text(page.id), .integer(Int64(index + 1)), .text(row.id)])
        }
    }

    /// Folders by id, once each, in the order sent. An id the course does not have is refused.
    private static func byIDs(_ rows: [FolderRow], _ ids: [String]) throws -> [FolderRow] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let found = unique.compactMap { id in rows.first { $0.id == id } }
        let missing = unique.count - found.count
        if missing > 0 { throw BankRefusal.refused(400, missing == 1 ? "That folder is not in this course." : "Those folders are not in this course.") }
        return found
    }

    /// Legacy: folders by name, in week order. A name means the folder of that name on this page,
    /// else the one on no page, else one on another page (refused by the caller, naming that page).
    private static func byLabels(_ rows: [FolderRow], _ pageID: String, _ labels: [String]) throws -> [FolderRow] {
        var seen = Set<String>()
        let names = try labels.map { try BankText.required($0, "Week", 80) }.filter { seen.insert($0).inserted }.sorted { BankText.compareWeeks($0, $1) < 0 }
        var unknown: [String] = []
        var found: [FolderRow] = []
        for name in names {
            let named = rows.filter { $0.name == name }
            if let row = named.first(where: { $0.courseExamId == pageID }) ?? named.first(where: { $0.courseExamId == nil }) ?? named.first {
                found.append(row)
            } else {
                unknown.append(name)
            }
        }
        if !unknown.isEmpty { throw BankRefusal.refused(400, "\(BankText.list(unknown)) \(unknown.count == 1 ? "is not a week" : "are not weeks") in this course.") }
        return found
    }
}
