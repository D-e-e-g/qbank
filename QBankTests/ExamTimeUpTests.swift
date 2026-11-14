import Foundation
import QBankKit
import Testing
@testable import QBank

/// An exam whose time runs out while Exam setup or a twin job's screen stays open (the audit's
/// finding 8): the app reads the server's `status` and moves it on by the clock, in place of
/// `finishedAt` being nil.
@MainActor
struct ExamTimeUpTests {
    private static let course = CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")
    /// Her running exam's end; its grace is over 30 seconds later.
    private static let endsAt = "2026-10-12T00:17:01.000Z"

    /// A clock the test moves on by hand.
    private final class Clock {
        var now: Date

        init(_ iso: String) {
            now = QBankJSON.parseDate(iso)!
        }

        func set(_ iso: String) {
            now = QBankJSON.parseDate(iso)!
        }
    }

    private static func running(status: String? = nil) -> String {
        StudyBodies.summary("run", weeks: ["Week 1"], folders: ["f1"], finished: false, endsAt: endsAt, status: status)
    }

    private static func setup(inProgress: String?, exams: [String] = []) -> StubServer.Reply {
        .ok(StudyBodies.setup(folders: StudyBodies.threePools, inProgress: inProgress, exams: exams))
    }

    private func model(_ server: StubServer, clock: Clock, slept: @escaping (Duration) -> Void = { _ in }) -> ExamSetupModel {
        let (app, _) = TestApp.make(server, account: .student())
        return ExamSetupModel(app: app, route: ExamSetupRoute(course: Self.course), now: { clock.now }, sleep: { slept($0) })
    }

    /// The audit's sequence: Exam setup read her running exam and stayed open past its end. While
    /// its grace lasts the server still holds it open, so Start asks, as the server's start guard
    /// does; once its time is up it has ended, and Start starts with nothing to end.
    @Test func startDoesNotAskAboutAnExamWhoseTimeRanOutWhileTheSetupWasOpen() async throws {
        let clock = Clock("2026-10-12T00:05:00.000Z")
        let server = StubServer([
            "GET /api/courses/c1/exams": Self.setup(inProgress: Self.running()),
            "POST /api/courses/c1/exams": StubServer.Reply(status: 201, body: StudyBodies.exam()),
        ])
        let model = model(server, clock: clock)
        await model.load()
        model.toggle(model.folders[1])

        clock.set("2026-10-12T00:17:20.000Z")
        #expect(model.running.exam(at: clock.now)?.id == "run", "in its grace")
        #expect(await model.start() == nil)
        #expect(model.asksToReplace)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
        model.asksToReplace = false

        clock.set("2026-10-12T00:17:32.000Z")
        #expect(model.running.exam(at: clock.now) == nil, "its time is up")
        #expect(await model.start()?.id == "e1")
        #expect(!model.asksToReplace)
        #expect(String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).hasSuffix(#""replaces":null}"#))
    }

    /// "min left" counts down with the clock, and shows 0, never 1, once the time has run out.
    @Test func minutesLeftReachZeroWhenTheTimeRunsOut() async throws {
        let clock = Clock("2026-10-12T00:05:00.000Z")
        let model = model(StubServer(["GET /api/courses/c1/exams": Self.setup(inProgress: Self.running())]), clock: clock)
        await model.load()
        let exam = try #require(model.running.exam)
        let line = { (iso: String) in model.runningLine(exam, at: QBankJSON.parseDate(iso)!) }
        #expect(line("2026-10-12T00:05:00.000Z") == "Week 1 · 3 of 5 answered · 13 min left")
        #expect(line("2026-10-12T00:16:02.000Z") == "Week 1 · 3 of 5 answered · 1 min left")
        #expect(line("2026-10-12T00:17:00.500Z") == "Week 1 · 3 of 5 answered · 1 min left", "half a second left")
        #expect(line("2026-10-12T00:17:01.000Z") == "Week 1 · 3 of 5 answered · 0 min left")
        #expect(line("2026-10-12T00:17:20.000Z") == "Week 1 · 3 of 5 answered · 0 min left")
    }

