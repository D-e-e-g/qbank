import Foundation
import QBankKit
import Testing
@testable import QBank

/// Exam twins: the rules and words of the Twin option, as the web's `twins.test.ts` checks them.
struct TwinsWordingTests {
    static let course = QuestionJob.Course(id: "c1", code: "NURS 406", title: "Mental Health")

    static func status(available: Bool, nextAvailableAt: Date? = nil) -> QuestionMakerStatus {
        QuestionMakerStatus(
            available: available, reason: available ? nil : "Making questions is not available on this account. Import works on every account.",
            dailyLimit: 3, startedToday: 0, nextAvailableAt: nextAvailableAt, levels: [], defaultLevel: .exam, sampleSize: 5,
            limits: .init(photos: 20, photoBytes: 3_750_000, fileBytes: 20_000_000, textCharacters: 400_000), imageTypes: [], fileTypes: []
        )
    }

    static func job(
        id: String = "j1", status: TwinJob.Status = .running, pool: TwinJob.Pool = .wrong, twinCount: Int = 5,
        course: QuestionJob.Course = course, folders: [String] = ["Week 5"]
    ) -> TwinJob {
        TwinJob(
            id: id, status: status, steps: [], course: course, pool: pool,
            folders: folders.enumerated().map { .init(id: "f\($0.offset)", name: $0.element, questionCount: twinCount, twinCount: twinCount, alreadyTwinned: 0) },
            twinCount: twinCount, note: "QBank writes exam twins of 5 wrong questions in Week 5.",
            createdAt: QBankJSON.parseDate("2026-10-18T17:00:00.000Z")!, updatedAt: QBankJSON.parseDate("2026-10-18T17:00:00.000Z")!
        )
    }

    static func step(_ state: TwinJob.Step.State, _ done: Int? = nil, _ total: Int? = nil) -> TwinJob.Step {
        TwinJob.Step(key: "twins", label: "Exam twins", state: state, done: done, total: total)
    }

    @Test func theTwinOptionShowsOnlyWhileSheMayMakeQuestionsNow() {
        #expect(Twins.canTwin(Self.status(available: true)))
        #expect(!Twins.canTwin(Self.status(available: false)))
        #expect(!Twins.canTwin(Self.status(available: false, nextAvailableAt: .now.addingTimeInterval(3_600))))
        #expect(!Twins.canTwin(nil))
    }

    @Test func herTwinJobsAreListedAlsoAtTheDailyLimitAndNeverForOtherAccounts() {
        #expect(Twins.listsJobs(Self.status(available: true)))
        #expect(Twins.listsJobs(Self.status(available: false, nextAvailableAt: .now.addingTimeInterval(3_600))))
        #expect(!Twins.listsJobs(Self.status(available: false)))
        #expect(!Twins.listsJobs(nil))
    }

    @Test func onlyTheCoursesJobsInTheServersOrder() {
        let other = QuestionJob.Course(id: "c2", code: "NURS 401", title: "Adult Health")
        let jobs = [Self.job(id: "a"), Self.job(id: "b", course: other), Self.job(id: "c")]
        #expect(Twins.jobs(jobs, courseID: "c1").map(\.id) == ["a", "c"])
    }

    @Test func aJobSaysItsFoldersPoolAndState() {
        #expect(Twins.title(Self.job()) == "Week 5")
        #expect(Twins.title(Self.job(folders: ["Week 4", "Week 5", "Week 6"])) == "Weeks 4-6")
        #expect(Twins.meta(Self.job()) == "5 exam twins · Wrong questions only")
        #expect(Twins.meta(Self.job(pool: .all, twinCount: 1)) == "1 exam twin")
        #expect(Twins.scope(Self.job()) == "Week 5 · Wrong questions only")
        #expect(Twins.state(Self.job()) == "Writing")
        #expect(Twins.state(Self.job(status: .done)) == "Ready")
        #expect(Twins.state(Self.job(status: .failed)) == "Failed")
        #expect(Twins.state(Self.job(status: .cancelled)) == "Cancelled")
        #expect(Twins.state(Self.job(status: "paused")) == nil)
        #expect(Twins.isRunning(Self.job()))
        #expect(!Twins.isRunning(Self.job(status: .done)))
        #expect(!Twins.isRunning(Self.job(status: "paused")))
    }

