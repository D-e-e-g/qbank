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
    public let finishedAt: Date?
    public let endReason: ExamEndReason?
    public let answeredCount: Int
    public let fullyRight: Int?
    public let points: Int?
    public let maxPoints: Int?
    public let minutesUsed: Int?

    enum CodingKeys: String, CodingKey {
        case id, weeks, pool, practiceWeeks, questionCount, timeLimitSeconds, startedAt, endsAt
        case finishedAt, endReason, answeredCount, fullyRight, points, maxPoints, minutesUsed
        case courseID = "courseId"
        case courseExamID = "courseExamId"
        case folderIDs = "folderIds"
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
    public let finishedAt: Date?
    public let endReason: ExamEndReason?
    /// The server's clock when it answered. The timer counts down from `endsAt - serverNow`,
    /// so a wrong phone clock does not change her time.
    public let serverNow: Date
    public let questions: [Question]
    public let answeredQuestionIDs: [String]
    public let result: ExamResult?

    public var isRunning: Bool { finishedAt == nil }

    /// Seconds left when the server answered.
    public var secondsLeftAtServerNow: TimeInterval { max(0, endsAt.timeIntervalSince(serverNow)) }

    enum CodingKeys: String, CodingKey {
        case id, courseCode, courseTitle, weeks, pool, practiceWeeks, timeLimitSeconds, startedAt, endsAt
        case finishedAt, endReason, serverNow, questions, result
        case courseID = "courseId"
        case folderIDs = "folderIds"
        case answeredQuestionIDs = "answeredQuestionIds"
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
        public let points: Int
        public let maxPoints: Int
        public let guessed: Bool
        /// Her answer, or nil when she did not answer.
        public let response: AnswerResponse?
        /// The order she saw, or nil.
        public let shuffle: Layout?

        public var id: String { questionID }

        enum CodingKeys: String, CodingKey {
            case status, points, maxPoints, guessed, response, shuffle
            case questionID = "questionId"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            questionID = try container.decode(String.self, forKey: .questionID)
            status = try container.decode(Status.self, forKey: .status)
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

/// The body of `POST /api/courses/{id}/exams`.
struct StartExamRequest: Encodable {
    let folderIds: [String]
    let pool: ExamPool
}

/// The body of `POST /api/exams/{id}/finish`.
struct FinishExamRequest: Encodable {
    let reason: ExamEndReason
}
