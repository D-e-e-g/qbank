import Foundation

/// Questions as the runner reads them, shared by a set, a Review list and (later) an exam.
enum StudyViews {
    /// The question rows as the runner reads them, each with the term definitions from its own set.
    static func questions(_ tx: StoreTransaction, rows: [StoreRow]) throws -> [JSONValue] {
        var definitions: [String: [String: StoreRow]] = [:]
        for chunk in Chunks.of(Array(Set(rows.map { $0.string("set_id") })).sorted()) {
            for term in try tx.rows("SELECT set_id, key, term, meaning FROM term WHERE set_id IN \(Chunks.marks(chunk))", chunk.map(StoreValue.text)) {
                definitions[term.string("set_id"), default: [:]][term.string("key")] = term
            }
        }
        return try rows.map { row in
            let body = try bodyNode(row)
            let termKeys = (try? JSParser.parse(row.string("term_keys")))?.list ?? []
            let own = definitions[row.string("set_id")] ?? [:]
            return .object([
                "id": .string(row.string("id")), "publicId": .string(row.string("public_id")), "position": .int(row.integer("position")),
                "type": .string(try questionType(row)), "topic": .string(row.string("topic")), "cj": .optional(row.text("cj")),
                "stem": .string(row.string("stem")), "ask": .string(row.string("ask")), "rationale": .string(row.string("rationale")),
                "takeaway": .string(row.string("takeaway")), "body": body.json, "table": ImportMedia.readTable(body.record?["table"]),
                "images": .array(ImportMedia.readImages(body.record?["images"])),
                "terms": .array(
                    termKeys.compactMap { $0.text.flatMap { own[$0] } }.map {
                        .object(["key": .string($0.string("key")), "term": .string($0.string("term")), "meaning": .string($0.string("meaning"))])
                    }),
            ])
        }
    }

    private static func bodyNode(_ row: StoreRow) throws -> JSNode {
        guard let body = try? JSParser.parse(row.string("body")) else { throw BankRefusal.failed }
        return body
    }

    private static func questionType(_ row: StoreRow) throws -> String {
        let type = row.string("type")
        guard ImportChecker.typeLabels.contains(where: { $0.type == type }) else { throw BankRefusal.refused(404, "This set could not be read.") }
        return type
    }
}

extension BankRefusal {
    /// A refusal of the study routes, which name their own code (`course_not_found`, `attempt_conflict`) where most routes say `request_refused`.
    static func study(_ status: Int, _ code: String, _ message: String) -> BankRefusal { BankRefusal(status: status, code: code, message: message) }

    static let courseNotFound = BankRefusal.study(404, "course_not_found", "That course is not in the app.")
}

/// The server's rules for a course the study routes work in.
enum StudyLookup {
    /// A course or topic that is not deleted, as the progress service finds it.
    static func course(_ tx: StoreTransaction, _ id: String) throws -> CourseRow {
        guard BankBody.isAnyUUID(id), let row = try tx.rows("SELECT * FROM course WHERE id = ?", [.text(id)]).first else { throw BankRefusal.courseNotFound }
        let course = CourseRow(row)
        if course.deletedAt != nil { throw BankRefusal.courseNotFound }
        return course
    }
}

extension BankBody {
    /// A text in the form of a UUID, whatever its version: what the study service checks before it looks an id up.
    static func isAnyUUID(_ text: String) -> Bool {
        text.wholeMatch(of: /(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
    }
}
