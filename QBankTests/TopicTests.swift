import Foundation
import QBankKit
import Testing
@testable import QBank

/// Study topics on Home, held on Home, in Import and on a topic's own screens.
@MainActor
struct TopicTests {
    private static let design = Bodies.topic(id: "t1", title: "Invented Systems Design", order: 1)
    private static let spanish = Bodies.topic(id: "t2", title: "Invented Spanish Verbs", order: 2)
    private static let archivedTopic = Bodies.topic(id: "t3", title: "Invented Old Notes", order: 3, archived: true)

    /// A semester she studies with one archived course, an archived semester, and three topics.
    private static let catalog = Bodies.catalog(
        [
            Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 101"), Bodies.course(id: "c2", code: "NURS 102", order: 2, archived: true)]),
            Bodies.semester(id: "s2", number: 2, archived: true, courses: [Bodies.course(id: "c3", code: "NURS 201")]),
        ],
        topics: [design, spanish, archivedTopic]
    )

    private static func body(_ server: StubServer, _ route: String) throws -> [String: Any] {
        let request = server.requests.last { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" == route }
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Home

    @Test func homeListsTopicsAfterSemestersAndWhatSheArchivedLast() async throws {
        let (app, _) = TestApp.make(StubServer(["GET /api/semesters": .ok(Self.catalog)]), account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(model.studiedSemesters.map(\.name) == ["Semester 1"])
        #expect(model.courses(in: model.studiedSemesters[0]).map(\.code) == ["NURS 101"])
        #expect(model.topics.map(\.title) == ["Invented Systems Design", "Invented Spanish Verbs"])
        #expect(model.archived.map(\.title) == ["Semester 1", "Semester 2", "Study topics"])
        #expect(model.archived.map { $0.courses.map(Wording.name) } == [["NURS 102"], ["NURS 201"], ["Invented Old Notes"]])
    }

    @Test func nothingArchivedLeavesNoArchivedGroup() async throws {
        let (app, _) = TestApp.make(StubServer(["GET /api/semesters": .ok(Bodies.semesters(topics: [Self.design]))]), account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(model.archived.isEmpty)
        #expect(model.canEdit)
    }

    @Test func onlyAUserAccountEditsHomeAndNotFromThePhonesCopy() async throws {
        let (admin, _) = TestApp.make(StubServer(["GET /api/semesters": .ok(Self.catalog)]), account: .admin)
        let viewing = HomeModel(app: admin)
        await viewing.load()
        #expect(viewing.offersEditing && !viewing.canEdit, "the admin sees the user's controls, and they change nothing")

        let server = StubServer(["GET /api/semesters": .ok(Self.catalog)])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        server["GET /api/semesters"] = .offline
        await model.load()
        #expect(!model.offersEditing && !model.canEdit, "adding, moving and archiving need QBank")
    }

    @Test func aTopicSheMadeOpensWithItsName() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters())])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        server["GET /api/semesters"] = .ok(Bodies.semesters(topics: [Self.design]))
        let made = try Bodies.decodeCatalog(Bodies.semesters(topics: [Self.design])).topics[0]
        let route = await model.made(made)
        #expect(route == CourseRoute(id: "t1", name: "Invented Systems Design", kind: .topic))
        #expect(model.topics.map(\.id) == ["t1"], "Home read the list again")
    }

