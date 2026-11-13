#if DEBUG
import Foundation
import QBankKit

/// A practice set on the fake server, her answers scored with the server's rules, and her
/// sittings, which a test may keep in a file across launches.
nonisolated extension FakeQBankServer {
    // MARK: Practice

    /// A set of either course, its questions drawn from `FakePracticeQuestions`.
    func practiceSet(id: String) -> Reply {
        guard let (courseID, folder) = find(set: id), let entry = summary(of: id) else {
            return failure(404, "request_refused", "That set is not in the app.")
        }
        return (200, [
            "id": id, "courseId": courseID, "title": entry.title, "weekLabel": folder.name, "folderId": folder.id,
            "kind": "practice",
            "questions": (0..<entry.questions).map { FakePracticeQuestions.question(setID: id, index: $0) },
            "sitting": sittingJSON(id, questionCount: entry.questions),
            "run": state.withLock { Self.run(setID: id, questionIDs: (0..<entry.questions).map { "\(id)-q\($0)" }, state: $0) },
        ])
    }

    // MARK: Sittings, with the rules of the server's `progress/sittings.ts`

    /// The set's questions she has an answer to: the invented earlier ones, and those answered here.
    private static func answered(setID: String, questionIDs: [String], latest: [String: (status: String, at: Date)]) -> Set<String> {
        Set(questionIDs.prefix(earlierProgress[setID]?.answered ?? 0)).union(questionIDs.filter { latest[$0] != nil })
    }

    /// Where she stands in the set, by the server's rule.
    static func run(setID: String, questionIDs: [String], state: State) -> String {
        FakeSittingRules.run(answered: answered(setID: setID, questionIDs: questionIDs, latest: state.latest), sitting: state.sittings[setID], questionIDs: questionIDs)
    }

    /// The questions answered in the sitting she would continue, in the set's order, or nil.
    static func continuing(setID: String, questionIDs: [String], state: State) -> [String]? {
        FakeSittingRules.continuing(answered: answered(setID: setID, questionIDs: questionIDs, latest: state.latest), sitting: state.sittings[setID], questionIDs: questionIDs)
    }

    /// The sitting an answer joins, opening one if it should. Runs before the answer is counted, so
    /// the seed is what she had before it.
    private static func join(_ questionID: String, setID: String, questionIDs: [String], fromReview: Bool, at date: Date, state: inout State) {
        let answered = answered(setID: setID, questionIDs: questionIDs, latest: state.latest)
        if let sitting = FakeSittingRules.joining(questionID, answered: answered, sitting: state.sittings[setID], questionIDs: questionIDs, fromReview: fromReview, at: date) {
            state.sittings[setID] = sitting
        }
    }

    private func sittingJSON(_ setID: String, questionCount: Int) -> Any {
        let questionIDs = (0..<questionCount).map { "\(setID)-q\($0)" }
        return state.withLock { state -> Any in
            guard let shown = Self.continuing(setID: setID, questionIDs: questionIDs, state: state) else { return NSNull() }
            let sitting = state.sittings[setID].flatMap { $0.isOpen ? $0 : nil }
            return [
                "id": sitting.map { _ in "fake-sitting-\(setID)" } ?? NSNull(),
                "startedAt": sitting.map { QBankJSON.formatDate($0.startedAt) } ?? NSNull(),
                "answeredQuestionIds": shown,
                "answers": shown.map { answerJSON($0, setID: setID, questionIDs: questionIDs, saved: state.savedAnswers[$0]) },
            ] as [String: Any]
        }
    }

    /// Her saved answer to a question, or the invented earlier one, as a sitting lists it.
    private func answerJSON(_ questionID: String, setID: String, questionIDs: [String], saved: Data?) -> [String: Any] {
        if let saved, let json = try? JSONSerialization.jsonObject(with: saved) as? [String: Any] {
            return json.merging(["response": NSNull(), "shuffle": NSNull()]) { _, new in new }
        }
        let earlier = Self.earlierProgress[setID]
        let isRight = (questionIDs.firstIndex(of: questionID) ?? 0) < (earlier?.right ?? 0)
        return [
            "clientAttemptId": "earlier-\(questionID)", "questionId": questionID, "status": isRight ? "correct" : "incorrect",
            "points": isRight ? 1 : 0, "maxPoints": 1, "guessed": false,
            "answeredAt": date(days: -(earlier?.lastAnsweredDaysAgo ?? 0)), "inReview": !isRight,
            "label": isRight ? "Correct" : "Not correct", "pointsText": NSNull(), "ruleText": NSNull(),
            "response": NSNull(), "shuffle": NSNull(),
        ]
    }

    /// Ends the sitting she would continue. Every answer stays.
    func startOver(_ id: String) -> Reply {
        guard find(set: id) != nil, let entry = summary(of: id) else {
            return failure(404, "request_refused", "That set is not in the app.")
        }
        let questionIDs = (0..<entry.questions).map { "\(id)-q\($0)" }
        let ended = state.withLock { state -> Bool in
            let hadOne = Self.continuing(setID: id, questionIDs: questionIDs, state: state) != nil || state.sittings[id]?.isOpen == true
            if hadOne {
                var sitting = state.sittings[id] ?? FakeSitting(seeded: [], own: [], startedAt: now)
                sitting.isOpen = false
                sitting.endedByStartOver = true
                state.sittings[id] = sitting
            }
            return hadOne
        }
        keepAnswers()
        return (200, ["ended": ended])
    }

    /// Writes what her answers left, for a test that comes back after killing the app.
    private func keepAnswers() {
        guard let answersFile else { return }
        let kept = state.withLock { state in
            KeptAnswers(
                attempts: state.attempts, latest: state.latest.mapValues { KeptAnswers.Latest(status: $0.status, at: $0.at) },
                savedAnswers: state.savedAnswers, sittings: state.sittings
            )
        }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: answersFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: answersFile, options: .atomic)
    }

    /// Reads what an earlier launch wrote.
    func readKeptAnswers() {
        guard let answersFile, let data = try? Data(contentsOf: answersFile),
              let kept = try? JSONDecoder().decode(KeptAnswers.self, from: data) else { return }
        state.withLock { state in
            state.attempts = kept.attempts
            state.latest = kept.latest.mapValues { (status: $0.status, at: $0.at) }
            state.savedAnswers = kept.savedAnswers
            state.sittings = kept.sittings
        }
    }

    /// The course and folder a current set is in.
    private func find(set id: String) -> (courseID: String, folder: FakeStudy.Folder)? {
        for courseID in state.withLock({ $0.courses.map(\.id) }) {
            if let folder = study.folders(courseID).first(where: { $0.sets.contains(id) }) {
                return (courseID, folder)
            }
        }
        return nil
    }

    /// Scores an answer with the server's rules and saves it. A repeated `clientAttemptId` gets the
    /// saved attempt back with `replayed`, as on the server.
    func recordAttempt(_ rawBody: Data?) -> Reply {
        guard let rawBody, let submission = try? JSONDecoder().decode(FakeSubmission.self, from: rawBody) else {
            return failure(400, "invalid_request", "That answer could not be read.")
        }
        if let data = state.withLock({ $0.attempts[submission.clientAttemptId] }),
           var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            saved["replayed"] = true
            return (200, saved)
        }
        if let session = submission.studySessionId {
            let (status, saved) = study.examAnswer(
                sessionID: session, clientAttemptID: submission.clientAttemptId, questionID: submission.questionId,
                response: submission.response, guessed: submission.guessed, shuffle: submission.shuffle
            )
            if status == 201, let record = try? JSONSerialization.data(withJSONObject: saved) {
                state.withLock { $0.attempts[submission.clientAttemptId] = record }
            }
            return (status, saved)
        }
        guard let template = FakePracticeQuestions.template(forQuestionID: submission.questionId),
              let data = try? JSONSerialization.data(withJSONObject: template.merging(
                  ["id": submission.questionId, "publicId": "Q", "position": 1], uniquingKeysWith: { $1 })),
              let question = try? QBankJSON.decoder.decode(Question.self, from: data) else {
            return failure(404, "request_refused", "That question is not in the app.")
        }
        let score: Score
        do {
            score = try Scoring.score(question.body, response: submission.response)
        } catch {
            return failure(400, "invalid_request", error.message)
        }
        let answeredAt = Date.now
        // Question ids are "<set id>-q<index>".
        let setID = submission.questionId.split(separator: "-").dropLast().joined(separator: "-")
        let questionIDs = (0..<(summary(of: setID)?.questions ?? 0)).map { "\(setID)-q\($0)" }
        let saved: [String: Any] = [
            "clientAttemptId": submission.clientAttemptId, "questionId": submission.questionId,
            "courseId": find(set: setID)?.courseID ?? Self.mentalHealthID,
            "status": score.status.rawValue, "points": score.points, "maxPoints": score.maxPoints,
            "guessed": submission.guessed, "answeredAt": QBankJSON.formatDate(answeredAt),
            "inReview": score.staysInReview(guessed: submission.guessed), "label": score.label,
            "pointsText": question.type.flatMap(score.pointsText(for:)) ?? NSNull(),
            "ruleText": question.type?.scoringRule ?? NSNull(), "replayed": false,
        ]
        let record = (try? JSONSerialization.data(withJSONObject: saved)) ?? Data()
        let status = score.status.rawValue
        state.withLock { state in
            state.attempts[submission.clientAttemptId] = record
            state.savedAnswers[submission.questionId] = record
            Self.join(submission.questionId, setID: setID, questionIDs: questionIDs, fromReview: submission.fromReview ?? false, at: answeredAt, state: &state)
            state.latest[submission.questionId] = (status, answeredAt)
        }
        keepAnswers()
        if let (weekLabel, setTitle) = placeOf(questionID: submission.questionId) {
            study.practiced(
                questionID: submission.questionId, courseID: Self.mentalHealthID, score: score,
                guessed: submission.guessed, at: answeredAt, weekLabel: weekLabel, setTitle: setTitle
            )
        }
        return (201, saved)
    }

    /// The folder name and set title of a Mental Health practice question, from its set's id.
    private func placeOf(questionID: String) -> (String, String)? {
        let setID = questionID.split(separator: "-").dropLast().joined(separator: "-")
        guard let (courseID, folder) = find(set: setID), courseID == Self.mentalHealthID, let entry = Self.catalog[setID] else { return nil }
        return (folder.name, entry.title)
    }
}

/// The parts of `POST /api/attempts` the fake server reads.
private nonisolated struct FakeSubmission: Decodable {
    let clientAttemptId: String
    let questionId: String
    let response: AnswerResponse
    let guessed: Bool
    let shuffle: Layout?
    let studySessionId: String?
    let fromReview: Bool?
}

/// What `FakeQBankServer` keeps of her answers between launches.
private nonisolated struct KeptAnswers: Codable {
    struct Latest: Codable {
        let status: String
        let at: Date
    }

    let attempts: [String: Data]
    let latest: [String: Latest]
    let savedAnswers: [String: Data]
    let sittings: [String: FakeSitting]
}
#endif
