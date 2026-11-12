import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// Exam twins against recordings of the server's real routes and background runner, with the
/// server's own stand-in for Claude: each call sends what the recorded request sent, and each
/// recorded response decodes into the models.
@Suite("Contract: exam twins")
struct TwinJobContractTests {
    static let course = "c0000000-0000-4000-8000-000000000501"
    static let week5 = "f0000000-0000-4000-8000-000000000501"
    static let week6 = "f0000000-0000-4000-8000-000000000502"
    static let job = "a0b00000-0000-4000-8000-000000000501"
    static let stopped = "a0b00000-0000-4000-8000-000000000502"
    static let failed = "a0b00000-0000-4000-8000-000000000503"

    // MARK: Starting

    @Test func twinsOfHerWrongQuestionsInAFolderStartAtOnce() async throws {
        let fixture = try Fixture.load("twin-job-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.startTwinJob(NewTwinJob(courseID: Self.course, folderIDs: [Self.week5], pool: .wrong))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.id == Self.job)
        #expect(job.status == .running)
        #expect(job.pool == .wrong)
        #expect(job.steps.map(\.label) == ["Read your questions", "Exam twins", "File the twins"])
        #expect(job.steps.map(\.state) == [.current, .todo, .todo])
        #expect(job.course == .init(id: Self.course, code: "NURS 406", title: "Invented Mental Health"))
        #expect(job.folders == [.init(id: Self.week5, name: "Week 5", questionCount: 3, twinCount: 3, alreadyTwinned: 0)])
        #expect(job.twinCount == 3)
        #expect(job.note == "QBank writes exam twins of 3 wrong questions in Week 5. Once they are filed, exams over Week 5 ask only its exam twins.")
        #expect(job.sets.isEmpty)
        #expect(job.exam == nil)
        // The job's times come in Postgres's own text, not ISO 8601.
        let created = try #require(fixture.response.body["createdAt"]?.stringValue)
        #expect(!created.contains("T"))
        #expect(job.createdAt == QBankJSON.parseDate(created))
    }

    /// Nothing to twin, every one already twinned, or past the daily limit: a sentence to show as it is.
    @Test(arguments: [
        ("twin-job-no-wrong", ServerError.Code.invalidRequest, [TwinJobContractTests.week6], ExamPool.wrong),
        ("twin-job-already-twinned", .invalidRequest, [TwinJobContractTests.week5], .wrong),
        ("twin-job-daily-limit", .dailyLimit, [TwinJobContractTests.week6], .all),
    ])
    func refusalsSayWhyInHerWords(name: String, code: ServerError.Code, folders: [String], pool: ExamPool) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.startTwinJob(NewTwinJob(courseID: Self.course, folderIDs: folders, pool: pool))
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: code)
    }

    @Test func anAccountThatMayNotMakeQuestionsIsRefusedTheTwinJobs() async throws {
        let fixture = try Fixture.load("twin-jobs-not-allowed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport, token: "synthetic-other-session-token")
        let error = await #expect(throws: QBankError.self) { try await client.twinJobs() }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .notAllowed)
    }

    /// A twin job counts against her daily limit like a set: the status says so, with when she can
    /// start another, so her twin jobs can still be listed.
    @Test func aTwinJobCountsAgainstTheDailyLimit() async throws {
        let fixture = try Fixture.load("question-maker-twins-daily-limit")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let status = try await client.questionMakerStatus()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(!status.available)
        #expect(status.startedToday == 3)
        #expect(status.nextAvailableAt != nil)
    }

    // MARK: Following a job

    @Test func halfwayThroughItCountsTheTwinsWritten() async throws {
        let fixture = try Fixture.load("twin-job-twins")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.twinJob(id: Self.job)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .running)
        #expect(job.steps.map(\.state) == [.done, .current, .todo])
        #expect(job.steps[1] == .init(key: "twins", label: "Exam twins", state: .current, done: 2, total: 3))
    }

    @Test func aDoneJobNamesItsSetsAndTheExamOnThem() async throws {
        let fixture = try Fixture.load("twin-job-done")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.twinJob(id: Self.job)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .done)
        #expect(job.steps.allSatisfy { $0.state == .done })
        #expect(job.sets.map(\.title) == ["Week 5 Harder A exam", "Week 5 Harder B exam"])
        #expect(job.sets.map(\.questionCount) == [2, 1])
        #expect(job.sets.map(\.folderID) == [Self.week5, Self.week5])
        #expect(job.sets.map(\.twinsOf.title) == ["Week 5 Harder A", "Week 5 Harder B"])
        #expect(job.warnings.isEmpty)
        #expect(job.finishedAt != nil)
        let exam = try #require(job.exam)
        #expect(exam.folderIDs == [Self.week5])
        #expect(exam.body == fixture.response.body["exam"])
    }

    /// Start exam on the twins sends the job's exam as the server wrote it, saying no exam is running.
    @Test func theExamOnTheTwinsStartsFromTheJobsExamAsItIs() async throws {
        let done = try Fixture.load("twin-job-done")
        let start = try Fixture.load("twin-exam-start")
        let transport = try FixtureTransport([done, start])
        let (client, _) = TestClient.make(transport)
        let job = try await client.twinJob(id: Self.job)
        let started = try await client.startExam(courseID: job.course.id, on: try #require(job.exam), replaces: nil)
        try expectRequest(transport.requests.last, matches: start)
        guard case .started(let exam) = started else {
            Issue.record("no exam started: \(started)")
            return
        }
        #expect(exam.pool == .wrong)
        #expect(exam.folderIDs == [Self.week5])
        #expect(exam.questions.count == 3)
        #expect(exam.finishedAt == nil)
    }

    @Test func aFailedJobSaysWhy() async throws {
        let fixture = try Fixture.load("twin-job-failed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.twinJob(id: Self.failed)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .failed)
        #expect(job.failure == fixture.response.body["failure"]?.stringValue)
        #expect(job.failure?.isEmpty == false)
        #expect(job.steps.map(\.state) == [.done, .failed, .todo])
        #expect(job.exam == nil)
        #expect(job.folders.first?.alreadyTwinned == 3)
    }

    @Test func aJobThatIsNotHersIsNotFound() async throws {
        let fixture = try Fixture.load("twin-job-not-found")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last ?? "")
        let error = await #expect(throws: QBankError.self) { try await client.twinJob(id: id) }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: "not_found")
    }

    // MARK: Her jobs, and stopping one

    @Test func herTwinJobsAreNewestFirst() async throws {
        let fixture = try Fixture.load("twin-jobs")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let jobs = try await client.twinJobs()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(jobs.map(\.id) == [Self.failed, Self.stopped, Self.job])
        #expect(jobs.map(\.status) == [.failed, .cancelled, .done])
        #expect(jobs.map(\.pool) == [.wrong, .all, .wrong])
    }

    @Test func stoppingAJobCancelsIt() async throws {
        let fixture = try Fixture.load("twin-job-cancel")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.cancelTwinJob(id: Self.stopped)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .cancelled)
        #expect(job.steps.map(\.state) == [.cancelled, .todo, .todo])
        #expect(job.failure == nil)
    }

    @Test func aFinishedJobCannotBeStopped() async throws {
        let fixture = try Fixture.load("twin-job-cancel-finished")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.cancelTwinJob(id: Self.job) }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .wrongStep)
    }

    // MARK: A later server

    /// A status, step state, pool, or field the server adds later still decodes, so a newer server
    /// never breaks the screen that follows a job.
    @Test func wordsAndFieldsAddedLaterStillDecode() throws {
        guard case .object(var body) = try Fixture.load("twin-job-twins").response.body,
              case .array(var steps) = body["steps"], case .object(var step) = steps[1] else {
            Issue.record("not a job body")
            return
        }
        body["status"] = .string("paused")
        body["pool"] = .string("guessed")
        body["level"] = .string("expert")
        body["step"] = .string("polish")
        body["shinyNewField"] = .object(["any": .bool(true)])
        step["state"] = .string("waiting")
        step["key"] = .string("polish")
        steps[1] = .object(step)
        body["steps"] = .array(steps)
        let job = try QBankJSON.decoder.decode(TwinJob.self, from: JSONEncoder().encode(JSONValue.object(body)))
        #expect(job.status == "paused")
        #expect(job.status != .running)
        #expect(job.pool == "guessed")
        #expect(job.steps[1].state == "waiting")
        #expect(job.steps[1].key == "polish")
    }
}
