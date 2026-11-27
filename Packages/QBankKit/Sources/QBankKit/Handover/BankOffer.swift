import Foundation

/// The sets of this phone's bank that QBank Cloud does not hold, when this phone takes the bank QBank
/// Cloud already has (`BankAdoption`), and what adding one to QBank Cloud as a new set sends: the set
/// rebuilt as a question file from its rows, for the import every set goes through
/// (`POST /api/imports`). Adding is the person's choice, one tap for all of them; nothing here adds,
/// removes or renames anything on either side.
public enum BankOffer {
    /// A set of this phone's bank, as the offer names it.
    public struct PhoneSet: Sendable, Equatable, Identifiable {
        /// Where the set is on this phone, which is where it goes in QBank Cloud.
        public struct Place: Sendable, Equatable {
            /// `course` or `topic`.
            public let kind: CourseKind
            /// Empty for a topic.
            public let code: String
            public let title: String
            /// The semester of a course, 1 to 3; nil for a topic.
            public let semesterNumber: Int?
            /// The set's folder, or nil when it is in none.
            public let folder: String?

            public init(kind: CourseKind, code: String, title: String, semesterNumber: Int?, folder: String?) {
                self.kind = kind
                self.code = code
                self.title = title
                self.semesterNumber = semesterNumber
                self.folder = folder
            }
        }

        public let id: String
        public let title: String
        public let place: Place
    }

    /// The current sets of the bank, not deleted and not in a deleted course or folder, in the order
    /// Home lists them, with each one's lineage and file, which say whether QBank Cloud holds it.
    static func currentSets(in tx: StoreTransaction) throws -> [(set: PhoneSet, lineage: String, file: String)] {
        let rows = try tx.rows(
            """
            SELECT s.id, s.title, s.lineage_id, s.file_hash, c.kind, c.code, c.title AS course_title, m.number, f.name AS folder_name
            FROM \(BankSummary.openSets)
            LEFT JOIN semester m ON m.id = c.semester_id
            WHERE \(BankSummary.isOpen)
            ORDER BY c.kind, m.number, c.sort_order, c.id, f.sort_order, s.sort_order, s.id
            """)
        return rows.map { row in
            let place = PhoneSet.Place(
                kind: CourseKind(rawValue: row.text("kind") ?? "topic"), code: row.text("code") ?? "", title: row.text("course_title") ?? "",
                semesterNumber: row.int("number"), folder: row.text("folder_name"))
            return (PhoneSet(id: row.text("id") ?? "", title: row.text("title") ?? "", place: place), row.text("lineage_id") ?? "", row.text("file_hash") ?? "")
        }
    }

    /// What a bank holds of every set it ever had, of any version, deleted or not: their lineages and
    /// their files.
    struct HeldSets: Sendable, Equatable {
        let lineages: Set<String>
        let files: Set<String>
    }

    static func heldSets(in tx: StoreTransaction) throws -> HeldSets {
        let rows = try tx.rows("SELECT lineage_id, file_hash FROM practice_set")
        return HeldSets(lineages: Set(rows.compactMap { $0.text("lineage_id") }), files: Set(rows.compactMap { $0.text("file_hash") }))
    }

    /// The current sets of `store` that a bank holding `held` does not hold: none of its sets has the
    /// set's lineage, as a set that moved between the two has, or its very file, as the same file
    /// imported on each side has.
    static func sets(of store: LocalStore, notIn held: HeldSets) throws -> [PhoneSet] {
        try store.read { try currentSets(in: $0) }
            .filter { !held.lineages.contains($0.lineage) && !held.files.contains($0.file) }
            .map(\.set)
    }

    /// The sets of `store` named by `ids`, in the order Home lists them. A set that is no longer one of
    /// its current sets is left out.
    public static func sets(_ ids: [String], in store: LocalStore) throws -> [PhoneSet] {
        let wanted = Set(ids)
        return try store.read { try currentSets(in: $0) }.map(\.set).filter { wanted.contains($0.id) }
    }

    /// The import that adds `set` to QBank Cloud as a new set, as a question file rebuilt from `store`:
    /// into the course or topic of the same name in `catalog`, QBank Cloud's courses and topics, or a
    /// new one when there is none; into the folder of the same name, or a new one, Unsorted going into
    /// Unsorted; and beside any set of the same name there, never in its place.
    public static func importRequest(for set: PhoneSet, from store: LocalStore, into catalog: Catalog) throws -> ImportRequest {
        let source = try store.read { try questionFile(of: set.id, in: $0) }
        let folder: ImportRequest.Folder = set.place.folder.map { BankText.sameName($0, "Unsorted") ? .unsorted : .named($0) } ?? .unsorted
        return ImportRequest(source: source, title: nil, course: course(for: set.place, in: catalog), folder: folder, decision: .separate)
    }

