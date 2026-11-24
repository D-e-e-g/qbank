import Foundation

/// What a field of a row holds, as `docs/on-phone-bank.md` ("How values are stored") names the kinds.
enum ArchiveKind: Sendable {
    /// A lowercase UUID, `8-4-4-4-12`.
    case id
    /// UTC with milliseconds, `YYYY-MM-DDTHH:MM:SS.sssZ`.
    case time
    /// `YYYY-MM-DD`.
    case date
    case text
    /// A JSON integer, within the range when there is one.
    case int(ClosedRange<Int64>?)
    case bool
    /// A JSON value, carried as its own text. `any` is any value that is not null.
    case json(JSONShape)
    /// One of a fixed set of words.
    case choice([String])

    enum JSONShape: Sendable { case any, object, array }
}

/// A field of a row: its name in the archive, its column in the store, its kind, and whether it may be null.
struct ArchiveField: Sendable {
    let name: String
    let column: String
    let kind: ArchiveKind
    let nullable: Bool
}

/// One of the twelve tables, as the archive and the store both hold it.
struct ArchiveTable: Sendable {
    /// The table's key in the document.
    let key: String
    /// The table in the store.
    let table: String
    let fields: [ArchiveField]
    /// The field that keys a row: the id, or for progress and Review clears the question's lineage.
    let rowKey: String?
    /// The references a row makes, as the field and the key of the table whose row it names.
    let references: [(field: String, target: String)]
    /// Whether the table is one row or none (`studyPlace`) rather than a list.
    let single: Bool

    var columns: String { fields.map(\.column).joined(separator: ", ") }
    var insert: String { "INSERT INTO \(table) (\(columns)) VALUES (\(fields.map { _ in "?" }.joined(separator: ", ")))" }
    var select: String { "SELECT \(columns) FROM \(table)" + (rowKey.map { " ORDER BY \(column(of: $0))" } ?? "") }

    func column(of name: String) -> String { fields.first { $0.name == name }?.column ?? name }
}

/// The twelve tables, in the archive's order. Each field is named as `docs/on-phone-bank.md` names it
/// and stored in the column of that name in snake case.
enum BankArchiveTables {
    private static func field(_ name: String, _ kind: ArchiveKind, null: Bool = false) -> ArchiveField {
        var column = ""
        for character in name {
            if character.isUppercase { column += "_" }
            column += character.lowercased()
        }
        return ArchiveField(name: name, column: column, kind: kind, nullable: null)
    }

    /// The two marks a delete leaves on a row, both null or both set.
    private static let deletion = [field("deletedAt", .time, null: true), field("deletionId", .id, null: true)]

    private static func list(
        _ key: String, _ table: String, key rowKey: String = "id", _ fields: [ArchiveField], deletable: Bool = false, refs: [(String, String)] = []
    ) -> ArchiveTable {
        ArchiveTable(key: key, table: table, fields: fields + (deletable ? deletion : []), rowKey: rowKey, references: refs.map { (field: $0.0, target: $0.1) }, single: false)
    }

    private static let status = ArchiveKind.choice(["correct", "partial", "incorrect"])

