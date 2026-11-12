import Foundation
import QBankKit
import Testing
@testable import QBank

/// Starting an exam over a running one, as the fake server answers it the way the server does:
/// `replaces` names the running exam she agreed to end, null says none is running, and leaving it
/// out, as an app from before it does, ends a running exam unasked.
@MainActor
struct FakeExamStartTests {
    static let course = FakeQBankServer.mentalHealthID

    let server = FakeQBankServer(signedIn: true, examInProgress: true)

    var client: QBankClient {
        QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
            transport: server,
            sessionStore: InMemorySessionStore(FakeQBankServer.storedStudentSession())
        )
    }

    func running() async throws -> ExamSummary? {
        try await client.examSetup(courseID: Self.course).inProgress
    }

    /// A start sent as an app from before `replaces` sends it, with no such field.
    func startWithoutReplaces() async throws -> Int {
        var request = URLRequest(url: URL(string: "https://fake-qbank.invalid/api/courses/\(Self.course)/exams")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(FakeQBankServer.sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["folderIds": [FakeStudy.week3], "pool": "all"])
        return try await server.send(request).1.statusCode
    }

    @Test func withoutReplacesARunningExamEndsUnaskedAsBefore() async throws {
        let before = try #require(try await running())
        #expect(try await startWithoutReplaces() == 201)
        let setup = try await client.examSetup(courseID: Self.course)
        #expect(setup.inProgress?.id != before.id)
        #expect(setup.exams.first { $0.id == before.id }?.endReason == .left)
    }

    @Test func noneRunningSaidWhileOneRunsIsRefusedAndNothingChanges() async throws {
        let before = try #require(try await running())
        let answer = try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: nil)
        #expect(answer == .examInProgress(before))
        #expect(try await running() == before, "still running, and nothing new started")
    }

    @Test func anotherExamNamedIsRefused() async throws {
        let before = try #require(try await running())
        let answer = try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: "e0000000-0000-4000-8000-999999999999")
        #expect(answer == .examInProgress(before))
    }

    @Test func theRunningExamNamedEndsAsLeftAndTheNewOneStarts() async throws {
        let before = try #require(try await running())
        let started = try #require(try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: before.id).started)
        let setup = try await client.examSetup(courseID: Self.course)
        #expect(setup.inProgress?.id == started.id)
        #expect(setup.exams.first { $0.id == before.id }?.endReason == .left)
    }

    @Test func noneRunningStartsWithNullAndANamedExamThatAlreadyEnded() async throws {
        let before = try #require(try await running())
        _ = try await client.finishExam(id: before.id, reason: .left)
        let first = try #require(try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: before.id).started)
        _ = try await client.finishExam(id: first.id, reason: .finished)
        #expect(try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: nil).started != nil)
    }

    @Test func aRefusedPoolIsSaidBeforeTheRunningExam() async throws {
        let refusal = try await #require(throws: QBankError.self) {
            try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], pool: .wrong, replaces: nil)
        }
        #expect(refusal.serverCode == .noWrongQuestions)
    }
}
