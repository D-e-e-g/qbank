import Foundation

/// Which questions an exam draws from inside the ticked folders.
public enum ExamPool: String, Codable, Sendable, CaseIterable {
    /// Every question of the ticked folders.
    case all
    /// Only the questions she last answered not fully right.
    case wrong
}

/// Why an exam ended.
public enum ExamEndReason: String, Codable, Sendable {
    /// She finished.
    case finished
    /// She left midway.
    case left
    /// Her time ran out.
    case timeout
}

/// Where an exam stands on the server's clock (`Exam.status`, `ExamSummary.status`). Read it in
/// place of `finishedAt` being nil.
public enum ExamStatus: String, Codable, Sendable, Comparable {
    /// Before `endsAt`.
    case running
    /// Its time has run out, so no time is left. For `graceDuration` after `endsAt` an answer sent
    /// before the end is still taken, and starting another exam still asks before ending it. It
    /// ends when the app finishes it or once the grace is over.
    case grace
    /// It has ended, with `finishedAt`, `endReason` and its score. An exam whose time is up (past
    /// `endsAt` and the grace) reads as ended, a timeout at `endsAt`, whether or not its end is
    /// recorded yet.
    case ended

    /// How long after `endsAt` an exam stays in its grace, as the server's contract says.
    public static let graceDuration: TimeInterval = 30

    /// When an exam that ends at `endsAt` has its time up: past its end and its grace.
    public static func timeUp(endsAt: Date) -> Date {
        endsAt.addingTimeInterval(graceDuration)
    }

    /// Where an exam the server read as `status` stands at `date`, as time moves on from that read:
    /// running before `endsAt`, in its grace until its time is up, then ended. Never earlier than
    /// the server said, so a phone clock running behind does not reopen it.
    public static func of(_ status: ExamStatus, endsAt: Date, at date: Date) -> ExamStatus {
        let byClock: ExamStatus = date < endsAt ? .running : date <= timeUp(endsAt: endsAt) ? .grace : .ended
        return max(status, byClock)
    }

    /// The status sent, or, from a server that sends none (or one this app does not know), the one
    /// `finishedAt` implies.
    static func decode<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key, finishedAt: Date?) -> ExamStatus {
        let sent = (try? container.decodeIfPresent(ExamStatus.self, forKey: key)) ?? nil
        return sent ?? (finishedAt == nil ? .running : .ended)
    }

    public static func < (lhs: ExamStatus, rhs: ExamStatus) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .running: 0
        case .grace: 1
        case .ended: 2
        }
    }
}

/// How the server sizes and times an exam (`ExamSetup.rules`), as its `planExam` uses them.
public struct ExamRules: Codable, Sendable, Equatable {
    /// The most questions an exam draws.
    public let maxQuestions: Int
    /// The time for an exam of `maxQuestions`.
    public let fullTimeSeconds: Int
    /// The time per question when the folders hold fewer than `maxQuestions`, so the exam is all of them.
    public let secondsPerQuestion: Int

    public init(maxQuestions: Int, fullTimeSeconds: Int, secondsPerQuestion: Int) {
        self.maxQuestions = maxQuestions
        self.fullTimeSeconds = fullTimeSeconds
        self.secondsPerQuestion = secondsPerQuestion
    }
}

/// The exam that starting over some folders would give, as the server plans it.
public struct ExamPreview: Codable, Sendable, Equatable {
    /// A folder the exam draws from, and how many of its questions it takes.
    public struct Folder: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// The questions the folder holds in the pool.
        public let questionCount: Int
        /// How many of them the exam takes.
        public let drawn: Int
        public let source: ExamSetup.Week.Source
    }

    /// In the course's order. A folder that holds no question in the pool is left out.
    public let folders: [Folder]
    /// How many questions the exam draws: 0 when no folder is left.
    public let questionCount: Int
    public let timeLimitSeconds: Int
    /// The folders without an exam bank, so the exam draws their practice questions. Nil when the
    /// course has no exam bank at all.
    public let practiceWeeks: [String]?
}

/// `GET /api/courses/{id}/exams`: the folder picker, her running exam, and her ended exams.
public struct ExamSetup: Codable, Sendable, Equatable {
    /// What an exam over every folder of one exam page draws.
    public struct PagePreview: Codable, Sendable, Equatable {
        public let courseExamID: String
        public let preview: ExamPreview

