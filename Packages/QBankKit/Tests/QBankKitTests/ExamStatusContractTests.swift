import Foundation
import Testing
@testable import QBankKit

/// Where an exam stands, as the server names it (`status`): running, then a grace with no time
/// left that is still open, then ended. An exam whose time is up reads as ended, a timeout at its
/// end time with its score, whether or not its end is recorded yet.
@Suite("Contract: exam status")
struct ExamStatusContractTests {
    private static let endsAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRunningExamSaysSo() throws {
        let running = try #require(try Fixture.load("exam-setup-in-progress").decodeBody(ExamSetup.self).inProgress)
        #expect(running.status == .running)
        #expect(!running.hasEnded)
        let exam = try Fixture.load("exam-running").decodeBody(Exam.self)
        #expect(exam.status == .running)
        #expect(exam.isRunning)
        #expect(exam.secondsLeftAtServerNow > 0)
    }

    @Test func inItsGraceAnExamHasNoTimeLeftAndIsStillOpen() throws {
        let exam = try Fixture.load("exam-grace").decodeBody(Exam.self)
        #expect(exam.status == .grace)
        #expect(exam.finishedAt == nil)
        #expect(exam.endReason == nil)
        #expect(exam.result == nil)
        #expect(exam.isRunning, "the runner opens it, and ends it as a timeout")
        #expect(exam.secondsLeftAtServerNow == 0)

        let setup = try Fixture.load("exam-setup-grace").decodeBody(ExamSetup.self)
        let open = try #require(setup.inProgress)
        #expect(open.id == exam.id)
        #expect(open.status == .grace)
        #expect(setup.exams.allSatisfy { $0.hasEnded })
    }

    @Test func anExamWhoseTimeIsUpReadsAsEndedWithItsScore() throws {
        let exam = try Fixture.load("exam-time-up").decodeBody(Exam.self)
        #expect(exam.status == .ended)
        #expect(!exam.isRunning)
        #expect(exam.endReason == .timeout)
        #expect(exam.finishedAt == exam.endsAt, "a timeout at its end time")
        #expect(exam.result != nil)

        let setup = try Fixture.load("exam-setup-time-up").decodeBody(ExamSetup.self)
        #expect(setup.inProgress == nil)
        let ended = try #require(setup.exams.first { $0.id == exam.id })
        #expect(ended.status == .ended)
        #expect(ended.endReason == .timeout)
        #expect(ended.finishedAt == ended.endsAt)
        #expect(ended.fullyRight != nil, "with its score")
    }

    /// From a server that sends no `status`, or one this app does not know, `finishedAt` says it.
    @Test func withoutAStatusTheEndSaysWhereItStands() throws {
        func decoded<T: Decodable>(_ name: String, _ type: T.Type, status: JSONValue?) throws -> T {
            guard case .object(var body) = try Fixture.load(name).response.body else {
                throw FixtureError("\(name) has no object body")
            }
            body["status"] = status
            return try QBankJSON.decoder.decode(T.self, from: JSONEncoder().encode(JSONValue.object(body)))
        }
        #expect(try decoded("exam-running", Exam.self, status: nil).status == .running)
        #expect(try decoded("exam-ended", Exam.self, status: nil).status == .ended)
        #expect(try decoded("exam-ended", Exam.self, status: .string("paused")).status == .ended)
        #expect(try decoded("exam-grace", Exam.self, status: .string("paused")).status == .running)
        #expect(try decoded("exam-ended", Exam.self, status: nil).isRunning == false)
    }

    /// The status a read gave, moved on by the clock: running until the end, then the grace for 30
    /// seconds, then ended. Never earlier than the server said.
    @Test func theStatusMovesOnWithTheClock() {
        let at = { (seconds: TimeInterval, read: ExamStatus) in
            ExamStatus.of(read, endsAt: Self.endsAt, at: Self.endsAt.addingTimeInterval(seconds))
        }
        #expect(at(-60, .running) == .running)
        #expect(at(-0.001, .running) == .running)
        #expect(at(0, .running) == .grace)
        #expect(at(30, .running) == .grace)
        #expect(at(30.001, .running) == .ended)
        #expect(at(-60, .grace) == .grace, "a phone clock behind the server's")
        #expect(at(-60, .ended) == .ended)
        #expect(ExamStatus.timeUp(endsAt: Self.endsAt) == Self.endsAt.addingTimeInterval(30))
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
