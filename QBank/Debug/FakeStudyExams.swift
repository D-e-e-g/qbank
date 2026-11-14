#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// The fake server's exams: setup and its plans, starting, answering and ending one, its result,
/// and the exam twins a twin job files, with the real server's rules and words.
nonisolated extension FakeStudy {
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
    func setup(_ courseID: String, folderIDs: [String], pool: ExamPool) -> [String: Any] {
        settleExpired()
        return state.withLock { state in
            let course = Self.ordered(state, courseID: courseID)
            let folders = course.filter { !Self.pool($0, sizes: state.sizes).isEmpty }
            let exams = state.exams.filter { $0.courseID == courseID }.sorted { $0.startedAt > $1.startedAt }.map { $0.asRead(at: .now) }
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
                "inProgress": exams.firstIndex { $0.isOpen(at: .now) }.map { summaries[$0] } ?? NSNull(),
                "exams": exams.indices.filter { !exams[$0].isOpen(at: .now) }.map { summaries[$0] },
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
    static func page(of exam: Exam, in state: State) -> String? {
        state.courseExams.filter { $0.courseID == exam.courseID }.sorted { $0.sortOrder < $1.sortOrder }.first { page in
            exam.folderIDs.allSatisfy { id in state.folders.contains { $0.id == id && $0.examPageID == page.id } }
        }?.id
    }

    func summaryJSON(_ stored: Exam, in state: State) -> [String: Any] {
        let now = Date.now
        let exam = stored.asRead(at: now)
        let result = exam.finishedAt == nil ? nil : score(exam, in: state)
        return [
            "id": exam.id, "courseId": exam.courseID, "weeks": exam.names, "folderIds": exam.folderIDs,
            "courseExamId": Self.json(Self.page(of: exam, in: state)),
            "pool": exam.pool.rawValue, "practiceWeeks": exam.practiceWeeks.map { $0 as Any } ?? NSNull(),
            "questionCount": exam.questions.count, "timeLimitSeconds": exam.timeLimitSeconds,
            "startedAt": QBankJSON.formatDate(exam.startedAt), "endsAt": QBankJSON.formatDate(exam.endsAt),
            "status": exam.readStatus(at: now).rawValue,
            "finishedAt": Self.json(exam.finishedAt.map(QBankJSON.formatDate)), "endReason": Self.json(exam.endReason?.rawValue),
            "answeredCount": exam.answers.count,
            "fullyRight": result.map { $0["fullyRight"] as Any } ?? NSNull(),
            "points": result.map { $0["points"] as Any } ?? NSNull(),
            "maxPoints": result.map { $0["maxPoints"] as Any } ?? NSNull(),
            "minutesUsed": result.map { $0["minutesUsed"] as Any } ?? NSNull(),
        ]
    }

    /// Starts an exam. `replaces`, when sent, says which running exam she agreed to end, or null
    /// for none; without it, as from an app before it, any running exam ends unasked.
    func start(_ courseID: String, body: [String: Any]) -> Reply {
        let folderIDs = body["folderIds"] as? [String] ?? []
        let pool = (body["pool"] as? String).flatMap(ExamPool.init(rawValue:)) ?? .all
        let replaces: Replaces = body.keys.contains("replaces") ? .exam(body["replaces"] as? String) : .unsaid
        switch begin(courseID: courseID, folderIDs: folderIDs, pool: pool, at: .now, endingRunning: true, replaces: replaces) {
        case .success(let id): return examView(id, status: 201)
        case .failure(let refusal):
            guard let runningID = refusal.runningID, let running = state.withLock({ state in state.exams.first { $0.id == runningID }.map { summaryJSON($0, in: state) } }) else {
                return Self.failure(400, refusal.code, refusal.message)
            }
            return (409, ["error": refusal.code, "message": refusal.message, "inProgress": running])
        }
    }

    struct Refusal: Error {
        let code: String
        let message: String
        /// The running exam a start did not agree to end, for its 409.
        var runningID: String?
    }

    /// What a start says about her running exam, as the server's `replaces`.
    enum Replaces {
        /// Nothing, as an app from before `replaces`: a running exam ends unasked.
        case unsaid
        /// The running exam she agreed to end, or nil when the app knows of none running.
        case exam(String?)
    }

    /// Draws an exam as the server does, folder by folder in her order and without shuffling, so a
    /// test knows which question comes when.
    func begin(
        courseID: String, folderIDs: [String], pool: ExamPool, at startedAt: Date, endingRunning: Bool, replaces: Replaces = .unsaid
    ) -> Result<String, Refusal> {
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
        // An open exam of hers (running, or in its grace) she did not agree to end refuses the start,
        // and nothing changes. One whose time is up is not open: it ends as a timeout whatever
        // `replaces` says.
        if case .exam(let agreed) = replaces, let unconfirmed = state.withLock({ state in
            state.exams.filter { $0.isOpen(at: startedAt) && $0.id != agreed }.max { $0.startedAt < $1.startedAt }
        }) {
            return .failure(Refusal(
                code: "exam_in_progress", message: "An exam is still running. Starting a new one ends it, so confirm that first.",
                runningID: unconfirmed.id
            ))
        }
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

    func examView(_ id: String, status: Int = 200) -> Reply {
        settleExpired()
        let now = Date.now
        guard let exam = state.withLock({ $0.exams.first { $0.id == id } })?.asRead(at: now) else {
            return Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        let course = exam.courseID == FakeQBankServer.mentalHealthID ? ("NURS 310", "Mental Health") : ("NURS 220", "Fundamentals")
        let result = exam.finishedAt == nil ? nil : state.withLock { score(exam, in: $0) }
        return (status, [
            "id": exam.id, "courseId": exam.courseID, "courseCode": course.0, "courseTitle": course.1,
            "weeks": exam.names, "folderIds": exam.folderIDs,
            "pool": exam.pool.rawValue, "practiceWeeks": exam.practiceWeeks.map { $0 as Any } ?? NSNull(),
            "timeLimitSeconds": exam.timeLimitSeconds, "startedAt": QBankJSON.formatDate(exam.startedAt),
            "endsAt": QBankJSON.formatDate(exam.endsAt), "status": exam.readStatus(at: now).rawValue,
            "finishedAt": Self.json(exam.finishedAt.map(QBankJSON.formatDate)),
            "endReason": Self.json(exam.endReason?.rawValue), "serverNow": QBankJSON.formatDate(now),
            "questions": exam.questions.enumerated().map { Self.questionJSON($1.id, position: $0 + 1, week: $1.name) },
            "answeredQuestionIds": exam.questions.map(\.id).filter { exam.answers[$0] != nil },
            "result": result.map { $0 as Any } ?? NSNull(),
        ])
    }

    func finish(_ id: String, reason: ExamEndReason) -> Reply {
        guard state.withLock({ $0.exams.contains { $0.id == id } }) else {
            return Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        close(id, reason: reason)
        return examView(id)
    }

    /// Ends the exam that has not ended. Once its time has run out, the end is a timeout at the
    /// moment time ran out, whatever was asked.
    private func close(_ id: String, reason: ExamEndReason) {
        state.withLock { state in
            guard let index = state.exams.firstIndex(where: { $0.id == id }), state.exams[index].finishedAt == nil else { return }
            let deadline = state.exams[index].endsAt
            let timedOut = Date.now >= deadline
            state.exams[index].finishedAt = timedOut ? deadline : .now
            state.exams[index].endReason = timedOut ? .timeout : reason
        }
    }

    /// Records the end of every exam whose time is up, past its end and its grace, exactly as a
    /// reader already reads it. One in its grace stays open.
    func settleExpired() {
        let expired = state.withLock { state in state.exams.filter { $0.status(at: .now) == .expired }.map(\.id) }
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
            guard exam.isOpen(at: .now) else {
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
}
#endif