    @Test func eachStepSaysHowFarItIs() {
        #expect(Twins.progress(Self.step(.done, 3, 3)) == "Done")
        #expect(Twins.progress(Self.step(.current, 2, 5)) == "2 of 5")
        #expect(Twins.progress(Self.step(.current)) == "Working")
        #expect(Twins.progress(Self.step(.todo)) == "")
        #expect(Twins.progress(Self.step(.failed, 1, 5)) == "Failed")
        #expect(Twins.progress(Self.step(.cancelled, 1, 5)) == "Cancelled")
    }

    @Test func theOfferNamesThePool() {
        #expect(Twins.offer(wrongOnly: true) == "Or QBank writes a new exam twin of each wrong question in the folders you tick, and you take the exam on the twins. Your questions stay as they are.")
        #expect(Twins.offer(wrongOnly: false).hasPrefix("Or QBank writes a new exam twin of each question in"))
    }
}

/// The Twin option of Exam setup and a twin job's screen, end to end against the fake server, which
/// follows the server's twin-job rules and words, and the bodies the app sends, against a stub.
@MainActor
struct TwinJobTests {
    static let course = CourseRef(id: FakeQBankServer.mentalHealthID, code: "NURS 310", title: "Mental Health")

    static func setup(_ app: AppModel) -> ExamSetupModel {
        ExamSetupModel(app: app, route: ExamSetupRoute(course: course))
    }