    @Test func homeLandsOnTheTopicSheUsedLast() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Self.catalog), "GET /api/me/place": .ok(Bodies.place("t2"))])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        #expect(await model.landingCourse() == CourseRoute(id: "t2", name: "Invented Spanish Verbs", kind: .topic))
    }

    // MARK: New topic

    @Test func aNewTopicNeedsAName() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student())
        let model = NewTopicModel(app: app)
        model.name = "   "
        #expect(await model.save() == nil)
        #expect(model.problem == "Give the topic a name.")
        #expect(server.requests.isEmpty)
    }

    @Test func aNewTopicSendsItsNameTrimmed() async throws {
        let server = StubServer(["POST /api/topics": StubServer.Reply(status: 201, body: Self.design)])
        let (app, _) = TestApp.make(server, account: .student())
        let model = NewTopicModel(app: app)
        model.name = "  Invented Systems Design "
        let made = try #require(await model.save())
        #expect(made.kind == .topic && made.title == "Invented Systems Design")
        #expect(try Self.body(server, "POST /api/topics") as? [String: String] == ["title": "Invented Systems Design"])
    }

    @Test func aTakenNameSaysTheServersWords() async {
        let server = StubServer(["POST /api/topics": .error(409, "request_refused", "You already have a topic named Invented Systems Design.")])
        let (app, _) = TestApp.make(server, account: .student())
        let model = NewTopicModel(app: app)
        model.name = "Invented Systems Design"
        #expect(await model.save() == nil)
        #expect(model.problem == "You already have a topic named Invented Systems Design.")
    }

    // MARK: Holding a topic on Home, and a semester in Settings

    private func loaded(_ server: StubServer) async -> CatalogModel {
        let (app, _) = TestApp.make(server, account: .student())
        let catalog = CatalogModel(app: app)
        await catalog.load()
        return catalog
    }

    @Test func aTopicIsRenamedByItsTitleAlone() async throws {
        let renamed = Bodies.topic(id: "t1", title: "Invented Distributed Systems")
        let server = StubServer([
            "GET /api/semesters": .ok(Self.catalog),
            "PATCH /api/courses/t1": .ok(renamed),
        ])
        let catalog = await loaded(server)
        let model = TopicEditModel(catalog: catalog, id: "t1")
        #expect(model.title == "Invented Systems Design")
        model.title = ""
        await model.save()
        #expect(model.problem == "Give the topic a name.")
        #expect(!server.calls.contains("PATCH /api/courses/t1"))

        model.title = "Invented Distributed Systems"
        server["GET /api/semesters"] = .ok(Bodies.catalog([], topics: [renamed]))
        await model.save()
        #expect(try Self.body(server, "PATCH /api/courses/t1") as? [String: String] == ["title": "Invented Distributed Systems"])
        #expect(model.note == "Saved.")
        #expect(model.topic?.title == "Invented Distributed Systems")
    }

    @Test func aTopicHeldOnHomeIsArchivedAndUnarchived() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.catalog([], topics: [Self.design])),
            "PATCH /api/courses/t1": .ok(Bodies.topic(id: "t1", title: "Invented Systems Design", archived: true)),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        let topic = try #require(model.topics.first)
        #expect(model.otherSemesters(than: topic).isEmpty, "a topic has no semester to move to")
        server["GET /api/semesters"] = .ok(Bodies.catalog([], topics: [Bodies.topic(id: "t1", title: "Invented Systems Design", archived: true)]))
        await model.setArchived(topic, true)
        #expect(try Self.body(server, "PATCH /api/courses/t1") as? [String: Bool] == ["archived": true])
        #expect(model.topics.isEmpty)
        #expect(model.archived.map(\.title) == ["Study topics"])

        server["GET /api/semesters"] = .ok(Bodies.catalog([], topics: [Self.design]))
        await model.setArchived(try #require(model.archived.first?.courses.first), false)
        #expect(try Self.body(server, "PATCH /api/courses/t1") as? [String: Bool] == ["archived": false])
        #expect(model.topics.map(\.id) == ["t1"])
        #expect(model.editProblem == nil)
    }

    @Test func aTopicHeldOnHomeMovesUpOrDownAmongTheOnesInUse() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Self.catalog),
            "PUT /api/topic-order": .ok(#"{"topics":[\#(Self.spanish),\#(Self.design),\#(Self.archivedTopic)]}"#),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = HomeModel(app: app)
        await model.load()
        let design = try #require(model.topics.first)
        let spanish = try #require(model.topics.last)
        #expect(!model.canMove(design, by: -1), "the first one has no Move up")
        #expect(model.canMove(design, by: 1))
        #expect(model.canMove(spanish, by: -1))
        #expect(!model.canMove(spanish, by: 1), "the last one in use has no Move down; archived ones do not count")
        await model.move(design, by: 1)
        #expect(try Self.body(server, "PUT /api/topic-order") as? [String: [String]] == ["topicIds": ["t2", "t1", "t3"]], "every topic, the archived one last")
        #expect(server.calls.suffix(2) == ["GET /api/semesters", "GET /api/deleted-courses"], "the list is read again")
        #expect(model.editProblem == nil)
    }

    @Test func onlyWhatIsInUseCanBeArchived() async throws {
        let (app, _) = TestApp.make(StubServer(["GET /api/semesters": .ok(Self.catalog)]), account: .student())
        let model = HomeModel(app: app)
        await model.load()
        let all = model.archived.flatMap(\.courses)
        #expect(model.canArchive(try #require(model.courses(in: model.studiedSemesters[0]).first)))
        #expect(model.canArchive(try #require(model.topics.first)))
        #expect(!model.canArchive(try #require(all.first { $0.id == "c2" })), "an archived course has Unarchive")
        #expect(!model.canArchive(try #require(all.first { $0.id == "c3" })), "a course of an archived semester is in Archived with it")
        #expect(model.otherSemesters(than: try #require(all.first { $0.id == "c3" })).map(\.id) == ["s1"], "moving it brings it back")
        #expect(!model.canArchive(try #require(all.first { $0.id == "t3" })))
    }

    @Test func aSemesterIsArchivedByHand() async throws {
        let studied = Bodies.catalog([Bodies.semester(id: "s1", number: 1)])
        let archived = Bodies.catalog([Bodies.semester(id: "s1", number: 1, archived: true)])
        let server = StubServer([
            "GET /api/semesters": .ok(studied),
            "PATCH /api/semesters/s1": .ok(Bodies.semester(id: "s1", number: 1, archived: true)),
        ])
        let catalog = await loaded(server)
        let model = SemesterModel(catalog: catalog, id: "s1")
        #expect(CatalogModel.summary(of: try #require(model.semester)) == "No courses yet")
        server["GET /api/semesters"] = .ok(archived)
        await model.toggleArchived()
        #expect(try Self.body(server, "PATCH /api/semesters/s1") as? [String: Bool] == ["archived": true])
        #expect(model.isArchived)
        #expect(model.archiveNote == "Archived. It moves to Archived on Home, with its courses.")
        #expect(CatalogModel.summary(of: try #require(model.semester)) == "Archived · No courses yet")
    }

    // MARK: Import

    private static func importing(place: String?, extra: [String: StubServer.Reply] = [:]) async -> (StubServer, ImportModel) {
        let server = StubServer([
            "GET /api/semesters": .ok(Self.catalog),
            "GET /api/me/place": .ok(Bodies.place(place)),
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "GET /api/courses/t1": .ok(StudyBodies.topicDetail()),
            "GET /api/courses/t2": .ok(StudyBodies.topicDetail(id: "t2", title: "Invented Spanish Verbs")),
        ].merging(extra) { _, new in new })
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        return (server, model)
    }

    @Test func importListsStudiedCoursesAndTopicsAndStartsOnHerTopic() async {
        let (_, model) = await Self.importing(place: "t1")
        #expect(model.destination.courses?.map(\.id) == ["c1"], "archived courses and semesters are left out")
        #expect(model.destination.topics.map(\.id) == ["t1", "t2"], "archived topics are left out")
        #expect(model.destination.courseID == "t1")
        #expect(model.destination.courseLabel == "Invented Systems Design")
        #expect(model.destination.detail?.kind == .topic)
    }

    @Test func importIntoANewTopicSendsItsName() async throws {
        let (server, model) = await Self.importing(place: "c1", extra: [
            "POST /api/imports/check": .ok(ImportModelTests.report()),
            "POST /api/imports": StubServer.Reply(status: 201, body: ImportModelTests.imported().replacingOccurrences(of: #""courseId":"c1","courseCode":"NURS 101""#, with: #""courseId":"t9","courseCode":"""#)),
        ])
        model.setSource(ImportModelTests.file)
        await model.check()
        await model.destination.chooseCourse(.newTopic)
        #expect(model.destination.makesTopic && !model.destination.makesCourse)
        #expect(model.destination.courseLabel == "New topic")
        model.destination.newTopicName = " Invented Statistics "
        server["GET /api/semesters"] = .ok(Bodies.catalog([], topics: [Bodies.topic(id: "t9", title: "Invented Statistics")]))
        await model.commit()
        let body = try Self.body(server, "POST /api/imports")
        #expect(body["courseId"] == nil && body["newCourse"] == nil)
        #expect(body["newTopic"] as? [String: String] == ["title": "Invented Statistics"])
        let done = try #require(model.done)
        #expect(done.courseName == "Invented Statistics")
        #expect(ImportWording.doneCopy(done) == "“Invented Sleep” · 3 questions in Invented Statistics, Unsorted. It is in the topic’s Folders list until you move it.")
    }

    @Test func makeQuestionsCannotMakeATopic() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Self.catalog), "GET /api/me/place": .ok(Bodies.place(nil)), "GET /api/courses/c1": .ok(StudyBodies.course())])
        let (app, _) = TestApp.make(server, account: .student())
        let destination = SetDestination(app: app, allowsNewCourse: false)
        try await destination.load()
        await destination.chooseCourse(.newTopic)
        #expect(destination.courseID == "c1")
        #expect(!destination.makesTopic)
    }

    // MARK: A topic's screens

    @Test func aStudyPageTakesItsPrimerLink() throws {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.topicDetail().utf8))
        let page = EditExamPageModel(app: app, course: topic, pageID: "tp1")
        #expect(page.hasLink)
        #expect(page.link == "https://notes.example.com/caching")
        #expect(!page.hasChanges)
        page.link = "  https://notes.example.com/queues "
        #expect(page.hasChanges)
        #expect(page.primerLink == .url("https://notes.example.com/queues"))
        page.link = " "
        #expect(page.primerLink == PrimerLink.none, "an empty field takes the link off")

        let new = EditExamPageModel(app: app, course: topic, pageID: nil)
        #expect(new.name == "Page 2")
        #expect(new.link.isEmpty)
    }

    @Test func anExamPageLeavesTheLinkAlone() throws {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        let course = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.course(pages: [(id: "p1", name: "Exam 1", folders: ["f1"])]).utf8))
        let page = EditExamPageModel(app: app, course: course, pageID: "p1")
        #expect(!page.hasLink)
        #expect(page.primerLink == .unchanged)
        #expect(EditExamPageModel(app: app, course: course, pageID: nil).name == "Page 2")
    }

    @Test func aNewStudyPageSendsItsLink() async throws {
        let server = StubServer(["POST /api/courses/t1/course-exams": StubServer.Reply(status: 201, body: StudyBodies.courseExam("tp2", "Page 2", order: 2, weeks: [], folders: [], link: "https://notes.example.com/queues"))])
        let (app, _) = TestApp.make(server, account: .student())
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.topicDetail().utf8))
        let page = EditExamPageModel(app: app, course: topic, pageID: nil)
        page.link = "https://notes.example.com/queues"
        #expect(await page.save() == .saved("tp2"))
        let body = try Self.body(server, "POST /api/courses/t1/course-exams")
        #expect(body["name"] as? String == "Page 2")
        #expect(body["linkUrl"] as? String == "https://notes.example.com/queues")
    }

    @Test func aTopicsFoldersAndExamsSayPage() async throws {
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.topicDetail().utf8))
        let loose = try #require(topic.folders.first { $0.examPageID == nil })
        #expect(FolderWording.folderNote(loose, page: nil) == "On no page · 1 set · 1 question")

        let server = StubServer([
            "GET /api/courses/t1": .ok(StudyBodies.topicDetail()),
            "GET /api/courses/t1/exams": .ok(StudyBodies.setup(folders: [("tf1", "Caching", "tp1", 3, 0, "practice"), ("tf2", "Unsorted", nil, 1, 0, "practice")])),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let route = ExamSetupRoute(course: CourseRef(id: "t1", code: "", title: "Invented Systems Design", kind: .topic))
        let model = ExamSetupModel(app: app, route: route)
        await model.load()
        #expect(model.words == Wording.words(.topic))
        #expect(model.groups.map(\.title) == ["Page 1", "On no page"])
    }
}
