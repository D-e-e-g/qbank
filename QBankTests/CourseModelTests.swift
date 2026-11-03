import QBankKit
import Testing
@testable import QBank

@MainActor
struct CourseModelTests {
    @Test func loadsTheCourse() async throws {
        let server = StubServer(["GET /api/courses/c1": .ok(Bodies.courseDetail())])
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        let course = try #require(model.course)
        #expect(course.code == "NURS 101")
        #expect(course.folders.first?.sets.map(\.id) == ["set1"])
    }

    @Test func anOlderLoadAnsweredLateLeavesTheNewerCourse() async throws {
        let server = StubServer()
        server.script("GET /api/courses/c1", [
            .ok(Bodies.courseDetail(sets: [Bodies.set(id: "before")])),
            .ok(Bodies.courseDetail(sets: [Bodies.set(id: "after")])),
        ])
        server.hold("GET /api/courses/c1")
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "c1")
        let older = Task { await model.load() }
        while !server.calls.contains("GET /api/courses/c1") { await Task.yield() }
        await model.load()
        #expect(model.course?.folders.first?.sets.map(\.id) == ["after"])
        server.release("GET /api/courses/c1")
        await older.value
        #expect(model.course?.folders.first?.sets.map(\.id) == ["after"])
        #expect(!model.isLoading)
    }

    /// Each exam page's Start exam line is the server's plan over its folders, kept when a later
    /// read of the plans fails.
    @Test func examPagesSayTheServersPlan() async throws {
        let plan = StudyBodies.preview([("f1", "Week 1", 10, 8, "practice"), ("f2", "Week 2", 10, 7, "practice")], questions: 15, seconds: 900)
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1", "f2"])])),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(folders: StudyBodies.threePools, pages: [("x1", plan)])),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        let page = try #require(model.layout?.page("x1"))
        let draw = try #require(model.plan(for: page).flatMap(FolderWording.examDraw))
        #expect(draw == "15 questions from the 20 in these 2 folders, or Wrong questions only.")

        server["GET /api/courses/c1/exams"] = .error(500, "internal_error", "Something went wrong.")
        await model.load()
        #expect(model.plan(for: page)?.questionCount == 15)
    }

    @Test func missingCourseSaysTheServersWords() async {
        let server = StubServer(["GET /api/courses/gone": .error(404, "request_refused", "That course is not in the app.")])
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "gone")
        await model.load()
        #expect(model.course == nil)
        #expect(model.problem == "That course is not in the app.")
    }

    @Test func remembersTheCourseAsHerPlace() async throws {
        let server = StubServer(["PUT /api/me/place": .ok(Bodies.place("c1"))])
        let (app, _) = TestApp.make(server, account: .student())
        await CourseModel(app: app, id: "c1").rememberPlace()
        #expect(server.calls == ["PUT /api/me/place"])
        let body = try #require(server.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"courseId":"c1"}"#)
    }

    @Test func adminLeavesNoPlace() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .admin)
        await CourseModel(app: app, id: "c1").rememberPlace()
        #expect(server.requests.isEmpty)
    }

    @Test func restoreBringsBackThePreviousVersionAndReloads() async throws {
        let replaced = Bodies.set(id: "v2", title: "Invented set", status: "replaced", canRestore: true)
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [replaced])),
            "POST /api/practice-sets/v2/restore": .ok(Bodies.set(id: "v1", status: "restored", canRestore: true)),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        let replacedSet = try #require(model.course?.folders.first?.sets.first)
        server["GET /api/courses/c1"] = .ok(Bodies.courseDetail(sets: [Bodies.set(id: "v1", status: "restored", canRestore: true)]))
        await model.restore(replacedSet)
        #expect(model.isRestoring == false)
        #expect(model.course?.folders.first?.sets.first?.status == .restored)
        // The exam pages' read of her exams runs beside each course read.
        #expect(server.calls.filter { !$0.hasSuffix("/exams") } == ["GET /api/courses/c1", "POST /api/practice-sets/v2/restore", "GET /api/courses/c1"])
    }

    @Test func refusedRestoreSaysWhyAndKeepsTheCourse() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [Bodies.set(id: "v2", status: "replaced", canRestore: true)])),
            "POST /api/practice-sets/v2/restore": .error(404, "request_refused", "That set is not the current version."),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        await model.restore(try #require(model.course?.folders.first?.sets.first))
        #expect(model.problem == "That set is not the current version.")
        #expect(model.course != nil)
        #expect(server.calls.filter { !$0.hasSuffix("/exams") }.count == 2)
    }

    @Test func withoutSignalTheSavedCourseShowsWithHerWaitingAnswers() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [Bodies.set(id: "set1", questionIDs: ["q-sata", "q-single"])])),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
        ])
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        #expect(model.savedAt == nil)
        let practice = PracticeModel(app: app, source: .set(id: "set1"), courseID: "c1", title: "Invented set")
        await practice.load()

        connection.update(isOnline: false)
        practice.update(.sata([0, 2]))
        await practice.check()
        practice.next()
        practice.update(.single(1))
        await practice.check()
        #expect(app.offline?.waiting.count == 2)

        await model.load()
        #expect(model.savedAt != nil)
        #expect(model.problem == nil)
        let set = try #require(model.course?.folders.first?.sets.first)
        #expect(set.answeredCount == 2)
        #expect(set.fullyRightCount == 1)
        #expect(Wording.status(set) == "Done today · 1 of 2 fully right")
        #expect(model.course?.answeredCount == 2)
        #expect(server.calls.filter { $0 == "GET /api/courses/c1" }.count == 1, "without a network path it reads the phone's copy")
    }

    @Test func offlineTheCourseIsNotRememberedAsHerPlace() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student(), connection: Connection(isOnline: false))
        await CourseModel(app: app, id: "c1").rememberPlace()
        #expect(server.requests.isEmpty)
    }
}
