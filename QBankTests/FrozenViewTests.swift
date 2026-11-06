import Foundation
import QBankKit
import Testing
@testable import QBank

/// The admin's look at a user account: one note, one account named, and nothing sent.
@MainActor
@Suite("Frozen view")
struct FrozenViewTests {
    private static let students = #"{"students":[{"id":"u1","email":"sam@example.com","name":"Sam","createdAt":"2026-01-05T12:00:00.000Z"},{"id":"u2","email":"robin@example.com","name":"Robin","createdAt":"2026-02-09T12:00:00.000Z"}],"viewingId":"u2"}"#

    @Test func theNoteAndTheLineNameTheAccountChosenOnTheWeb() async {
        let server = StubServer(["GET /api/admin/students": .ok(Self.students)])
        let (app, _) = TestApp.make(server, account: .admin)
        #expect(app.frozen.note == "This is a frozen view of a user account. Nothing here can be changed.", "until QBank says whose")
        #expect(app.frozen.line == nil)
        await app.frozen.readAccount(with: app.client)
        #expect(app.frozen.note == "This is a frozen view of robin@example.com. Nothing here can be changed.")
        #expect(app.frozen.line == "Frozen view of robin@example.com")
    }

    @Test func aFailedReadKeepsTheNameItHad() async {
        let server = StubServer(["GET /api/admin/students": .ok(Self.students)])
        let (app, _) = TestApp.make(server, account: .admin)
        await app.frozen.readAccount(with: app.client)
        server["GET /api/admin/students"] = .offline
        await app.frozen.readAccount(with: app.client)
        #expect(app.frozen.line == "Frozen view of robin@example.com")
    }

    @Test func aUserAccountsControlsJustDoWhatTheySay() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student())
        var ran = false
        app.frozen.perform { ran = true }
        #expect(ran)
        #expect(app.frozen.noteID == nil)
        await app.frozen.readAccount(with: app.client)
        #expect(server.requests.isEmpty, "a user account never asks for the accounts list")
        #expect(app.frozen.line == nil)
    }

    @Test func theAdminsControlsAnswerWithTheNoteInstead() {
        let (app, _) = TestApp.make(StubServer(), account: .admin)
        var ran = false
        app.frozen.perform { ran = true }
        #expect(!ran)
        let first = app.frozen.noteID
        #expect(first != nil)
        app.frozen.perform { ran = true }
        #expect(app.frozen.noteID != first, "a second tap shows it for its full time again")
    }

    /// The server's backstop: if a write still went, its refusal reads as the note, not an error.
    @Test(arguments: [ServerError.Code.adminReadOnly, .adminCannotRecordAnswer, .adminCannotDeleteExam])
    func aRefusalThatStillArrivesShowsTheSameNote(code: ServerError.Code) {
        let (app, _) = TestApp.make(StubServer(), account: .admin)
        #expect(app.handle(.server(ServerError(status: 403, code: code, message: "The server's own words."))))
        #expect(app.frozen.noteID != nil)
    }

    @Test func aUserAccountNeverReadsARefusalAsTheNote() {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        #expect(!app.handle(.server(ServerError(status: 403, code: .adminReadOnly, message: ""))))
        #expect(app.frozen.noteID == nil)
    }

    @Test func courseEditsSendNothing() async throws {
        let server = StubServer(["GET /api/courses/c1": .ok(StudyBodies.course())])
        let (app, _) = TestApp.make(server, account: .admin)
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        #expect(model.offersEditing, "the controls look as the user's do")
        #expect(!model.canEdit, "and an edit may not go")
        let folder = try #require(model.course?.folders.first)
        let before = server.calls
        #expect(await model.rename(folder, to: "Renamed") == nil)
        #expect(await model.makeFolder(named: "New", on: nil) == nil)
        #expect(await model.saveOrder(page: nil, folderIDs: []) == nil)
        #expect(server.calls == before, "and no read follows, because nothing changed")
        #expect(app.frozen.noteID != nil)
    }

    @Test func homeEditsSendNothing() async {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters()), "GET /api/admin/students": .ok(Self.students)])
        let (app, _) = TestApp.make(server, account: .admin)
        let model = HomeModel(app: app)
        await model.load()
        #expect(app.frozen.line == "Frozen view of robin@example.com", "Home reads whose courses these are with them")
        await model.addSemester()
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
    }

    @Test func aFrozenImportChecksAndFilesNothing() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .admin)
        let model = ImportModel(app: app)
        model.setSource(#"{"title":"Invented"}"#)
        await model.check()
        await model.commit()
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
        #expect(app.frozen.noteID != nil)
    }

    @Test func aFrozenBringBackSendsNothing() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .admin)
        await RecentlyDeletedModel(app: app, courseID: "c1").bringBack(.exam(id: "e1"), saying: "Back.")
        #expect(server.requests.isEmpty)
        #expect(app.frozen.noteID != nil)
    }

    @Test func theAddTabSaysTheNoteWhereTheServerWouldSayWhy() async {
        let (app, _) = TestApp.make(StubServer(), account: .admin)
        #expect(AddModel(app: app).makeNote == app.frozen.note)
    }
}
