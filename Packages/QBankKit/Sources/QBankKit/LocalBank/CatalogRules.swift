import Foundation

/// The rule family for semesters, courses and study topics: what the server answers on
/// `/api/semesters`, `/api/courses`, `/api/topics` and `/api/topic-order`, in its words.
enum CatalogRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/semesters") { call in
            let catalog = try CatalogViews.catalog(call.tx)
            return .ok(.object(["semesters": .array(catalog.semesters), "topics": .array(catalog.topics)]))
        }
        router.post("/api/semesters", createSemester)
        router.patch("/api/semesters/:id", updateSemester)
        router.post("/api/courses", createCourse)
        router.patch("/api/courses/:id", updateCourse)
        router.get("/api/courses/:id") { call in
            .ok(try CourseView.load(call.tx, courseID: try BankBody.pathID(call)))
        }
        router.post("/api/topics", createTopic)
        router.put("/api/topic-order", orderTopics)
    }

    // MARK: Semesters

    private static func createSemester(_ call: BankCall) throws -> BankAnswer {
        let body = try BankBody(call.body)
        let number = try body.integer("number")
        let name = try body.optionalString("name")
        let startsOn = try body.nullableString("startsOn")
        let endsOn = try body.nullableString("endsOn")
        if number < 1 || number > 3 { throw BankRefusal.refused(400, "A semester is 1, 2, or 3.") }
        let title = try name.map { try BankText.required($0, "Name", 80) } ?? "Semester \(number)"
        let start = try BankText.date(string(startsOn), "Start date")
        let end = try BankText.date(string(endsOn), "End date")
        if try !call.tx.rows("SELECT id FROM semester WHERE number = ?", [.integer(Int64(number))]).isEmpty {
            throw BankRefusal.refused(409, "Semester \(number) already exists.")
        }
        let id = call.newID()
        try call.tx.execute(
            "INSERT INTO semester (id, number, name, starts_on, ends_on, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id), .integer(Int64(number)), .text(title), .optional(start), .optional(end), .text(call.nowText)])
        return .created(try CatalogViews.semester(call.tx, id: id))
    }

    private static func updateSemester(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let name = try body.optionalString("name")
        let startsOn = try body.nullableString("startsOn")
        let endsOn = try body.nullableString("endsOn")
        let archived = try body.optionalBool("archived")
        let current = try BankLookup.semester(call.tx, id)
        let title = try name.map { try BankText.required($0, "Semester name", 80) } ?? current.name
        let start = startsOn.isAbsent ? current.startsOn : try BankText.date(string(startsOn), "Start date")
        let end = endsOn.isAbsent ? current.endsOn : try BankText.date(string(endsOn), "End date")
        let archivedAt = archiveDate(current.archivedAt, archived, call)
        try call.tx.execute(
            "UPDATE semester SET name = ?, starts_on = ?, ends_on = ?, archived_at = ? WHERE id = ?",
            [.text(title), .optional(start), .optional(end), .optional(archivedAt), .text(id)])
        return .ok(try CatalogViews.semester(call.tx, id: id))
    }

    // MARK: Courses

    private static func createCourse(_ call: BankCall) throws -> BankAnswer {
        let body = try BankBody(call.body)
        let semesterId = try body.uuid("semesterId")
        let codeText = try body.string("code")
        let titleText = try body.string("title")
        let semester = try BankLookup.semester(call.tx, semesterId)
        let code = try BankText.required(codeText, "Course code", 32)
        let title = try BankText.required(titleText, "Course name", 160)
        try assertCodeFree(call.tx, semester.id, code, except: nil)
        let sortOrder = try nextSort(call.tx, "SELECT max(sort_order) FROM course WHERE semester_id = ?", [.text(semester.id)])
        let id = call.newID()
        try call.tx.execute(
            "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, 'course', ?, ?, ?, ?)",
            [.text(id), .text(semester.id), .text(code), .text(title), .integer(Int64(sortOrder)), .text(call.nowText)])
        return .created(try CatalogViews.card(call.tx, courseID: id))
    }

    private static func updateCourse(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        let body = try BankBody(call.body)
        let code = try body.optionalString("code")
        let title = try body.optionalString("title")
        let semesterId = try body.optionalUUID("semesterId")
        let archived = try body.optionalBool("archived")
        let tx = call.tx
        let current = try BankLookup.course(tx, id)
        if let semesterId { _ = try BankLookup.semester(tx, semesterId) }
        if current.kind == "topic" {
            try updateTopic(call, current, code: code, title: title, semesterId: semesterId, archived: archived)
        } else {
            let newCode = try code.map { try BankText.required($0, "Course code", 32) } ?? current.code
            let newTitle = try title.map { try BankText.required($0, "Course name", 160) } ?? current.title
            let currentSemester = current.semesterId ?? ""
            let targetSemester = semesterId ?? currentSemester
            if targetSemester != currentSemester { _ = try BankLookup.semester(tx, targetSemester) }
            try assertCodeFree(tx, targetSemester, newCode, except: id)
            let sortOrder =
                targetSemester == currentSemester
                ? current.sortOrder : try nextSort(tx, "SELECT max(sort_order) FROM course WHERE semester_id = ?", [.text(targetSemester)])
            let archivedAt = archiveDate(current.archivedAt, archived, call)
            try tx.execute(
                "UPDATE course SET code = ?, title = ?, semester_id = ?, sort_order = ?, archived_at = ? WHERE id = ?",
                [.text(newCode), .text(newTitle), .text(targetSemester), .integer(Int64(sortOrder)), .optional(archivedAt), .text(id)])
        }
        return .ok(try CatalogViews.card(tx, courseID: id))
    }

    /// Renames, archives or unarchives a topic. A topic has no code or semester to change.
    private static func updateTopic(_ call: BankCall, _ current: CourseRow, code: String?, title: String?, semesterId: String?, archived: Bool?) throws {
        if code != nil || semesterId != nil { throw BankRefusal.refused(400, "A topic has no course code or semester. Change its name instead.") }
        let newTitle = try title.map { try BankText.required($0, "Topic name", 160) } ?? current.title
        let archivedAt = archiveDate(current.archivedAt, archived, call)
        try assertTopicTitleFree(call.tx, newTitle, except: current.id)
        try call.tx.execute("UPDATE course SET title = ?, archived_at = ? WHERE id = ?", [.text(newTitle), .optional(archivedAt), .text(current.id)])
    }

    // MARK: Topics

    private static func createTopic(_ call: BankCall) throws -> BankAnswer {
        let body = try BankBody(call.body)
        let title = try BankText.required(try body.string("title"), "Topic name", 160)
        try assertTopicTitleFree(call.tx, title, except: nil)
        let sortOrder = try nextSort(call.tx, "SELECT max(sort_order) FROM course WHERE kind = 'topic' AND deleted_at IS NULL")
        let id = call.newID()
        try call.tx.execute(
            "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, NULL, 'topic', '', ?, ?, ?)",
            [.text(id), .text(title), .integer(Int64(sortOrder)), .text(call.nowText)])
        return .created(try CatalogViews.card(call.tx, courseID: id))
    }

    /// Saves the order of the topics. A list that does not name exactly the topics, archived ones
    /// included, is refused, so a stale screen cannot drop or misplace one.
    private static func orderTopics(_ call: BankCall) throws -> BankAnswer {
        let ids = try BankBody(call.body).uuids("topicIds", max: 500)
        let held = Set(try call.tx.rows("SELECT id FROM course WHERE kind = 'topic' AND deleted_at IS NULL").map { $0.string("id") })
        let sent = Set(ids)
        if sent.count != ids.count || sent.count != held.count || !ids.allSatisfy(held.contains) {
            throw BankRefusal.refused(409, "Your topics changed since this list was shown. Reload and try again.")
        }
        for (index, id) in ids.enumerated() {
            try call.tx.execute("UPDATE course SET sort_order = ? WHERE id = ?", [.integer(Int64(index + 1)), .text(id)])
        }
        let counts = try CatalogViews.counts(call.tx)
        let topics = try call.tx.rows("SELECT * FROM course WHERE kind = 'topic' AND deleted_at IS NULL ORDER BY sort_order, title").map(CourseRow.init)
        return .ok(.object(["topics": .array(topics.map { CatalogViews.card($0, counts[$0.id] ?? CourseCounts()) })]))
    }

    // MARK: Shared rules

    /// A course's code is unique among the semester's courses that are not deleted, ignoring case.
    private static func assertCodeFree(_ tx: StoreTransaction, _ semesterId: String, _ code: String, except id: String?) throws {
        let rows = try tx.rows("SELECT id, code FROM course WHERE semester_id = ? AND deleted_at IS NULL", [.text(semesterId)])
        if rows.contains(where: { $0.string("id") != id && BankText.sameName($0.string("code"), code) }) {
            throw BankRefusal.refused(409, "This semester already has a course with the code \(code).")
        }
    }

    /// The topics' names are unique among the topics that are not deleted, ignoring case.
    private static func assertTopicTitleFree(_ tx: StoreTransaction, _ title: String, except id: String?) throws {
        let rows = try tx.rows("SELECT id, title FROM course WHERE kind = 'topic' AND deleted_at IS NULL")
        if let taken = rows.first(where: { $0.string("id") != id && BankText.sameName($0.string("title"), title) }) {
            throw BankRefusal.refused(409, "You already have a topic named \(taken.string("title")).")
        }
    }

    private static func nextSort(_ tx: StoreTransaction, _ sql: String, _ bindings: [StoreValue] = []) throws -> Int {
        guard case .integer(let top)? = try tx.value(sql, bindings) else { return 1 }
        return Int(top) + 1
    }

    /// Archive by hand: true stamps now, false clears it, left out keeps it.
    private static func archiveDate(_ current: String?, _ archived: Bool?, _ call: BankCall) -> String? {
        guard let archived else { return current }
        return archived ? call.nowText : nil
    }

    private static func string(_ patch: BankBody.Patch<String>) -> String? {
        if case .value(let value) = patch { value } else { nil }
    }
}