    /// The server's word wins over a phone clock running behind: an exam it read in its grace has
    /// no time left, and one it read as ended is not asked about.
    @Test func theServersStatusIsNeverMovedBack() async throws {
        let clock = Clock("2026-10-12T00:05:00.000Z")
        let model = model(StubServer(["GET /api/courses/c1/exams": Self.setup(inProgress: Self.running(status: "grace"))]), clock: clock)
        await model.load()
        let exam = try #require(model.running.exam)
        #expect(exam.status == .grace)
        #expect(model.runningLine(exam, at: clock.now).hasSuffix("0 min left"))
        #expect(model.running.exam(at: clock.now)?.id == "run", "still open, so Start asks")

        let ended = try QBankJSON.decoder.decode(ExamSummary.self, from: Data(Self.running(status: "ended").utf8))
        #expect(RunningExam.running(ended).exam(at: clock.now) == nil)
    }

    /// Exam setup left open past the end reads itself again once the time is up, so the exam leaves
    /// Resume and shows among her past exams, as a timeout with its score. A read that still finds
    /// it open is tried again a little later.
    @Test func anOpenSetupIsReadAgainOnceTheTimeIsUp() async throws {
        let clock = Clock("2026-10-12T00:05:00.000Z")
        let timedOut = StudyBodies.summary("run", weeks: ["Week 1"], folders: ["f1"], reason: "timeout", endsAt: Self.endsAt, status: "ended")
        let server = StubServer(["GET /api/courses/c1/exams": Self.setup(inProgress: nil, exams: [timedOut])])
        server.script("GET /api/courses/c1/exams", [Self.setup(inProgress: Self.running()), Self.setup(inProgress: Self.running())])
        var naps: [Duration] = []
        let model = model(server, clock: clock) { nap in
            naps.append(nap)
            clock.now = clock.now.addingTimeInterval(TimeInterval(nap.components.seconds))
        }
        await model.load()
        #expect(model.running.exam?.id == "run")

        await model.followRunningExam()
        #expect(naps == [.seconds(12 * 60 + 32), .seconds(6)], "until its time is up, then again after a read that still found it open")
        #expect(model.running == .none)
        let past = try #require(model.setup?.exams.first)
        #expect(past.id == "run")
        #expect(past.status == .ended)
        #expect(past.pastLine == "12 min · Time ran out")
        #expect(past.scoreText == "2 of 5")
    }

