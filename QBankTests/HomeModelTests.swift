import QBankKit
import Testing
@testable import QBank

@MainActor
struct HomeModelTests {
    @Test func loadsSemestersWithoutArchivedCoursesInTheOwnersOrder() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(
                Bodies.semesters([
                    Bodies.course(id: "c2", code: "NURS 220", order: 2),
                    Bodies.course(id: "c3", code: "NURS 330", order: 3, archived: true),
                    Bodies.course(id: "c1", code: "NURS 101", order: 1),
                ]))
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        let semester = try #require(model.semesters?.first)
        #expect(model.courses(in: semester).map(\.code) == ["NURS 101", "NURS 220"])
        #expect(model.problem == nil)
    }

    @Test func withoutSignalHomeShowsTheSavedCoursesAndHowOldTheyAre() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters([Bodies.course(id: "c1", code: "NURS 101"), Bodies.course(id: "c2", code: "NURS 220", order: 2)])),
            "GET /api/courses/c1": .ok(Bodies.courseDetail()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(model.savedAt == nil)
        await CourseModel(app: app, id: "c1").load()

        server["GET /api/semesters"] = .offline
        await model.load()
        let semester = try #require(model.semesters?.first)
        #expect(model.courses(in: semester).map(\.code) == ["NURS 101", "NURS 220"])
        #expect(model.problem == nil, "a banner says it, not a problem")
        let listSaved = try #require(model.savedAt)
        let courses = model.courses(in: semester)
        let courseSaved = try #require(await app.offline?.saved(.course("c1"))?.savedAt)
        #expect(model.savedAt(courses[0]) == courseSaved, "a course opened later shows its own time")
        #expect(model.savedAt(courses[1]) == listSaved)
        #expect(model.isLoading == false)

        server["GET /api/semesters"] = .ok(Bodies.semesters())
        await model.load()
        #expect(model.savedAt == nil, "back online, the badges go")
        #expect(model.savedAt(courses[0]) == nil)
    }

    @Test func noSignalAndNothingSavedSaysSo() async {
        let server = StubServer(["GET /api/semesters": .offline])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(model.semesters == nil)
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
    }

    @Test func waitingAnswersCountIntoTheCourseCards() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters([Bodies.course(id: "c1", code: "NURS 101", answered: 3)])),
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [Bodies.set(id: "set1", questionIDs: ["q-sata", "q-single"])])),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
        ])
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        await CourseModel(app: app, id: "c1").load()
        let practice = PracticeModel(app: app, source: .set(id: "set1"), courseID: "c1", title: "Invented set")
        await practice.load()
        connection.update(isOnline: false)
        practice.update(.sata([0, 2]))
        await practice.check()
        #expect(app.offline?.waiting.count == 1)

        let model = HomeModel(app: app)
        await model.load()
        let semester = try #require(model.semesters?.first)
        #expect(model.courses(in: semester).first?.answeredCount == 4)
        #expect(Wording.answeredPercent(try #require(model.courses(in: semester).first)) == 40)
    }

    @Test func savingForOfflineWaitsForTheServersCopy() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/courses/c1": .ok(Bodies.courseDetail()),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        model.saveForOffline()
        await app.offline?.finishSavingCourses()
        #expect(server.calls.contains("GET /api/practice-sets/set1"))
        #expect(await app.offline?.saved(.practiceSet("set1")) != nil)
    }

    @Test func endedSessionSignsOut() async {
        let server = StubServer(["GET /api/semesters": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(app.route == .signedOut)
        #expect(model.problem == nil)
    }

    @Test func landsOnTheLastCourseOncePerSignIn() async {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(await model.landingCourse() == CourseRoute(id: "c1", name: "NURS 101"))
        #expect(await model.landingCourse() == nil)
        #expect(server.calls.filter { $0 == "GET /api/me/place" }.count == 1)
    }

    @Test func noPlaceStaysOnHome() async {
        let server = StubServer(["GET /api/me/place": .ok(Bodies.place(nil))])
        let (app, _) = TestApp.make(server, account: .student())
        #expect(await HomeModel(app: app).landingCourse() == nil)
    }

    @Test func adminHasNoStudyPlace() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .admin)
        #expect(await HomeModel(app: app).landingCourse() == nil)
        #expect(server.requests.isEmpty)
    }
}

/// Home's + and holding a course: adding a semester, archiving, unarchiving and moving a course.
@MainActor
struct HomeEditingTests {
    private static let twoSemesters = Bodies.catalog([
        Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 406")]),
        Bodies.semester(id: "s2", number: 2),
    ])

