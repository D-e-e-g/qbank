#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// The fake server's study side: her folders and exam pages, Review, Terms and exams, with the
/// real server's rules and words (`apps/api/src/progress`, `exams`, `content/service.ts`). Every
/// question is one of `FakePracticeQuestions`' invented ones, scored with QBankKit's port of the
/// server's scoring. Nothing here comes from a real course. Its exams are in `FakeStudyExams.swift`,
/// and its folders, exam pages and imports in `FakeStudyFolders.swift`.
nonisolated final class FakeStudy: Sendable {
    typealias Reply = (Int, [String: Any])

    /// A folder of sets, on one exam page or none, in her order within its list.
    struct Folder {
        let id: String
        let courseID: String
        var name: String
        var examPageID: String?
        var sortOrder: Int
        /// Its sets, by the id of the version that is current.
        var sets: [String]
        /// Its exam-bank questions, asked only on exams.
        var bank: [String]
    }

    /// A page of a course or topic.
    struct CourseExam {
        let id: String
        let courseID: String
        var name: String
        let sortOrder: Int
        /// Its primer link, a web address, or nil.
        var linkURL: String?
        /// What it is for, "exam", "concept" or "study", or nil for no badge.
        var badge: String?
    }

    struct Answer {
        let clientAttemptID: String
        let status: ScoreStatus
        let points: Int
        let maxPoints: Int
        let guessed: Bool
        let response: AnswerResponse
        let shuffle: Layout?
    }

    struct Exam {
        let id: String
        let courseID: String
        let folderIDs: [String]
        /// Its folders' names when it started.
        let names: [String]
        let pool: ExamPool
        let practiceWeeks: [String]?
        /// The questions in the order served, each with its folder and that folder's name then.
        let questions: [(id: String, folder: String, name: String)]
        let timeLimitSeconds: Int
        var startedAt: Date
        var finishedAt: Date?
        var endReason: ExamEndReason?
        var answers: [String: Answer] = [:]

        var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(timeLimitSeconds)) }

        /// Where it stands at `now`, as the server's `examStatus` tells it: one cut-off for every reader.
        func status(at now: Date) -> Status {
            if finishedAt != nil { return .ended }
            if now < endsAt { return .running }
            return now <= ExamStatus.timeUp(endsAt: endsAt) ? .grace : .expired
        }

        /// Running, or in its grace: it takes an answer, and a new exam or a delete waits for it.
        func isOpen(at now: Date) -> Bool {
            let status = status(at: now)
            return status == .running || status == .grace
        }

        /// As every reader is shown it: one whose time is up reads as ended, a timeout at its end
        /// time, whether or not its end is recorded yet.
        func asRead(at now: Date) -> Exam {
            guard status(at: now) == .expired else { return self }
            var exam = self
            exam.finishedAt = endsAt
            exam.endReason = .timeout
            return exam
        }

        /// What the wire's `status` says at `now`.
        func readStatus(at now: Date) -> ExamStatus {
            switch status(at: now) {
            case .running: .running
            case .grace: .grace
            case .expired, .ended: .ended
            }
        }

        /// The server's four states; `expired` reads as ended.
        enum Status {
            case running, grace, expired, ended
        }
    }

    /// A question in her Review list, from a practice answer.
    struct ReviewEntry {
        let questionID: String
        let weekLabel: String
        let setTitle: String
        var status: ScoreStatus
        var guessed: Bool
        var answeredAt: Date
    }

    struct State {
        var folders: [Folder]
        var courseExams: [CourseExam]
        var exams: [Exam] = []
        var review: [String: [ReviewEntry]]
        /// Her latest mark on each question she answered in this run, practice or exam.
        var latest: [String: ScoreStatus] = [:]
        /// The practice question each exam twin a twin job filed twins, by the twin's id.
        var twinOf: [String: String] = [:]
        var examCount = 0
        var courseExamCount = 0
        var folderCount = 0
        /// Courses and topics made while the app ran, which have pages and folders before any import.
        var known: Set<String> = []
        /// How many questions each set filed while the app ran has, by set id.
        var sizes: [String: Int] = [:]
    }

    static let week1 = "f0000000-0000-4000-8000-000000003101"
    static let week2 = "f0000000-0000-4000-8000-000000003102"
    static let week3 = "f0000000-0000-4000-8000-000000003103"
    static let weeks1to3 = "f0000000-0000-4000-8000-000000003104"
    static let exam1 = "c0e00000-0000-4000-8000-000000000001"
    static let exam2 = "c0e00000-0000-4000-8000-000000000002"

    /// How many questions each set has, by set id.
    static let setSizes: [String: Int] = [
        "rights-v1": 17, "communication-v1": 14, "psychosocial-v1": 12, "psychosocial-v2": 12, "depression-v1": 18,
        "anxiety-v1": 13, "mixed-v1": 8, FakePracticeQuestions.findingsSetID: 1, FakePracticeQuestions.allCorrectSetID: 1,
        "vitals-v1": 43, "safety-v1": 42, "mobility-v1": 61,
    ]

    /// The questions she had last answered not fully right before this run of the app.
    static let wrongAtStart = Set(
        ids("bank1", 4) + ids("communication-v1", 5) + ids("psychosocial-v2", 2) + ids("mixed-v1", 2)
            + ids("vitals-v1", 6) + ids("safety-v1", 9) + ids("mobility-v1", 2)
    )

    /// The courses' codes, for the refusals that name a course.
    static let codes = [FakeQBankServer.mentalHealthID: "NURS 310", FakeQBankServer.fundamentalsID: "NURS 220"]

    /// Invented terms: plain nursing words with plain meanings, written for this fake.
    static let terms: [(term: String, meaning: String, week: String, set: String)] = [
        ("Advocacy", "Speaking up for what the client needs and wants.", "Week 1", "Rights, Law, and Ethics"),
        ("Affect", "The feeling a person shows on the face and in the voice.", "Week 2", "Psychosocial Assessment and Safety Screening"),
        ("Autonomy", "The client's right to make informed choices about their own care.", "Week 1", "Rights, Law, and Ethics"),
        ("Beneficence", "The duty to do good for the client.", "Week 1", "Rights, Law, and Ethics"),
        ("Boundaries", "The limits that keep the nurse-client relationship about the client.", "Week 2", "Therapeutic Communication and the Relationship"),
        ("Clarifying", "Asking the client to say more so the nurse understands.", "Week 2", "Therapeutic Communication and the Relationship"),
        ("Competence", "Being able to understand a choice and its results.", "Week 1", "Rights, Law, and Ethics"),
        ("Least restrictive", "The step that limits the client's freedom the least.", "Week 1", "Rights, Law, and Ethics"),
        ("Rapport", "Trust and ease between the nurse and the client.", "Week 2", "Therapeutic Communication and the Relationship"),
        ("Restatement", "Repeating the client's main idea back in the nurse's words.", "Week 2", "Therapeutic Communication and the Relationship"),
        ("Serotonin", "A brain chemical linked to mood that many antidepressants act on.", "Week 3", "Depression and Antidepressants"),
        ("Veracity", "The duty to tell the truth.", "Week 1", "Rights, Law, and Ethics"),
    ]

    let state: Mutex<State>
    private let now: Date

    /// The set Weeks 1-3 holds: the mixed set, unless a scenario replaces it with one question.
    private static func weeks1to3Set(matrixMulti: Bool, sataAllCorrect: Bool) -> String {
        if sataAllCorrect { return FakePracticeQuestions.allCorrectSetID }
        if matrixMulti { return FakePracticeQuestions.findingsSetID }
        return "mixed-v1"
    }

    /// - Parameters:
    ///   - examInProgress: She left an exam over Weeks 1-2 going, started five minutes ago.
    ///   - examLastQuestionOpen: That exam has every question but its last answered.
    ///   - examEndsIn: That exam's time runs out this long after `now` instead.
    ///   - matrixMultiSet: Weeks 1-3 holds the one-question check-all table instead of the mixed set.
    ///   - sataAllCorrectSet: Weeks 1-3 holds one select-all question whose every option is correct.
    init(
        now: Date, examInProgress: Bool = false, examLastQuestionOpen: Bool = false, examEndsIn: TimeInterval? = nil,
        matrixMultiSet: Bool = false, sataAllCorrectSet: Bool = false
    ) {
        self.now = now
        let day: TimeInterval = 86_400
        let mentalHealth = FakeQBankServer.mentalHealthID, fundamentals = FakeQBankServer.fundamentalsID
        state = Mutex(State(
            folders: [
                Folder(id: Self.week1, courseID: mentalHealth, name: "Week 1", examPageID: Self.exam1, sortOrder: 1, sets: ["rights-v1"], bank: Self.ids("bank1", 17)),
                Folder(id: Self.week2, courseID: mentalHealth, name: "Week 2", examPageID: Self.exam1, sortOrder: 2, sets: ["communication-v1", "psychosocial-v2"], bank: []),
                Folder(id: Self.week3, courseID: mentalHealth, name: "Week 3", examPageID: Self.exam2, sortOrder: 1, sets: ["depression-v1", "anxiety-v1"], bank: Self.ids("bank3", 31)),
                Folder(
                    id: Self.weeks1to3, courseID: mentalHealth, name: "Weeks 1-3", examPageID: nil, sortOrder: 1,
                    sets: [Self.weeks1to3Set(matrixMulti: matrixMultiSet, sataAllCorrect: sataAllCorrectSet)], bank: []
                ),
                Folder(id: "f0000000-0000-4000-8000-000000002201", courseID: fundamentals, name: "Week 1", examPageID: nil, sortOrder: 1, sets: ["vitals-v1"], bank: []),
                Folder(id: "f0000000-0000-4000-8000-000000002202", courseID: fundamentals, name: "Week 2", examPageID: nil, sortOrder: 2, sets: ["safety-v1"], bank: []),
                Folder(id: "f0000000-0000-4000-8000-000000002203", courseID: fundamentals, name: "Week 3", examPageID: nil, sortOrder: 3, sets: ["mobility-v1"], bank: []),
            ],
            courseExams: [
                // Her course's pages from before badges, which the server badged Exam.
                CourseExam(id: Self.exam1, courseID: mentalHealth, name: "Exam 1", sortOrder: 1, badge: "exam"),
                CourseExam(id: Self.exam2, courseID: mentalHealth, name: "Exam 2", sortOrder: 2, badge: "exam"),
            ],
            review: [
                FakeQBankServer.mentalHealthID: [
                    ReviewEntry(questionID: "rights-v1-q4", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .partial, guessed: false, answeredAt: now.addingTimeInterval(-9 * day - 60)),
                    ReviewEntry(questionID: "rights-v1-q2", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .partial, guessed: false, answeredAt: now.addingTimeInterval(-9 * day - 120)),
                    ReviewEntry(questionID: "rights-v1-q5", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .correct, guessed: true, answeredAt: now.addingTimeInterval(-9 * day - 180)),
                    ReviewEntry(questionID: "communication-v1-q6", weekLabel: "Week 2", setTitle: "Therapeutic Communication and the Relationship", status: .incorrect, guessed: true, answeredAt: now.addingTimeInterval(-3 * day - 240)),
                    ReviewEntry(questionID: "rights-v1-q7", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .incorrect, guessed: false, answeredAt: now.addingTimeInterval(-9 * day - 300)),
                    ReviewEntry(questionID: "rights-v1-q0", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .incorrect, guessed: false, answeredAt: now.addingTimeInterval(-10 * day - 360)),
                    ReviewEntry(questionID: "communication-v1-q1", weekLabel: "Week 2", setTitle: "Therapeutic Communication and the Relationship", status: .incorrect, guessed: false, answeredAt: now.addingTimeInterval(-3 * day - 420)),
                    ReviewEntry(questionID: "communication-v1-q3", weekLabel: "Week 2", setTitle: "Therapeutic Communication and the Relationship", status: .partial, guessed: false, answeredAt: now.addingTimeInterval(-3 * day - 480)),
                    ReviewEntry(questionID: "communication-v1-q8", weekLabel: "Week 2", setTitle: "Therapeutic Communication and the Relationship", status: .correct, guessed: true, answeredAt: now.addingTimeInterval(-4 * day - 540)),
                    ReviewEntry(questionID: "rights-v1-q9", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .incorrect, guessed: false, answeredAt: now.addingTimeInterval(-11 * day - 600)),
                    ReviewEntry(questionID: "rights-v1-q11", weekLabel: "Week 1", setTitle: "Rights, Law, and Ethics", status: .correct, guessed: true, answeredAt: now.addingTimeInterval(-11 * day - 660)),
                    ReviewEntry(questionID: "communication-v1-q9", weekLabel: "Week 2", setTitle: "Therapeutic Communication and the Relationship", status: .incorrect, guessed: false, answeredAt: now.addingTimeInterval(-5 * day - 720)),
                ].sorted { $0.answeredAt > $1.answeredAt },
            ]
        ))
        seedPastExams()
        if examInProgress, case .success(let id) = begin(
            courseID: FakeQBankServer.mentalHealthID, folderIDs: [Self.week1, Self.week2], pool: .all,
            at: now.addingTimeInterval(-5 * 60), endingRunning: false
        ) {
            if examLastQuestionOpen { answerAllButLast(id) }
            if let examEndsIn { endExam(id, at: now.addingTimeInterval(examEndsIn)) }
        }
    }

    /// Moves the exam's start so that its time runs out at `end`.
    private func endExam(_ id: String, at end: Date) {
        state.withLock { state in
            guard let index = state.exams.firstIndex(where: { $0.id == id }) else { return }
            state.exams[index].startedAt = end.addingTimeInterval(-TimeInterval(state.exams[index].timeLimitSeconds))
        }
    }

    /// Answers every question of the exam but its last, each right, as she would have.
    private func answerAllButLast(_ id: String) {
        state.withLock { state in
            guard let index = state.exams.firstIndex(where: { $0.id == id }) else { return }
            for (position, question) in state.exams[index].questions.dropLast().enumerated() {
                guard let body = Self.question(question.id)?.body, let response = FakeAnswers.right(body),
                      let score = try? Scoring.score(body, response: response) else { continue }
                state.exams[index].answers[question.id] = Answer(
                    clientAttemptID: "seed-\(id)-\(position)", status: score.status, points: score.points, maxPoints: score.maxPoints,
                    guessed: false, response: response, shuffle: nil
                )
            }
        }
    }

    /// Her exams before this run: Weeks 1-2 three days ago (Exam 1), Week 1 when time ran out
    /// ten days ago (Exam 1), and Weeks 1-3 across both exam pages a week ago (on neither).
    private func seedPastExams() {
        let day: TimeInterval = 86_400
        let pasts: [(folders: [String], startedDaysAgo: Double, minutes: Double, reason: ExamEndReason, pattern: (Int) -> String?)] = [
            ([Self.week1, Self.week2], 3, 52, .finished, { $0 % 5 == 4 ? "wrong" : "right" }),
            ([Self.week1], 10, 26, .timeout, { $0 >= 15 ? nil : ($0 % 7 == 6 ? "wrong" : "right") }),
            ([Self.week1, Self.week2, Self.week3], 7, 41, .finished, { $0 % 4 == 3 ? "partly" : "right" }),
        ]
        for past in pasts {
            let startedAt = now.addingTimeInterval(-past.startedDaysAgo * day)
            guard case .success(let id) = begin(
                courseID: FakeQBankServer.mentalHealthID, folderIDs: past.folders, pool: .all, at: startedAt, endingRunning: false
            ) else { continue }
            state.withLock { state in
                guard let index = state.exams.firstIndex(where: { $0.id == id }) else { return }
                var exam = state.exams[index]
                for (position, question) in exam.questions.enumerated() {
                    guard let kind = past.pattern(position), let body = Self.question(question.id)?.body,
                          let response = kind == "right" ? FakeAnswers.right(body) : kind == "wrong" ? FakeAnswers.wrong(body) : FakeAnswers.partly(body),
                          let score = try? Scoring.score(body, response: response) else { continue }
                    exam.answers[question.id] = Answer(
                        clientAttemptID: "seed-\(id)-\(position)", status: score.status, points: score.points, maxPoints: score.maxPoints,
                        guessed: position == 2, response: response, shuffle: nil
                    )
                }
                let finishedAt = past.reason == .timeout ? exam.endsAt : startedAt.addingTimeInterval(past.minutes * 60)
                exam.finishedAt = min(finishedAt, exam.endsAt)
                exam.endReason = past.reason
                state.exams[index] = exam
            }
        }
    }

    // MARK: Routes

    /// Answers the study and folder routes; nil for any other route. A folder in a reply is drawn
    /// by `folderJSON`, which knows its sets.
    func answer(method: String, path: String, query: [String: String], body: [String: Any], folderJSON: (Folder) -> [String: Any]) -> Reply? {
        let parts = path.split(separator: "/").map(String.init)
        // /api/courses/{id}/...
        if parts.count >= 4, parts[0] == "api", parts[1] == "courses" {
            let courseID = parts[2]
            guard knows(courseID) else { return nil }
            switch (method, parts.dropFirst(3).joined(separator: "/")) {
            case ("GET", "terms"): return (200, ["terms": termsJSON(courseID)])
            case ("GET", "review"): return review(courseID, filter: query["filter"] ?? "all")
            case ("GET", "review/practice"): return reviewPractice(courseID, filter: query["filter"] ?? "all", questionID: query["question"])
            case ("POST", "review/clear"): return clearReview(courseID, confirmed: body["confirmed"] as? Bool ?? false)
            case ("GET", "exams"):
                let folderIDs = query["folderIds"].map { $0.split(separator: ",").map(String.init) } ?? []
                return (200, setup(courseID, folderIDs: folderIDs, pool: query["pool"].flatMap(ExamPool.init(rawValue:)) ?? .all))
            case ("POST", "exams"): return start(courseID, body: body)
            case ("POST", "course-exams"): return saveCourseExam(courseID: courseID, id: nil, body: body)
            case ("POST", "folders"): return Self.reply(createFolder(courseID: courseID, body: body), status: 201, folderJSON)
            case ("PUT", "folder-order"): return reorder(courseID: courseID, body: body, folderJSON)
            default: return nil
            }
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "course-exams", method == "PUT" {
            return saveCourseExam(courseID: nil, id: parts[2], body: body)
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "folders", method == "PATCH" {
            return Self.reply(changeFolder(id: parts[2], body: body), status: 200, folderJSON)
        }
        if parts.count == 4, parts[0] == "api", parts[1] == "practice-sets", parts[3] == "move", method == "POST" {
            return Self.reply(moveSet(id: parts[2], body: body), status: 200, folderJSON)
        }
        if parts.count >= 3, parts[0] == "api", parts[1] == "exams" {
            if parts.count == 3, method == "GET" { return examView(parts[2]) }
            if parts.count == 4, parts[3] == "finish", method == "POST" {
                let reason = (body["reason"] as? String).flatMap(ExamEndReason.init(rawValue:)) ?? .finished
                return finish(parts[2], reason: reason)
            }
        }
        return nil
    }

    /// One of the two studied courses, a course or topic made while the app ran, or a course an
    /// import made folders in.
    func knows(_ courseID: String) -> Bool {
        Self.codes[courseID] != nil || state.withLock { state in state.known.contains(courseID) || state.folders.contains { $0.courseID == courseID } }
    }

    /// A course or topic made while the app ran, so its pages and folders can be made at once.
    func register(course id: String) {
        _ = state.withLock { $0.known.insert(id) }
    }

    /// A course's folders in its page's order: each exam page's, then those on no page.
    func folders(_ courseID: String) -> [Folder] {
        state.withLock { state in Self.ordered(state, courseID: courseID) }
    }

    /// The course's exam pages for `GET /api/courses/{id}`.
    func courseExamsJSON(_ courseID: String) -> [[String: Any]] {
        state.withLock { state in
            state.courseExams.filter { $0.courseID == courseID }.map { Self.pageJSON($0, in: state) }
        }
    }

    /// The version that is current now takes the place of the one she restored from.
    func replace(set old: String, with new: String) {
        state.withLock { state in
            for index in state.folders.indices {
                state.folders[index].sets = state.folders[index].sets.map { $0 == old ? new : $0 }
            }
        }
    }

    static func ordered(_ state: State, courseID: String) -> [Folder] {
        let pages = state.courseExams.filter { $0.courseID == courseID }.sorted { $0.sortOrder < $1.sortOrder }
        let folders = state.folders.filter { $0.courseID == courseID }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return pages.flatMap { page in folders.filter { $0.examPageID == page.id } } + folders.filter { $0.examPageID == nil }
    }

    static func pageJSON(_ page: CourseExam, in state: State) -> [String: Any] {
        let folders = ordered(state, courseID: page.courseID).filter { $0.examPageID == page.id }
        return [
            "id": page.id, "name": page.name, "sortOrder": page.sortOrder,
            "weekLabels": folders.map(\.name), "folderIds": folders.map(\.id), "linkUrl": json(page.linkURL),
            "badge": json(page.badge),
        ]
    }

    func reviewCount(_ courseID: String) -> Int {
        state.withLock { Self.liveReview($0, courseID: courseID).count }
    }

    func termCount(_ courseID: String) -> Int {
        courseID == FakeQBankServer.mentalHealthID ? Self.terms.count : 0
    }

    // MARK: Terms

    /// The set each term's set title names, by the start of its id.
    private static let termSets = [
        "Rights, Law, and Ethics": "rights", "Psychosocial Assessment and Safety Screening": "psychosocial",
        "Therapeutic Communication and the Relationship": "communication", "Depression and Antidepressants": "depression",
    ]

    private func termsJSON(_ courseID: String) -> [[String: Any]] {
        guard courseID == FakeQBankServer.mentalHealthID else { return [] }
        let folders = self.folders(courseID)
        return Self.terms.map { term in
            // A term belongs to its set's folder now, wherever she moved the set.
            let prefix = Self.termSets[term.set].map { "\($0)-v" } ?? "-"
            let folder = folders.first { $0.sets.contains { $0.hasPrefix(prefix) } }
            return [
                "key": term.term.lowercased(), "term": term.term, "meaning": term.meaning,
                "weekLabel": folder?.name ?? term.week, "folderId": folder?.id ?? "", "folderName": folder?.name ?? term.week,
                "setTitle": term.set,
            ]
        }
    }

    // MARK: Review

    /// Her Review list, without the questions of sets she deleted, as every read leaves them out.
    private static func liveReview(_ state: State, courseID: String) -> [ReviewEntry] {
        let folders = state.folders.filter { $0.courseID == courseID }
        return (state.review[courseID] ?? []).filter { folder(of: $0.questionID, in: folders) != nil }
    }

    private func review(_ courseID: String, filter: String) -> Reply {
        let (entries, folders) = state.withLock { (Self.liveReview($0, courseID: courseID), Self.ordered($0, courseID: courseID)) }
        let counts: [String: Any] = [
            "all": entries.count,
            "missed": entries.count { $0.status == .incorrect },
            "partial": entries.count { $0.status == .partial },
            "guessed": entries.count(where: \.guessed),
        ]
        let shown = entries.filter { Self.matches($0, filter) }
        return (200, ["filter": filter, "counts": counts, "questions": shown.map { reviewJSON($0, folders: folders) }])
    }

    private static func matches(_ entry: ReviewEntry, _ filter: String) -> Bool {
        switch filter {
        case "missed": entry.status == .incorrect
        case "partial": entry.status == .partial
        case "guessed": entry.guessed
        default: true
        }
    }

    private func reviewJSON(_ entry: ReviewEntry, folders: [Folder]) -> [String: Any] {
        let template = FakePracticeQuestions.template(forQuestionID: entry.questionID) ?? [:]
        let type = (template["type"] as? String).flatMap(QuestionType.init(rawValue:))
        let folder = Self.folder(of: entry.questionID, in: folders)
        return [
            "questionId": entry.questionID, "topic": template["topic"] as? String ?? "",
            "weekLabel": entry.weekLabel, "folderId": folder?.id ?? "", "folderName": folder?.name ?? entry.weekLabel,
            "format": Self.formatName(type),
            "status": entry.status.rawValue, "guessed": entry.guessed,
            "answeredAt": QBankJSON.formatDate(entry.answeredAt), "setTitle": entry.setTitle,
        ]
    }

    /// The folder a question's set is in now. Question ids are "<set id>-q<index>".
    static func folder(of questionID: String, in folders: [Folder]) -> Folder? {
        let setID = questionID.split(separator: "-").dropLast().joined(separator: "-")
        return folders.first { $0.sets.contains(setID) || $0.bank.contains(questionID) }
    }

    /// The server's format names on Review rows (`QUESTION_TYPE_LABELS`).
    private static func formatName(_ type: QuestionType?) -> String {
        switch type {
        case .single: "Single answer"
        case .priority: "Priority / first action"
        case .sata: "Select all that apply"
        case .highlight: "Highlight"
        case .order: "Ordered response"
        case .match: "Matching"
        case .matrix: "Matrix"
        case .matrixmulti: "Matrix, check all that fit"
        case .cloze: "Drop-down cloze"
        case nil: "Question"
        }
    }

    private func reviewPractice(_ courseID: String, filter: String, questionID: String?) -> Reply {
        let entries = state.withLock { Self.liveReview($0, courseID: courseID) }
        let ids: [String]
        if let questionID {
            guard FakePracticeQuestions.template(forQuestionID: questionID) != nil else {
                return Self.failure(404, "question_not_found", "That question is not in this course.")
            }
            ids = [questionID]
        } else {
            // The server shuffles; the fake keeps the list's order so a test knows what comes next.
            ids = entries.filter { Self.matches($0, filter) }.map(\.questionID)
        }
        let questions = ids.enumerated().map { position, id in
            Self.questionJSON(id, position: position + 1, week: entries.first { $0.questionID == id }?.weekLabel ?? "")
        }
        return (200, [
            "id": courseID, "courseId": courseID, "title": questionID == nil ? "Review" : "Review question",
            "weekLabel": "", "folderId": NSNull(), "kind": "practice", "questions": questions,
        ])
    }

    private func clearReview(_ courseID: String, confirmed: Bool) -> Reply {
        let count = state.withLock { Self.liveReview($0, courseID: courseID).count }
        guard confirmed else {
            return Self.failure(400, "confirmation_required", "Clear all \(Wording.count(count, "question")) from this course's Review list?")
        }
        state.withLock { $0.review[courseID] = [] }
        return (200, ["cleared": count])
    }

    /// A practice answer from the runner: it joins or leaves Review, and marks the question for
    /// Wrong questions only.
    func practiced(questionID: String, courseID: String, score: Score, guessed: Bool, at: Date, weekLabel: String, setTitle: String) {
        state.withLock { state in
            state.latest[questionID] = score.status
            var entries = state.review[courseID] ?? []
            entries.removeAll { $0.questionID == questionID }
            if score.staysInReview(guessed: guessed) {
                entries.insert(ReviewEntry(questionID: questionID, weekLabel: weekLabel, setTitle: setTitle, status: score.status, guessed: guessed, answeredAt: at), at: 0)
            }
            state.review[courseID] = entries
        }
    }

    // MARK: Deleting, for `FakeDeletions`

    /// A folder's exam sets: its exam bank's questions, by the set they came from. An imported or
    /// twin exam set's questions are "bank-<set id>-q<n>"; the invented banks', "bank1-q<n>".
    static func examSets(_ folder: Folder) -> [(id: String, questionIDs: [String])] {
        var sets: [(id: String, questionIDs: [String])] = []
        for question in folder.bank {
            let parts = question.split(separator: "-").dropLast()
            let id = parts.first == "bank" && parts.count > 1 ? parts.dropFirst().joined(separator: "-") : parts.joined(separator: "-")
            if let index = sets.firstIndex(where: { $0.id == id }) {
                sets[index].questionIDs.append(question)
            } else {
                sets.append((id, [question]))
            }
        }
        return sets
    }

    func folder(_ id: String) -> Folder? {
        state.withLock { state in state.folders.first { $0.id == id } }
    }

    /// The folder holding an exam set, and its questions.
    func folder(holdingExamSet id: String) -> (folder: Folder, questionIDs: [String])? {
        state.withLock { state in
            for folder in state.folders {
                if let set = Self.examSets(folder).first(where: { $0.id == id }) { return (folder, set.questionIDs) }
            }
            return nil
        }
    }

    /// Of these questions, how many are in her Review list.
    func inReview(_ questionIDs: Set<String>, courseID: String) -> Int {
        state.withLock { state in (state.review[courseID] ?? []).count { questionIDs.contains($0.questionID) } }
    }

    /// The exams of hers still going in the course.
    func runningExams(courseID: String) -> [Exam] {
        settleExpired()
        return state.withLock { state in state.exams.filter { $0.courseID == courseID && $0.isOpen(at: .now) } }
    }

    func exam(_ id: String) -> Exam? {
        settleExpired()
        return state.withLock { state in state.exams.first { $0.id == id } }
    }

    /// The exam as Exam setup lists it.
    func summaryJSON(examID: String) -> [String: Any]? {
        state.withLock { state in state.exams.first { $0.id == examID }.map { summaryJSON($0, in: state) } }
    }

    /// Her ended exams in the course over a folder.
    func pastExams(over folderID: String, courseID: String) -> Int {
        state.withLock { state in state.exams.count { $0.courseID == courseID && !$0.isOpen(at: .now) && $0.folderIDs.contains(folderID) } }
    }

    /// Takes a practice set out of its folder, remembering its place.
    func take(set id: String) -> (folderID: String, index: Int)? {
        state.withLock { state in
            guard let folder = state.folders.firstIndex(where: { $0.sets.contains(id) }),
                  let index = state.folders[folder].sets.firstIndex(of: id) else { return nil }
            state.folders[folder].sets.remove(at: index)
            return (state.folders[folder].id, index)
        }
    }

    func putBack(set id: String, in folderID: String, at index: Int) {
        state.withLock { state in
            guard let folder = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
            state.folders[folder].sets.insert(id, at: min(index, state.folders[folder].sets.count))
        }
    }

    /// Takes an exam set's questions out of its folder's exam bank.
    func take(examSet id: String) -> (folderID: String, questionIDs: [String])? {
        guard let (folder, questionIDs) = folder(holdingExamSet: id) else { return nil }
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            state.folders[index].bank.removeAll { questionIDs.contains($0) }
        }
        return (folder.id, questionIDs)
    }

    func putBack(bank questionIDs: [String], in folderID: String) {
        file(bank: questionIDs, in: folderID)
    }

    /// Takes a folder, with its sets, out of the course.
    func take(folder id: String) -> Folder? {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else { return nil }
            return state.folders.remove(at: index)
        }
    }

    /// Puts a deleted folder back: on its exam page if that is still there, else at the end of the
    /// Folders list. Refused, in the server's words, when that list has a folder of its name now.
    func putBack(folder: Folder) -> String? {
        state.withLock { state in
            var folder = folder
            if let page = folder.examPageID, !state.courseExams.contains(where: { $0.id == page }) {
                folder.examPageID = nil
                folder.sortOrder = Self.end(of: nil, courseID: folder.courseID, in: state)
            }
            if let clash = Self.nameTaken(folder.name, courseID: folder.courseID, page: folder.examPageID, except: [folder.id], in: state) {
                return "\(clash.message.dropLast()). Rename one of them, then bring this one back."
            }
            state.folders.append(folder)
            return nil
        }
    }

    /// An exam page she has, with its folders in her order on it.
    func page(_ id: String) -> (page: CourseExam, folders: [Folder])? {
        state.withLock { state in
            state.courseExams.first { $0.id == id }.map { page in
                (page, Self.ordered(state, courseID: page.courseID).filter { $0.examPageID == id })
            }
        }
    }

    /// The exam page as `GET /api/courses/{id}` lists it.
    func pageJSON(_ id: String) -> [String: Any]? {
        state.withLock { state in state.courseExams.first { $0.id == id }.map { Self.pageJSON($0, in: state) } }
    }

    /// Why the page cannot be deleted now, in the server's words: one of its folders has the name of
    /// a folder in the Folders list, where it would show.
    func pageDeleteRefusal(_ id: String) -> String? {
        state.withLock { state in
            guard let page = state.courseExams.first(where: { $0.id == id }) else { return nil }
            for folder in Self.ordered(state, courseID: page.courseID) where folder.examPageID == id {
                if let clash = state.folders.first(where: { $0.courseID == page.courseID && $0.examPageID == nil && $0.name.lowercased() == folder.name.lowercased() }) {
                    let name = Self.codes[page.courseID] ?? "This course"
                    return "\(name) already has a folder named \(clash.name) in its Folders list. Rename one of them before deleting \(page.name)."
                }
            }
            return nil
        }
    }

    /// Her ended exams that belong to the page, as Exam setup places them; with `folderIDs`, as if
    /// those folders were on it.
    func pastExams(onPage id: String, folderIDs: [String]? = nil) -> Int {
        state.withLock { state in
            if let folderIDs {
                return state.exams.count { !$0.isOpen(at: .now) && !$0.folderIDs.isEmpty && $0.folderIDs.allSatisfy(folderIDs.contains) }
            }
            return state.exams.count { !$0.isOpen(at: .now) && Self.page(of: $0, in: state) == id }
        }
    }

    /// Takes an exam page out of its course. Its folders stay, at the end of the Folders list in the
    /// page's order; each is remembered with its place on the page, for Undo.
    func take(page id: String) -> (page: CourseExam, folders: [(id: String, sortOrder: Int)])? {
        state.withLock { state in
            guard let index = state.courseExams.firstIndex(where: { $0.id == id }) else { return nil }
            let page = state.courseExams.remove(at: index)
            let own = state.folders.filter { $0.examPageID == id }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            for folder in own {
                guard let at = state.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                state.folders[at].sortOrder = Self.end(of: nil, courseID: page.courseID, in: state)
                state.folders[at].examPageID = nil
            }
            return (page, own.map { ($0.id, $0.sortOrder) })
        }
    }

    /// Of a deleted page's folders, the ones Undo puts back on it: still in the course, on no page.
    func foldersBack(_ folders: [(id: String, sortOrder: Int)]) -> [Folder] {
        state.withLock { state in
            folders.compactMap { remembered in state.folders.first { $0.id == remembered.id && $0.examPageID == nil } }
        }
    }

    /// Why a deleted exam page cannot come back now, in the server's words: another page has its name.
    func pageNameClash(_ page: CourseExam) -> String? {
        state.withLock { state in Self.pageNameClash(page, in: state) }
    }

    private static func pageNameClash(_ page: CourseExam, in state: State) -> String? {
        state.courseExams.first { $0.courseID == page.courseID && $0.name.lowercased() == page.name.lowercased() }.map { clash in
            "This course already has an exam named \(clash.name). Rename one of them, then bring this one back."
        }
    }

    /// Puts a deleted exam page back in its place, with its folders still on no page back on it in
    /// its order. Refused, in the server's words, while another page has its name.
    func putBack(page: CourseExam, folders: [(id: String, sortOrder: Int)]) -> String? {
        state.withLock { state in
            if let clash = Self.pageNameClash(page, in: state) { return clash }
            state.courseExams.append(page)
            for remembered in folders {
                guard let index = state.folders.firstIndex(where: { $0.id == remembered.id && $0.examPageID == nil }) else { continue }
                state.folders[index].examPageID = page.id
                state.folders[index].sortOrder = remembered.sortOrder
            }
            return nil
        }
    }

    func take(exam id: String) -> Exam? {
        state.withLock { state in
            guard let index = state.exams.firstIndex(where: { $0.id == id }) else { return nil }
            return state.exams.remove(at: index)
        }
    }

    func putBack(exam: Exam) {
        state.withLock { $0.exams.append(exam) }
    }

    // MARK: Plumbing

    /// The most a question can score: what its own key scores.
    static func maxPoints(_ question: Question) -> Int? {
        guard let right = FakeAnswers.right(question.body) else { return nil }
        return (try? Scoring.score(question.body, response: right))?.maxPoints
    }

    static func ids(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix)-q\($0)" }
    }

    /// Exam-bank questions are asked only on exams and stay out of Review.
    static func isBank(_ id: String) -> Bool {
        id.hasPrefix("bank")
    }

    static func questionJSON(_ id: String, position: Int, week: String) -> [String: Any] {
        var question = FakePracticeQuestions.template(forQuestionID: id) ?? [:]
        question["id"] = id
        question["publicId"] = "Q\(position)"
        question["position"] = position
        question["weekLabel"] = week
        return question
    }

    static func question(_ id: String) -> Question? {
        guard let data = try? JSONSerialization.data(withJSONObject: questionJSON(id, position: 1, week: "")) else { return nil }
        return try? QBankJSON.decoder.decode(Question.self, from: data)
    }

    static func jsonObject(_ value: some Encodable) -> Any {
        (try? QBankJSON.encoder.encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }

    /// "Week 3", "Week 3 and Week 4", "Week 2, Week 3 and Week 4".
    static func listText(_ labels: [String]) -> String {
        guard labels.count > 1, let last = labels.last else { return labels.joined() }
        return "\(labels.dropLast().joined(separator: ", ")) and \(last)"
    }

    static func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    static func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }
}
#endif
