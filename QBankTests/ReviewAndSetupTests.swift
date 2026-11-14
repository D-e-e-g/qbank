import Foundation
import QBankKit
import Testing
@testable import QBank

@MainActor
struct ReviewModelTests {
    private static let course = CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")

    @Test func loadsTheWholeListAndFiltersOnThePhone() async throws {
        let server = StubServer(["GET /api/courses/c1/review": .ok(StudyBodies.review())])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ReviewModel(app: app, course: Self.course)
        await model.load()
        #expect(model.questions.map(\.questionID) == ["q1", "q2"])
        #expect(model.selectedCount == 2)
        #expect(model.allCount == 2)
        #expect(model.clearTitle == "Clear all 2 questions from this course's Review list?")
        #expect(server.requests.first?.url?.query() == nil, "the whole list")

        model.choose(.missed)
        #expect(model.questions.map(\.questionID) == ["q1"])
        #expect(model.selectedCount == 1)
        model.choose(.partial)
        #expect(model.questions.map(\.questionID) == ["q2"])
        model.choose(.guessed)
        #expect(model.questions.map(\.questionID) == ["q1"], "a missed guess is a guess too")
        #expect(server.requests.count == 1, "filters need no connection")
    }

    @Test func withoutAConnectionTheListSavedLastShows() async throws {
        let server = StubServer(["GET /api/courses/c1/review": .ok(StudyBodies.review())])
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        await ReviewModel(app: app, course: Self.course).load()
        connection.update(isOnline: false)
        server["GET /api/courses/c1/review"] = .offline
        let model = ReviewModel(app: app, course: Self.course)
        await model.load()
        #expect(model.questions.map(\.questionID) == ["q1", "q2"])
        #expect(model.savedAt != nil)
        #expect(model.problem == nil)
    }

    @Test func practiceGoesToTheFilteredListOrOneQuestion() async throws {
        let server = StubServer(["GET /api/courses/c1/review": .ok(StudyBodies.review())])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ReviewModel(app: app, course: Self.course)
        await model.load()
        model.choose(.partial)
        #expect(model.practice() == PracticeRoute(source: .review(filter: .partial, questionID: nil), courseID: "c1", title: "Review"))
        let one = try #require(model.questions.first)
        #expect(model.practice(one).source == .review(filter: .partial, questionID: "q2"))
    }

