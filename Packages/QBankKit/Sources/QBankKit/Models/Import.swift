import Foundation

/// `POST /api/imports/check`: a question file's counts, or the errors that block it, in the
/// importer's words. Nothing is written.
public struct ImportReport: Codable, Sendable, Equatable {
    /// How many questions of one format the file holds: "6 Single answer".
    public struct Format: Codable, Sendable, Equatable {
        public let type: String
        public let label: String
        public let count: Int
    }

    /// True when the file can be imported. Warnings do not block it; errors do.
    public let ok: Bool
    /// The file's own title, which fills the set name. Nil when the file has none or cannot be read.
    public let title: String?
    public let description: String
    /// `.exam` when the file says `"kind": "exam"`: its questions are asked only on exams.
    public let kind: PracticeSet.Kind
    public let questionCount: Int
    public let termCount: Int
    public let formats: [Format]
    public let errors: [String]
    public let warnings: [String]
    /// Every error and warning in the order the check found them, each with its rule, its question
    /// and its place in the file. `errors` and `warnings` are their sentences.
    public let issues: [Issue]

    /// One thing the check found.
    public struct Issue: Codable, Sendable, Equatable {
        public enum Severity: String, Codable, Sendable {
            /// Blocks the import.
            case error
            case warning
        }

        /// The question an issue is about.
        public struct Question: Codable, Sendable, Equatable {
            /// Its place in the file's list of questions, from 0: "Question 1" in a message is 0.
            public let index: Int
            /// Its `id` as the file writes it, a number as text. Nil when it has no text or number id.
            public let id: String?
        }

        public let severity: Severity
        /// The rule it breaks. The server adds codes over time, so show the message of one you do
        /// not know.
        public let code: String
        /// Nil for an issue with the file as a whole.
        public let question: Question?
        /// A JSON pointer into the file's JSON, inside its code fence when it has one. Empty is the
        /// whole file. A field that is missing is pointed to where it belongs.
        public let path: String
        /// The same sentence as in `errors` or `warnings`.
        public let message: String
    }
}

/// What `QBankClient.importSet` sends: the file, its course and folder, and what to do about a set
/// of the same name.
public struct ImportRequest: Sendable, Equatable {
    /// The course or topic the set goes into.
    public enum Course: Sendable, Equatable {
        /// One of her courses or topics.
        case existing(id: String)
        /// A course made by the import, in semester `semesterNumber` (1, 2, or 3).
        case new(code: String, title: String, semesterNumber: Int)
        /// A study topic made by the import, named `title`.
        case newTopic(title: String)
    }

    /// The folder the set goes into.
    public enum Folder: Sendable, Equatable {
        /// The course's Unsorted folder, made at the top of its Folders list the first time.
        case unsorted
        /// One of the course's folders. Not with a new course or topic, which has none yet.
        case id(String)
        /// A folder by name: the course's folder of that name on no exam page, else its only folder
        /// of that name, else a new folder at the end of its Folders list.
        case named(String)
    }

    /// What to do when the course already has a current set of the same kind and name.
    public enum Decision: String, Sendable, Equatable {
        /// Refuse with a conflict, so she can choose. Nothing is written.
        case `import`
        /// Swap the set's questions for the file's; it stays in its folder, and the old version
        /// stays restorable.
        case replace
        /// Keep both, as two sets of the same name.
        case separate
    }

    public let source: String
    /// The set name, when she changed the one the file gives.
    public let title: String?
    public let course: Course
    public let folder: Folder
    public let decision: Decision

    public init(source: String, title: String?, course: Course, folder: Folder, decision: Decision = .import) {
        self.source = source
        self.title = title
        self.course = course
        self.folder = folder
        self.decision = decision
    }

    /// The same import with another decision, after she answered the conflict.
    public func deciding(_ decision: Decision) -> ImportRequest {
        ImportRequest(source: source, title: title, course: course, folder: folder, decision: decision)
    }
}

/// The answer to `QBankClient.importSet`.
public enum ImportOutcome: Sendable, Equatable {
    case imported(ImportedSet)
    /// The course already has a set of this name. Nothing was written: she chooses to replace it,
    /// import it as a separate set, or cancel.
    case conflict(ImportConflict)
}

/// A set the import wrote.
public struct ImportedSet: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case imported
        case replaced
    }

    public let kind: Kind
    public let setKind: PracticeSet.Kind
    public let setID: String
    public let courseID: String
    public let courseCode: String
    public let title: String
    /// The folder the set is in. A replaced set stays in its folder, whatever folder the import named.
    public let folderID: String
    public let folderName: String
    /// The folder's exam page, or nil when it is in the course's Folders list.
    public let examPageID: String?
    public let questionCount: Int
    public let termCount: Int
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case kind, setKind, courseCode, title, folderName, questionCount, termCount, warnings
        case setID = "setId"
        case courseID = "courseId"
        case folderID = "folderId"
        case examPageID = "examPageId"
    }
}

/// `409` from `POST /api/imports`: the course already has a current set of this kind and name.
public struct ImportConflict: Codable, Sendable, Equatable, Identifiable {
    public let title: String
    public let courseID: String
    public let courseCode: String
    public let courseTitle: String
    /// The existing set's folder. Replacing it keeps it there.
    public let folderID: String
    public let folderName: String
    public let existingQuestionCount: Int
    public let incomingQuestionCount: Int
    /// The existing set.
    public let setID: String

    public var id: String { setID }

    enum CodingKeys: String, CodingKey {
        case title, courseCode, courseTitle, folderName, existingQuestionCount, incomingQuestionCount
        case courseID = "courseId"
        case folderID = "folderId"
        case setID = "setId"
    }
}

/// The body of `POST /api/imports/check`.
struct ImportSourceRequest: Encodable {
    let source: String
}

/// The body of `POST /api/imports`. Unsorted is the server's default, so it is sent as no folder.
struct ImportSetRequest: Encodable {
    let request: ImportRequest

    private struct NewCourse: Encodable {
        let code: String
        let title: String
        let semesterNumber: Int
    }

    private struct NewTopic: Encodable {
        let title: String
    }

    private enum CodingKeys: String, CodingKey {
        case source, title, courseId, newCourse, newTopic, folderId, folderName, decision
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request.source, forKey: .source)
        try container.encodeIfPresent(request.title, forKey: .title)
        switch request.course {
        case .existing(let id):
            try container.encode(id, forKey: .courseId)
        case .new(let code, let title, let semesterNumber):
            try container.encode(NewCourse(code: code, title: title, semesterNumber: semesterNumber), forKey: .newCourse)
        case .newTopic(let title):
            try container.encode(NewTopic(title: title), forKey: .newTopic)
        }
        switch request.folder {
        case .unsorted:
            break
        case .id(let id):
            try container.encode(id, forKey: .folderId)
        case .named(let name):
            try container.encode(name, forKey: .folderName)
        }
        try container.encode(request.decision.rawValue, forKey: .decision)
    }
}