    private func loaded(_ server: StubServer) async -> HomeModel {
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        return model
    }

    private static func body(_ server: StubServer, _ method: String) throws -> String {
        let request = try #require(server.requests.last { $0.httpMethod == method })
        return String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    @Test func addsTheLowestMissingSemester() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s2", number: 2)])),
            "POST /api/semesters": StubServer.Reply(status: 201, body: Bodies.semester(id: "s1", number: 1)),
        ])
        let model = await loaded(server)
        #expect(model.nextSemesterNumber == 1)
        server["GET /api/semesters"] = .ok(Self.twoSemesters)
        await model.addSemester()
        #expect(server.calls == ["GET /api/semesters", "GET /api/deleted-courses", "POST /api/semesters", "GET /api/semesters", "GET /api/deleted-courses"])
        #expect(try Self.body(server, "POST") == #"{"number":1}"#)
        #expect(model.editProblem == nil)
        #expect(model.nextSemesterNumber == 3)
    }

    @Test func allThreeSemestersLeaveNothingToAdd() async {
        let full = Bodies.catalog((1...3).map { Bodies.semester(id: "s\($0)", number: $0) })
        let server = StubServer(["GET /api/semesters": .ok(full)])
        let model = await loaded(server)
        #expect(model.nextSemesterNumber == nil)
        await model.addSemester()
        #expect(server.calls == ["GET /api/semesters", "GET /api/deleted-courses"])
    }

    @Test func aRefusalSaysTheServersWords() async {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.catalog([])),
            "POST /api/semesters": .error(409, "request_refused", "Semester 1 already exists."),
        ])
        let model = await loaded(server)
        await model.addSemester()
        #expect(model.editProblem == "Semester 1 already exists.")
        #expect(!model.isEditing)
    }

    @Test func aHeldCourseIsArchivedWithNoQuestionAndUnarchived() async throws {
        let archived = Bodies.catalog([
            Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 406", archived: true)]),
            Bodies.semester(id: "s2", number: 2),
        ])
        let server = StubServer([
            "GET /api/semesters": .ok(Self.twoSemesters),
            "PATCH /api/courses/c1": .ok(Bodies.course(id: "c1", code: "NURS 406", archived: true)),
        ])
        let model = await loaded(server)
        let course = try #require(model.courses(in: model.studiedSemesters[0]).first)
        server["GET /api/semesters"] = .ok(archived)
        await model.setArchived(course, true)
        #expect(try Self.body(server, "PATCH") == #"{"archived":true}"#)
        #expect(model.courses(in: model.studiedSemesters[0]).isEmpty)
        #expect(model.archived.map { $0.courses.map(\.code) } == [["NURS 406"]])

        server["GET /api/semesters"] = .ok(Self.twoSemesters)
        await model.setArchived(try #require(model.archived.first?.courses.first), false)
        #expect(try Self.body(server, "PATCH") == #"{"archived":false}"#)
        #expect(model.archived.isEmpty)
    }

    @Test func aHeldCourseMovesToAnotherSemesterSheStudies() async throws {
        let withArchived = Bodies.catalog([
            Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 406")]),
            Bodies.semester(id: "s2", number: 2),
            Bodies.semester(id: "s3", number: 3, archived: true),
        ])
        let server = StubServer([
            "GET /api/semesters": .ok(withArchived),
            "PATCH /api/courses/c1": .ok(Bodies.course(id: "c1", code: "NURS 406")),
        ])
        let model = await loaded(server)
        let course = try #require(model.courses(in: model.studiedSemesters[0]).first)
        let others = model.otherSemesters(than: course)
        #expect(others.map(\.number) == [2], "not its own, nor one she archived")
        await model.move(course, to: try #require(others.first))
        #expect(try Self.body(server, "PATCH") == #"{"code":"NURS 406","semesterId":"s2","title":"Invented NURS 406"}"#)
        #expect(server.calls.suffix(2) == ["GET /api/semesters", "GET /api/deleted-courses"], "the list is read again")
    }

    @Test func nothingIsEditedFromThePhonesCopy() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Self.twoSemesters)])
        let model = await loaded(server)
        let course = try #require(model.courses(in: model.studiedSemesters[0]).first)
        server["GET /api/semesters"] = .offline
        await model.load()
        #expect(model.savedAt != nil)
        #expect(!model.canEdit)
        await model.setArchived(course, true)
        await model.addSemester()
        #expect(!server.calls.contains { $0.hasPrefix("PATCH") || $0.hasPrefix("POST") })
    }
}