    @Test func clearSendsHerConfirmationThenReloads() async throws {
        let server = StubServer([
            "GET /api/courses/c1/review": .ok(StudyBodies.review()),
            "POST /api/courses/c1/review/clear": .ok(#"{"cleared":2}"#),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ReviewModel(app: app, course: Self.course)
        await model.load()
        server["GET /api/courses/c1/review"] = .ok(StudyBodies.review(counts: (0, 0, 0, 0), questions: []))
        await model.clear()
        #expect(server.calls == ["GET /api/courses/c1/review", "POST /api/courses/c1/review/clear", "GET /api/courses/c1/review"])
        let body = try #require(server.requests[1].httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"confirmed":true}"#)
        #expect(model.questions.isEmpty)
        #expect(model.allCount == 0)
    }

    @Test func aRefusalIsSaidInTheServersWords() async {
        let server = StubServer(["GET /api/courses/c1/review": .error(404, "course_not_found", "That course is not in the app.")])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ReviewModel(app: app, course: Self.course)
        await model.load()
        #expect(model.problem == "That course is not in the app.")
    }

    @Test func rowsAreMarkedAsTheWebMarksThem() throws {
        let decode = { (json: String) in try QBankJSON.decoder.decode(ReviewQuestion.self, from: Data(json.utf8)) }
        #expect(try decode(StudyBodies.reviewQuestion("a", status: "partial")).mark == (.partial, "Partly right"))
        #expect(try decode(StudyBodies.reviewQuestion("a", status: "partial", guessed: true)).mark == (.partial, "Partly right, guessed"))
        #expect(try decode(StudyBodies.reviewQuestion("a", status: "correct", guessed: true)).mark == (.guessed, "Guessed"))
        #expect(try decode(StudyBodies.reviewQuestion("a", status: "incorrect")).mark == (.wrong, "Missed"))
        #expect(try decode(StudyBodies.reviewQuestion("a", status: "incorrect", guessed: true)).mark == (.wrong, "Missed, guessed"))
    }

    @Test func theOwnersClearAnswersWithTheNoteAndSendsNothing() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .admin)
        await ReviewModel(app: app, course: Self.course).clear()
        #expect(app.frozen.noteID != nil)
        #expect(server.requests.isEmpty)
    }

    @Test func reviewPracticeLoadsTheServersQuestions() async throws {
        let server = StubServer(["GET /api/courses/c1/review/practice": .ok(PracticeModelTests.practiceSet(courseID: "c1").replacingOccurrences(of: #""title":"Invented set""#, with: #""title":"Review""#))])
        let (app, _) = TestApp.make(server, account: .student())
        let model = PracticeModel(app: app, source: .review(filter: .guessed, questionID: nil), courseID: "c1", title: "Review")
        await model.load()
        #expect(model.phase == .answering)
        #expect(model.isReview)
        #expect(model.title == "Review")
        #expect(server.requests.first?.url?.query() == "filter=guessed")

        let one = PracticeModel(app: app, source: .review(filter: .all, questionID: "q-single"), courseID: "c1", title: "Review")
        await one.load()
        #expect(server.requests.last?.url?.query() == "question=q-single")
    }
}

@MainActor
struct TermsModelTests {
    @Test func searchMatchesTheTermOrItsMeaningInAnyCase() async throws {
        let server = StubServer(["GET /api/courses/c1/terms": .ok(#"""
        {"terms":[
         {"key":"autonomy","term":"Autonomy","meaning":"The right to make informed choices.","weekLabel":"Week 1","setTitle":"Ethics"},
         {"key":"rapport","term":"Rapport","meaning":"Trust between nurse and client.","weekLabel":"Week 2","setTitle":"Talking"},
         {"key":"naive","term":"Naïve","meaning":"Not yet exposed.","weekLabel":"Week 2","setTitle":"Talking"}
        ]}
        """#)])
        let (app, _) = TestApp.make(server, account: .student())
        let model = TermsModel(app: app, course: CourseRef(id: "c1", code: "NURS 101", title: "Invented"))
        await model.load()
        #expect(model.shown.map(\.term) == ["Autonomy", "Rapport", "Naïve"])
        model.query = "TRUST"
        #expect(model.shown.map(\.term) == ["Rapport"])
        model.query = "  choices  right "
        #expect(model.shown.map(\.term) == ["Autonomy"], "every word has to match")
        model.query = "naive"
        #expect(model.shown.map(\.term) == ["Naïve"], "accents do not matter")
        model.query = "zebra"
        #expect(model.shown.isEmpty)
    }
}

@MainActor
struct ExamSetupModelTests {
    private static let course = CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics")
    /// The model's clock: when the setup was read.
    private static let readAt = QBankJSON.parseDate("2026-10-12T00:05:00.000Z")!

    private func model(
        _ server: StubServer, account: Account = .student(), route: ExamSetupRoute = ExamSetupRoute(course: course)
    ) -> ExamSetupModel {
        let (app, _) = TestApp.make(server, account: account)
        return ExamSetupModel(app: app, route: route, now: { Self.readAt })
    }

    private func server(pages: [StudyBodies.Page] = [], pools: [StudyBodies.Pool] = StudyBodies.threePools) -> StubServer {
        StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: pages)),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: pools)),
        ])
    }

    @Test func nothingIsTickedUntilSheTicks() async throws {
        let model = model(server())
        await model.load()
        #expect(model.picked.isEmpty)
        #expect(model.summaryCount == nil)
        #expect(model.summarySplit == "Tick at least one folder.")
        #expect(model.meta(model.folders[0]) == "10 questions")
        #expect(model.meta(model.folders[2]) == "20 questions · exam bank")
        #expect(model.footer == "Questions are drawn only from the folders you tick, in proportion to each folder’s size.")
        #expect(model.preselectedLine == nil)
    }

    @Test func foldersAreGroupedByExamPageInHerOrder() async throws {
        let pools = StudyBodies.threePools.map { pool in
            (pool.id, pool.name, pool.id == "f3" ? nil : "x1", pool.count, pool.wrong, pool.source) as StudyBodies.Pool
        }
        let model = model(server(pages: [("x1", "Exam 1", ["f2", "f1"])], pools: pools))
        await model.load()
        #expect(model.groups.map(\.title) == ["Exam 1", "On no page"])
        #expect(model.groups.map { $0.folders.map(\.name) } == [["Week 2", "Week 1"], ["Week 3"]])
    }

    @Test func withoutTheCourseTheFoldersShowAsTheSetupListsThem() async throws {
        let server = StubServer(["GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools))])
        let model = model(server)
        await model.load()
        #expect(model.groups.map(\.title) == [nil])
        #expect(model.folders.map(\.id) == ["f1", "f2", "f3"])
    }

    /// The query of each exam setup read, in order.
    private func setupQueries(_ server: StubServer) -> [String] {
        server.requests.filter { $0.url?.path() == "/api/courses/c1/exams" && $0.httpMethod == "GET" }.map { $0.url?.query() ?? "" }
    }

    /// The setup the server answers once she ticked folders, with its plan over them.
    private func planned(_ preview: String, pools: [StudyBodies.Pool] = StudyBodies.threePools, rules: StudyBodies.Rules = StudyBodies.rules) -> StubServer.Reply {
        .ok(StudyBodies.setup(folders: pools, rules: rules, preview: preview))
    }

    @Test func sharedNamesSayTheirExamPage() async throws {
        let pools: [StudyBodies.Pool] = [("f1", "First Pass", "x1", 10, 0, "practice"), ("f2", "First Pass", nil, 10, 0, "practice")]
        let server = server(pages: [("x1", "Exam 1", ["f1"])], pools: pools)
        let model = model(server)
        await model.load()
        model.toggle(model.folders[0])
        model.toggle(model.folders[1])
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview([("f1", "First Pass", 10, 10, "practice"), ("f2", "First Pass", 10, 10, "practice")], seconds: 1800), pools: pools)])
        await model.readPlan()
        #expect(model.summarySplit == "10 from First Pass (Exam 1) · 10 from First Pass (no page) · Fewer than 40, so it’s all of them at 1.5 minutes each.")
    }

    @Test func tickedFoldersShowTheServersPlanForThem() async throws {
        let server = server()
        let model = model(server)
        await model.load()
        model.toggle(model.folders[0])
        model.toggle(model.folders[2])
        #expect(model.picked.map(\.name) == ["Week 1", "Week 3"])
        #expect(model.summaryCount == nil, "no plan until the server sends one")
        #expect(model.summarySplit == "Working out what the exam draws.")
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview(
            [("f1", "Week 1", 10, 10, "practice"), ("f3", "Week 3", 20, 20, "exam")], seconds: 2700, practice: ["Week 1"]
        ))])
        await model.readPlan()
        #expect(setupQueries(server) == ["", "folderIds=f1&folderIds=f3&pool=all"])
        #expect(model.drawn(model.folders[0]) == 10)
        #expect(model.drawn(model.folders[1]) == nil)
        #expect(model.summaryCount == "30 questions")
        #expect(model.summaryTime == "in 45 minutes")
        #expect(model.summarySplit == "10 from Week 1 · 20 from Week 3 · Fewer than 40, so it’s all of them at 1.5 minutes each.")
        #expect(model.fallbackLine == "Week 1 has no exam bank yet, so it uses its practice questions.")
        #expect(!model.isPlanUpdating)

        model.toggle(model.folders[1])
        #expect(model.isPlanUpdating, "the last plan stays until the new one arrives")
        #expect(model.summaryCount == "30 questions")
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview(
            [("f1", "Week 1", 10, 10, "practice"), ("f2", "Week 2", 10, 10, "practice"), ("f3", "Week 3", 20, 20, "exam")],
            seconds: 3600, practice: ["Week 1", "Week 2"]
        ))])
        await model.readPlan()
        #expect(!model.isPlanUpdating)
        #expect(model.summaryCount == "40 questions")
        #expect(model.summarySplit == "10 from Week 1 · 10 from Week 2 · 20 from Week 3")
        #expect(model.fallbackLine == "Weeks 1-2 have no exam bank yet, so they use their practice questions.")
        await model.readPlan()
        #expect(setupQueries(server).count == 3, "the plan on screen is already for these folders")
        model.toggle(model.folders[1])
        #expect(model.picked.count == 2, "a second tap unticks")
    }

    /// The numbers are the server's: a change to its rules shows on the phone without an update.
    @Test func theSummaryFollowsTheServersRulesNotTheOldOnes() async throws {
        let rules: StudyBodies.Rules = (25, 1800, 60)
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools, rules: rules)),
        ])
        let model = model(server)
        await model.load()
        model.toggle(model.folders[0])
        model.toggle(model.folders[1])
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview(
            [("f1", "Week 1", 10, 10, "practice"), ("f2", "Week 2", 10, 10, "practice")], seconds: 1200, practice: nil
        ), rules: rules)])
        await model.readPlan()
        #expect(model.summaryCount == "20 questions")
        #expect(model.summaryTime == "in 20 minutes")
        #expect(model.summarySplit == "10 from Week 1 · 10 from Week 2 · Fewer than 25, so it’s all of them at 1 minute each.")
        #expect(model.fallbackLine == nil, "the server said the course has no exam bank")

        model.toggle(model.folders[2])
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview(
            [("f1", "Week 1", 10, 6, "practice"), ("f2", "Week 2", 10, 6, "practice"), ("f3", "Week 3", 20, 13, "exam")], seconds: 1800
        ), rules: rules)])
        await model.readPlan()
        #expect(model.summaryCount == "25 questions")
        #expect(model.summaryTime == "in 30 minutes")
        #expect(model.summarySplit == "6 from Week 1 · 6 from Week 2 · 13 from Week 3")
        #expect(model.drawn(model.folders[2]) == 13)
    }

    @Test func wrongQuestionsOnlyCountsHerWrongOnesAndLocksEmptyFolders() async throws {
        let server = server()
        let model = model(server)
        await model.load()
        model.toggle(model.folders[2])
        model.wrongOnly = true
        #expect(model.meta(model.folders[0]) == "2 wrong of 10")
        #expect(model.meta(model.folders[2]) == "0 wrong of 20 · exam bank")
        #expect(!model.canTick(model.folders[2]))
        #expect(!model.isTicked(model.folders[2]), "its tick waits for the switch to go off")
        #expect(model.summarySplit == "Tick at least one folder with wrong questions.")
        #expect(model.footer == "Questions are drawn only from the wrong ones in the folders you tick, in proportion to how many each folder has.")
        model.toggle(model.folders[2])
        #expect(model.picked.isEmpty, "a locked folder cannot be ticked")
        model.toggle(model.folders[0])
        model.toggle(model.folders[1])
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview([("f1", "Week 1", 2, 2, "practice"), ("f2", "Week 2", 3, 3, "practice")], seconds: 450))])
        await model.readPlan()
        #expect(setupQueries(server).last == "folderIds=f1&folderIds=f2&pool=wrong")
        #expect(model.summaryCount == "5 questions")
        #expect(model.summaryTime == "in 7.5 minutes")
        model.wrongOnly = false
        #expect(model.isTicked(model.folders[2]), "back with the switch off")
        #expect(model.isPlanUpdating, "the plan was for her wrong questions")
    }

    @Test func noWrongQuestionsAnywhereSaysSo() async throws {
        let model = model(server(pools: [("f1", "Week 1", nil, 4, 0, "practice")]))
        await model.load()
        model.wrongOnly = true
        #expect(model.summarySplit == "No wrong questions in this course right now.")
        #expect(model.fallbackLine == nil)
    }

    /// Ticking without a connection: the plan for what she had ticked still shows, and a new tick
    /// says its plan comes back with the connection, instead of showing the old numbers.
    @Test func withoutAConnectionANewTickWaitsForThePlan() async throws {
        let server = server()
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        let model = ExamSetupModel(app: app, route: ExamSetupRoute(course: Self.course))
        await model.load()
        model.toggle(model.folders[0])
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview([("f1", "Week 1", 10, 10, "practice")], seconds: 900))])
        await model.readPlan()
        connection.update(isOnline: false)
        #expect(model.summaryCount == "10 questions", "still the plan for what is ticked")
        model.toggle(model.folders[1])
        server.script("GET /api/courses/c1/exams", [.offline])
        await model.readPlan()
        #expect(model.summaryCount == nil)
        #expect(model.drawn(model.folders[0]) == nil)
        #expect(model.summarySplit == "What the exam draws shows once you’re back online.")
        #expect(model.problem == nil, "the screen already says exams need a connection")
        model.toggle(model.folders[1])
        #expect(model.summaryCount == "10 questions", "back to what the plan was for")

        model.toggle(model.folders[1])
        connection.update(isOnline: true)
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview([("f1", "Week 1", 10, 10, "practice"), ("f2", "Week 2", 10, 10, "practice")], seconds: 1800))])
        await model.load()
        #expect(model.summaryCount == "20 questions", "the reload with the connection reads the plan")
    }

    @Test func anExamPagesStartButtonTicksItsFolders() async throws {
        let server = server()
        server.script("GET /api/courses/c1/exams", [planned(StudyBodies.preview([("f1", "Week 1", 10, 10, "practice"), ("f2", "Week 2", 10, 10, "practice")], seconds: 1800))])
        let model = model(server, route: ExamSetupRoute(course: Self.course, folderIDs: ["f1", "f2", "gone"], examName: "Exam 1"))
        await model.load()
        #expect(model.picked.map(\.name) == ["Week 1", "Week 2"], "a folder the setup does not have is left out")
        #expect(model.preselectedLine == "Exam 1 · 2 folders ticked for you")
        #expect(setupQueries(server) == ["folderIds=f1&folderIds=f2&folderIds=gone&pool=all"], "the first read asks for the page's plan")
        #expect(model.summaryCount == "20 questions")
        await model.readPlan()
        #expect(setupQueries(server).count == 1, "the plan read first is already for the ticked folders")
        model.toggle(model.folders[0])
        await model.load()
        #expect(model.picked.map(\.name) == ["Week 2"], "a reload keeps what she changed")
        #expect(setupQueries(server).last == "folderIds=f2&pool=all")
    }

    @Test func startSendsTheTickedFoldersAndThePool() async throws {
        let server = server()
        server["POST /api/courses/c1/exams"] = StubServer.Reply(status: 201, body: StudyBodies.exam())
        let model = model(server)
        await model.load()
        model.toggle(model.folders[1])
        model.toggle(model.folders[0])
        model.wrongOnly = true
        let exam = await model.start()
        #expect(exam?.id == "e1")
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"folderIds":["f1","f2"],"pool":"wrong","replaces":null}"#, "no exam is known to run")
    }

    // MARK: Starting over a running exam

    @Test func startWaitsUntilTheRunningExamIsKnown() async throws {
        let server = server()
        server.script("GET /api/courses/c1/exams", [.offline])
        let model = model(server)
        #expect(!model.canStart)
        #expect(await model.start() == nil)
        await model.load()
        #expect(model.running == .unknown, "a failed read is not \"none running\"")
        #expect(!model.canStart)
        await model.load()
        #expect(model.running == .none)
        model.toggle(model.folders[0])
        #expect(model.canStart)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
    }

    @Test func aRunningExamIsAskedAboutAndNamedAsTheOneToEnd() async throws {
        let running = StudyBodies.summary("run", weeks: ["Week 1"], folders: ["f1"], finished: false, endsAt: "2026-10-12T00:17:01.000Z")
        let server = StubServer([
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools, inProgress: running)),
            "POST /api/courses/c1/exams": StubServer.Reply(status: 201, body: StudyBodies.exam()),
        ])
        let model = model(server)
        await model.load()
        #expect(model.running.exam?.id == "run")
        model.toggle(model.folders[1])
        #expect(await model.start() == nil)
        #expect(model.asksToReplace)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") }, "nothing starts before she agrees")
        model.asksToReplace = false
        #expect(await model.startReplacing()?.id == "e1")
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"folderIds":["f2"],"pool":"all","replaces":"run"}"#)
        #expect(model.running == .unknown, "the new exam runs; the setup is read again when it closes")
    }

    /// An exam started on another device after the setup was read: the server refuses, and the
    /// question comes up about that exam instead of an error.
    @Test func anExamTheSetupDidNotKnowBringsUpTheQuestion() async throws {
        let other = StudyBodies.summary("other", weeks: ["Week 3"], folders: ["f3"], finished: false, answered: 1, questions: 4, endsAt: "2026-10-12T00:20:00.000Z")
        let server = server()
        let model = model(server)
        await model.load()
        #expect(model.running == .none)
        model.toggle(model.folders[0])
        server["POST /api/courses/c1/exams"] = StubServer.Reply(
            status: 409,
            body: #"{"error":"exam_in_progress","message":"An exam is still running. Starting a new one ends it, so confirm that first.","inProgress":\#(other)}"#
        )
        #expect(await model.start() == nil)
        #expect(model.problem == nil)
        #expect(model.asksToReplace)
        let exam = try #require(model.running.exam)
        #expect(exam.id == "other")
        #expect(model.runningLine(exam, at: Self.readAt) == "Week 3 · 1 of 4 answered · 15 min left", "Resume shows it")
        #expect(String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).hasSuffix(#""replaces":null}"#))

        server["POST /api/courses/c1/exams"] = StubServer.Reply(status: 201, body: StudyBodies.exam())
        #expect(await model.startReplacing()?.id == "e1")
        #expect(String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).hasSuffix(#""replaces":"other"}"#))
    }

    @Test func aRefusedStartIsSaidInTheServersWords() async throws {
        let server = server()
        server["POST /api/courses/c1/exams"] = .error(400, "no_wrong_questions", "Week 1 has no wrong questions. Untick it, or turn off Wrong questions only.")
        let model = model(server)
        await model.load()
        model.toggle(model.folders[0])
        #expect(await model.start() == nil)
        #expect(model.problem == "Week 1 has no wrong questions. Untick it, or turn off Wrong questions only.")
        #expect(!model.isStarting)
    }

    @Test func theRunningExamAndPastOnesReadAsOnTheWeb() async throws {
        let running = StudyBodies.summary("run", weeks: ["Week 1", "Week 2"], pool: "wrong", finished: false, answered: 3, questions: 11, endsAt: "2026-10-12T00:17:01.000Z")
        let server = StubServer(["GET /api/courses/c1/exams": .ok(StudyBodies.setup(
            folders: StudyBodies.threePools,
            inProgress: running,
            exams: [
                StudyBodies.summary("s1", weeks: ["Week 1"], pool: "wrong", reason: "timeout", questions: 22, right: 15),
                StudyBodies.summary("s2", weeks: ["First Pass", "Second Pass"], folders: ["f8", "f9"]),
            ]
        ))])
        let model = model(server)
        await model.load()
        let exam = try #require(model.setup?.inProgress)
        #expect(model.runningLine(exam, at: Self.readAt) == "Weeks 1-2 · Wrong questions only · 3 of 11 answered · 13 min left")
        let past = try #require(model.setup?.exams.first)
        #expect(past.pastLine == "12 min · Wrong questions only · Time ran out")
        #expect(past.scoreText == "15 of 22")
        #expect(past.pastTitle.hasPrefix("Week 1 · "))
        #expect(model.setup?.exams.last?.pastTitle.hasPrefix("First Pass, Second Pass · ") == true)
    }

    @Test func theOwnerSeesTheNoteForATickAndCannotStart() async throws {
        let server = server()
        let (app, _) = TestApp.make(server, account: .admin)
        let model = ExamSetupModel(app: app, route: ExamSetupRoute(course: Self.course))
        await model.load()
        model.toggle(model.folders[0])
        #expect(model.picked.isEmpty)
        #expect(app.frozen.noteID != nil)
        #expect(await model.start() == nil)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
    }
}
