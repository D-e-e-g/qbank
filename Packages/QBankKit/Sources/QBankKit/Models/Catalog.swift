import Foundation

/// `GET /api/semesters`: her semesters, each with its courses, and her study topics.
public struct Catalog: Codable, Sendable, Equatable {
    public let semesters: [Semester]
    /// Her study topics in her order, archived ones included. Empty from a server before topics.
    public let topics: [CourseSummary]

    public init(semesters: [Semester], topics: [CourseSummary] = []) {
        self.semesters = semesters
        self.topics = topics
    }

    enum CodingKeys: String, CodingKey {
        case semesters, topics
    }

    public init(from decoder: any Decoder) throws {
        // A copy saved on the phone before topics holds the semesters alone, as a list.
        if let semesters = try? decoder.singleValueContainer().decode([Semester].self) {
            self.init(semesters: semesters)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            semesters: try container.decode([Semester].self, forKey: .semesters),
            // Added with topics.
            topics: try container.decodeIfPresent([CourseSummary].self, forKey: .topics) ?? []
        )
    }

    /// Every course and topic, the archived ones too.
    public var everyCourse: [CourseSummary] {
        semesters.flatMap(\.courses) + topics
    }

    /// Her course or topic with this id.
    public func course(id: String) -> CourseSummary? {
        everyCourse.first { $0.id == id }
    }
}

/// A semester and its courses, as Home lists them.
public struct Semester: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let number: Int
    public let name: String
    /// A calendar date such as `2026-01-12`, or nil.
    public let startsOn: String?
    public let endsOn: String?
    /// When she archived it by hand, or nil. Nil from a server before archiving semesters.
    public let archivedAt: Date?
    public let courses: [CourseSummary]

    public init(id: String, number: Int, name: String, startsOn: String?, endsOn: String?, archivedAt: Date? = nil, courses: [CourseSummary]) {
        self.id = id
        self.number = number
        self.name = name
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.archivedAt = archivedAt
        self.courses = courses
    }
}

/// What a course row is: a course in a semester, or a study topic, which has no semester and an
/// empty code. Open, so a kind the server adds later still decodes.
public struct CourseKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let course: CourseKind = "course"
    public static let topic: CourseKind = "topic"
}

/// A course card on Home.
public struct CourseSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// `.course` from a server or a saved copy from before topics.
    public let kind: CourseKind
    public let code: String
    public let title: String
    public let sortOrder: Int
    public let archivedAt: Date?
    public let questionCount: Int
    /// Folder names that hold sets, counted once each: what an app from before folders shows.
    public let weekCount: Int
    /// Her folders in the course, empty ones included: the card's "N folders".
    public let folderCount: Int
    public let reviewCount: Int
    public let answeredCount: Int
    public let fullyRightCount: Int
    public let points: Int
    public let maxPoints: Int

    public init(
        id: String, kind: CourseKind = .course, code: String, title: String, sortOrder: Int, archivedAt: Date?, questionCount: Int,
        weekCount: Int, folderCount: Int? = nil, reviewCount: Int, answeredCount: Int, fullyRightCount: Int, points: Int, maxPoints: Int
    ) {
        self.id = id
        self.kind = kind
        self.code = code
        self.title = title
        self.sortOrder = sortOrder
        self.archivedAt = archivedAt
        self.questionCount = questionCount
        self.weekCount = weekCount
        self.folderCount = folderCount ?? weekCount
        self.reviewCount = reviewCount
        self.answeredCount = answeredCount
        self.fullyRightCount = fullyRightCount
        self.points = points
        self.maxPoints = maxPoints
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, code, title, sortOrder, archivedAt, questionCount, weekCount, folderCount
        case reviewCount, answeredCount, fullyRightCount, points, maxPoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Added with topics; everything from before them is a course.
        kind = try container.decodeIfPresent(CourseKind.self, forKey: .kind) ?? .course
        code = try container.decode(String.self, forKey: .code)
        title = try container.decode(String.self, forKey: .title)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        questionCount = try container.decode(Int.self, forKey: .questionCount)
        weekCount = try container.decode(Int.self, forKey: .weekCount)
        // Added with folders; a server or a saved copy from before them had one folder per week.
        folderCount = try container.decodeIfPresent(Int.self, forKey: .folderCount) ?? weekCount
        reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        answeredCount = try container.decode(Int.self, forKey: .answeredCount)
        fullyRightCount = try container.decode(Int.self, forKey: .fullyRightCount)
        points = try container.decode(Int.self, forKey: .points)
        maxPoints = try container.decode(Int.self, forKey: .maxPoints)
    }
}

