import Foundation

/// How an answer scored: full points, some, or none.
public enum ScoreStatus: String, Codable, Sendable {
    case correct
    case partial
    case incorrect
}

/// One answer to send with `POST /api/attempts`.
///
/// `clientAttemptID` makes the send safe to repeat: the server saves an id once and answers a
/// repeat with the saved attempt, which is what lets the offline queue retry without counting twice.
public struct AttemptSubmission: Codable, Sendable, Equatable, Hashable {
    public let clientAttemptID: String
    public let questionID: String
    public let response: AnswerResponse
    public let guessed: Bool
    public let shuffle: Layout?
    /// The running exam's id, for an exam answer.
    public let studySessionID: String?

    public init(
        clientAttemptID: String = AttemptSubmission.newID(),
        questionID: String,
        response: AnswerResponse,
        guessed: Bool = false,
        shuffle: Layout? = nil,
        studySessionID: String? = nil
    ) {
        self.clientAttemptID = clientAttemptID
        self.questionID = questionID
        self.response = response
        self.guessed = guessed
        self.shuffle = shuffle
        self.studySessionID = studySessionID
    }

    /// A new lowercase UUID, the form the server stores.
    public static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case response, guessed, shuffle
        case clientAttemptID = "clientAttemptId"
        case questionID = "questionId"
        case studySessionID = "studySessionId"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientAttemptID, forKey: .clientAttemptID)
        try container.encode(questionID, forKey: .questionID)
        try container.encode(response, forKey: .response)
        try container.encode(guessed, forKey: .guessed)
        try container.encodeIfPresent(shuffle, forKey: .shuffle)
        try container.encodeIfPresent(studySessionID, forKey: .studySessionID)
    }
}

/// The server's record of a scored answer.
public struct SavedAttempt: Codable, Sendable, Equatable {
    public let clientAttemptID: String
    public let questionID: String
    public let courseID: String
    public let status: ScoreStatus
    public let points: Int
    public let maxPoints: Int
    public let guessed: Bool
    public let answeredAt: Date
    /// Whether the question is in her Review list after this answer.
    public let inReview: Bool
    /// The banner text, such as "Correct".
    public let label: String
    /// The banner's point line, "1 of 3 points", for a multi-part format; nil for single answer and priority.
    public let pointsText: String?
    /// How the format is scored, the banner's rule line; nil for the formats that add none.
    public let ruleText: String?
    /// True when this id was already saved and nothing new was written.
    public let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case status, points, maxPoints, guessed, answeredAt, inReview, label, pointsText, ruleText, replayed
        case clientAttemptID = "clientAttemptId"
        case questionID = "questionId"
        case courseID = "courseId"
    }
}
