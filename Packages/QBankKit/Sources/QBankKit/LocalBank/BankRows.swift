import Foundation

// The rows the catalog rules read, and the lookups that refuse in the server's own words.

struct SemesterRow {
    let id: String
    let number: Int
    let name: String
    let startsOn: String?
    let endsOn: String?
    let archivedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        number = row.integer("number")
        name = row.string("name")
        startsOn = row.text("starts_on")
        endsOn = row.text("ends_on")
        archivedAt = row.text("archived_at")
    }
}

struct CourseRow {
    let id: String
    let semesterId: String?
    /// `course`, or `topic` for a study topic: a course with no semester and an empty code.
    let kind: String
    let code: String
    let title: String
    let sortOrder: Int
    let archivedAt: String?
    let deletedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        semesterId = row.text("semester_id")
        kind = row.string("kind")
        code = row.string("code")
        title = row.string("title")
        sortOrder = row.integer("sort_order")
        archivedAt = row.text("archived_at")
        deletedAt = row.text("deleted_at")
    }

    /// A course as a sentence names it: a course by its code, a topic (which has none) by its name.
    var sentenceName: String { kind == "topic" ? title : code }
}

struct PageRow {
    let id: String
    let courseId: String
    let name: String
    let sortOrder: Int
    let linkUrl: String?
    let badge: String?
    let deletedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        courseId = row.string("course_id")
        name = row.string("name")
        sortOrder = row.integer("sort_order")
        linkUrl = row.text("link_url")
        badge = row.text("badge")
        deletedAt = row.text("deleted_at")
    }
}

struct FolderRow {
    let id: String
    let courseId: String
    let name: String
    /// The exam page it is on, or nil when it is in the course's Folders list.
    var courseExamId: String?
    let sortOrder: Int
    let deletedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        courseId = row.string("course_id")
        name = row.string("name")
        courseExamId = row.text("course_exam_id")
        sortOrder = row.integer("sort_order")
        deletedAt = row.text("deleted_at")
    }
}

struct SetRow {
    let id: String
    let courseId: String
    let lineageId: String
    let title: String
    let description: String
    let weekLabel: String
    let folderId: String?
    let importedAt: String
    let replacedAt: String?
    let isCurrent: Bool
    let kind: String
    let deletedAt: String?

    init(_ row: StoreRow) {
        id = row.string("id")
        courseId = row.string("course_id")
        lineageId = row.string("lineage_id")
        title = row.string("title")
        description = row.string("description")
        weekLabel = row.string("week_label")
        folderId = row.text("folder_id")
        importedAt = row.string("imported_at")
        replacedAt = row.text("replaced_at")
        isCurrent = row.flag("is_current")
        kind = row.string("kind")
        deletedAt = row.text("deleted_at")
    }
}

/// Lookups, each refusing with the sentence the server uses for a row that is not there.
enum BankLookup {
    static func semester(_ tx: StoreTransaction, _ id: String) throws -> SemesterRow {
        guard let row = try tx.rows("SELECT * FROM semester WHERE id = ?", [.text(id)]).first else {
            throw BankRefusal.refused(404, "That semester is not in the app.")
        }
        return SemesterRow(row)
    }

    /// A course or topic that has not been deleted.
    static func course(_ tx: StoreTransaction, _ id: String) throws -> CourseRow {
        guard let row = try tx.rows("SELECT * FROM course WHERE id = ?", [.text(id)]).first else {
            throw BankRefusal.refused(404, "That course is not in the app.")
        }
        let course = CourseRow(row)
        if course.deletedAt != nil { throw BankRefusal.refused(404, "That course is not in the app.") }
        return course
    }

    /// Whether the course is there and has not been deleted: what the rest of its content needs to be reachable.
    static func live(_ tx: StoreTransaction, _ courseId: String) throws -> Bool {
        try !tx.rows("SELECT id FROM course WHERE id = ? AND deleted_at IS NULL", [.text(courseId)]).isEmpty
    }

    /// A page that has not been deleted, in a course that has not been deleted.
    static func page(_ tx: StoreTransaction, _ id: String) throws -> PageRow {
        guard let row = try tx.rows("SELECT * FROM course_exam WHERE id = ?", [.text(id)]).first else {
            throw BankRefusal.refused(404, "That page is not in the app.")
        }
        let page = PageRow(row)
        if try !live(tx, page.courseId) { throw BankRefusal.refused(404, "That page is not in the app.") }
        if page.deletedAt != nil { throw BankRefusal.refused(404, "That page was deleted.") }
        return page
    }

    /// A folder that has not been deleted, as every read shows it: on no page while its page is deleted.
    static func folder(_ tx: StoreTransaction, _ id: String) throws -> FolderRow {
        guard let row = try tx.rows("SELECT * FROM folder WHERE id = ?", [.text(id)]).first else {
            throw BankRefusal.refused(404, "That folder is not in the app.")
        }
        var folder = FolderRow(row)
        if try !live(tx, folder.courseId) { throw BankRefusal.refused(404, "That folder is not in the app.") }
        if folder.deletedAt != nil { throw BankRefusal.refused(404, "That folder was deleted.") }
        if let pageId = folder.courseExamId,
            try tx.rows("SELECT id FROM course_exam WHERE id = ? AND deleted_at IS NULL", [.text(pageId)]).isEmpty
        {
            folder.courseExamId = nil
        }
        return folder
    }

    /// A set of any version that has not been deleted, in a course that has not been deleted.
    static func set(_ tx: StoreTransaction, _ id: String) throws -> SetRow {
        guard let row = try tx.rows("SELECT * FROM practice_set WHERE id = ?", [.text(id)]).first else {
            throw BankRefusal.refused(404, "That set is not in the app.")
        }
        let set = SetRow(row)
        if try !live(tx, set.courseId) { throw BankRefusal.refused(404, "That set is not in the app.") }
        if set.deletedAt != nil { throw BankRefusal.refused(404, "That set was deleted.") }
        return set
    }
}
