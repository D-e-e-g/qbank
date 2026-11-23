import Foundation

/// The rule family for importing a question file: what the server answers on `POST /api/imports/check`
/// and `POST /api/imports`, in its words. The check reads only the file. An import checks it again,
/// then files it as a set in a course, a topic, or a new one made for it, and in a folder of that.
/// A set of the same kind and name is a conflict the person decides: replace it with a new version,
/// or add the file beside it. Nothing the person already has is deleted, moved or renamed.
enum ImportRules {
    static func register(in router: inout BankRouter) {
        router.post("/api/imports/check", writes: false) { call in
            .ok(ImportChecker.report(for: try BankBody(call.body).string("source")).wire)
        }
        router.post("/api/imports", commit)
    }

    /// A course the import makes: in the semester of that number, made too when the person has none.
    private struct NewCourse {
        let code: String
        let title: String
        let semesterNumber: Int
        let semesterName: String?

        init(_ body: BankBody) throws {
            code = try body.string("code")
            title = try body.string("title")
            semesterNumber = try body.integer("semesterNumber")
            semesterName = try body.optionalString("semesterName")
        }
    }

    private enum Destination {
        case existing(String)
        case course(NewCourse)
        case topic(String)
    }

    /// The course or topic the set goes into, as the import's own sentences name it.
    private struct Target {
        let id: String
        let code: String
        let title: String
        let kind: String
    }

    private static func commit(_ call: BankCall) throws -> BankAnswer {
        let body = try BankBody(call.body)
        let source = try body.string("source")
        let givenTitle = try body.optionalString("title")
        let folderId = try body.optionalUUID("folderId")
        let givenFolder = try body.optionalString("folderName")
        let legacyFolder = try body.optionalString("weekLabel")
        let courseId = try body.optionalUUID("courseId")
        let newCourse = try body.optionalObject("newCourse").map(NewCourse.init)
        let newTopic = try body.optionalObject("newTopic").map { try $0.string("title") }
        let decision = try body.optionalChoice("decision", ["import", "replace", "separate"]) ?? "import"
        let tx = call.tx
        // A course that was deleted is refused before the file is read; one that names nothing is refused after.
        if let courseId, let row = try tx.rows("SELECT deleted_at FROM course WHERE id = ?", [.text(courseId)]).first, row.text("deleted_at") != nil {
            throw BankRefusal.refused(404, "That course is not in the app.")
        }

        let checked = ImportChecker.check(source)
        guard checked.ok, let fileTitle = checked.title else {
            let message = checked.errors.first ?? "This file can't be imported."
            return BankAnswer(
                status: 400,
                body: .object([
                    "error": .string("invalid_import"), "message": .string(message), "errors": .array(checked.errors.map(JSONValue.string)),
                    "warnings": .array(checked.warnings.map(JSONValue.string)),
                ]))
        }
        let title = try givenTitle.map { try BankText.required($0, "Set name", 200) } ?? fileTitle
        if courseId != nil && newCourse != nil { throw BankRefusal.refused(400, "Choose a course or a new course, not both.") }
        let places = [courseId != nil, newCourse != nil, newTopic != nil].filter { $0 }.count
        if places > 1 { throw BankRefusal.refused(400, "Choose one place for the set: a course, a topic, a new course, or a new topic.") }
        guard places == 1 else { throw BankRefusal.refused(400, "Choose a course.") }
        let folderName = givenFolder ?? legacyFolder
        if folderId != nil && folderName != nil { throw BankRefusal.refused(400, "Choose a folder or a folder name, not both.") }
        if folderId != nil && newCourse != nil { throw BankRefusal.refused(400, "A new course has no folders yet. Name a folder, or leave it for Unsorted.") }
        if folderId != nil && newTopic != nil { throw BankRefusal.refused(400, "A new topic has no folders yet. Name a folder, or leave it for Unsorted.") }
        let wantedFolder = try folderName.map { try BankText.required($0, "Folder name", 80) }
        let topicTitle = try newTopic.map { try BankText.required($0, "Topic name", 160) }

        let destination: Destination
        if let courseId {
            destination = .existing(courseId)
        } else if let newCourse {
            destination = .course(newCourse)
        } else {
            destination = .topic(topicTitle ?? "")
        }
        let course = try target(call, destination)
        let existing = try matchingSet(tx, courseID: course.id, kind: checked.kind, title: title)
        if let existing, decision == "import" {
            return try conflict(tx, existing: existing, course: course, title: title, incoming: checked.questions.count)
        }
        let replacing = decision == "replace" ? existing : nil
        // A replacement is a new version of the set, so it stays in the set's folder.
        let folder = try replacing.map { try folderOfSet(tx, $0) } ?? importFolder(call, course: course, folderId: folderId, folderName: wantedFolder)
        let written = try ImportWrite.insertSet(
            call, check: checked, source: source, title: title, courseID: course.id, folder: folder, replacing: replacing)
        return .created(
            .object([
                "kind": .string(replacing == nil ? "imported" : "replaced"), "setKind": .string(checked.kind), "setId": .string(written.setID),
                "courseId": .string(course.id), "courseCode": .string(course.code), "title": .string(title), "weekLabel": .string(folder.name),
                "folderId": .string(folder.id), "folderName": .string(folder.name), "examPageId": .optional(folder.courseExamId),
                "questionCount": .int(checked.questions.count), "termCount": .int(checked.terms.count),
                "warnings": .array(checked.warnings.map(JSONValue.string)), "importedByAgent": .null,
            ]))
    }

