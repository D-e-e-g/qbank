import Foundation

// Deleting a course or study topic, an exam page alone, a set, a folder with every set in it, or a
// past exam, and Undo.
// Every delete is three steps: its preview names what goes and hands out `confirm`; the delete sends
// that `confirm` and takes exactly what the preview named, or is refused when something changed
// since; Undo brings it back as it was for `undoDays` (30). Nothing is ever deleted except by her
// confirmed request.

/// A set's kind: practice, or exam (asked only on exams, in its folder's exam bank). Open, so a kind
/// the server adds later still decodes.
public struct SetKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let practice: SetKind = "practice"
    public static let exam: SetKind = "exam"
}

/// A delete's warning as the server splits it for a confirmation: its question as the title
/// ("Delete Week 1?", "Delete NURS 220 and its 146 questions?"), and the rest, what goes with it,
/// her answers and Undo, as the body. Together they are `message`, word for word.
public struct DeleteWarning: Decodable, Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// What every delete's preview carries: the warning to show her, the refusal the delete would get
/// right now, and the `confirm` that deletes exactly what the warning named.
public protocol DeletionPreview: Sendable {
    /// The warning, in the server's words: what goes, her answers, and Undo.
    var message: String { get }
    /// `message` split into its question and the rest, or nil from a server before it sent one.
    var warning: DeleteWarning? { get }
    /// The sentence the delete would be refused with right now, such as an exam in progress still
    /// asking its questions, or nil.
    var refusal: String? { get }
    var confirm: String { get }
    /// How long Undo can bring it back.
    var undoDays: Int { get }
}

/// One count, now and once it is deleted.
public struct CountChange: Decodable, Sendable, Equatable {
    public let before: Int
    public let after: Int

    public init(before: Int, after: Int) {
        self.before = before
        self.after = after
    }
}

/// Her standing in the course now and once it is deleted, as the course page and Exam setup count it.
public struct StandingChange: Decodable, Sendable, Equatable {
    public let answeredCount: CountChange
    public let fullyRightCount: CountChange
    /// Her Review list.
    public let reviewCount: CountChange
    public let points: CountChange
    public let maxPoints: CountChange
    /// Her Wrong questions, over every folder.
    public let wrongCount: CountChange
}

/// What deleting a set takes with it: its questions, every version of it, her answers to it.
public struct SetDeletion: Decodable, Sendable, Equatable, DeletionPreview {
    public let setID: String
    public let title: String
    public let kind: SetKind
    public let folderID: String
    public let folderName: String
    public let examPageID: String?
    public let questionCount: Int
    /// Its versions that go with it, the current one included.
    public let versionCount: Int
    /// Of its questions, the ones she has answered. Those answers stay saved and stop counting.
    public let answeredCount: Int
    /// Of its questions, the ones in her Review list, which leave it.
    public let reviewCount: Int
    public let progress: StandingChange
    public let message: String
    public let warning: DeleteWarning?
    public let refusal: String?
    public let confirm: String
    public let undoDays: Int

    private enum CodingKeys: String, CodingKey {
        case title, kind, folderName, questionCount, versionCount, answeredCount, reviewCount
        case progress, message, warning, refusal, confirm, undoDays
        case setID = "setId"
        case folderID = "folderId"
        case examPageID = "examPageId"
    }
}

/// What deleting a folder takes with it: every set in it, named, their questions and her answers,
/// and its place on its exam page.
public struct FolderDeletion: Decodable, Sendable, Equatable, DeletionPreview {
    /// A set that goes with the folder.
    public struct Set: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let kind: SetKind
        public let questionCount: Int
        public let answeredCount: Int
    }

    public let folderID: String
    public let name: String
    /// The exam page it comes off, or nil.
    public let examPageID: String?
    public let examPageName: String?
    /// Every set in it, practice sets then exam sets, each by title.
    public let sets: [Set]
    public let setCount: Int
    public let questionCount: Int
    public let answeredCount: Int
    public let reviewCount: Int
    /// Her past exams over it. They stay.
    public let pastExamCount: Int
    public let progress: StandingChange
    public let message: String
    public let warning: DeleteWarning?
    public let refusal: String?
    public let confirm: String
    public let undoDays: Int

    private enum CodingKeys: String, CodingKey {
        case name, examPageName, sets, setCount, questionCount, answeredCount, reviewCount, pastExamCount
        case progress, message, warning, refusal, confirm, undoDays
        case folderID = "folderId"
        case examPageID = "examPageId"
    }
}

