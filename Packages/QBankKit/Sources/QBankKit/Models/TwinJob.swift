import Foundation

// Exam twins (the Twin option of Exam setup): she picks folders and a pool as for an exam, and
// instead of an exam on those questions QBank writes an exam twin of each, files them beside their
// practice sets, and then starts the exam on the twins. The server writes them with its own Claude
// key, for the accounts it allows, as it makes questions.

/// What `QBankClient.startTwinJob` sends: the course, the ticked folders, and the pool, as Start
/// exam would send them.
public struct NewTwinJob: Encodable, Sendable, Equatable {
    public let courseID: String
    public let folderIDs: [String]
    public let pool: ExamPool

    public init(courseID: String, folderIDs: [String], pool: ExamPool) {
        self.courseID = courseID
        self.folderIDs = folderIDs
        self.pool = pool
    }

    private enum CodingKeys: String, CodingKey {
        case courseID = "courseId"
        case folderIDs = "folderIds"
        case pool
    }
}

/// A twin job: QBank writing exam twins of the questions in the folders and pool she picked. It
/// never waits for her: it reads her questions, writes the twins, and files them, then names the
/// exam that starts on them. Its words (`note`, `failure`, `warnings`, the steps' labels) are the
/// server's, to show as they are.
public struct TwinJob: Decodable, Sendable, Hashable, Identifiable {
    /// Where the job is. Open, so a status the server adds later still decodes.
    public struct Status: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        /// QBank is working on it.
        public static let running: Status = "running"
        /// The twins are filed: see `sets`, and `exam` starts the exam on them.
        public static let done: Status = "done"
        /// Stopped: `failure` says why.
        public static let failed: Status = "failed"
        /// She stopped it. Sets already filed stay.
        public static let cancelled: Status = "cancelled"
    }

    /// The questions it twins, as an exam's pool. Open, so a pool the server adds later still decodes.
    public struct Pool: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        /// Every practice question of the folders.
        public static let all: Pool = "all"
        /// The practice questions she last answered not fully right.
        public static let wrong: Pool = "wrong"
    }

    /// One of the job's steps, as the server names it: Read your questions, Exam twins, File the twins.
    public struct Step: Decodable, Sendable, Hashable {
        /// Open, so a state the server adds later still decodes.
        public struct State: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public init(stringLiteral value: String) { self.rawValue = value }

            public static let done: State = "done"
            public static let current: State = "current"
            public static let failed: State = "failed"
            public static let cancelled: State = "cancelled"
            /// Not reached yet.
            public static let todo: State = "todo"
        }

        /// `read`, `twins`, or `file`, or one the server adds later.
        public let key: String
        public let label: String
        public let state: State
        /// How far the current step has got, when it counts something: sets read, twins written, sets filed.
        public let done: Int?
        public let total: Int?

        public init(key: String, label: String, state: State, done: Int? = nil, total: Int? = nil) {
            self.key = key
            self.label = label
            self.state = state
            self.done = done
            self.total = total
        }
    }

    /// A folder she picked, with what the job does in it.
    public struct Folder: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// Its practice questions in the pool.
        public let questionCount: Int
        /// Of those, the ones this job writes a twin for.
        public let twinCount: Int
        /// Of those, the ones that already had an exam twin, kept as they are.
        public let alreadyTwinned: Int

        public init(id: String, name: String, questionCount: Int, twinCount: Int, alreadyTwinned: Int) {
            self.id = id
            self.name = name
            self.questionCount = questionCount
            self.twinCount = twinCount
            self.alreadyTwinned = alreadyTwinned
        }
    }

    /// An exam set the job filed, in the folder of the practice set whose questions it twins.
    public struct FiledSet: Decodable, Sendable, Hashable, Identifiable {
        /// The practice set these twin, as it was named when the job started.
        public struct Source: Decodable, Sendable, Hashable {
            public let id: String
            public let title: String

            public init(id: String, title: String) {
                self.id = id
                self.title = title
            }
        }

        public let setID: String
        public let title: String
        public let folderID: String
        public let folderName: String
        public let examPageID: String?
        public let questionCount: Int
        public let termCount: Int
        public let twinsOf: Source

        public var id: String { setID }

        public init(
            setID: String, title: String, folderID: String, folderName: String, examPageID: String? = nil, questionCount: Int,
            termCount: Int = 0, twinsOf: Source
        ) {
            self.setID = setID
            self.title = title
            self.folderID = folderID
            self.folderName = folderName
            self.examPageID = examPageID
            self.questionCount = questionCount
            self.termCount = termCount
            self.twinsOf = twinsOf
        }

        private enum CodingKeys: String, CodingKey {
            case title, folderName, questionCount, termCount, twinsOf
            case setID = "setId"
            case folderID = "folderId"
            case examPageID = "examPageId"
        }
    }

    /// The exam on the twins, once the job is done: the body of `POST /api/courses/{id}/exams`.
    /// `QBankClient.startExam(courseID:on:replaces:)` sends it as the server wrote it, with `replaces` added.
    public struct Exam: Codable, Sendable, Hashable {
        /// The body as the server sent it.
        public let body: JSONValue

        public init(body: JSONValue) {
            self.body = body
        }

        /// The folders the twins are in.
        public var folderIDs: [String] {
            body["folderIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        public init(from decoder: any Decoder) throws {
            body = try JSONValue(from: decoder)
        }

        /// The body with `replaces` set: the running exam she agreed to end, or null.
        func replacing(_ examID: String?) -> Exam {
            guard case .object(var fields) = body else { return self }
            fields["replaces"] = examID.map(JSONValue.string) ?? .null
            return Exam(body: .object(fields))
        }

        public func encode(to encoder: any Encoder) throws {
            try body.encode(to: encoder)
        }
    }

    public let id: String
    public let status: Status
    public let steps: [Step]
    public let course: QuestionJob.Course
    public let pool: Pool
    /// The folders she picked, in the course's order.
    public let folders: [Folder]
    /// Exam twins it writes, one per practice question, as it started.
    public let twinCount: Int
    /// What it does, as a sentence to show her.
    public let note: String
    /// The exam sets filed so far.
    public let sets: [FiledSet]
    /// Once done, the exam on the twins; nil until then.
    public let exam: Exam?
    public let createdAt: Date
    public let updatedAt: Date
    public let finishedAt: Date?
    /// Why it failed, as a sentence to show her.
    public let failure: String?
    /// Her checker's warnings left on the twins, and the twins left out as they were filed.
    public let warnings: [String]

    public init(
        id: String, status: Status, steps: [Step], course: QuestionJob.Course, pool: Pool, folders: [Folder], twinCount: Int,
        note: String, sets: [FiledSet] = [], exam: Exam? = nil, createdAt: Date, updatedAt: Date, finishedAt: Date? = nil,
        failure: String? = nil, warnings: [String] = []
    ) {
        self.id = id
        self.status = status
        self.steps = steps
        self.course = course
        self.pool = pool
        self.folders = folders
        self.twinCount = twinCount
        self.note = note
        self.sets = sets
        self.exam = exam
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.failure = failure
        self.warnings = warnings
    }
}

struct TwinJobList: Decodable {
    let jobs: [TwinJob]
}
