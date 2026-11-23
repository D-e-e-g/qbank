import Foundation

/// A course's exam pages (what the app called course exams) as the screens read them.
enum PageViews {
    /// The pages not deleted, in the order they were added, each with its folders in the person's order.
    static func list(_ tx: StoreTransaction, courseID: String) throws -> [JSONValue] {
        try pages(tx, courseID: courseID).map(\.json)
    }

    struct Page {
        let row: PageRow
        let folders: [FolderRow]

        var json: JSONValue {
            .object([
                "id": .string(row.id), "name": .string(row.name), "sortOrder": .int(row.sortOrder),
                "weekLabels": .array(folders.map { .string($0.name) }), "folderIds": .array(folders.map { .string($0.id) }),
                "linkUrl": .optional(row.linkUrl), "badge": .optional(row.badge),
            ])
        }
    }

    static func pages(_ tx: StoreTransaction, courseID: String) throws -> [Page] {
        let every = try FolderOrder.pages(tx, courseID: courseID)
        let folders = FolderOrder.inCourseOrder(try FolderOrder.live(tx, courseID: courseID), every)
        return every.filter { $0.deletedAt == nil }.map { page in Page(row: page, folders: folders.filter { $0.courseExamId == page.id }) }
    }

    static func find(_ tx: StoreTransaction, courseID: String, id: String) throws -> JSONValue {
        guard let page = try pages(tx, courseID: courseID).first(where: { $0.row.id == id }) else { throw BankRefusal.failed }
        return page.json
    }
}