/// `GET /api/courses/{id}`: a course, its folders and exam pages, and its practice sets.
public struct CourseDetail: Codable, Sendable, Equatable, Identifiable {
    public struct SemesterRef: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let number: Int
        public let name: String
    }

    public let id: String
    /// `.course` from a server or a saved copy from before topics.
    public let kind: CourseKind
    public let code: String
    public let title: String
    public let archivedAt: Date?
    /// Nil for a topic, which is in no semester.
    public let semester: SemesterRef?
    /// Practice questions. Exam-bank questions are counted per folder.
    public let questionCount: Int
    /// How many questions an exam over every folder draws from.
    public let examQuestionCount: Int
    /// The time an exam over every folder gets, as the server's rules give it. Nil in a copy saved
    /// on the phone before the app read it.
    public let examTimeLimitSeconds: Int?
    /// Folder names that hold sets, counted once each: what an app from before folders shows.
    public let weekCount: Int
    /// Her folders in the course, empty ones included.
    public let folderCount: Int
    public let termCount: Int
    public let reviewCount: Int
    public let answeredCount: Int
    public let fullyRightCount: Int
    public let points: Int
    public let maxPoints: Int
    /// The folders by name, as an app from before folders reads them: two folders that share a
    /// name on different exam pages show as one week here. `folders` is what the app uses.
    public let weeks: [Week]
    /// The course's exam pages, such as Exam 1, in the order they were added. Empty until one is
    /// made, and from a server older than course exams.
    public let exams: [CourseExam]
    /// Every folder of the course, empty ones included, in the course's order: each exam page's
    /// folders, pages in the order of `exams`, then the folders on no exam page; each list in her
    /// order. From a server older than folders, each week reads as a folder named and identified by
    /// its label.
    public let folders: [Folder]

    public init(
        id: String, kind: CourseKind = .course, code: String, title: String, archivedAt: Date?, semester: SemesterRef?,
        questionCount: Int, examQuestionCount: Int, weekCount: Int, termCount: Int, reviewCount: Int,
        answeredCount: Int, fullyRightCount: Int, points: Int, maxPoints: Int, weeks: [Week], exams: [CourseExam] = [],
        folders: [Folder]? = nil, folderCount: Int? = nil, examTimeLimitSeconds: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.code = code
        self.title = title
        self.archivedAt = archivedAt
        self.semester = semester
        self.questionCount = questionCount
        self.examQuestionCount = examQuestionCount
        self.examTimeLimitSeconds = examTimeLimitSeconds
        self.weekCount = weekCount
        self.termCount = termCount
        self.reviewCount = reviewCount
        self.answeredCount = answeredCount
        self.fullyRightCount = fullyRightCount
        self.points = points
        self.maxPoints = maxPoints
        self.weeks = weeks
        self.exams = exams
        self.folders = folders ?? Folder.legacy(weeks: weeks, exams: exams)
        self.folderCount = folderCount ?? self.folders.count
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, code, title, archivedAt, semester, questionCount, examQuestionCount, examTimeLimitSeconds, weekCount, folderCount, termCount
        case reviewCount, answeredCount, fullyRightCount, points, maxPoints, weeks, exams, folders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Added with topics; everything from before them is a course.
        kind = try container.decodeIfPresent(CourseKind.self, forKey: .kind) ?? .course
        code = try container.decode(String.self, forKey: .code)
        title = try container.decode(String.self, forKey: .title)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        // Null for a topic.
        semester = try container.decodeIfPresent(SemesterRef.self, forKey: .semester)
        questionCount = try container.decode(Int.self, forKey: .questionCount)
        examQuestionCount = try container.decode(Int.self, forKey: .examQuestionCount)
        examTimeLimitSeconds = try container.decodeIfPresent(Int.self, forKey: .examTimeLimitSeconds)
        weekCount = try container.decode(Int.self, forKey: .weekCount)
        termCount = try container.decode(Int.self, forKey: .termCount)
        reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        answeredCount = try container.decode(Int.self, forKey: .answeredCount)
        fullyRightCount = try container.decode(Int.self, forKey: .fullyRightCount)
        points = try container.decode(Int.self, forKey: .points)
        maxPoints = try container.decode(Int.self, forKey: .maxPoints)
        weeks = try container.decode([Week].self, forKey: .weeks)
        // Added with course exams; a server from before them leaves it out, which reads as none.
        exams = try container.decodeIfPresent([CourseExam].self, forKey: .exams) ?? []
        // Added with folders; a server or a saved copy from before them reads each week as a folder.
        folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? Folder.legacy(weeks: weeks, exams: exams)
        folderCount = try container.decodeIfPresent(Int.self, forKey: .folderCount) ?? folders.count
    }
}

