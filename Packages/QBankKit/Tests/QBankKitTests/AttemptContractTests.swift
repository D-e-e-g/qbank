import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: answers")
struct AttemptContractTests {
    /// The questions the attempt fixtures answered, from the same recording.
    static func questions() throws -> [String: Question] {
        let set = try Fixture.load("practice-set").decodeBody(PracticeSet.self)
        return Dictionary(uniqueKeysWithValues: set.questions.map { ($0.id, $0) })
    }

    static let practiceAttempts = [
        "attempt-saved", "attempt-partial", "attempt-guessed", "attempt-highlight",
        "attempt-order", "attempt-match", "attempt-matrix", "attempt-cloze",
    ]

    @Test(arguments: practiceAttempts)
    func sendsTheAnswerAndReadsTheReceipt(name: String) async throws {
        let fixture = try Fixture.load(name)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let saved = try await client.recordAttempt(submission)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(saved.clientAttemptID == submission.clientAttemptID)
        #expect(saved.questionID == submission.questionID)
        #expect(saved.replayed == false)
        #expect(fixture.response.status == 201)
    }

    /// The phone's scoring gives the mark the server gave, for every format.
    @Test(arguments: practiceAttempts + ["exam-attempt"])
    func phoneScoringMatchesTheServer(name: String) throws {
        let fixture = try Fixture.load(name)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let saved = try fixture.decodeBody(SavedAttempt.self)
        let question: Question
        if name == "exam-attempt" {
            let exam = try Fixture.load("exam-start").decodeBody(Exam.self)
            question = try #require(exam.questions.first { $0.id == submission.questionID })
        } else {
            question = try #require(try Self.questions()[submission.questionID])
        }
        let score = try Scoring.score(question.body, response: submission.response)
        #expect(score.points == saved.points)
        #expect(score.maxPoints == saved.maxPoints)
        #expect(score.status == saved.status)
        // The words the phone shows while an answer waits are the ones the server sends once it has it.
        let phone = Feedback(phone: score, type: question.type)
        #expect(phone.label == saved.label)
        #expect(phone.pointsText == saved.pointsText)
        #expect(phone.ruleText == saved.ruleText)
        if name != "exam-attempt" {
            #expect(score.staysInReview(guessed: submission.guessed) == saved.inReview)
        }
    }

    @Test func replayReturnsTheSavedAttempt() async throws {
        let fixture = try Fixture.load("attempt-replayed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let saved = try await client.recordAttempt(submission)
        #expect(fixture.response.status == 200)
        #expect(saved.replayed == true)
        #expect(saved == SavedAttempt.replayOf(try Fixture.load("attempt-saved").decodeBody(SavedAttempt.self)))
    }

    @Test(arguments: [
        ("attempt-conflict", 409, ServerError.Code.attemptConflict),
        ("attempt-invalid", 400, .invalidResponse),
        ("exam-attempt-again", 409, .alreadyAnswered),
        ("exam-attempt-after-end", 409, .examFinished),
    ])
    func refusedAnswers(name: String, status: Int, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let error = await #expect(throws: QBankError.self) { try await client.recordAttempt(submission) }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error")
            return
        }
        #expect(server.status == status)
        #expect(server.code == code)
        #expect(error?.isTemporary == false)
        let refusal = try #require(error)
        #expect(AttemptQueue.keepsWaiting(after: refusal) == false)
        try expectRequest(transport.requests.first, matches: fixture)
    }
}