    // MARK: The course

    private static func target(_ call: BankCall, _ destination: Destination) throws -> Target {
        let tx = call.tx
        switch destination {
        case .existing(let id):
            let course = try BankLookup.course(tx, id)
            if course.archivedAt != nil { throw BankRefusal.refused(400, "That course is archived. Unarchive it before importing.") }
            return Target(id: course.id, code: course.code, title: course.title, kind: course.kind)
        case .course(let input):
            return try makeCourse(call, input)
        case .topic(let title):
            try CatalogRules.assertTopicTitleFree(tx, title, except: nil)
            let sortOrder = try CatalogRules.nextSort(tx, "SELECT max(sort_order) FROM course WHERE kind = 'topic' AND deleted_at IS NULL")
            let id = call.newID()
            try tx.execute(
                "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, NULL, 'topic', '', ?, ?, ?)",
                [.text(id), .text(title), .integer(Int64(sortOrder)), .text(call.nowText)])
            return Target(id: id, code: "", title: title, kind: "topic")
        }
    }

    private static func makeCourse(_ call: BankCall, _ input: NewCourse) throws -> Target {
        let tx = call.tx
        let number = input.semesterNumber
        if number < 1 || number > 3 { throw BankRefusal.refused(400, "A semester is 1, 2, or 3.") }
        let semesterId: String
        if let row = try tx.rows("SELECT id FROM semester WHERE number = ?", [.integer(Int64(number))]).first {
            semesterId = row.string("id")
        } else {
            semesterId = call.newID()
            let name = try input.semesterName.map { try BankText.required($0, "Name", 80) } ?? "Semester \(number)"
            try tx.execute(
                "INSERT INTO semester (id, number, name, starts_on, ends_on, created_at) VALUES (?, ?, ?, NULL, NULL, ?)",
                [.text(semesterId), .integer(Int64(number)), .text(name), .text(call.nowText)])
        }
        let code = try BankText.required(input.code, "Course code", 32)
        let title = try BankText.required(input.title, "Course name", 160)
        try CatalogRules.assertCodeFree(tx, semesterId, code, except: nil)
        let sortOrder = try CatalogRules.nextSort(tx, "SELECT max(sort_order) FROM course WHERE semester_id = ?", [.text(semesterId)])
        let id = call.newID()
        try tx.execute(
            "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, 'course', ?, ?, ?, ?)",
            [.text(id), .text(semesterId), .text(code), .text(title), .integer(Int64(sortOrder)), .text(call.nowText)])
        return Target(id: id, code: code, title: title, kind: "course")
    }

