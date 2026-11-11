#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// The fake server's study side: her folders and exam pages, Review, Terms and exams, with the
/// real server's rules and words (`apps/api/src/progress`, `exams`, `content/service.ts`). Every
/// question is one of `FakePracticeQuestions`' invented ones, scored with QBankKit's port of the
/// server's scoring. Nothing here comes from a real course.
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
        let startedAt: Date
        var finishedAt: Date?
        var endReason: ExamEndReason?
        var answers: [String: Answer] = [:]

        var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(timeLimitSeconds)) }
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

    private let state: Mutex<State>
    private let now: Date

    /// The set Weeks 1-3 holds: the mixed set, unless a scenario replaces it with one question.
    private static func weeks1to3Set(matrixMulti: Bool, sataAllCorrect: Bool) -> String {
        if sataAllCorrect { return FakePracticeQuestions.allCorrectSetID }
        if matrixMulti { return FakePracticeQuestions.findingsSetID }
        return "mixed-v1"
    }

    /// - Parameters:
    ///   - examInProgress: She left an exam over Weeks 1-2 going, started five minutes ago.
    ///   - matrixMultiSet: Weeks 1-3 holds the one-question check-all table instead of the mixed set.
    ///   - sataAllCorrectSet: Weeks 1-3 holds one select-all question whose every option is correct.
    init(now: Date, examInProgress: Bool = false, matrixMultiSet: Bool = false, sataAllCorrectSet: Bool = false) {
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
        if examInProgress {
            _ = begin(
                courseID: FakeQBankServer.mentalHealthID, folderIDs: [Self.week1, Self.week2], pool: .all,
                at: now.addingTimeInterval(-5 * 60), endingRunning: false
            )
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

    private static func ordered(_ state: State, courseID: String) -> [Folder] {
        let pages = state.courseExams.filter { $0.courseID == courseID }.sorted { $0.sortOrder < $1.sortOrder }
        let folders = state.folders.filter { $0.courseID == courseID }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return pages.flatMap { page in folders.filter { $0.examPageID == page.id } } + folders.filter { $0.examPageID == nil }
    }

    private static func pageJSON(_ page: CourseExam, in state: State) -> [String: Any] {
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

    // MARK: Exam setup and start

    /// What an exam over a folder draws from: its exam bank, or its sets' practice questions.
    private static func pool(_ folder: Folder, sizes: [String: Int]) -> [String] {
        folder.bank.isEmpty ? folder.sets.flatMap { ids($0, setSizes[$0] ?? sizes[$0] ?? 0) } : folder.bank
    }

    /// With Wrong questions only: the questions she last answered not fully right, and in an exam
    /// bank the twins of her wrong practice questions until she answers the twin itself.
    private static func wrongPool(_ folder: Folder, sizes: [String: Int], latest: [String: ScoreStatus], twinOf: [String: String]) -> [String] {
        pool(folder, sizes: sizes).filter { id in
            if latest[id] == nil, let practice = twinOf[id] { return isWrong(practice, latest: latest) }
            return isWrong(id, latest: latest)
        }
    }

    private static func isWrong(_ id: String, latest: [String: ScoreStatus]) -> Bool {
        latest[id].map { $0 != .correct } ?? wrongAtStart.contains(id)
    }

    /// The setup, with the server's rules, its plan over `folderIDs` from `pool` when some were
    /// asked for, and its plan over each exam page's folders.
    private func setup(_ courseID: String, folderIDs: [String], pool: ExamPool) -> [String: Any] {
        settleExpired()
        return state.withLock { state in
            let course = Self.ordered(state, courseID: courseID)
            let folders = course.filter { !Self.pool($0, sizes: state.sizes).isEmpty }
            let exams = state.exams.filter { $0.courseID == courseID }.sorted { $0.startedAt > $1.startedAt }
            let summaries = exams.map { summaryJSON($0, in: state) }
            let pools = folders.map { folder -> [String: Any] in
                [
                    "id": folder.id, "name": folder.name, "examPageId": Self.json(folder.examPageID),
                    "questionCount": Self.pool(folder, sizes: state.sizes).count,
                    "wrongCount": Self.wrongPool(folder, sizes: state.sizes, latest: state.latest, twinOf: state.twinOf).count,
                    "source": folder.bank.isEmpty ? "practice" : "exam",
                ]
            }
            // An app from before folders reads the same pools by name.
            var weeks: [[String: Any]] = []
            for folder in folders where !weeks.contains(where: { $0["label"] as? String == folder.name }) {
                let same = folders.filter { $0.name == folder.name }
                weeks.append([
                    "label": folder.name, "questionCount": same.reduce(0) { $0 + Self.pool($1, sizes: state.sizes).count },
                    "wrongCount": same.reduce(0) { $0 + Self.wrongPool($1, sizes: state.sizes, latest: state.latest, twinOf: state.twinOf).count },
                    "source": same.contains { !$0.bank.isEmpty } ? "exam" : "practice",
                ])
            }
            let (sizes, latest, twinOf) = (state.sizes, state.latest, state.twinOf)
            let all = { (folder: Folder) in Self.pool(folder, sizes: sizes) }
            let draw = pool == .wrong ? { (folder: Folder) in Self.wrongPool(folder, sizes: sizes, latest: latest, twinOf: twinOf) } : all
            let pages = state.courseExams.filter { $0.courseID == courseID }.sorted { $0.sortOrder < $1.sortOrder }
            let rules = ExamPlan.rules
            return [
                "courseId": courseID, "weeks": weeks, "folders": pools,
                "inProgress": exams.firstIndex { $0.finishedAt == nil }.map { summaries[$0] } ?? NSNull(),
                "exams": exams.indices.filter { exams[$0].finishedAt != nil }.map { summaries[$0] },
                "rules": ["maxQuestions": rules.maxQuestions, "fullTimeSeconds": rules.fullTimeSeconds, "secondsPerQuestion": rules.secondsPerQuestion],
                "preview": folderIDs.isEmpty ? NSNull() : Self.preview(course.filter { folderIDs.contains($0.id) }, in: course, draw: draw),
                "courseExams": pages.map { page in
                    ["courseExamId": page.id, "preview": Self.preview(course.filter { $0.examPageID == page.id }, in: course, draw: all)]
                },
            ]
        }
    }

    /// The exam that starting over these folders would give, as the server's preview plans it: a
    /// folder with nothing to draw is left out.
    static func preview(_ ticked: [Folder], in course: [Folder], draw: (Folder) -> [String]) -> [String: Any] {
        let drawing = ticked.filter { !draw($0).isEmpty }
        let plan = ExamPlan(drawing.map { ExamPlan.Pool(id: $0.id, name: $0.name, questionCount: draw($0).count) })
        let rows = zip(drawing, plan.draws).map { folder, row -> [String: Any] in
            ["id": folder.id, "name": folder.name, "questionCount": row.questionCount, "drawn": row.drawn, "source": folder.bank.isEmpty ? "practice" : "exam"]
        }
        // An app from before folders reads the same draw by name.
        var weeks: [[String: Any]] = []
        for row in rows {
            if let index = weeks.firstIndex(where: { $0["label"] as? String == row["name"] as? String }) {
                weeks[index]["questionCount"] = (weeks[index]["questionCount"] as? Int ?? 0) + (row["questionCount"] as? Int ?? 0)
                weeks[index]["drawn"] = (weeks[index]["drawn"] as? Int ?? 0) + (row["drawn"] as? Int ?? 0)
            } else {
                weeks.append(["label": row["name"] ?? "", "questionCount": row["questionCount"] ?? 0, "drawn": row["drawn"] ?? 0, "source": row["source"] ?? "practice"])
            }
        }
        return [
            "folders": rows, "weeks": weeks, "questionCount": plan.questionCount, "timeLimitSeconds": plan.timeLimitSeconds,
            "practiceWeeks": course.contains { !$0.bank.isEmpty } ? drawing.filter(\.bank.isEmpty).map(\.name) : NSNull(),
        ]
    }

    /// The time an exam over every folder gets, as a course's `examTimeLimitSeconds` says.
    static func examTime(questionCount: Int) -> Int {
        ExamPlan([ExamPlan.Pool(id: "", name: "", questionCount: questionCount)]).timeLimitSeconds
    }

    /// The exam page holding every folder an exam covered, as the server's `courseExamOf` rules.
    private static func page(of exam: Exam, in state: State) -> String? {
        state.courseExams.filter { $0.courseID == exam.courseID }.sorted { $0.sortOrder < $1.sortOrder }.first { page in
            exam.folderIDs.allSatisfy { id in state.folders.contains { $0.id == id && $0.examPageID == page.id } }
        }?.id
    }

    private func summaryJSON(_ exam: Exam, in state: State) -> [String: Any] {
        let result = exam.finishedAt == nil ? nil : score(exam, in: state)
        return [
            "id": exam.id, "courseId": exam.courseID, "weeks": exam.names, "folderIds": exam.folderIDs,
            "courseExamId": Self.json(Self.page(of: exam, in: state)),
            "pool": exam.pool.rawValue, "practiceWeeks": exam.practiceWeeks.map { $0 as Any } ?? NSNull(),
            "questionCount": exam.questions.count, "timeLimitSeconds": exam.timeLimitSeconds,
            "startedAt": QBankJSON.formatDate(exam.startedAt), "endsAt": QBankJSON.formatDate(exam.endsAt),
            "finishedAt": Self.json(exam.finishedAt.map(QBankJSON.formatDate)), "endReason": Self.json(exam.endReason?.rawValue),
            "answeredCount": exam.answers.count,
            "fullyRight": result.map { $0["fullyRight"] as Any } ?? NSNull(),
            "points": result.map { $0["points"] as Any } ?? NSNull(),
            "maxPoints": result.map { $0["maxPoints"] as Any } ?? NSNull(),
            "minutesUsed": result.map { $0["minutesUsed"] as Any } ?? NSNull(),
        ]
    }

    private func start(_ courseID: String, body: [String: Any]) -> Reply {
        let folderIDs = body["folderIds"] as? [String] ?? []
        let pool = (body["pool"] as? String).flatMap(ExamPool.init(rawValue:)) ?? .all
        switch begin(courseID: courseID, folderIDs: folderIDs, pool: pool, at: .now, endingRunning: true) {
        case .success(let id): return examView(id, status: 201)
        case .failure(let refusal): return Self.failure(400, refusal.code, refusal.message)
        }
    }

    struct Refusal: Error {
        let code: String
        let message: String
    }

    /// Draws an exam as the server does, folder by folder in her order and without shuffling, so a
    /// test knows which question comes when.
    private func begin(courseID: String, folderIDs: [String], pool: ExamPool, at startedAt: Date, endingRunning: Bool) -> Result<String, Refusal> {
        let (course, latest, twinOf, sizes) = state.withLock { (Self.ordered($0, courseID: courseID), $0.latest, $0.twinOf, $0.sizes) }
        guard !folderIDs.isEmpty else { return .failure(Refusal(code: "no_folders", message: "Tick at least one folder.")) }
        if folderIDs.contains(where: { id in !course.contains { $0.id == id } }) {
            return .failure(Refusal(code: "folder_not_found", message: "That folder is not in this course."))
        }
        let ticked = course.filter { folderIDs.contains($0.id) }
        let draw = { (folder: Folder) -> [String] in
            pool == .wrong ? Self.wrongPool(folder, sizes: sizes, latest: latest, twinOf: twinOf) : Self.pool(folder, sizes: sizes)
        }
        let empty = ticked.filter { draw($0).isEmpty }.map(\.name)
        if !empty.isEmpty {
            let one = empty.count == 1
            return .failure(Refusal(
                code: pool == .wrong ? "no_wrong_questions" : "no_questions",
                message: pool == .wrong
                    ? "\(Self.listText(empty)) \(one ? "has" : "have") no wrong questions. Untick \(one ? "it" : "them"), or turn off Wrong questions only."
                    : "\(Self.listText(empty)) \(one ? "has" : "have") no questions."
            ))
        }
        let plan = ExamPlan(ticked.map { ExamPlan.Pool(id: $0.id, name: $0.name, questionCount: draw($0).count) })
        let questions = zip(ticked, plan.draws).flatMap { folder, row in
            draw(folder).prefix(row.drawn).map { (id: $0, folder: folder.id, name: folder.name) }
        }
        let practiceWeeks = course.contains { !$0.bank.isEmpty } ? ticked.filter(\.bank.isEmpty).map(\.name) : nil
        // A running exam of hers ends first, as if she had left it.
        if endingRunning {
            for exam in state.withLock({ $0.exams.filter { $0.finishedAt == nil } }) {
                close(exam.id, reason: .left)
            }
        }
        return state.withLock { state in
            state.examCount += 1
            let id = String(format: "e0000000-0000-4000-8000-%012d", state.examCount)
            state.exams.append(Exam(
                id: id, courseID: courseID, folderIDs: ticked.map(\.id), names: ticked.map(\.name), pool: pool,
                practiceWeeks: practiceWeeks, questions: questions, timeLimitSeconds: plan.timeLimitSeconds, startedAt: startedAt
            ))
            return .success(id)
        }
    }

    // MARK: One exam

    private func examView(_ id: String, status: Int = 200) -> Reply {
        settleExpired()
        guard let exam = state.withLock({ $0.exams.first { $0.id == id } }) else {
            return Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        let course = exam.courseID == FakeQBankServer.mentalHealthID ? ("NURS 310", "Mental Health") : ("NURS 220", "Fundamentals")
        let result = exam.finishedAt == nil ? nil : state.withLock { score(exam, in: $0) }
        return (status, [
            "id": exam.id, "courseId": exam.courseID, "courseCode": course.0, "courseTitle": course.1,
            "weeks": exam.names, "folderIds": exam.folderIDs,
            "pool": exam.pool.rawValue, "practiceWeeks": exam.practiceWeeks.map { $0 as Any } ?? NSNull(),
            "timeLimitSeconds": exam.timeLimitSeconds, "startedAt": QBankJSON.formatDate(exam.startedAt),
            "endsAt": QBankJSON.formatDate(exam.endsAt), "finishedAt": Self.json(exam.finishedAt.map(QBankJSON.formatDate)),
            "endReason": Self.json(exam.endReason?.rawValue), "serverNow": QBankJSON.formatDate(.now),
            "questions": exam.questions.enumerated().map { Self.questionJSON($1.id, position: $0 + 1, week: $1.name) },
            "answeredQuestionIds": exam.questions.map(\.id).filter { exam.answers[$0] != nil },
            "result": result.map { $0 as Any } ?? NSNull(),
        ])
    }

    private func finish(_ id: String, reason: ExamEndReason) -> Reply {
        guard state.withLock({ $0.exams.contains { $0.id == id } }) else {
            return Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        close(id, reason: reason)
        return examView(id)
    }

    /// Ends the running exam. After its time is up, the end is a timeout at the moment time ran out.
    private func close(_ id: String, reason: ExamEndReason) {
        state.withLock { state in
            guard let index = state.exams.firstIndex(where: { $0.id == id }), state.exams[index].finishedAt == nil else { return }
            let deadline = state.exams[index].endsAt
            let timedOut = Date.now >= deadline
            state.exams[index].finishedAt = timedOut ? deadline : .now
            state.exams[index].endReason = timedOut ? .timeout : reason
        }
    }

    private func settleExpired() {
        let expired = state.withLock { state in state.exams.filter { $0.finishedAt == nil && Date.now >= $0.endsAt }.map(\.id) }
        for id in expired { close(id, reason: .timeout) }
    }

    /// An answer on a running exam. Nil when the submission is not for an exam.
    func examAnswer(sessionID: String, clientAttemptID: String, questionID: String, response: AnswerResponse, guessed: Bool, shuffle: Layout?) -> Reply {
        settleExpired()
        return state.withLock { state -> Reply in
            guard let index = state.exams.firstIndex(where: { $0.id == sessionID }) else {
                return Self.failure(404, "exam_not_found", "That exam is not in the app.")
            }
            let exam = state.exams[index]
            guard exam.finishedAt == nil else {
                return Self.failure(409, "exam_finished", "This exam has ended. That answer was not saved.")
            }
            guard let served = exam.questions.first(where: { $0.id == questionID }), let question = Self.question(questionID) else {
                return Self.failure(400, "question_not_in_exam", "That question is not on this exam.")
            }
            guard exam.answers[questionID] == nil else {
                return Self.failure(409, "already_answered", "That question was already answered on this exam.")
            }
            let score: Score
            switch Result(catching: { () throws(ScoringError) -> Score in try Scoring.score(question.body, response: response) }) {
            case .success(let scored): score = scored
            case .failure(let error): return Self.failure(400, "invalid_request", error.message)
            }
            state.exams[index].answers[questionID] = Answer(
                clientAttemptID: clientAttemptID, status: score.status, points: score.points, maxPoints: score.maxPoints,
                guessed: guessed, response: response, shuffle: shuffle
            )
            state.latest[questionID] = score.status
            let bank = Self.isBank(questionID)
            var inReview = false
            if !bank, var entries = state.review[exam.courseID] {
                entries.removeAll { $0.questionID == questionID }
                inReview = score.staysInReview(guessed: guessed)
                if inReview {
                    entries.insert(ReviewEntry(questionID: questionID, weekLabel: served.name, setTitle: "Exam", status: score.status, guessed: guessed, answeredAt: .now), at: 0)
                }
                state.review[exam.courseID] = entries
            }
            return (201, [
                "clientAttemptId": clientAttemptID, "questionId": questionID, "courseId": exam.courseID,
                "status": score.status.rawValue, "points": score.points, "maxPoints": score.maxPoints,
                "guessed": guessed, "answeredAt": QBankJSON.formatDate(.now), "inReview": inReview,
                "label": score.label, "pointsText": question.type.flatMap(score.pointsText(for:)) ?? NSNull(),
                "ruleText": question.type?.scoringRule ?? NSNull(), "replayed": false,
            ])
        }
    }

    private static let stepOrder = ["Recognize cues", "Analyze cues", "Prioritize hypotheses", "Generate solutions", "Take action", "Take actions", "Evaluate outcomes"]

    /// The result of an ended exam, counted as the server counts it: by folder under each folder's
    /// name now, and by the names its folders had, for an app from before folders.
    private func score(_ exam: Exam, in state: State) -> [String: Any] {
        var items: [[String: Any]] = []
        var weeks = exam.names.map { (label: $0, right: 0, total: 0) }
        var folders = exam.folderIDs.map { id in
            (id: id, label: state.folders.first { $0.id == id }?.name ?? exam.names[exam.folderIDs.firstIndex(of: id) ?? 0], right: 0, total: 0)
        }
        var steps: [(label: String, right: Int, total: Int)] = []
        var counts = (fullyRight: 0, partial: 0, missed: 0, guessed: 0, answered: 0, points: 0, maxPoints: 0, review: 0, bankWrong: 0)
        for served in exam.questions {
            let answer = exam.answers[served.id]
            let question = Self.question(served.id)
            let maxPoints = answer?.maxPoints ?? question.flatMap(Self.maxPoints) ?? 1
            let right = answer?.status == .correct
            if let answer {
                counts.answered += 1
                counts.points += answer.points
                if answer.guessed { counts.guessed += 1 }
                switch answer.status {
                case .correct: counts.fullyRight += 1
                case .partial: counts.partial += 1
                case .incorrect: counts.missed += 1
                }
                let mark = Score(points: answer.points, maxPoints: answer.maxPoints, status: answer.status, answered: true)
                if Self.isBank(served.id) {
                    if !right { counts.bankWrong += 1 }
                } else if mark.staysInReview(guessed: answer.guessed) {
                    counts.review += 1
                }
            }
            counts.maxPoints += maxPoints
            if let index = weeks.firstIndex(where: { $0.label == served.name }) {
                weeks[index].total += 1
                if right { weeks[index].right += 1 }
            }
            if let index = folders.firstIndex(where: { $0.id == served.folder }) {
                folders[index].total += 1
                if right { folders[index].right += 1 }
            }
            let step = question?.clinicalJudgmentStep.flatMap { $0.isEmpty ? nil : $0 } ?? "Not labeled"
            if let index = steps.firstIndex(where: { $0.label == step }) {
                steps[index].total += 1
                if right { steps[index].right += 1 }
            } else {
                steps.append((step, right ? 1 : 0, 1))
            }
            var item: [String: Any] = [
                "questionId": served.id, "status": answer?.status.rawValue ?? "unanswered",
                "label": answer.map { Score(points: $0.points, maxPoints: $0.maxPoints, status: $0.status, answered: true).label } ?? "Not answered",
                "points": answer?.points ?? 0, "maxPoints": maxPoints, "guessed": answer?.guessed ?? false,
                "response": NSNull(), "shuffle": NSNull(),
            ]
            if let answer {
                item["response"] = Self.jsonObject(answer.response)
                item["shuffle"] = answer.shuffle.map { Self.jsonObject($0) } ?? NSNull()
            }
            items.append(item)
        }
        let rank = { (label: String) -> Int in
            Self.stepOrder.firstIndex { $0.lowercased() == label.lowercased() } ?? Self.stepOrder.count + (label == "Not labeled" ? 1 : 0)
        }
        let used = min(Double(exam.timeLimitSeconds), max(0, (exam.finishedAt ?? .now).timeIntervalSince(exam.startedAt)))
        return [
            "questionCount": items.count, "answered": counts.answered, "unanswered": items.count - counts.answered,
            "fullyRight": counts.fullyRight, "partial": counts.partial, "missed": counts.missed, "guessed": counts.guessed,
            "points": counts.points, "maxPoints": counts.maxPoints, "minutesUsed": max(1, Int((used / 60).rounded())),
            "reviewCount": counts.review, "examBankWrong": counts.bankWrong,
            "byWeek": weeks.filter { $0.total > 0 }.map { ["label": $0.label, "right": $0.right, "total": $0.total] },
            "byFolder": folders.filter { $0.total > 0 }.map { ["folderId": $0.id, "label": $0.label, "right": $0.right, "total": $0.total] },
            "byStep": steps.sorted { rank($0.label) < rank($1.label) }.map { ["label": $0.label, "right": $0.right, "total": $0.total] },
            "items": items,
        ]
    }

    // MARK: Import, with the rules of `content/service.ts` `commitImport`

    /// The folder holding a current practice set.
    func folder(holding setID: String) -> Folder? {
        state.withLock { state in state.folders.first { $0.sets.contains(setID) } }
    }

    /// The folder an import files a set under: the one she picked, the one she named (the course's
    /// folder of that name on no exam page, else its only folder of that name, else a new one at the
    /// end of its Folders list), or Unsorted, made at the top of the Folders list the first time.
    func importFolder(courseID: String, folderID: String?, folderName: String?) -> Result<Folder, Failure> {
        state.withLock { state in
            if let folderID {
                guard let folder = state.folders.first(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    return .failure(Failure(status: 400, message: "That folder is not in this course."))
                }
                return .success(folder)
            }
            if let folderName {
                let named = state.folders.filter { $0.courseID == courseID && $0.name.lowercased() == folderName.lowercased() }
                if let loose = named.first(where: { $0.examPageID == nil }) { return .success(loose) }
                if named.count == 1 { return .success(named[0]) }
                return .success(Self.newFolder(folderName, courseID: courseID, page: nil, in: &state))
            }
            if let unsorted = state.folders.first(where: { $0.courseID == courseID && $0.examPageID == nil && $0.name == "Unsorted" }) {
                return .success(unsorted)
            }
            let top = (state.folders.filter { $0.courseID == courseID && $0.examPageID == nil }.map(\.sortOrder).min() ?? 1) - 1
            var unsorted = Self.newFolder("Unsorted", courseID: courseID, page: nil, in: &state)
            unsorted.sortOrder = top
            state.folders[state.folders.count - 1] = unsorted
            return .success(unsorted)
        }
    }

    /// Files a new practice set in a folder, or with `replacing`, in that set's place.
    func file(set id: String, in folderID: String, replacing old: String?, questionCount: Int) {
        state.withLock { state in
            state.sizes[id] = questionCount
            if let old, let index = state.folders.firstIndex(where: { $0.sets.contains(old) }) {
                state.folders[index].sets = state.folders[index].sets.map { $0 == old ? id : $0 }
            } else if let index = state.folders.firstIndex(where: { $0.id == folderID }) {
                state.folders[index].sets.append(id)
            }
        }
    }

    /// Files an exam set's questions in a folder's exam bank.
    func file(bank questionIDs: [String], in folderID: String) {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
            state.folders[index].bank += questionIDs
        }
    }

    // MARK: Exam twins, with the rules of `question-maker/twins.ts`

    /// A folder as a twin job reads it: its practice questions in the pool, set by set, which of
    /// them already have an exam twin there, and whether its exam bank holds questions that twin
    /// none of them, which leaves the folder as it is.
    struct TwinSource {
        let folder: Folder
        /// Each current practice set's questions in the pool, in order; sets with none left out.
        let sets: [(setID: String, questionIDs: [String])]
        let twinned: Set<String>
        let unmatched: Bool

        var pooled: [String] { sets.flatMap(\.questionIDs) }
    }

    /// The ticked folders in her order, or nil when one is not in the course.
    func twinSources(courseID: String, folderIDs: [String], pool: ExamPool) -> [TwinSource]? {
        state.withLock { state in
            let course = Self.ordered(state, courseID: courseID)
            guard folderIDs.allSatisfy({ id in course.contains { $0.id == id } }) else { return nil }
            return course.filter { folderIDs.contains($0.id) }.map { folder in
                let sets = folder.sets.map { set in
                    (setID: set, questionIDs: Self.ids(set, Self.setSizes[set] ?? state.sizes[set] ?? 0).filter { pool == .all || Self.isWrong($0, latest: state.latest) })
                }
                return TwinSource(
                    folder: folder,
                    sets: sets.filter { !$0.questionIDs.isEmpty },
                    twinned: Set(folder.bank.compactMap { state.twinOf[$0] }),
                    unmatched: folder.bank.contains { state.twinOf[$0] == nil }
                )
            }
        }
    }

    /// Files exam twins of these practice questions as an exam set in the folder's bank, each
    /// twin with the same question as the one it twins.
    func fileTwins(of practiceIDs: [String], examSetID: String, in folderID: String) {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
            for practice in practiceIDs {
                let twin = "bank-\(examSetID)-\(practice.split(separator: "-").last ?? "q0")"
                state.folders[index].bank.append(twin)
                state.twinOf[twin] = practice
            }
        }
    }

    // MARK: Folders and exam pages, with the rules and words of `content/folders.ts`

    /// A refusal, in the server's words.
    struct Failure: Error {
        let status: Int
        let message: String

        var reply: Reply { FakeStudy.failure(status, "request_refused", message) }
    }

    private static func reply(_ result: Result<Folder, Failure>, status: Int, _ folderJSON: (Folder) -> [String: Any]) -> Reply {
        switch result {
        case .success(let folder): (status, folderJSON(folder))
        case .failure(let failure): failure.reply
        }
    }

    /// A required name, trimmed: refused when blank or longer than 80 characters.
    private static func requiredText(_ value: Any?, label: String) -> Result<String, Failure> {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(Failure(status: 400, message: "\(label) is required.")) }
        if text.count > 80 { return .failure(Failure(status: 400, message: "\(label) is too long.")) }
        return .success(text)
    }

    /// A list as a refusal names it: the exam page, or the course for its Folders list.
    private static func listLabel(_ page: String?, courseID: String, in state: State) -> String {
        page.flatMap { page in state.courseExams.first { $0.id == page }?.name } ?? codes[courseID] ?? "This course"
    }

    /// Refuses a name another folder of the list already has, ignoring case.
    private static func nameTaken(_ name: String, courseID: String, page: String?, except ids: Set<String>, in state: State) -> Failure? {
        let clash = state.folders.first {
            $0.courseID == courseID && $0.examPageID == page && !ids.contains($0.id) && $0.name.lowercased() == name.lowercased()
        }
        return clash.map { Failure(status: 409, message: "\(listLabel(page, courseID: courseID, in: state)) already has a folder named \($0.name).") }
    }

    /// The exam page a folder may go on: one of its course's.
    private static func page(_ id: String, courseID: String, in state: State) -> Failure? {
        state.courseExams.contains { $0.id == id && $0.courseID == courseID } ? nil : Failure(status: 400, message: "That exam page is not in this course.")
    }

    /// The next place at the end of a list.
    private static func end(of page: String?, courseID: String, in state: State) -> Int {
        (state.folders.filter { $0.courseID == courseID && $0.examPageID == page }.map(\.sortOrder).max() ?? 0) + 1
    }

    private static func newFolder(_ name: String, courseID: String, page: String?, in state: inout State) -> Folder {
        state.folderCount += 1
        let folder = Folder(
            id: String(format: "f0000000-0000-4000-8000-%012d", 9000 + state.folderCount), courseID: courseID, name: name,
            examPageID: page, sortOrder: end(of: page, courseID: courseID, in: state), sets: [], bank: []
        )
        state.folders.append(folder)
        return folder
    }

    private func createFolder(courseID: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            let name: String
            switch Self.requiredText(body["name"], label: "Folder name") {
            case .success(let text): name = text
            case .failure(let failure): return .failure(failure)
            }
            let page = body["examPageId"] as? String
            if let page, let failure = Self.page(page, courseID: courseID, in: state) { return .failure(failure) }
            if let failure = Self.nameTaken(name, courseID: courseID, page: page, except: [], in: state) { return .failure(failure) }
            return .success(Self.newFolder(name, courseID: courseID, page: page, in: &state))
        }
    }

    /// Renames a folder, puts it on an exam page, or takes it off one. A folder that changes list
    /// goes to the end of its new list.
    private func changeFolder(id: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else {
                return .failure(Failure(status: 404, message: "That folder is not in the app."))
            }
            let folder = state.folders[index]
            var name = folder.name
            if body.keys.contains("name") {
                switch Self.requiredText(body["name"], label: "Folder name") {
                case .success(let text): name = text
                case .failure(let failure): return .failure(failure)
                }
            }
            let page = body.keys.contains("examPageId") ? body["examPageId"] as? String : folder.examPageID
            if let page, let failure = Self.page(page, courseID: folder.courseID, in: state) { return .failure(failure) }
            if let failure = Self.nameTaken(name, courseID: folder.courseID, page: page, except: [id], in: state) { return .failure(failure) }
            if page != folder.examPageID {
                state.folders[index].sortOrder = Self.end(of: page, courseID: folder.courseID, in: state)
                state.folders[index].examPageID = page
            }
            state.folders[index].name = name
            return .success(state.folders[index])
        }
    }

    /// Moves a set to a folder of its course, or to a new one at the end of the Folders list.
    private func moveSet(id: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            guard let from = state.folders.firstIndex(where: { $0.sets.contains(id) }) else {
                return .failure(Failure(status: 404, message: "That set is not in the app."))
            }
            let courseID = state.folders[from].courseID
            let folderID = body["folderId"] as? String, newName = body["newFolderName"]
            if folderID != nil, newName != nil { return .failure(Failure(status: 400, message: "Choose a folder or a new folder name, not both.")) }
            let to: Int
            if let folderID {
                guard let index = state.folders.firstIndex(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    return .failure(Failure(status: 400, message: "That folder is not in this course."))
                }
                to = index
            } else if newName != nil {
                let name: String
                switch Self.requiredText(newName, label: "Folder name") {
                case .success(let text): name = text
                case .failure(let failure): return .failure(failure)
                }
                if let failure = Self.nameTaken(name, courseID: courseID, page: nil, except: [], in: state) { return .failure(failure) }
                _ = Self.newFolder(name, courseID: courseID, page: nil, in: &state)
                to = state.folders.count - 1
            } else {
                return .failure(Failure(status: 400, message: "Choose a folder to move it to."))
            }
            if to != from {
                state.folders[from].sets.removeAll { $0 == id }
                state.folders[to].sets.append(id)
            }
            return .success(state.folders[to])
        }
    }

    /// Saves her order of one list. A list that does not name exactly its folders is refused.
    private func reorder(courseID: String, body: [String: Any], _ folderJSON: (Folder) -> [String: Any]) -> Reply {
        let result = state.withLock { state -> Result<[Folder], Failure> in
            let page = body["examPageId"] as? String
            if let page, let failure = Self.page(page, courseID: courseID, in: state) { return .failure(failure) }
            let ids = body["folderIds"] as? [String] ?? []
            let list = state.folders.filter { $0.courseID == courseID && $0.examPageID == page }.map(\.id)
            guard ids.count == list.count, Set(ids) == Set(list) else {
                return .failure(Failure(status: 409, message: "The folders changed since this list was shown. Reload and try again."))
            }
            for (position, id) in ids.enumerated() {
                if let index = state.folders.firstIndex(where: { $0.id == id }) { state.folders[index].sortOrder = position + 1 }
            }
            return .success(ids.compactMap { id in state.folders.first { $0.id == id } })
        }
        switch result {
        case .success(let folders): return (200, ["folders": folders.map(folderJSON)])
        case .failure(let failure): return failure.reply
        }
    }

    /// Adds an exam page or renames one and sets its folders, in the order sent. Folders it gives
    /// up go to the end of the Folders list.
    private func saveCourseExam(courseID givenCourse: String?, id: String?, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            let courseID: String
            if let id {
                guard let page = state.courseExams.first(where: { $0.id == id }) else {
                    return Self.failure(404, "request_refused", "That exam is not in the app.")
                }
                courseID = page.courseID
            } else {
                courseID = givenCourse ?? ""
            }
            let name: String
            switch Self.requiredText(body["name"], label: "Exam name") {
            case .success(let text): name = text
            case .failure(let failure): return failure.reply
            }
            if state.courseExams.contains(where: { $0.courseID == courseID && $0.id != id && $0.name.lowercased() == name.lowercased() }) {
                return Self.failure(409, "request_refused", "This course already has an exam named \(name).")
            }
            // Null or empty takes the link off; left out, a page keeps its link.
            let link: String??
            switch body["linkUrl"] {
            case nil: link = .none
            case let text as String where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let scheme = URL(string: trimmed)?.scheme?.lowercased()
                guard trimmed.count <= 2000, scheme == "http" || scheme == "https", URL(string: trimmed)?.host() != nil else {
                    return Self.failure(400, "request_refused", "A link has to be a web address, such as https://example.com/primer.")
                }
                link = .some(trimmed)
            default: link = .some(nil)
            }
            // Null takes the badge off; left out, a page keeps it, and a new page has none.
            let badge: String??
            switch body["badge"] {
            case nil: badge = .none
            case let value as String where ["exam", "concept", "study"].contains(value): badge = .some(value)
            case is NSNull: badge = .some(nil)
            default: return Self.failure(400, "invalid_request", "That badge is not one QBank knows.")
            }
            let sent = body["folderIds"] as? [String]
            var target: [Folder] = []
            for folderID in sent ?? [] where !target.contains(where: { $0.id == folderID }) {
                guard let folder = state.folders.first(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    let missing = Set(sent ?? []).count { folderID in !state.folders.contains { $0.id == folderID && $0.courseID == courseID } }
                    return Self.failure(400, "request_refused", missing == 1 ? "That folder is not in this course." : "Those folders are not in this course.")
                }
                target.append(folder)
            }
            // A folder of another page is refused, naming the page that has it.
            var held: [(page: String, names: [String])] = []
            for folder in target {
                guard let holder = folder.examPageID, holder != id else { continue }
                let pageName = state.courseExams.first { $0.id == holder }?.name ?? "another exam page"
                if let index = held.firstIndex(where: { $0.page == pageName }) { held[index].names.append(folder.name) } else { held.append((pageName, [folder.name])) }
            }
            if !held.isEmpty {
                return Self.failure(409, "request_refused", held.map { "\(Self.listText($0.names)) \($0.names.count == 1 ? "is" : "are") in \($0.page)." }.joined(separator: " "))
            }
            for (index, folder) in target.enumerated() {
                if let clash = target.prefix(index).first(where: { $0.name.lowercased() == folder.name.lowercased() }) {
                    return Self.failure(409, "request_refused", "\(name) already has a folder named \(clash.name).")
                }
            }
            let keep = Set(target.map(\.id))
            let leaving = id.map { id in Self.ordered(state, courseID: courseID).filter { $0.examPageID == id && !keep.contains($0.id) } } ?? []
            if sent != nil {
                for folder in leaving {
                    if let failure = Self.nameTaken(folder.name, courseID: courseID, page: nil, except: keep.union([folder.id]), in: state) { return failure.reply }
                }
            }
            let page: CourseExam
            if let id, let index = state.courseExams.firstIndex(where: { $0.id == id }) {
                state.courseExams[index].name = name
                if let link { state.courseExams[index].linkURL = link }
                if let badge { state.courseExams[index].badge = badge }
                page = state.courseExams[index]
            } else {
                state.courseExamCount += 1
                page = CourseExam(
                    id: String(format: "c0e00000-0000-4000-8000-%012d", 100 + state.courseExamCount), courseID: courseID, name: name,
                    sortOrder: (state.courseExams.filter { $0.courseID == courseID }.map(\.sortOrder).max() ?? 0) + 1,
                    linkURL: link ?? nil, badge: badge ?? nil
                )
                state.courseExams.append(page)
            }
            // Without folderIds a page keeps its folders.
            if sent != nil {
                for folder in leaving {
                    guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                    state.folders[index].sortOrder = Self.end(of: nil, courseID: courseID, in: state)
                    state.folders[index].examPageID = nil
                }
                for (position, folder) in target.enumerated() {
                    guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                    state.folders[index].examPageID = page.id
                    state.folders[index].sortOrder = position + 1
                }
            }
            return (id == nil ? 201 : 200, Self.pageJSON(page, in: state))
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
        return state.withLock { state in state.exams.filter { $0.courseID == courseID && $0.finishedAt == nil } }
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
        state.withLock { state in state.exams.count { $0.courseID == courseID && $0.finishedAt != nil && $0.folderIDs.contains(folderID) } }
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
                return state.exams.count { $0.finishedAt != nil && !$0.folderIDs.isEmpty && $0.folderIDs.allSatisfy(folderIDs.contains) }
            }
            return state.exams.count { $0.finishedAt != nil && Self.page(of: $0, in: state) == id }
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

    private static func jsonObject(_ value: some Encodable) -> Any {
        (try? QBankJSON.encoder.encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }

    /// "Week 3", "Week 3 and Week 4", "Week 2, Week 3 and Week 4".
    static func listText(_ labels: [String]) -> String {
        guard labels.count > 1, let last = labels.last else { return labels.joined() }
        return "\(labels.dropLast().joined(separator: ", ")) and \(last)"
    }

    private static func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }
}