/// A page of a course or topic, such as "Exam 1" or "Page 3", and the folders on it. A folder is on
/// one page of its course at most.
public struct CourseExam: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sortOrder: Int
    /// The names of its folders, for an app from before folders.
    public let weekLabels: [String]
    /// Its folders (`CourseDetail.folders` with this `examPageID`), in her order on the page.
    /// Empty from a server older than folders.
    public let folderIDs: [String]
    /// Its primer: the web address where she wrote the page up, which the page opens, or nil.
    /// Nil from a server before primer links.
    public let linkURL: String?
    /// What the page is for, or nil for no badge. Nil from a server before badges, and for a badge
    /// this version does not know.
    public let badge: PageBadge?
    /// True when the server sent `badge`, null included, so its update takes one. A server before
    /// badges sends none and would drop a badge it was given.
    public let takesBadge: Bool

    public init(
        id: String, name: String, sortOrder: Int, weekLabels: [String], folderIDs: [String] = [], linkURL: String? = nil,
        badge: PageBadge? = nil, takesBadge: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.weekLabels = weekLabels
        self.folderIDs = folderIDs
        self.linkURL = linkURL
        self.badge = badge
        self.takesBadge = takesBadge
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, weekLabels, badge
        case folderIDs = "folderIds"
        case linkURL = "linkUrl"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        weekLabels = try container.decode([String].self, forKey: .weekLabels)
        folderIDs = try container.decodeIfPresent([String].self, forKey: .folderIDs) ?? []
        linkURL = try container.decodeIfPresent(String.self, forKey: .linkURL)
        badge = try container.decodeIfPresent(String.self, forKey: .badge).flatMap(PageBadge.init(rawValue:))
        takesBadge = container.contains(.badge)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(weekLabels, forKey: .weekLabels)
        try container.encode(folderIDs, forKey: .folderIDs)
        try container.encodeIfPresent(linkURL, forKey: .linkURL)
        // A saved copy keeps whether the server takes a badge: null when it has none.
        if takesBadge { try container.encode(badge, forKey: .badge) }
    }
}

/// The one badge a page can carry, which says what it is for. A new page has none; she sets it in
/// the page's editor.
public enum PageBadge: String, Codable, Sendable, CaseIterable {
    case exam
    case concept
    case study
}

/// What saving an exam page does to its primer link.
public enum PrimerLink: Sendable, Equatable {
    /// Leaves it as it is, or none on a new page: a course's exam page has no link field.
    case unchanged
    /// Takes it off.
    case none
    /// An http or https address, which the server checks.
    case url(String)
}

/// The body of `POST /api/courses/{id}/course-exams` and `PUT /api/course-exams/{id}`.
struct CourseExamRequest: Encodable {
    let name: String
    let folderIds: [String]
    let link: PrimerLink
    /// The badge to set, nil for none; left out when nil, so the page keeps its badge. Only PUT
    /// sends one: a new page has no badge.
    var badge: PageBadge??

    private enum CodingKeys: String, CodingKey {
        case name, folderIds, linkUrl, badge
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(folderIds, forKey: .folderIds)
        switch link {
        case .unchanged:
            // Left out, PUT keeps the page's link.
            break
        case .none:
            try container.encodeNil(forKey: .linkUrl)
        case .url(let url):
            try container.encode(url, forKey: .linkUrl)
        }
        switch badge {
        case nil:
            break
        case .some(nil):
            // Null takes the badge off.
            try container.encodeNil(forKey: .badge)
        case .some(let badge?):
            try container.encode(badge, forKey: .badge)
        }
    }
}

/// A folder of a course: her practice sets, on one exam page or none. Its id is its identity, so
/// two folders may share a name on different exam pages, and a rename changes nothing else.
public struct Folder: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The exam page (`CourseDetail.exams`) it is on, or nil when it is on none.
    public let examPageID: String?
    /// Its place in its list: its exam page's folders, or the folders on no exam page.
    public let sortOrder: Int
    /// Its practice sets. Exam-bank sets are counted in `examBankCount` instead.
    public let sets: [PracticeSetSummary]
    /// Exam-bank questions in this folder, asked only on exams. 0 without an exam bank.
    public let examBankCount: Int
    /// Its exam sets (its exam bank), by title, each asked only on exams. Empty without an exam
    /// bank. One can be deleted on its own.
    public let examSets: [ExamSetSummary]

    public init(
        id: String, name: String, examPageID: String?, sortOrder: Int, sets: [PracticeSetSummary], examBankCount: Int,
        examSets: [ExamSetSummary] = []
    ) {
        self.id = id
        self.name = name
        self.examPageID = examPageID
        self.sortOrder = sortOrder
        self.sets = sets
        self.examBankCount = examBankCount
        self.examSets = examSets
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, sets, examBankCount, examSets
        case examPageID = "examPageId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        examPageID = try container.decodeIfPresent(String.self, forKey: .examPageID)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        sets = try container.decode([PracticeSetSummary].self, forKey: .sets)
        examBankCount = try container.decode(Int.self, forKey: .examBankCount)
        // Added with deleting; a server or a saved copy from before it sent only the count.
        examSets = try container.decodeIfPresent([ExamSetSummary].self, forKey: .examSets) ?? []
    }

    /// The folders a course from before folders has: one per week, named and identified by its
    /// label, on the exam holding that label, in week order.
    static func legacy(weeks: [Week], exams: [CourseExam]) -> [Folder] {
        weeks.enumerated().map { index, week in
            Folder(
                id: week.label,
                name: week.label,
                examPageID: exams.first { $0.weekLabels.contains(week.label) }?.id,
                sortOrder: index + 1,
                sets: week.sets,
                examBankCount: week.examBankCount
            )
        }
    }
}