    /// The job's screen once the job has ended and, when it is done, her running exam is read.
    static func follow(_ app: AppModel, _ job: TwinJob) async -> TwinJobModel {
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: course, jobID: job.id, seed: job), pollInterval: .zero)
        await model.follow()
        await model.readRunningExam()
        return model
    }

    /// Exam setup with Week 2 ticked: its 7 wrong questions with Wrong questions only.
    static func week2(_ app: AppModel, wrongOnly: Bool = true) async throws -> ExamSetupModel {
        let setup = setup(app)
        await setup.load()
        setup.wrongOnly = wrongOnly
        setup.toggle(try #require(setup.folders.first { $0.id == FakeStudy.week2 }))
        return setup
    }

    // MARK: Exam setup

    @Test func aStudentTheServerDoesNotAllowSeesNoTwinOptionAndNoJobs() async {
        let setup = Self.setup(MakeQuestionsTests.app(maker: false))
        await setup.load()
        #expect(setup.maker?.available == false)
        #expect(!setup.canTwin)
        #expect(setup.twinJobs == nil)
    }

    @Test func anAccountThatMayNotMakeQuestionsIsNeverSentToTheTwinJobRoutes() async {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools)),
            "GET /api/question-maker": .ok(Self.status(available: false)),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")))
        await setup.load()
        #expect(!setup.canTwin)
        #expect(!server.calls.contains { $0.contains("twin-jobs") })
    }

    @Test func theOwnerIsNotAskedAboutMakingQuestions() async {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools)),
            "GET /api/question-maker": .ok(Self.status(available: true)),
        ])
        let (app, _) = TestApp.make(server, account: .admin)
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")))
        await setup.load()
        #expect(!setup.canTwin)
        #expect(!server.calls.contains { $0.contains("question-maker") || $0.contains("twin-jobs") })
    }

    @Test func writeExamTwinsSendsTheTickedFoldersAndThePool() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools)),
            "GET /api/question-maker": .ok(Self.status(available: true)),
            "GET /api/twin-jobs": .ok(#"{"jobs":[]}"#),
        ])
        server["POST /api/twin-jobs"] = StubServer.Reply(status: 202, body: Self.jobBody(status: "running"))
        let (app, _) = TestApp.make(server, account: .student())
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")))
        await setup.load()
        #expect(setup.canTwin)
        #expect(setup.twinJobs == [])
        setup.toggle(setup.folders[1])
        setup.toggle(setup.folders[0])
        setup.wrongOnly = true
        let job = await setup.writeTwins()
        #expect(job?.id == "j1")
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"courseId":"c1","folderIds":["f1","f2"],"pool":"wrong"}"#)
        #expect(setup.twinJobs?.map(\.id) == ["j1"])
    }

    @Test func theTwinsOfHerWrongQuestionsAreWrittenFiledAndTakenAsAnExam() async throws {
        let app = MakeQuestionsTests.app()
        let setup = try await Self.week2(app)
        #expect(setup.canTwin)
        #expect(setup.twinJobs == [])
        let started = try #require(await setup.writeTwins())
        #expect(started.status == .running)
        #expect(started.pool == .wrong)
        #expect(started.twinCount == 7)
        #expect(started.note == "QBank writes exam twins of 7 wrong questions in Week 2. Once they are filed, exams over Week 2 ask only its exam twins.")
        #expect(started.steps.map(\.label) == ["Read your questions", "Exam twins", "File the twins"])
        #expect(started.steps.map(\.state) == [.current, .todo, .todo])

        let model = await Self.follow(app, started)
        let job = try #require(model.job)
        #expect(job.status == .done)
        #expect(job.steps.allSatisfy { $0.state == .done })
        #expect(job.sets.map(\.title) == ["Therapeutic Communication and the Relationship exam", "Psychosocial Assessment and Safety Screening exam"])
        #expect(job.sets.map(\.questionCount) == [5, 2])
        #expect(job.sets.map(Twins.filed) == [
            "Week 2 · 5 questions · Twins of Therapeutic Communication and the Relationship",
            "Week 2 · 2 questions · Twins of Psychosocial Assessment and Safety Screening",
        ])
        #expect(job.exam?.folderIDs == [FakeStudy.week2])
        #expect(model.running == .none)
        #expect(model.canStart)

        // The exam her job names starts on exactly the twins.
        let exam = try #require(await model.start())
        #expect(exam.pool == .wrong)
        #expect(exam.folderIDs == [FakeStudy.week2])
        #expect(exam.questions.count == 7)
        #expect(exam.questions.allSatisfy { FakeStudy.isBank($0.id) })

        // Exam setup lists the job, and Week 2 now asks only its exam twins.
        await setup.load()
        #expect(setup.twinJobs?.map(\.id) == [started.id])
        #expect(setup.twinJobs?.first.map(Twins.state) == "Ready")
        let week2 = try #require(setup.folders.first { $0.id == FakeStudy.week2 })
        #expect(week2.source == .exam)
        #expect(week2.questionCount == 7)
        #expect(week2.wrongCount == 7)
    }

    @Test func herRunningExamIsAskedAboutBeforeTheExamOnTheTwins() async throws {
        let app = MakeQuestionsTests.app()
        let running = try #require(try await app.client.startExam(courseID: Self.course.id, folderIDs: [FakeStudy.week1], replaces: nil).started)
        let setup = try await Self.week2(app)
        let started = try #require(await setup.writeTwins())
        let model = await Self.follow(app, started)
        #expect(model.isDone)
        #expect(model.running.exam?.folderIDs == [FakeStudy.week1])
        #expect(await model.start() == nil)
        #expect(model.asksToReplace)
        model.asksToReplace = false

        // She agrees: the running exam ends as left, and the exam on the twins starts.
        let exam = try #require(await model.startReplacing())
        #expect(exam.folderIDs == [FakeStudy.week2])
        let after = try await app.client.examSetup(courseID: Self.course.id)
        #expect(after.inProgress?.id == exam.id)
        #expect(after.exams.first { $0.id == running.id }?.endReason == .left)
    }

    /// An exam started elsewhere after the twin page read none: the server refuses, nothing ends,
    /// and the question comes up about that exam.
    @Test func anExamStartedElsewhereMeanwhileIsAskedAboutNotEnded() async throws {
        let app = MakeQuestionsTests.app()
        let setup = try await Self.week2(app)
        let started = try #require(await setup.writeTwins())
        let model = await Self.follow(app, started)
        #expect(model.running == .none)
        let elsewhere = try #require(try await app.client.startExam(courseID: Self.course.id, folderIDs: [FakeStudy.week1], replaces: nil).started)

        #expect(await model.start() == nil)
        #expect(model.actionProblem == nil)
        #expect(model.asksToReplace)
        #expect(model.running.exam?.id == elsewhere.id)
        #expect(try await app.client.examSetup(courseID: Self.course.id).inProgress?.id == elsewhere.id, "still running")

        let exam = try #require(await model.startReplacing())
        #expect(try await app.client.examSetup(courseID: Self.course.id).inProgress?.id == exam.id)
    }

    /// The audit's sequence: the read of her running exam fails, and Start used to count that as
    /// none and end her exam unasked. Start stays off, the read is tried again, and then it asks.
    @Test func startStaysOffUntilTheRunningExamIsRead() async throws {
        let running = StudyBodies.summary("run", weeks: ["Week 1"], folders: ["f1"], finished: false)
        let server = StubServer(["GET /api/twin-jobs/j1": .ok(Self.jobBody(status: "done"))])
        server.script("GET /api/courses/c1/exams", [.offline])
        server["GET /api/courses/c1/exams"] = .ok(StudyBodies.setup(folders: StudyBodies.threePools, inProgress: running))
        let (app, _) = TestApp.make(server, account: .student())
        let twins = TwinJobModel(
            app: app, route: TwinJobRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), jobID: "j1"), pollInterval: .zero,
            now: { QBankJSON.parseDate("2026-10-12T00:05:00.000Z")! }
        )
        await twins.follow()
        #expect(twins.isDone)
        #expect(twins.running == .unknown)
        #expect(twins.needsRunningExam)
        #expect(!twins.canStart, "Start waits for the read")
        #expect(await twins.start() == nil)
        #expect(!server.calls.contains("POST /api/courses/c1/exams"))

        await twins.readRunningExam()
        #expect(server.calls.filter { $0 == "GET /api/courses/c1/exams" }.count == 2, "the failed read is tried again")
        #expect(twins.running.exam?.id == "run")
        #expect(twins.runningProblem == nil)
        #expect(twins.canStart)
        #expect(await twins.start() == nil)
        #expect(twins.asksToReplace)
        #expect(!server.calls.contains("POST /api/courses/c1/exams"))

        // After an exam closes, Start waits for a new read.
        twins.examClosed()
        #expect(!twins.canStart)
    }

    @Test func aRefusalIsSaidUntilSheChangesTheFoldersOrThePool() async throws {
        let app = MakeQuestionsTests.app()
        let setup = Self.setup(app)
        await setup.load()
        setup.toggle(try #require(setup.folders.first { $0.id == FakeStudy.week3 }))
        #expect(await setup.writeTwins() == nil)
        #expect(setup.twinProblem == "Week 3 already has exam questions QBank can't match to its practice questions, so QBank leaves it as it is. Start the exam to take them.")
        #expect(!setup.isTwinning)
        setup.toggle(try #require(setup.folders.first { $0.id == FakeStudy.week2 }))
        #expect(setup.twinProblem == nil)
    }

    @Test func aTwinJobCountsAgainstTheDailyLimitAndStaysListed() async throws {
        let app = MakeQuestionsTests.app()
        let setup = try await Self.week2(app)
        // Two sets were started today already; the job is the third of three.
        let started = try #require(await setup.writeTwins())
        await setup.load()
        #expect(!setup.canTwin)
        #expect(setup.maker?.reason == "You have started 3 sets in the last 24 hours, the most for one day.")
        #expect(setup.twinJobs?.map(\.id) == [started.id])
    }

    @Test func aFolderAlreadyTwinningIsRefusedByName() async throws {
        let app = MakeQuestionsTests.app()
        let setup = try await Self.week2(app)
        #expect(await setup.writeTwins() != nil)
        #expect(await setup.writeTwins() == nil)
        #expect(setup.twinProblem == "QBank is still writing exam twins in Week 2. Try again once they are filed.")
    }

    // MARK: A twin job's screen

    @Test func stoppingAJobCancelsIt() async throws {
        let app = MakeQuestionsTests.app()
        let setup = try await Self.week2(app)
        let started = try #require(await setup.writeTwins())
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: Self.course, jobID: started.id, seed: started), pollInterval: .zero)
        #expect(model.isWorking)
        await model.stop()
        #expect(model.job?.status == .cancelled)
        #expect(model.job?.steps.map(\.state) == [.cancelled, .todo, .todo])
        #expect(!model.isWorking)
        #expect(model.actionProblem == nil)
        // Its folder is free again: what refuses another job now is the daily limit, which it counted against.
        #expect(await setup.writeTwins() == nil)
        #expect(setup.twinProblem == "You have started 3 sets in the last 24 hours, the most for one day. You can start another in 3 hours.")
    }

    @Test func aFailedJobSaysWhyAndOffersNoExam() async {
        let server = StubServer(["GET /api/twin-jobs/j1": .ok(Self.jobBody(status: "failed", failure: "These exam twins were not written. Start them again."))])
        let (app, _) = TestApp.make(server, account: .student())
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), jobID: "j1"), pollInterval: .zero)
        await model.follow()
        #expect(model.job?.status == .failed)
        #expect(model.job?.failure == "These exam twins were not written. Start them again.")
        #expect(!model.isDone)
        #expect(!model.needsRunningExam)
        #expect(await model.start() == nil)
        #expect(server.calls == ["GET /api/twin-jobs/j1"])
    }

    @Test func aJobThatIsNotHersIsGone() async {
        let server = StubServer(["GET /api/twin-jobs/j1": .error(404, "not_found", "Those exam twins are not in QBank.")])
        let (app, _) = TestApp.make(server, account: .student())
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), jobID: "j1"), pollInterval: .zero)
        await model.follow()
        #expect(model.isGone)
        #expect(!model.isWorking)
        #expect(model.problem == "Those exam twins are not in QBank.")
    }

    @Test func aDroppedConnectionIsTriedAgain() async {
        let server = StubServer(["GET /api/twin-jobs/j1": .ok(Self.jobBody(status: "done"))])
        server.script("GET /api/twin-jobs/j1", [.offline])
        server["GET /api/courses/c1/exams"] = .ok(StudyBodies.setup(folders: StudyBodies.threePools))
        let (app, _) = TestApp.make(server, account: .student())
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), jobID: "j1"), pollInterval: .zero)
        await model.follow()
        await model.readRunningExam()
        #expect(model.isDone)
        #expect(model.problem == nil)
        #expect(server.calls == ["GET /api/twin-jobs/j1", "GET /api/twin-jobs/j1", "GET /api/courses/c1/exams"])
    }

    /// Start exam on the twins sends the job's exam as the server wrote it, fields it may add later included.
    @Test func theExamOnTheTwinsIsSentAsTheServerWroteIt() async throws {
        let server = StubServer([
            "GET /api/twin-jobs/j1": .ok(Self.jobBody(status: "done", exam: #"{"folderIds":["f2","f1"],"pool":"wrong","later":true}"#)),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools)),
        ])
        server["POST /api/courses/c1/exams"] = StubServer.Reply(status: 201, body: StudyBodies.exam())
        let (app, _) = TestApp.make(server, account: .student())
        let model = TwinJobModel(app: app, route: TwinJobRoute(course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), jobID: "j1"), pollInterval: .zero)
        await model.follow()
        await model.readRunningExam()
        #expect(await model.start()?.id == "e1")
        let body = try #require(server.requests.last?.httpBody)
        let sent = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(sent == .object([
            "folderIds": .array([.string("f2"), .string("f1")]), "pool": .string("wrong"), "later": .bool(true), "replaces": .null,
        ]))
    }

    // MARK: Bodies

    static func status(available: Bool) -> String {
        """
        {"available":\(available),"reason":\(available ? "null" : #""Making questions is not available on this account. Import works on every account.""#),\
        "dailyLimit":3,"startedToday":0,"nextAvailableAt":null,"levels":[],"defaultLevel":"exam","sampleSize":5,\
        "limits":{"photos":20,"photoBytes":3750000,"fileBytes":20000000,"textCharacters":400000},"imageTypes":[],"fileTypes":[]}
        """
    }

    static func jobBody(status: String, failure: String? = nil, exam: String? = nil) -> String {
        let state = status == "done" ? "done" : status == "running" ? "current" : status
        let exam = exam ?? (status == "done" ? #"{"folderIds":["f1"],"pool":"wrong"}"# : "null")
        return """
        {"id":"j1","status":"\(status)","step":"twins","steps":[\
        {"key":"read","label":"Read your questions","state":"done","done":null,"total":null},\
        {"key":"twins","label":"Exam twins","state":"\(state)","done":null,"total":null},\
        {"key":"file","label":"File the twins","state":"\(status == "done" ? "done" : "todo")","done":null,"total":null}],\
        "course":{"id":"c1","code":"NURS 101","title":"Invented Basics"},"level":"exam","pool":"wrong",\
        "folders":[{"id":"f1","name":"Week 1","questionCount":2,"twinCount":2,"alreadyTwinned":0}],"twinCount":2,\
        "note":"QBank writes exam twins of 2 wrong questions in Week 1.","sets":[],"exam":\(exam),\
        "createdAt":"2026-10-18 17:00:00.000+00","updatedAt":"2026-10-18 17:00:01.000+00","finishedAt":null,\
        "failure":\(failure.map { "\"\($0)\"" } ?? "null"),"warnings":[],\
        "usage":{"calls":0,"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}}
        """
    }
}