/// Answers to the invented questions, made from each question's own key: the right one, a wrong
/// one, and a partly right one where the format allows it.
nonisolated enum FakeAnswers {
    static func right(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .single(let options): options.firstIndex(where: \.isCorrect).map { .single(choice: $0) }
        case .priority(let options): options.firstIndex(where: \.isCorrect).map { .priority(choice: $0) }
        case .sata(let options): .sata(picks: options.indices.filter { options[$0].isCorrect })
        case .highlight(let segments): .highlight(picks: segments.indices.filter { segments[$0].isCorrect })
        case .order(let items): .order(positions: Array(items.indices))
        case .match(let pairs, _): .match(choices: pairs.map(\.right))
        case .matrix(_, let rows): .matrix(choices: rows.map(\.answer))
        case .matrixmulti(_, let rows): .matrixmulti(choices: rows.map(\.answers))
        case .cloze(let cloze): .cloze(choices: cloze.blanks.map(\.answer))
        case .unsupported: nil
        }
    }

    static func wrong(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .single(let options): options.firstIndex { !$0.isCorrect }.map { .single(choice: $0) }
        case .priority(let options): options.firstIndex { !$0.isCorrect }.map { .priority(choice: $0) }
        case .sata(let options): options.firstIndex { !$0.isCorrect }.map { .sata(picks: [$0]) }
        case .highlight(let segments): segments.firstIndex { !$0.isCorrect }.map { .highlight(picks: [$0]) }
        case .order(let items): .order(positions: Array(items.indices.reversed()))
        case .match(let pairs, _): .match(choices: pairs.indices.map { pairs[(($0 + 1) % pairs.count)].right })
        case .matrix(let columns, let rows): .matrix(choices: rows.map { row in columns.first { $0 != row.answer } ?? row.answer })
        case .matrixmulti(let columns, let rows):
            .matrixmulti(choices: rows.map { row in columns.first { !row.answers.contains($0) }.map { [$0] } ?? [] })
        case .cloze(let cloze): .cloze(choices: cloze.blanks.map { ($0.answer + 1) % max(1, $0.options.count) })
        case .unsupported: nil
        }
    }

    /// Partly right where the format gives points per part; a wrong answer otherwise.
    static func partly(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .sata(let options):
            let right = options.indices.filter { options[$0].isCorrect }
            return .sata(picks: Array(right.dropLast()))
        case .matrix(let columns, let rows):
            return .matrix(choices: rows.enumerated().map { index, row in index == 0 ? (columns.first { $0 != row.answer } ?? row.answer) : row.answer })
        default:
            return wrong(body)
        }
    }
}
#endif