/// An exam set of a folder's exam bank, asked only on exams.
public struct ExamSetSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let questionCount: Int

    public init(id: String, title: String, questionCount: Int) {
        self.id = id
        self.title = title
        self.questionCount = questionCount
    }
}

/// The body of `POST /api/courses/{id}/folders`, and of `PATCH /api/folders/{id}` for a rename.
struct FolderNameRequest: Encodable {
    let name: String
}

/// The body of `PATCH /api/folders/{id}` that puts a folder on an exam page or, with nil, on none.
struct FolderPageRequest: Encodable {
    let examPageId: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Taking it off its page is sent as null; left out, the folder would keep its page.
        try container.encode(examPageId, forKey: .examPageId)
    }

    enum CodingKeys: String, CodingKey {
        case examPageId
    }
}

/// The body of `POST /api/practice-sets/{id}/move`: a folder of the course, or a new one by name.
struct MoveSetRequest: Encodable {
    let folderId: String?
    let newFolderName: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encodeIfPresent(newFolderName, forKey: .newFolderName)
    }

    enum CodingKeys: String, CodingKey {
        case folderId, newFolderName
    }
}

/// The body of `PUT /api/courses/{id}/folder-order`: one list's folders in her order.
struct FolderOrderRequest: Encodable {
    let examPageId: String?
    let folderIds: [String]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The folders on no exam page are sent as null, not left out.
        try container.encode(examPageId, forKey: .examPageId)
        try container.encode(folderIds, forKey: .folderIds)
    }

    enum CodingKeys: String, CodingKey {
        case examPageId, folderIds
    }
}

/// One week of a course: its sets under one folder name, as an app from before folders reads them.
public struct Week: Codable, Sendable, Equatable, Identifiable {
    public let label: String
    public let sets: [PracticeSetSummary]
    /// Exam-bank questions that count toward this week, asked only on exams. 0 without an exam bank.
    public let examBankCount: Int

    public var id: String { label }
}

/// A practice set row on the course screen.
public struct PracticeSetSummary: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case imported
        case replaced
        case restored
    }

    public let id: String
    public let title: String
    public let description: String
    public let questionCount: Int
    public let importedAt: Date
    public let activeSince: Date
    public let status: Status
    public let canRestore: Bool
    public let answeredCount: Int
    public let fullyRightCount: Int
    public let lastAnsweredAt: Date?
    public let questionIDs: [String]
    /// The agent key that imported this version of the set, or nil when she imported it in the app,
    /// QBank made it, or it came from a server or a saved copy from before agent keys.
    public let importedByAgent: ImportingAgent?

    enum CodingKeys: String, CodingKey {
        case id, title, description, questionCount, importedAt, activeSince, status, canRestore
        case answeredCount, fullyRightCount, lastAnsweredAt
        case questionIDs = "questionIds"
        case importedByAgent
    }
}

/// A row of the course's Terms screen.
public struct Term: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let term: String
    public let meaning: String
    /// The name of its set's folder, for an app from before folders.
    public let weekLabel: String
    /// The folder of the set that defines it. Nil from a server older than folders.
    public let folderID: String?
    /// That folder's name, or the week label from a server older than folders.
    public let folderName: String
    public let setTitle: String

    public var id: String { "\(key)|\(folderID ?? weekLabel)|\(setTitle)" }

    public init(key: String, term: String, meaning: String, weekLabel: String, folderID: String? = nil, folderName: String? = nil, setTitle: String) {
        self.key = key
        self.term = term
        self.meaning = meaning
        self.weekLabel = weekLabel
        self.folderID = folderID
        self.folderName = folderName ?? weekLabel
        self.setTitle = setTitle
    }

    enum CodingKeys: String, CodingKey {
        case key, term, meaning, weekLabel, folderName, setTitle
        case folderID = "folderId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        term = try container.decode(String.self, forKey: .term)
        meaning = try container.decode(String.self, forKey: .meaning)
        weekLabel = try container.decode(String.self, forKey: .weekLabel)
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? weekLabel
        setTitle = try container.decode(String.self, forKey: .setTitle)
    }
}