    // MARK: The set it may replace

    /// The course's current set of this kind and name, by the name as written. A practice set and an exam set never replace each other, and a set that was deleted is not one: a new set of its name is added beside it.
    private static func matchingSet(_ tx: StoreTransaction, courseID: String, kind: String, title: String) throws -> SetRow? {
        try tx.rows(
            """
            SELECT * FROM practice_set WHERE course_id = ? AND is_current = 1 AND deleted_at IS NULL AND kind = ? AND title = ?
            ORDER BY imported_at DESC, id DESC
            """, [.text(courseID), .text(kind), .text(title)]
        ).first.map(SetRow.init)
    }

    /// The folder a set is in. Every set has one once the bank is made, so one without is a fault of the bank.
    private static func folderOfSet(_ tx: StoreTransaction, _ set: SetRow) throws -> FolderRow {
        guard let folderId = set.folderId else { throw BankRefusal.failed }
        return try BankLookup.folder(tx, folderId)
    }

    private static func conflict(_ tx: StoreTransaction, existing: SetRow, course: Target, title: String, incoming: Int) throws -> BankAnswer {
        let folder = try folderOfSet(tx, existing)
        let count = try tx.value("SELECT count(*) FROM question WHERE set_id = ?", [.text(existing.id)])
        var existingCount = 0
        if case .integer(let number)? = count { existingCount = Int(number) }
        return BankAnswer(
            status: 409,
            body: .object([
                "conflict": .bool(true), "title": .string(title), "courseId": .string(course.id), "courseCode": .string(course.code),
                "courseTitle": .string(course.title), "weekLabel": .string(folder.name), "folderId": .string(folder.id), "folderName": .string(folder.name),
                "existingQuestionCount": .int(existingCount), "incomingQuestionCount": .int(incoming), "setId": .string(existing.id),
            ]))
    }

    // MARK: The folder

    private static let unsorted = "Unsorted"

    /// The folder an import goes into: `folderId`, or the folder named `folderName`, or else Unsorted, made at the top of the Folders list the first time. A named folder the course does not have is made at the end of the Folders list.
    private static func importFolder(_ call: BankCall, course: Target, folderId: String?, folderName: String?) throws -> FolderRow {
        let tx = call.tx
        let rows = try FolderOrder.rows(tx, courseID: course.id)
        if let folderId {
            guard let chosen = rows.first(where: { $0.id == folderId }) else { throw BankRefusal.refused(400, "That folder is not in this course.") }
            return chosen
        }
        if let folderName {
            let named = rows.filter { BankText.sameName($0.name, folderName) }
            if let found = named.first(where: { $0.courseExamId == nil }) ?? (named.count == 1 ? named.first : nil) { return found }
            return try newLooseFolder(call, course: course, rows: rows, name: folderName, atTop: false)
        }
        if let found = rows.first(where: { $0.courseExamId == nil && BankText.sameName($0.name, unsorted) }) { return found }
        return try newLooseFolder(call, course: course, rows: rows, name: unsorted, atTop: true)
    }

    private static func newLooseFolder(_ call: BankCall, course: Target, rows: [FolderRow], name: String, atTop: Bool) throws -> FolderRow {
        let tx = call.tx
        let loose = rows.filter { $0.courseExamId == nil }
        try FolderRules.assertNameFree(loose, name, course.kind == "topic" ? course.title : course.code, except: nil)
        let sortOrder = atTop && !loose.isEmpty ? (loose.map(\.sortOrder).min() ?? 0) - 1 : FolderRules.endOf(loose)
        let id = call.newID()
        try tx.execute(
            "INSERT INTO folder (id, course_id, name, course_exam_id, sort_order, created_at) VALUES (?, ?, ?, NULL, ?, ?)",
            [.text(id), .text(course.id), .text(name), .integer(Int64(sortOrder)), .text(call.nowText)])
        return try BankLookup.folder(tx, id)
    }
}