    static let all: [ArchiveTable] = [
        list(
            "semesters", "semester",
            [
                field("id", .id), field("number", .int(1...3)), field("name", .text), field("startsOn", .date, null: true), field("endsOn", .date, null: true),
                field("archivedAt", .time, null: true), field("createdAt", .time),
            ]),
        list(
            "courses", "course",
            [
                field("id", .id), field("semesterId", .id, null: true), field("kind", .choice(["course", "topic"])), field("code", .text), field("title", .text),
                field("sortOrder", .int(nil)), field("archivedAt", .time, null: true), field("createdAt", .time),
            ], deletable: true, refs: [("semesterId", "semesters")]),
        list(
            "courseExams", "course_exam",
            [
                field("id", .id), field("courseId", .id), field("name", .text), field("sortOrder", .int(nil)), field("linkUrl", .text, null: true),
                field("badge", .choice(["exam", "concept", "study"]), null: true), field("createdAt", .time),
            ], deletable: true, refs: [("courseId", "courses")]),
        list(
            "folders", "folder",
            [
                field("id", .id), field("courseId", .id), field("name", .text), field("courseExamId", .id, null: true), field("sortOrder", .int(nil)), field("createdAt", .time),
            ], deletable: true, refs: [("courseId", "courses"), ("courseExamId", "courseExams")]),
        list(
            "practiceSets", "practice_set",
            [
                field("id", .id), field("courseId", .id), field("lineageId", .id), field("title", .text), field("description", .text), field("weekLabel", .text),
                field("folderId", .id, null: true), field("sortOrder", .int(nil)), field("importedAt", .time), field("fileHash", .text), field("stats", .json(.object)),
                field("isCurrent", .bool), field("replacedAt", .time, null: true), field("kind", .choice(["practice", "exam"])),
            ], deletable: true, refs: [("courseId", "courses"), ("folderId", "folders")]),
        list(
            "questions", "question",
            [
                field("id", .id), field("setId", .id), field("lineageId", .id), field("publicId", .text), field("position", .int(1...Int64.max)), field("type", .text),
                field("topic", .text), field("cj", .text, null: true), field("clientNeed", .text, null: true), field("difficulty", .int(nil), null: true),
                field("weekLabel", .text), field("stem", .text), field("ask", .text), field("body", .json(.object)), field("rationale", .text), field("takeaway", .text),
                field("termKeys", .json(.array)), field("source", .text, null: true), field("contentHash", .text), field("twinOf", .text, null: true),
                field("twinOfLineageId", .id, null: true),
            ], refs: [("setId", "practiceSets")]),
        list("terms", "term", [field("id", .id), field("setId", .id), field("key", .text), field("term", .text), field("meaning", .text)], refs: [("setId", "practiceSets")]),
        list(
            "studySessions", "study_session",
            [
                field("id", .id), field("courseId", .id), field("mode", .choice(["practice", "exam", "review"])), field("setId", .id, null: true),
                field("questionIds", .json(.array)), field("examWeeks", .json(.array), null: true), field("examFolderIds", .json(.array), null: true),
                field("timeLimitSeconds", .int(nil), null: true), field("startedAt", .time), field("finishedAt", .time, null: true),
                field("score", .json(.object), null: true), field("endReason", .choice(["finished", "left", "timeout"]), null: true),
                field("examPool", .choice(["all", "wrong"])), field("examPracticeWeeks", .json(.array), null: true), field("seededQuestionIds", .json(.array), null: true),
            ], deletable: true, refs: [("courseId", "courses"), ("setId", "practiceSets")]),
        list(
            "attempts", "attempt",
            [
                field("id", .id), field("clientAttemptId", .id), field("studySessionId", .id, null: true), field("questionId", .id), field("response", .json(.any)),
                field("shuffle", .json(.any), null: true), field("status", status), field("points", .int(nil)), field("maxPoints", .int(nil)), field("guessed", .bool),
                field("answeredAt", .time),
            ], refs: [("studySessionId", "studySessions"), ("questionId", "questions")]),
        list(
            "questionProgress", "question_progress", key: "questionLineageId",
            [
                field("questionLineageId", .id), field("attempts", .int(nil)), field("correctAttempts", .int(nil)), field("lastStatus", status), field("lastGuessed", .bool),
                field("lastAnsweredAt", .time), field("lastPoints", .int(nil)), field("lastMaxPoints", .int(nil)), field("inReview", .bool), field("lastAttemptId", .id),
            ], refs: [("lastAttemptId", "attempts")]),
        list(
            "reviewClears", "review_clear", key: "questionLineageId",
            [field("questionLineageId", .id), field("lastAttemptId", .id), field("clearedAt", .time)], refs: [("lastAttemptId", "attempts")]),
        ArchiveTable(
            key: "studyPlace", table: "study_place", fields: [field("courseId", .id), field("updatedAt", .time)], rowKey: nil,
            references: [(field: "courseId", target: "courses")], single: true),
    ]
}