    /// A twin job's Start exam follows the same rule as Exam setup's.
    @Test func twinStartDoesNotAskAboutAnExamWhoseTimeIsUp() async throws {
        let clock = Clock("2026-10-12T00:05:00.000Z")
        let server = StubServer([
            "GET /api/twin-jobs/j1": .ok(TwinJobTests.jobBody(status: "done")),
            "GET /api/courses/c1/exams": Self.setup(inProgress: Self.running()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let twins = TwinJobModel(app: app, route: TwinJobRoute(course: Self.course, jobID: "j1"), pollInterval: .zero, now: { clock.now })
        await twins.follow()
        await twins.readRunningExam()
        #expect(twins.canStart)

        clock.set("2026-10-12T00:17:20.000Z")
        #expect(await twins.start() == nil)
        #expect(twins.asksToReplace, "in its grace the server still asks")
        twins.asksToReplace = false

        clock.set("2026-10-12T00:17:32.000Z")
        server["POST /api/courses/c1/exams"] = StubServer.Reply(status: 201, body: StudyBodies.exam())
        #expect(await twins.start()?.id == "e1")
        #expect(!twins.asksToReplace)
        #expect(String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).hasSuffix(#""replaces":null}"#))
    }
}

/// The Debug fake server names an exam's state as the server does: running, then a 30-second grace
/// that still takes an answer and still holds a new exam, then time up, read as ended for every
/// reader with its score.
@MainActor
struct FakeExamTimeUpTests {
    private static let course = FakeQBankServer.mentalHealthID

    /// Her client against a fake server whose exam over Weeks 1-2 runs out `endsIn` from now.
    private func fake(endsIn: TimeInterval) -> (QBankClient, FakeQBankServer) {
        let server = FakeQBankServer(signedIn: true, examInProgress: true, examEndsIn: endsIn)
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
            transport: server,
            sessionStore: InMemorySessionStore(FakeQBankServer.storedStudentSession())
        )
        return (client, server)
    }

    @Test func aRunningExamSaysSo() async throws {
        let (client, _) = fake(endsIn: 600)
        let running = try #require(try await client.examSetup(courseID: Self.course).inProgress)
        #expect(running.status == .running)
        #expect(try await client.exam(id: running.id).status == .running)
    }

    @Test func inItsGraceItTakesAnAnswerAndHoldsANewExam() async throws {
        let (client, server) = fake(endsIn: -10)
        let open = try #require(try await client.examSetup(courseID: Self.course).inProgress)
        #expect(open.status == .grace)
        #expect(open.finishedAt == nil)
        let exam = try await client.exam(id: open.id)
        #expect(exam.status == .grace)
        #expect(exam.isRunning)
        #expect(exam.secondsLeftAtServerNow == 0)

        let question = try #require(exam.questions.first)
        let answered = try FakeStudyRulesTests.answer(server.study, exam: exam.id, question.id, FakeAnswers.right)
        #expect(answered.0 == 201, "an answer sent before the end is still taken")
        let start = try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: nil)
        guard case .examInProgress(let held) = start else {
            Issue.record("a start in the grace went through: \(start)")
            return
        }
        #expect(held.id == open.id, "the start guard still holds it")
        #expect(held.status == .grace)
    }

    @Test func onceItsTimeIsUpItReadsAsEndedWithItsScore() async throws {
        let (client, server) = fake(endsIn: -31)
        let setup = try await client.examSetup(courseID: Self.course)
        #expect(setup.inProgress == nil)
        let ended = try #require(setup.exams.first { $0.weeks == ["Week 1", "Week 2"] && $0.endReason == .timeout })
        #expect(ended.status == .ended)
        #expect(ended.finishedAt == ended.endsAt, "a timeout at its end time")
        #expect(ended.fullyRight == 0)
        let exam = try await client.exam(id: ended.id)
        #expect(exam.status == .ended)
        #expect(!exam.isRunning)
        #expect(exam.result?.answered == 0)
        let question = try #require(exam.questions.first)
        let late = try FakeStudyRulesTests.answer(server.study, exam: exam.id, question.id, FakeAnswers.right)
        #expect(FakeStudyRulesTests.refusal(late) == "409 exam_finished: This exam has ended. That answer was not saved.")
        #expect(try await client.startExam(courseID: Self.course, folderIDs: [FakeStudy.week3], replaces: nil).started != nil)
    }

    /// A reader that does not settle the exam first, such as the delete preview, reads it as ended too.
    @Test func everyReaderReadsAnExamWhoseTimeIsUpAsEnded() throws {
        let study = FakeQBankServer(signedIn: true, examInProgress: true, examEndsIn: -31).study
        let id = try #require(study.state.withLock { $0.exams.first { $0.finishedAt == nil }?.id })
        let summary = try #require(study.summaryJSON(examID: id))
        #expect(summary["status"] as? String == "ended")
        #expect(summary["endReason"] as? String == "timeout")
        #expect(summary["finishedAt"] as? String == summary["endsAt"] as? String)
        #expect(summary["fullyRight"] as? Int == 0)
        #expect(study.state.withLock { $0.exams.first { $0.id == id }?.finishedAt } == nil, "nothing was written by reading it")
    }
}