    /// The bank's course or topic for `place`, by the name each must not share: a course in the same
    /// semester with the same code, ignoring case, whatever its title; a topic with the same title,
    /// ignoring case. One that is not archived comes first; an archived one is named all the same, so
    /// the import says to unarchive it rather than refuse a second of that name. Else a new one.
    static func course(for place: PhoneSet.Place, in catalog: Catalog) -> ImportRequest.Course {
        func same(_ left: String, _ right: String) -> Bool {
            BankText.sameName(left.trimmingCharacters(in: .whitespaces), right.trimmingCharacters(in: .whitespaces))
        }
        func first(_ candidates: [CourseSummary], _ same: (CourseSummary) -> Bool) -> CourseSummary? {
            candidates.first { $0.archivedAt == nil && same($0) } ?? candidates.first(where: same)
        }
        if place.kind == .course, let number = place.semesterNumber {
            let courses = catalog.semesters.filter { $0.number == number }.flatMap(\.courses)
            if let match = first(courses, { same($0.code, place.code) }) {
                return .existing(id: match.id)
            }
            return .new(code: place.code, title: place.title, semesterNumber: number)
        }
        if let match = first(catalog.topics, { same($0.title, place.title) }) {
            return .existing(id: match.id)
        }
        return .newTopic(title: place.title)
    }

    // MARK: The question file

    /// The file fields a question's row is written under, as the import check reads them, in the
    /// order the server writes them in.
    private static let questionFields: [(file: String, column: String)] = [
        ("id", "public_id"), ("type", "type"), ("topic", "topic"), ("cj", "cj"), ("need", "client_need"), ("diff", "difficulty"),
        ("wk", "week_label"), ("stem", "stem"), ("ask", "ask"), ("rationale", "rationale"), ("takeaway", "takeaway"),
        ("terms", "term_keys"), ("src", "source"),
    ]

    /// A set as a question file, rebuilt from its rows as the server rebuilds one to check an archive:
    /// its title, description, kind and terms, and its questions in position order, each its body with
    /// every hoisted field under its file name, leaving out a null or empty one.
    static func questionFile(of setID: String, in tx: StoreTransaction) throws -> String {
        guard let set = try tx.rows("SELECT title, description, kind FROM practice_set WHERE id = ?", [.text(setID)]).first else {
            throw StoreError.storage(operation: "read the set to add", reason: "set \(setID) is not in the bank")
        }
        var terms = JSObject()
        for row in try tx.rows("SELECT key, term, meaning FROM term WHERE set_id = ? ORDER BY id", [.text(setID)]) {
            terms.set(row.text("key") ?? "", .array([.string(row.text("term") ?? ""), .string(row.text("meaning") ?? "")]))
        }
        let questions = try tx.rows("SELECT * FROM question WHERE set_id = ? ORDER BY position, id", [.text(setID)]).map(question)
        var file = JSObject()
        file.set("title", .string(set.text("title") ?? ""))
        file.set("desc", .string(set.text("description") ?? ""))
        file.set("kind", .string(set.text("kind") ?? "practice"))
        file.set("terms", .object(terms))
        file.set("questions", .array(questions))
        return JS.stringify(.object(file))
    }

    /// A question as a file writes it: its body, then each hoisted field under its file name.
    private static func question(_ row: StoreRow) throws -> JSNode {
        let names = Set(questionFields.map(\.file))
        var file = JSObject()
        // The check keeps every field it does not hoist in the body, so a stored body never holds one;
        // one that does is dropped, as the server drops it.
        if case .object(let body) = try JSParser.parse(row.text("body") ?? "{}") {
            for (key, value) in body.entries where !names.contains(key) { file.set(key, value) }
        }
        for (name, column) in questionFields {
            let value: JSNode
            switch row[column] {
            case .null: continue
            case .integer(let number): value = .number(Double(number))
            case .real(let number): value = .number(number)
            case .text(let text) where column == "term_keys": value = try JSParser.parse(text)
            case .text(let text): value = .string(text)
            }
            if value == .string("") || value == .array([]) { continue }
            file.set(name, value)
        }
        return .object(file)
    }
}