        enum CodingKeys: String, CodingKey {
            case preview
            case courseExamID = "courseExamId"
        }
    }

    /// A folder to tick, with what an exam over it draws from.
    public struct Folder: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// The exam page it is on, or nil.
        public let examPageID: String?
        /// How many questions an exam over this folder draws from.
        public let questionCount: Int
        /// Of those, the ones she last answered not fully right: what a wrong-questions exam draws from.
        public let wrongCount: Int
        public let source: Week.Source

        public init(id: String, name: String, examPageID: String?, questionCount: Int, wrongCount: Int, source: Week.Source) {
            self.id = id
            self.name = name
            self.examPageID = examPageID
            self.questionCount = questionCount
            self.wrongCount = wrongCount
            self.source = source
        }

        enum CodingKeys: String, CodingKey {
            case id, name, questionCount, wrongCount, source
            case examPageID = "examPageId"
        }
    }

    public struct Week: Codable, Sendable, Equatable, Identifiable {
        public enum Source: String, Codable, Sendable {
            /// The week has an exam bank.
            case exam
            /// The week's exams use its practice questions.
            case practice
        }

        public let label: String
        /// How many questions an exam over this week draws from.
        public let questionCount: Int
        /// Of those, the ones she last answered not fully right: what a wrong-questions exam draws from.
        public let wrongCount: Int
        public let source: Source

        public var id: String { label }
    }

    public let courseID: String
    /// The pools by question week, for an app from before folders.
    public let weeks: [Week]
    /// The pools by folder: every folder with a current question, in the course's order. From a
    /// server older than folders, each week reads as a folder identified by its label.
    public let folders: [Folder]
    public let inProgress: ExamSummary?
    /// Newest first.
    public let exams: [ExamSummary]
    public let rules: ExamRules
    /// The exam over the folders and pool the setup was read with, or nil when it was read without folders.
    public let preview: ExamPreview?
    /// One for each of the course's exam pages, in their order.
    public let courseExams: [PagePreview]

    enum CodingKeys: String, CodingKey {
        case weeks, folders, inProgress, exams, rules, preview, courseExams
        case courseID = "courseId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decode(String.self, forKey: .courseID)
        weeks = try container.decode([Week].self, forKey: .weeks)
        folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? weeks.map { week in
            Folder(id: week.label, name: week.label, examPageID: nil, questionCount: week.questionCount, wrongCount: week.wrongCount, source: week.source)
        }
        inProgress = try container.decodeIfPresent(ExamSummary.self, forKey: .inProgress)
        exams = try container.decode([ExamSummary].self, forKey: .exams)
        rules = try container.decode(ExamRules.self, forKey: .rules)
        preview = try container.decodeIfPresent(ExamPreview.self, forKey: .preview)
        courseExams = try container.decode([PagePreview].self, forKey: .courseExams)
    }
}

