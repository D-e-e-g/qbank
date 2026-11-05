import Foundation

extension PracticeSet {
    /// How far she has got through the set this time, kept on the server so every device opens it at
    /// the first question she has not answered. Nil when there is nothing to continue: the set opens
    /// at question 1. Nil too on a Review run, and from a server or a saved copy from before sittings.
    public struct Sitting: Codable, Sendable, Equatable {
        /// Nil until her next answer saves it: a set she was midway through before sittings, which
        /// continues from the answers it has.
        public let id: String?
        /// Nil as `id` is.
        public let startedAt: Date?
        /// The set's questions answered in this sitting.
        public let answeredQuestionIDs: [String]
        /// Her latest answer to each of them, to count in the result at the end.
        public let answers: [SittingAnswer]

        public init(id: String?, startedAt: Date?, answeredQuestionIDs: [String], answers: [SittingAnswer]) {
            self.id = id
            self.startedAt = startedAt
            self.answeredQuestionIDs = answeredQuestionIDs
            self.answers = answers
        }

        enum CodingKeys: String, CodingKey {
            case id, startedAt, answers
            case answeredQuestionIDs = "answeredQuestionIds"
        }
    }

    /// The set with an answer she checked on this phone counted in its sitting, opening one if it has
    /// none. The copy saved on the phone keeps her place this way, for when QBank cannot be reached.
    public func counting(_ answer: SittingAnswer) -> PracticeSet {
        guard questions.contains(where: { $0.id == answer.questionID }) else { return self }
        var answers = sitting?.answers.filter { $0.questionID != answer.questionID } ?? []
        answers.append(answer)
        let answered = Set(sitting?.answeredQuestionIDs ?? []).union([answer.questionID])
        var set = self
        set.sitting = Sitting(
            id: sitting?.id,
            // A sitting the phone begins starts with this answer. An answer left waiting from
            // before it, such as from a run she finished, is not part of it.
            startedAt: sitting == nil ? answer.answeredAt : sitting?.startedAt,
            answeredQuestionIDs: questions.map(\.id).filter(answered.contains),
            answers: answers
        )
        return set
    }

    /// The set with the answers still waiting on the phone counted in its sitting, so a night without
    /// signal opens at the right question. Each is scored on the phone with the server's rules. A
    /// Review answer waits outside it: it counts once QBank has it, and never begins one. So does an
    /// answer from before the sitting began.
    public func counting(waiting: [PendingAttempt]) -> PracticeSet {
        var set = self
        for attempt in waiting.sorted(by: { $0.queuedAt < $1.queuedAt }) where attempt.submission.joinsASitting {
            if let startedAt = set.sitting?.startedAt, attempt.queuedAt < startedAt { continue }
            guard let question = questions.first(where: { $0.id == attempt.submission.questionID }),
                  let answer = SittingAnswer(waiting: attempt, question: question) else { continue }
            set = set.counting(answer)
        }
        return set
    }
}

/// One answer of a sitting, enough to count it in the set's result. Her response and the order she
/// saw stay on the server: no screen shows them again.
public struct SittingAnswer: Codable, Sendable, Equatable {
    public let clientAttemptID: String
    /// The current question it answers, even if she answered an earlier version of the set.
    public let questionID: String
    public let status: ScoreStatus
    public let points: Int
    public let maxPoints: Int
    public let guessed: Bool
    public let answeredAt: Date
    public let label: String
    public let pointsText: String?
    public let ruleText: String?

    public init(clientAttemptID: String, questionID: String, feedback: Feedback, guessed: Bool, answeredAt: Date) {
        self.clientAttemptID = clientAttemptID
        self.questionID = questionID
        status = feedback.score.status
        points = feedback.score.points
        maxPoints = feedback.score.maxPoints
        self.guessed = guessed
        self.answeredAt = answeredAt
        label = feedback.label
        pointsText = feedback.pointsText
        ruleText = feedback.ruleText
    }

    /// A waiting answer as the phone scores it, or nil when the question cannot be scored here.
    init?(waiting attempt: PendingAttempt, question: Question) {
        guard let score = try? Scoring.score(question.body, response: attempt.submission.response) else { return nil }
        self.init(
            clientAttemptID: attempt.id, questionID: question.id, feedback: Feedback(phone: score, type: question.type),
            guessed: attempt.submission.guessed, answeredAt: attempt.queuedAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case status, points, maxPoints, guessed, answeredAt, label, pointsText, ruleText
        case clientAttemptID = "clientAttemptId"
        case questionID = "questionId"
    }
}
