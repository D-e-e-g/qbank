import Foundation
import QBankKit
import Testing
@testable import QBank

@MainActor
struct ImportModelTests {
    static let file = #"{"title":"Invented Sleep","questions":[]}"#

    @Test func startsOnTheCourseSheStudiedLast() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters([Bodies.course(id: "c1", code: "NURS 101"), Bodies.course(id: "c2", code: "NURS 202", order: 2)])),
            "GET /api/me/place": .ok(Bodies.place("c2")),
            "GET /api/courses/c2": .ok(StudyBodies.course(id: "c2")),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        #expect(model.destination.courseID == "c2")
        #expect(model.destination.courseLabel == "NURS 202 · Invented NURS 202")
        #expect(model.destination.folder == .unsorted)
        #expect(model.destination.detail?.id == "c2")
    }

    @Test func importHereStartsOnThatFolder() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters([Bodies.course(id: "c1", code: "NURS 101"), Bodies.course(id: "c2", code: "NURS 202", order: 2)])),
            "GET /api/courses/c1": .ok(StudyBodies.course(id: "c1")),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app, courseID: "c1", folderID: "f2")
        await model.load()
        #expect(model.destination.courseID == "c1")
        #expect(model.destination.folder == .folder("f2"))
        #expect(!server.calls.contains("GET /api/me/place"), "the folder's course wins")
    }

    @Test func aFolderThatIsGoneFallsBackToUnsorted() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/courses/c1": .ok(StudyBodies.course(id: "c1")),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app, courseID: "c1", folderID: "removed")
        await model.load()
        #expect(model.destination.folder == .unsorted)
    }

    @Test func withoutCoursesItMakesANewOne() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([]))])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        #expect(model.destination.courseID == nil)
        #expect(model.destination.courseLabel == "New course")
    }

    @Test func foldersAreGroupedByExamPageWithUnsortedFirst() async throws {
        let unsorted = StudyBodies.folder("u1", "Unsorted", order: 0, sets: [])
        let course = StudyBodies.course(pages: [(id: "p1", name: "Exam 1", folders: ["f1", "f2"])])
            .replacingOccurrences(of: #""folders":["#, with: #""folders":[\#(unsorted),"#)
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place(nil)),
            "GET /api/courses/c1": .ok(course),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        #expect(model.destination.unsortedExists)
        #expect(model.destination.folderGroups.map(\.title) == ["Exam 1", "Folders"])
        #expect(model.destination.folderGroups.map { $0.folders.map(\.name) } == [["Week 1", "Week 2"], ["Week 3"]], "Unsorted is its own chip")
    }

    @Test func unsortedIsNewUntilItExists() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place(nil)),
            "GET /api/courses/c1": .ok(StudyBodies.course()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        #expect(!model.destination.unsortedExists)
    }

    @Test func checkFillsTheSetNameUnlessSheChangedIt() async throws {
        let server = StubServer(["POST /api/imports/check": .ok(Self.report())])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        #expect(!model.canCheck, "nothing to check yet")
        model.setSource(Self.file)
        await model.check()
        #expect(model.canImport)
        #expect(model.title == "Invented Sleep")
        let body = try #require(server.requests.last?.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["source": Self.file])

        model.setTitle("Sleep, my name")
        model.setSource(Self.file + " ")
        #expect(!model.canImport, "a new text needs a new check")
        await model.check()
        #expect(model.title == "Sleep, my name")
    }

    @Test func aFileWithErrorsCanBeCopiedForCodex() async throws {
        let server = StubServer(["POST /api/imports/check": .ok(Self.report(ok: false, errors: ["Question 1 (Q1): missing takeaway", "Question 2 (Q2): missing ask"]))])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        model.setSource(Self.file)
        await model.check()
        #expect(!model.canImport)
        #expect(!model.copied)
        #expect(model.copyErrors() == "Question 1 (Q1): missing takeaway\nQuestion 2 (Q2): missing ask")
        #expect(model.copied)
    }

    @Test(arguments: [
        (SetDestination.FolderChoice.unsorted, "", nil as String?, nil as String?),
        (.folder("f2"), "", "f2", nil),
        (.new, "  First Pass ", nil, "First Pass"),
    ])
    func importSendsTheCourseAndFolder(choice: SetDestination.FolderChoice, name: String, folderID: String?, folderName: String?) async throws {
        let (server, model) = try await Self.ready()
        model.destination.folder = choice
        model.destination.newFolderName = name
        await model.commit()
        let body = try Self.importBody(server)
        #expect(body["courseId"] as? String == "c1")
        #expect(body["decision"] as? String == "import")
        #expect(body["folderId"] as? String == folderID)
        #expect(body["folderName"] as? String == folderName)
        #expect(body["title"] as? String == "Invented Sleep")
        #expect(model.done?.set.folderName == "Unsorted")
    }

    @Test func aNewFolderNeedsAName() async throws {
        let (server, model) = try await Self.ready()
        model.destination.folder = .new
        model.destination.newFolderName = "  "
        let before = server.requests.count
        await model.commit()
        #expect(server.requests.count == before)
        #expect(model.problem == "Name the new folder, or pick one.")
    }

    @Test func aNewCourseIsSentWithItsSemester() async throws {
        let (server, model) = try await Self.ready()
        await model.destination.chooseCourse(.new)
        #expect(model.destination.courseID == nil)
        model.destination.newCode = " NURS 303 "
        model.destination.newTitle = "Invented Pharmacology"
        model.destination.semesterNumber = 2
        await model.commit()
        let body = try Self.importBody(server)
        #expect(body["courseId"] == nil)
        #expect(body["newCourse"] as? [String: AnyHashable] == ["code": "NURS 303", "title": "Invented Pharmacology", "semesterNumber": 2])
        #expect(body["folderId"] == nil)
    }

    @Test func aSetOfTheSameNameAsksAndHerAnswerIsSent() async throws {
        let (server, model) = try await Self.ready()
        server.script("POST /api/imports", [StubServer.Reply(status: 409, body: Self.conflict), StubServer.Reply(status: 201, body: Self.imported(kind: "replaced"))])
        await model.commit()
        let conflict = try #require(model.conflict)
        #expect(ImportWording.replaceTitle(conflict) == "Replace “Invented Sleep”?")
        #expect(ImportWording.replaceMessage(conflict) == "NURS 101, Week 1 already has a set with this name. Replacing swaps its 3 questions for the 4 in this file, and it stays in Week 1. Answers on unchanged questions are kept, and the old version stays restorable.")
        #expect(model.done == nil)
        await model.commit(.replace)
        #expect(model.conflict == nil)
        #expect(try Self.importBody(server)["decision"] as? String == "replace")
        #expect(model.done?.set.kind == .replaced)
    }

    @Test func aRefusedImportSaysTheServersWords() async throws {
        let (server, model) = try await Self.ready()
        server["POST /api/imports"] = .error(400, "request_refused", "Choose a course.")
        await model.commit()
        #expect(model.problem == "Choose a course.")
        #expect(model.done == nil)
    }

    @Test func doneNamesTheExamPageItLandedOn() async throws {
        let (server, model) = try await Self.ready()
        server["POST /api/imports"] = StubServer.Reply(status: 201, body: Self.imported(folder: "f1", folderName: "Week 1", page: "p1"))
        server["GET /api/courses/c1"] = .ok(StudyBodies.course(pages: [(id: "p1", name: "Exam 1", folders: ["f1"])]))
        await model.commit()
        let done = try #require(model.done)
        #expect(done.examPageName == "Exam 1")
        #expect(ImportWording.doneCopy(done) == "“Invented Sleep” · 3 questions in NURS 101, Week 1. It is on Exam 1.")
    }

    @Test func importAnotherFileKeepsTheCourseAndGoesBackToUnsorted() async throws {
        let (_, model) = try await Self.ready()
        model.destination.folder = .folder("f2")
        await model.commit()
        #expect(model.done != nil)
        await model.startOver()
        #expect(model.done == nil)
        #expect(model.destination.courseID == "c1")
        #expect(model.destination.folder == .unsorted)
        #expect(model.source.isEmpty)
        #expect(model.report == nil)
        #expect(model.title.isEmpty)
    }

    @Test func withoutAConnectionNothingIsChecked() async throws {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student(), connection: Connection(isOnline: false))
        let model = ImportModel(app: app)
        model.setSource(Self.file)
        #expect(!model.canCheck)
        await model.check()
        #expect(server.requests.isEmpty)
    }

    @Test func doneWording() throws {
        let unsorted = ImportModel.Done(set: try Self.set(), examPageName: nil)
        #expect(ImportWording.doneCopy(unsorted) == "“Invented Sleep” · 3 questions in NURS 101, Unsorted. It is in the course’s Folders list until you move it.")
        let folder = ImportModel.Done(set: try Self.set(folderName: "Week 2"), examPageName: nil)
        #expect(ImportWording.doneCopy(folder) == "“Invented Sleep” · 3 questions in NURS 101, Week 2.")
        let exam = ImportModel.Done(set: try Self.set(setKind: "exam", folderName: "Week 2", count: 1), examPageName: nil)
        #expect(ImportWording.doneCopy(exam) == "“Invented Sleep” · 1 exam question in NURS 101, Week 2. Exams now ask them instead of that folder’s practice questions.")
        let replaced = ImportModel.Done(set: try Self.set(kind: "replaced", folderName: "Week 2"), examPageName: nil)
        #expect(ImportWording.doneCopy(replaced) == "“Invented Sleep” · 3 questions in NURS 101, Week 2. The previous version can be restored from its folder.")
    }

    @Test func readyLine() throws {
        let report = try QBankJSON.decoder.decode(ImportReport.self, from: Data(Self.report(questions: 1, terms: 1).utf8))
        #expect(ImportWording.ready(report) == "Ready: 1 question, 1 term")
        let more = try QBankJSON.decoder.decode(ImportReport.self, from: Data(Self.report().utf8))
        #expect(ImportWording.ready(more) == "Ready: 3 questions, 2 terms")
    }

    // MARK: Helpers

    /// A model on course c1 with a checked, ready file.
    private static func ready() async throws -> (StubServer, ImportModel) {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "POST /api/imports/check": .ok(report()),
            "POST /api/imports": StubServer.Reply(status: 201, body: imported()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = ImportModel(app: app)
        await model.load()
        model.setSource(file)
        await model.check()
        try #require(model.canImport)
        return (server, model)
    }

    /// The body of the last import sent. An import is followed by reading the courses again, to
    /// save the new set for offline.
    private static func importBody(_ server: StubServer) throws -> [String: Any] {
        let request = server.requests.last { $0.httpMethod == "POST" && $0.url?.path() == "/api/imports" }
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func report(ok: Bool = true, questions: Int = 3, terms: Int = 2, errors: [String] = []) -> String {
        let list = errors.map { "\"\($0)\"" }.joined(separator: ",")
        let issues = errors.map { #"{"severity":"error","code":"invented_rule","question":null,"path":"","message":"\#($0)"}"# }.joined(separator: ",")
        return #"{"ok":\#(ok),"title":"Invented Sleep","description":"","kind":"practice","questionCount":\#(questions),"termCount":\#(terms),"formats":[{"type":"single","label":"Single answer","count":\#(questions)}],"errors":[\#(list)],"warnings":[],"issues":[\#(issues)]}"#
    }

    static func imported(kind: String = "imported", folder: String = "u1", folderName: String = "Unsorted", page: String? = nil) -> String {
        #"{"kind":"\#(kind)","setKind":"practice","setId":"new1","courseId":"c1","courseCode":"NURS 101","title":"Invented Sleep","weekLabel":"\#(folderName)","folderId":"\#(folder)","folderName":"\#(folderName)","examPageId":\#(page.map { "\"\($0)\"" } ?? "null"),"questionCount":3,"termCount":2,"warnings":[]}"#
    }

    static let conflict = #"{"conflict":true,"title":"Invented Sleep","courseId":"c1","courseCode":"NURS 101","courseTitle":"Invented Basics","weekLabel":"Week 1","folderId":"f1","folderName":"Week 1","existingQuestionCount":3,"incomingQuestionCount":4,"setId":"old1"}"#

    static func set(kind: String = "imported", setKind: String = "practice", folderName: String = "Unsorted", count: Int = 3) throws -> ImportedSet {
        let body = #"{"kind":"\#(kind)","setKind":"\#(setKind)","setId":"new1","courseId":"c1","courseCode":"NURS 101","title":"Invented Sleep","weekLabel":"\#(folderName)","folderId":"f9","folderName":"\#(folderName)","examPageId":null,"questionCount":\#(count),"termCount":2,"warnings":[]}"#
        return try QBankJSON.decoder.decode(ImportedSet.self, from: Data(body.utf8))
    }
}