/// What deleting an exam page (a study page, in a topic) changes: the page alone goes. Its folders
/// stay in the course, on no page at the end of its Folders list, with their sets and her progress,
/// and her past exams over it stay in Exam setup; Undo puts them back on it.
public struct ExamPageDeletion: Decodable, Sendable, Equatable, DeletionPreview {
    /// A folder on the page. It stays, with everything in it.
    public struct Folder: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let setCount: Int
        public let questionCount: Int
    }

    public let examPageID: String
    public let courseID: String
    public let name: String
    /// Its folders, in her order on it.
    public let folders: [Folder]
    public let folderCount: Int
    public let setCount: Int
    public let questionCount: Int
    public let examQuestionCount: Int
    /// Of those questions, the ones she has answered. Those answers keep counting.
    public let answeredCount: Int
    /// Her past exams over the page. They stay, on no page until Undo.
    public let pastExamCount: Int
    /// Her standing now and once it is deleted, which are the same.
    public let progress: StandingChange
    public let message: String
    public let warning: DeleteWarning?
    /// Set while one of its folders has the name of a folder already in the Folders list.
    public let refusal: String?
    public let confirm: String
    public let undoDays: Int

    private enum CodingKeys: String, CodingKey {
        case name, folders, folderCount, setCount, questionCount, examQuestionCount, answeredCount, pastExamCount
        case progress, message, warning, refusal, confirm, undoDays
        case examPageID = "examPageId"
        case courseID = "courseId"
    }
}

/// What deleting a past exam changes: her answers on it stop counting, so questions go back to an
/// earlier answer or to not answered.
public struct ExamDeletion: Decodable, Sendable, Equatable, DeletionPreview {
    public let examID: String
    public let courseID: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let questionCount: Int
    public let answeredCount: Int
    /// Questions whose latest answer goes back to the one she gave before this exam.
    public let changedCount: Int
    /// Questions she answered only on this exam, which go back to not answered.
    public let unansweredCount: Int
    public let progress: StandingChange
    public let message: String
    public let warning: DeleteWarning?
    /// Set while the exam is still going.
    public let refusal: String?
    public let confirm: String
    public let undoDays: Int

    private enum CodingKeys: String, CodingKey {
        case startedAt, finishedAt, questionCount, answeredCount, changedCount, unansweredCount
        case progress, message, warning, refusal, confirm, undoDays
        case examID = "examId"
        case courseID = "courseId"
    }
}

/// What deleting a course or study topic takes with it: everything in it, which comes back with it.
/// Its `message` is the one question to ask her ("Delete NURS 220 and its 146 questions? You can
/// bring it back for 30 days.").
public struct CourseDeletion: Decodable, Sendable, Equatable, DeletionPreview {
    public let courseID: String
    public let kind: CourseKind
    /// Empty for a topic.
    public let code: String
    public let title: String
    /// Nil for a topic.
    public let semester: CourseDetail.SemesterRef?
    public let folderCount: Int
    /// Its exam pages (study pages, in a topic).
    public let examPageCount: Int
    public let setCount: Int
    /// Its practice questions, as its card counts them.
    public let questionCount: Int
    public let examQuestionCount: Int
    /// Of its practice questions, the ones she has answered. Those answers stay saved and count
    /// again once it is back.
    public let answeredCount: Int
    public let reviewCount: Int
    /// Her past exams in it, which go with it and come back with it.
    public let pastExamCount: Int
    public let message: String
    public let warning: DeleteWarning?
    /// Set while a job or an exam in progress still works in it.
    public let refusal: String?
    public let confirm: String
    public let undoDays: Int

    private enum CodingKeys: String, CodingKey {
        case kind, code, title, semester, folderCount, examPageCount, setCount, questionCount, examQuestionCount
        case answeredCount, reviewCount, pastExamCount, message, warning, refusal, confirm, undoDays
        case courseID = "courseId"
    }
}

/// Her courses and study topics deleted in the last `undoDays`, newest first: Home's Recently deleted.
public struct RecentlyDeletedCourses: Decodable, Sendable, Equatable {
    public let undoDays: Int
    public let courses: [DeletedCourse]

    public init(undoDays: Int, courses: [DeletedCourse]) {
        self.undoDays = undoDays
        self.courses = courses
    }
}