/// A row of her exam history.
public struct ExamSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let courseID: String
    /// The names of the folders it covered, or of the weeks for an exam from before folders.
    public let weeks: [String]
    /// The folders it covered, in the course's order. Nil for an exam from before folders.
    public let folderIDs: [String]?
    /// The exam page (`CourseDetail.exams`) that holds every one of its folders, so exams taken
    /// before it was made belong to it too. Nil when no exam page does.
    public let courseExamID: String?
    public let pool: ExamPool
    /// The weeks that had no exam bank, so the exam drew their practice questions.
    /// Nil when the course had no exam bank at all.
    public let practiceWeeks: [String]?
    public let questionCount: Int
    public let timeLimitSeconds: Int
    public let startedAt: Date
    public let endsAt: Date
    /// Where it stood when the server answered.
    public let status: ExamStatus
    /// When it ended; for one whose time ran out, `endsAt`. Nil while running or in its grace.
    public let finishedAt: Date?
    public let endReason: ExamEndReason?
    public let answeredCount: Int
    public let fullyRight: Int?
    public let points: Int?
    public let maxPoints: Int?
    public let minutesUsed: Int?

    /// It has ended, with its score.
    public var hasEnded: Bool { status == .ended }

    /// Where it stands at `date` on this phone's clock, moved on from where the server read it.
    public func status(at date: Date) -> ExamStatus {
        ExamStatus.of(status, endsAt: endsAt, at: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, weeks, pool, practiceWeeks, questionCount, timeLimitSeconds, startedAt, endsAt, status
        case finishedAt, endReason, answeredCount, fullyRight, points, maxPoints, minutesUsed
        case courseID = "courseId"
        case courseExamID = "courseExamId"
        case folderIDs = "folderIds"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        courseID = try container.decode(String.self, forKey: .courseID)
        weeks = try container.decode([String].self, forKey: .weeks)
        folderIDs = try container.decodeIfPresent([String].self, forKey: .folderIDs)
        courseExamID = try container.decodeIfPresent(String.self, forKey: .courseExamID)
        pool = try container.decode(ExamPool.self, forKey: .pool)
        practiceWeeks = try container.decodeIfPresent([String].self, forKey: .practiceWeeks)
        questionCount = try container.decode(Int.self, forKey: .questionCount)
        timeLimitSeconds = try container.decode(Int.self, forKey: .timeLimitSeconds)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endsAt = try container.decode(Date.self, forKey: .endsAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = ExamStatus.decode(from: container, forKey: .status, finishedAt: finishedAt)
        endReason = try container.decodeIfPresent(ExamEndReason.self, forKey: .endReason)
        answeredCount = try container.decode(Int.self, forKey: .answeredCount)
        fullyRight = try container.decodeIfPresent(Int.self, forKey: .fullyRight)
        points = try container.decodeIfPresent(Int.self, forKey: .points)
        maxPoints = try container.decodeIfPresent(Int.self, forKey: .maxPoints)
        minutesUsed = try container.decodeIfPresent(Int.self, forKey: .minutesUsed)
    }
}

/// One exam: its questions in the order served, what she answered, and, once ended, the result.
public struct Exam: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let courseID: String
    public let courseCode: String
    public let courseTitle: String
    /// The names of the folders it covers, as they were when it started.
    public let weeks: [String]
    /// The folders it covers, in the course's order. Nil for an exam from before folders.
    public let folderIDs: [String]?
    public let pool: ExamPool
    public let practiceWeeks: [String]?
    public let timeLimitSeconds: Int
    public let startedAt: Date
    public let endsAt: Date
    /// Where it stood at `serverNow`.
    public let status: ExamStatus
    /// When it ended; for one whose time ran out, `endsAt`. Nil while running or in its grace.
    public let finishedAt: Date?
    public let endReason: ExamEndReason?
    /// The server's clock when it answered. The timer counts down from `endsAt - serverNow`,
    /// so a wrong phone clock does not change her time.
    public let serverNow: Date
    public let questions: [Question]
    public let answeredQuestionIDs: [String]
    public let result: ExamResult?

    /// Not ended: running, or in its grace with no time left, when the runner ends it as a timeout.
    public var isRunning: Bool { status != .ended }

    /// Seconds left when the server answered: none once its time has run out.
    public var secondsLeftAtServerNow: TimeInterval {
        status == .running ? max(0, endsAt.timeIntervalSince(serverNow)) : 0
    }

    enum CodingKeys: String, CodingKey {
        case id, courseCode, courseTitle, weeks, pool, practiceWeeks, timeLimitSeconds, startedAt, endsAt, status
        case finishedAt, endReason, serverNow, questions, result
        case courseID = "courseId"
        case folderIDs = "folderIds"
        case answeredQuestionIDs = "answeredQuestionIds"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        courseID = try container.decode(String.self, forKey: .courseID)
        courseCode = try container.decode(String.self, forKey: .courseCode)
        courseTitle = try container.decode(String.self, forKey: .courseTitle)
        weeks = try container.decode([String].self, forKey: .weeks)
        folderIDs = try container.decodeIfPresent([String].self, forKey: .folderIDs)
        pool = try container.decode(ExamPool.self, forKey: .pool)
        practiceWeeks = try container.decodeIfPresent([String].self, forKey: .practiceWeeks)
        timeLimitSeconds = try container.decode(Int.self, forKey: .timeLimitSeconds)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endsAt = try container.decode(Date.self, forKey: .endsAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = ExamStatus.decode(from: container, forKey: .status, finishedAt: finishedAt)
        endReason = try container.decodeIfPresent(ExamEndReason.self, forKey: .endReason)
        serverNow = try container.decode(Date.self, forKey: .serverNow)
        questions = try container.decode([Question].self, forKey: .questions)
        answeredQuestionIDs = try container.decode([String].self, forKey: .answeredQuestionIDs)
        result = try container.decodeIfPresent(ExamResult.self, forKey: .result)
    }
}

/// The score of an ended exam.
public struct ExamResult: Codable, Sendable, Equatable {
    /// Right answers out of the total for one folder, week, or clinical judgment step.
    public struct Breakdown: Codable, Sendable, Equatable, Identifiable {
        /// The folder of a By folder row, since two folders on different exam pages may share a
        /// name. Nil for the other breakdowns.
        public let folderID: String?
        public let label: String
        public let right: Int
        public let total: Int

        public var id: String { folderID ?? label }

        enum CodingKeys: String, CodingKey {
            case label, right, total
            case folderID = "folderId"
        }
    }

    /// One question's mark.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable {
            case correct
            case partial
            case incorrect
            case unanswered
        }

        public let questionID: String
        public let status: Status
        /// The mark's word: Correct, Partly correct, Not correct, or Not answered.
        public let label: String
        public let points: Int
        public let maxPoints: Int
        public let guessed: Bool
        /// Her answer, or nil when she did not answer.
        public let response: AnswerResponse?
        /// The order she saw, or nil.
        public let shuffle: Layout?

        public var id: String { questionID }

        enum CodingKeys: String, CodingKey {
            case status, label, points, maxPoints, guessed, response, shuffle
            case questionID = "questionId"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            questionID = try container.decode(String.self, forKey: .questionID)
            status = try container.decode(Status.self, forKey: .status)
            label = try container.decode(String.self, forKey: .label)
            points = try container.decode(Int.self, forKey: .points)
            maxPoints = try container.decode(Int.self, forKey: .maxPoints)
            guessed = try container.decode(Bool.self, forKey: .guessed)
            // Stored as sent. One the app cannot read shows as not answered rather than failing the result.
            response = try? container.decodeIfPresent(AnswerResponse.self, forKey: .response)
            shuffle = try? container.decodeIfPresent(Layout.self, forKey: .shuffle)
        }
    }

    public let questionCount: Int
    public let answered: Int
    public let unanswered: Int
    public let fullyRight: Int
    public let partial: Int
    public let missed: Int
    public let guessed: Int
    public let points: Int
    public let maxPoints: Int
    public let minutesUsed: Int
    /// Practice questions this exam sent to Review.
    public let reviewCount: Int
    /// Exam-bank questions she got wrong. They stay out of Review.
    public let examBankWrong: Int
    /// By each question's own week, for an app from before folders.
    public let byWeek: [Breakdown]
    /// By the folder each question was drawn from. Nil for an exam from before folders.
    public let byFolder: [Breakdown]?
    public let byStep: [Breakdown]
    public let items: [Item]
}

/// The answer to `QBankClient.startExam`.
public enum ExamStart: Sendable, Equatable {
    /// The new exam, running. The exam it replaced, if any, ended as left.
    case started(Exam)
    /// An exam of hers is running that the request did not name in `replaces`, so nothing started
    /// and nothing ended: this is that exam, to ask her about.
    case examInProgress(ExamSummary)
}

/// The body of `POST /api/courses/{id}/exams`. `replaces` is always sent: the running exam she
/// agreed to end, or null when the app knows of none running.
struct StartExamRequest: Encodable {
    let folderIds: [String]
    let pool: ExamPool
    let replaces: String?

    enum CodingKeys: String, CodingKey {
        case folderIds, pool, replaces
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderIds, forKey: .folderIds)
        try container.encode(pool, forKey: .pool)
        // Null, not left out: a missing field asks for the old start, which ends any running exam.
        try container.encode(replaces, forKey: .replaces)
    }
}

/// The 409 of `POST /api/courses/{id}/exams` when an exam is running that `replaces` did not name.
struct ExamInProgressRefusal: Decodable {
    let error: String
    let inProgress: ExamSummary
}

/// The body of `POST /api/exams/{id}/finish`.
struct FinishExamRequest: Encodable {
    let reason: ExamEndReason
}
