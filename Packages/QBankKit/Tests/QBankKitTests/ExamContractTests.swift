import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: exams")
struct ExamContractTests {
    @Test func setupShowsWrongCountsPerWeek() async throws {
        let fixture = try Fixture.load("exam-setup")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let setup = try await client.examSetup(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(setup.weeks.map(\.label) == ["Week 1", "Week 2"])
        #expect(setup.weeks.map(\.source) == [.exam, .practice])
        #expect(setup.weeks.map(\.wrongCount) == [1, 0])
        #expect(setup.inProgress == nil)
        #expect(setup.exams.isEmpty)
    }

    @Test func setupCarriesTheServersRules() throws {
        let setup = try Fixture.load("exam-setup").decodeBody(ExamSetup.self)
        #expect(setup.rules == ExamRules(maxQuestions: 40, fullTimeSeconds: 3600, secondsPerQuestion: 90))
        #expect(setup.preview == nil, "read without folders")
        #expect(setup.courseExams.isEmpty, "the course has no exam pages")
    }

    /// With folders, the setup is read for the server's plan over them, from the pool asked for.
    @Test func setupAsksForThePlanOverTheTickedFolders() async throws {
        guard case .object(var body) = try Fixture.load("exam-setup-course-exams").response.body,
              case .array(let pages)? = body["courseExams"], case .object(let page)? = pages.first else {
            Issue.record("The exam setup fixture has no exam page plans")
            return
        }
        body["preview"] = page["preview"]
        let transport = FixtureTransport(status: 200, body: String(decoding: try JSONEncoder().encode(JSONValue.object(body)), as: UTF8.self))
        let (client, _) = TestClient.make(transport)
        let setup = try await client.examSetup(courseID: "c1", folderIDs: [FolderContractTests.week1, FolderContractTests.week2], pool: .wrong)
        let url = try #require(transport.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/courses/c1/exams")
        #expect(components.query == "folderIds=\(FolderContractTests.week1)&folderIds=\(FolderContractTests.week2)&pool=wrong")
        let plan = try #require(setup.preview)
        #expect(plan.folders.map(\.drawn) == [3, 2])
        #expect(plan.questionCount == 5)
        #expect(plan.timeLimitSeconds == 450)
        #expect(plan.practiceWeeks == nil)
    }

    @Test func setupWithARunningExam() throws {
        let setup = try Fixture.load("exam-setup-in-progress").decodeBody(ExamSetup.self)
        let running = try #require(setup.inProgress)
        #expect(running.finishedAt == nil)
        #expect(running.endReason == nil)
        #expect(running.fullyRight == nil)
        #expect(running.pool == .all)
        #expect(running.practiceWeeks == ["Week 2"])
        #expect(running.courseExamID == nil, "the course has no exams")
    }

    @Test func setupAfterExams() throws {
        let setup = try Fixture.load("exam-setup-after").decodeBody(ExamSetup.self)
        #expect(setup.exams.count == 1)
        #expect(setup.exams.first?.endReason == .finished)
        #expect(setup.inProgress?.pool == .wrong)
    }

    @Test func startOverEveryQuestion() async throws {
        let fixture = try Fixture.load("exam-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folders = folderIDs(of: fixture)
        let started = try await client.startExam(courseID: courseID(of: fixture), folderIDs: folders, pool: .all, replaces: nil)
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .started(let exam) = started else {
            Issue.record("no exam started: \(started)")
            return
        }
        #expect(folders.count == 2, "Week 1 and Week 2")
        #expect(exam.isRunning)
        #expect(exam.result == nil)
        #expect(exam.questions.count == 4)
        #expect(exam.questions.allSatisfy { $0.weekLabel != nil })
        #expect(exam.timeLimitSeconds == 360)
        #expect(exam.secondsLeftAtServerNow > 0)
    }

    @Test func startOverWrongQuestions() async throws {
        let fixture = try Fixture.load("exam-start-wrong")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let started = try await client.startExam(courseID: courseID(of: fixture), folderIDs: folderIDs(of: fixture), pool: .wrong, replaces: nil)
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .started(let exam) = started else {
            Issue.record("no exam started: \(started)")
            return
        }
        #expect(exam.pool == .wrong)
        #expect(exam.weeks == ["Week 1"])
    }

    /// A start that says no exam is running while one is: nothing starts, and the answer names the
    /// running exam as Exam setup lists it, for the question the app asks.
    @Test func startOverARunningExamItDidNotNameIsRefusedWithThatExam() async throws {
        let fixture = try Fixture.load("exam-start-in-progress")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let answer = try await client.startExam(courseID: courseID(of: fixture), folderIDs: folderIDs(of: fixture), pool: .all, replaces: nil)
        try expectRequest(transport.requests.first, matches: fixture)
        let running = try #require(try Fixture.load("exam-setup-after").decodeBody(ExamSetup.self).inProgress)
        #expect(answer == .examInProgress(running))
    }

    /// The field is always sent: null says no exam is known to run, which an absent field does not.
    @Test func startSaysWhichRunningExamItEnds() async throws {
        let transport = try FixtureTransport("exam-start", "exam-start")
        let (client, _) = TestClient.make(transport)
        _ = try await client.startExam(courseID: "c1", folderIDs: ["f1"], replaces: nil)
        _ = try await client.startExam(courseID: "c1", folderIDs: ["f1"], replaces: "e1")
        let bodies = try transport.requests.map { try JSONDecoder().decode(JSONValue.self, from: #require($0.httpBody)) }
        #expect(bodies.map { $0["replaces"] } == [.null, .string("e1")])
    }

    @Test func weekWithoutWrongQuestionsIsRefused() async throws {
        let fixture = try Fixture.load("exam-start-no-wrong")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.startExam(courseID: courseID(of: fixture), folderIDs: folderIDs(of: fixture), pool: .wrong, replaces: nil)
        }
        #expect(error?.serverCode == .noWrongQuestions)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func examAnswerNamesItsExam() async throws {
        let fixture = try Fixture.load("exam-attempt")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        #expect(submission.studySessionID != nil)
        _ = try await client.recordAttempt(submission)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func runningExam() async throws {
        let fixture = try Fixture.load("exam-running")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let exam = try await client.exam(id: id)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.answeredQuestionIDs.count == 1)
        #expect(exam.isRunning)
    }

    @Test func finishScoresTheExam() async throws {
        let fixture = try Fixture.load("exam-finish")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").dropLast().last!)
        let exam = try await client.finishExam(id: id, reason: .finished)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.endReason == .finished)
        #expect(exam.isRunning == false)
        #expect(exam.result != nil)
    }

    @Test func endedExamResult() throws {
        let exam = try Fixture.load("exam-ended").decodeBody(Exam.self)
        let result = try #require(exam.result)
        #expect(result.questionCount == 4)
        #expect(result.answered == 1)
        #expect(result.unanswered == 3)
        #expect(result.byWeek.map(\.label) == ["Week 1", "Week 2"])
        #expect(result.byFolder?.map(\.label) == ["Week 1", "Week 2"], "by the folder each question's set is in now")
        #expect(result.byFolder?.map(\.id) == exam.folderIDs, "a row is its folder, as two folders may share a name")
        #expect(result.byWeek.map(\.id) == ["Week 1", "Week 2"])
        #expect(exam.folderIDs?.count == 2)
        #expect(result.byStep.map(\.label) == ["Analyze cues"])
        let answered = try #require(result.items.first { $0.status != .unanswered })
        #expect(answered.questionID == exam.answeredQuestionIDs.first)
        #expect(answered.status == .correct)
        #expect(answered.label == "Correct")
        #expect(answered.response == .single(choice: 0))
        #expect(answered.shuffle == .options(order: [0, 2, 1]))
        let unanswered = result.items.filter { $0.questionID != answered.questionID }
        #expect(unanswered.count == 3)
        #expect(unanswered.allSatisfy { $0.status == .unanswered && $0.label == "Not answered" && $0.response == nil && $0.shuffle == nil })
    }
}