/// A course or study topic she deleted, with what it held and when Undo runs out.
public struct DeletedCourse: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CourseKind
    /// Empty for a topic.
    public let code: String
    public let title: String
    /// Nil for a topic.
    public let semester: CourseDetail.SemesterRef?
    /// Its practice questions, as its card counted them.
    public let questionCount: Int
    public let deletedAt: Date
    /// Undo is refused after this.
    public let undoUntil: Date
    /// Why Undo would be refused now, such as its semester having a course of its code, or nil.
    public let undoRefusal: String?

    public init(
        id: String, kind: CourseKind, code: String, title: String, semester: CourseDetail.SemesterRef?, questionCount: Int,
        deletedAt: Date, undoUntil: Date, undoRefusal: String?
    ) {
        self.id = id
        self.kind = kind
        self.code = code
        self.title = title
        self.semester = semester
        self.questionCount = questionCount
        self.deletedAt = deletedAt
        self.undoUntil = undoUntil
        self.undoRefusal = undoRefusal
    }
}

/// What she deleted in a course in the last `undoDays`, newest first: everything Undo can still
/// bring back.
public struct RecentlyDeleted: Decodable, Sendable, Equatable {
    public let undoDays: Int
    /// Exam pages (study pages, in a topic) she deleted. A server from before exam pages could be
    /// deleted sends none.
    public let examPages: [DeletedExamPage]
    public let folders: [DeletedFolder]
    /// Sets she deleted on their own. Sets that went with a folder are under it.
    public let sets: [DeletedSet]
    public let exams: [DeletedExam]

    public init(undoDays: Int, examPages: [DeletedExamPage] = [], folders: [DeletedFolder], sets: [DeletedSet], exams: [DeletedExam]) {
        self.undoDays = undoDays
        self.examPages = examPages
        self.folders = folders
        self.sets = sets
        self.exams = exams
    }

    private enum CodingKeys: String, CodingKey {
        case undoDays, examPages, folders, sets, exams
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        undoDays = try container.decode(Int.self, forKey: .undoDays)
        examPages = try container.decodeIfPresent([DeletedExamPage].self, forKey: .examPages) ?? []
        folders = try container.decode([DeletedFolder].self, forKey: .folders)
        sets = try container.decode([DeletedSet].self, forKey: .sets)
        exams = try container.decode([DeletedExam].self, forKey: .exams)
    }

    public var isEmpty: Bool {
        examPages.isEmpty && folders.isEmpty && sets.isEmpty && exams.isEmpty
    }
}

/// An exam page she deleted, with the folders Undo puts back on it. They are in the course's
/// Folders list meanwhile.
public struct DeletedExamPage: Decodable, Sendable, Equatable, Identifiable {
    public struct Folder: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public let id: String
    public let name: String
    /// In its order.
    public let folders: [Folder]
    /// Her past exams that belong to it again with Undo.
    public let pastExamCount: Int
    public let deletedAt: Date
    /// Undo is refused after this.
    public let undoUntil: Date
    /// Why Undo would be refused now, such as another page having its name, or nil.
    public let undoRefusal: String?

    public init(id: String, name: String, folders: [Folder], pastExamCount: Int, deletedAt: Date, undoUntil: Date, undoRefusal: String?) {
        self.id = id
        self.name = name
        self.folders = folders
        self.pastExamCount = pastExamCount
        self.deletedAt = deletedAt
        self.undoUntil = undoUntil
        self.undoRefusal = undoRefusal
    }
}

/// A folder she deleted, with the sets that went with it.
public struct DeletedFolder: Decodable, Sendable, Equatable, Identifiable {
    public struct Set: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let kind: SetKind
        public let questionCount: Int
    }

    public let id: String
    public let name: String
    /// The exam page Undo puts it back on, or nil for the Folders list.
    public let examPageID: String?
    public let sets: [Set]
    public let deletedAt: Date
    /// Undo is refused after this.
    public let undoUntil: Date
    /// Why Undo would be refused now, such as its list having a folder of its name, or nil.
    public let undoRefusal: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, sets, deletedAt, undoUntil, undoRefusal
        case examPageID = "examPageId"
    }
}

/// A set she deleted on its own.
public struct DeletedSet: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: SetKind
    public let folderID: String?
    public let folderName: String
    public let questionCount: Int
    public let deletedAt: Date
    public let undoUntil: Date
    /// Why Undo would be refused now, such as its folder being deleted, or nil.
    public let undoRefusal: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, folderName, questionCount, deletedAt, undoUntil, undoRefusal
        case folderID = "folderId"
    }
}

/// One of her past exams she deleted: the exam as Exam setup listed it, and when Undo runs out.
public struct DeletedExam: Decodable, Sendable, Equatable, Identifiable {
    public let exam: ExamSummary
    public let deletedAt: Date
    public let undoUntil: Date

    public var id: String { exam.id }

    private enum CodingKeys: String, CodingKey {
        case deletedAt, undoUntil
    }

    public init(from decoder: any Decoder) throws {
        exam = try ExamSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        undoUntil = try container.decode(Date.self, forKey: .undoUntil)
    }
}
