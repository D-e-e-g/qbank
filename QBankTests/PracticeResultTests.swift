import Foundation
import QBankKit
import Testing
@testable import QBank

/// The set result, counted as the web's result screen counts it.
struct PracticeResultTests {
    static func question(_ id: String, type: String = "single", topic: String = "Topic", cj: String?) throws -> Question {
        let step = cj.map { "\"\($0)\"" } ?? "null"
        let json = #"{"id":"\#(id)","publicId":"P-\#(id)","position":1,"type":"\#(type)","topic":"\#(topic)","cj":\#(step),"stem":"S","ask":"A","rationale":"R","takeaway":"T","terms":[],"body":{"options":[{"t":"x","ok":true},{"t":"y"}]}}"#
        return try QBankJSON.decoder.decode(Question.self, from: Data(json.utf8))
    }

    static func attempt(_ score: Score?, guessed: Bool = false) -> PracticeModel.Attempt {
        PracticeModel.Attempt(
            layout: .plain, draft: .single(nil), guessed: guessed, clientAttemptID: UUID().uuidString,
            feedback: score.map { Feedback(phone: $0, type: .single) }
        )
    }

    static let right = Score(points: 2, maxPoints: 2, status: .correct, answered: true)
    static let partly = Score(points: 1, maxPoints: 3, status: .partial, answered: true)
    static let missed = Score(points: 0, maxPoints: 1, status: .incorrect, answered: true)

    @Test func countsFullyRightPartlyMissedAndGuessed() throws {
        let questions = try [
            Self.question("1", cj: "Analyze cues"),
            Self.question("2", cj: "Take action"),
            Self.question("3", cj: "Analyze cues"),
            Self.question("4", cj: nil),
            Self.question("5", topic: "", cj: ""),
        ]
        let attempts = [
            Self.attempt(Self.right, guessed: true),
            Self.attempt(Self.partly),
            Self.attempt(Self.missed),
            Self.attempt(Self.right),
            Self.attempt(nil, guessed: true),
        ]
        let result = PracticeResult(title: "Set", questions: questions, attempts: attempts, elapsed: 61)
        #expect(result.questionCount == 5)
        #expect(result.fullyRight == 2)
        #expect(result.partial == 1)
        #expect(result.missed == 1)
        #expect(result.guessed == 1, "a guess she never checked does not count")
        #expect(result.points == 5)
        #expect(result.maxPoints == 8, "an unanswered question adds nothing to the maximum")
        #expect(result.steps == [
            .init(label: "Analyze cues", right: 1, total: 2),
            .init(label: "Take action", right: 0, total: 1),
            .init(label: "Not labeled", right: 1, total: 2),
        ])
        #expect(result.rows.map(\.mark) == ["Guessed - Correct", "Partly correct", "Not correct", "Correct", "Not answered"])
        #expect(result.rows.map(\.detail) == ["Single answer · 2 of 2", "Single answer · 1 of 3", "Single answer · 0 of 1", "Single answer · 2 of 2", "Single answer"])
        #expect(result.rows.last?.title == "P-5", "a question without a topic shows its id")
        #expect(result.rows.map(\.number) == [1, 2, 3, 4, 5])
    }
}
