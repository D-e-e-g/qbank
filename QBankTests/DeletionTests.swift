import Foundation
import QBankKit
import Testing
@testable import QBank

/// Deleting a course or topic, an exam page, a set, a folder with its sets, and a past exam, Undo, and Recently
/// deleted, end to end against the fake server, which follows the server's rules and words; and the
/// confirm a delete sends and the refusals it shows, against a stub.
@MainActor
struct DeletionTests {
    static let communication = "communication-v1"
    static let communicationTitle = "Therapeutic Communication and the Relationship"

    /// The app signed in on the fake server as the student.
    static func app() -> AppModel {
        MakeQuestionsTests.app(maker: false)
    }

    /// The app signed in as the student, with an exam over Mental Health's Weeks 1-2 left going.
    static func app(examInProgress: Bool) -> AppModel {
        let defaults = TestApp.freshDefaults()
        return AppModel(
            client: QBankClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
                transport: FakeQBankServer(signedIn: true, examInProgress: examInProgress),
                sessionStore: InMemorySessionStore(FakeQBankServer.storedStudentSession())
            ),
            look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)),
            storage: .memory(),
            connection: Connection(isOnline: true)
        )
    }

    static func course(_ app: AppModel) async -> CourseModel {
        let course = CourseModel(app: app, id: FakeQBankServer.mentalHealthID)
        await course.load()
        return course
    }

    // MARK: A set

    @Test func aSetsWarningSaysWhatGoesInTheServersWords() async throws {
        let model = DeleteModel(app: Self.app(), target: .set(id: Self.communication, title: Self.communicationTitle))
        #expect(model.title == "Delete \(Self.communicationTitle)?", "before the warning arrives")
        #expect(!model.canDelete)
        await model.load()
        let warning = try #require(model.warning)
        #expect(warning.title == "Delete \(Self.communicationTitle)?")
        #expect(warning.message == "Its 14 questions go with it. You have answered 9 of them: those answers stop counting toward your progress, and 5 questions leave your Review list. You can undo this for 30 days.")
        #expect(warning.refusal == nil)
        #expect(model.canDelete)
    }

    @Test func aDeletedSetLeavesItsFolderAndUndoPutsItBackInItsPlace() async throws {
        let app = Self.app()
        let course = await Self.course(app)
        #expect(course.folder(FakeStudy.week2)?.sets.map(\.id) == [Self.communication, "psychosocial-v2"])
        #expect(course.course?.reviewCount == 12)
        let model = DeleteModel(app: app, target: .set(id: Self.communication, title: Self.communicationTitle))
        await model.load()
        #expect(await model.delete())
        let offer = try #require(app.deletions.offer)
        #expect(offer.line == "\(Self.communicationTitle) deleted.")
        #expect(offer.state == .offered)
        await course.load()
        #expect(course.folder(FakeStudy.week2)?.sets.map(\.id) == ["psychosocial-v2"])
        #expect(course.course?.reviewCount == 7, "its questions leave Review")

        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.state == .undone)
        #expect(app.deletions.offer?.back == "\(Self.communicationTitle) is back.")
        await course.load()
        #expect(course.folder(FakeStudy.week2)?.sets.map(\.id) == [Self.communication, "psychosocial-v2"], "in its place")
        #expect(course.course?.reviewCount == 12)
    }

    @Test func anExamSetIsListedInItsFolderAndDeletedOnItsOwn() async throws {
        let app = Self.app()
        let course = await Self.course(app)
        let week1 = try #require(course.folder(FakeStudy.week1))
        #expect(week1.examSets == [ExamSetSummary(id: "bank1", title: "Rights and Communication Exam", questionCount: 17)])
        let model = DeleteModel(app: app, target: .set(id: "bank1", title: "Rights and Communication Exam"))
        await model.load()
        #expect(model.warning?.title == "Delete Rights and Communication Exam from Week 1's exam bank?")
        #expect(model.warning?.message == "Its 17 questions go with it, and exams over Week 1 go back to asking its practice questions. You can undo this for 30 days.")
        #expect(await model.delete())
        await course.load()
        #expect(course.folder(FakeStudy.week1)?.examSets == [])
        #expect(course.folder(FakeStudy.week1)?.examBankCount == 0)
        #expect(course.folder(FakeStudy.week1)?.sets.map(\.id) == ["rights-v1"], "its practice set stays")
    }

    // MARK: A folder

    /// Deleting a folder with sets warns that its sets go too, naming each one.
    @Test func aFoldersWarningNamesEverySetThatGoesWithIt() async throws {
        let model = DeleteModel(app: Self.app(), target: .folder(id: FakeStudy.week2, name: "Week 2"))
        await model.load()
        let warning = try #require(model.warning)
        #expect(warning.title == "Delete Week 2?")
        #expect(warning.message == "Its 2 sets go with it: Psychosocial Assessment and Safety Screening and \(Self.communicationTitle), 26 questions in all. You have answered 9 of them: those answers stop counting toward your progress, and 5 questions leave your Review list. It comes off Exam 1. Your 2 past exams over it stay. You can undo this for 30 days.")
        #expect(warning.deleted == "Week 2 and its 2 sets deleted.")
        #expect(warning.back == "Week 2 and its 2 sets are back.")
    }

    @Test func aDeletedFolderTakesItsSetsAndUndoPutsItBackOnItsExamPage() async throws {
        let app = Self.app()
        let course = await Self.course(app)
        let model = DeleteModel(app: app, target: .folder(id: FakeStudy.week2, name: "Week 2"))
        await model.load()
        #expect(await model.delete())
        await course.load()
        #expect(course.folder(FakeStudy.week2) == nil)
        #expect(course.layout?.page(FakeStudy.exam1)?.folders.map(\.name) == ["Week 1"], "it comes off Exam 1")
        #expect(app.deletions.offer?.line == "Week 2 and its 2 sets deleted.")

        await app.deletions.undo(with: app)
        await course.load()
        #expect(course.layout?.page(FakeStudy.exam1)?.folders.map(\.name) == ["Week 1", "Week 2"])
        #expect(course.folder(FakeStudy.week2)?.sets.count == 2, "with its sets")
    }

    // MARK: An exam page

    /// Its warning names the folders that stay and her past exams over it, in the server's words.
    @Test func anExamPagesWarningSaysItsFoldersStay() async throws {
        let model = DeleteModel(app: Self.app(), target: .examPage(id: FakeStudy.exam1, name: "Exam 1"))
        #expect(model.title == "Delete Exam 1?", "before the warning arrives")
        await model.load()
        let warning = try #require(model.warning)
        #expect(warning.title == "Delete Exam 1?")
        #expect(warning.message == "Its 2 folders stay, with their sets and your progress, under Folders: Week 1 and Week 2. Your 2 past exams over it stay. You can undo this for 30 days.")
        #expect(warning.refusal == nil)
        #expect(warning.deleted == "Exam 1 deleted.")
        #expect(warning.back == "Exam 1 is back.")
        #expect(model.canDelete)
    }

    /// The page alone goes: its folders stay in the course, at the end of its Folders list with their
    /// sets and her progress, and her past exams stay in Exam setup. Undo puts them back on it.
    @Test func aDeletedExamPageLeavesItsFoldersInTheCourseAndUndoPutsThemBack() async throws {
        let app = Self.app()
        let course = await Self.course(app)
        let answered = course.course?.answeredCount
        let ref = CourseRef(id: FakeQBankServer.mentalHealthID, code: "NURS 310", title: "Mental Health")
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: ref))
        await setup.load()
        let pastExams = setup.setup?.exams.map(\.id)
        let model = DeleteModel(app: app, target: .examPage(id: FakeStudy.exam1, name: "Exam 1"))
        await model.load()
        #expect(await model.delete())
        #expect(app.deletions.offer?.line == "Exam 1 deleted.")
        await course.load()
        #expect(course.layout?.page(FakeStudy.exam1) == nil)
        #expect(course.course?.exams.map(\.name) == ["Exam 2"])
        #expect(course.course?.folders.filter { $0.examPageID == nil }.map(\.name) == ["Weeks 1-3", "Week 1", "Week 2"], "at the end of Folders, in the page's order")
        #expect(course.folder(FakeStudy.week2)?.sets.map(\.id) == [Self.communication, "psychosocial-v2"], "with their sets")
        #expect(course.course?.answeredCount == answered, "and her progress")
        await setup.load()
        #expect(setup.setup?.exams.map(\.id) == pastExams, "her past exams stay")

        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.state == .undone)
        #expect(app.deletions.offer?.back == "Exam 1 is back.")
        await course.load()
        #expect(course.layout?.page(FakeStudy.exam1)?.folders.map(\.name) == ["Week 1", "Week 2"], "back on it, in its order")
        #expect(course.course?.folders.filter { $0.examPageID == nil }.map(\.name) == ["Weeks 1-3"])
    }

    /// One of its folders has the name of a folder in the Folders list, where it would show.
    @Test func anExamPageWhoseFolderNameIsInTheFoldersListWaits() async throws {
        let app = Self.app()
        try await app.client.createFolder(courseID: FakeQBankServer.mentalHealthID, name: "Week 2")
        let model = DeleteModel(app: app, target: .examPage(id: FakeStudy.exam1, name: "Exam 1"))
        await model.load()
        #expect(model.warning?.refusal == "NURS 310 already has a folder named Week 2 in its Folders list. Rename one of them before deleting Exam 1.")
        #expect(!model.canDelete)
        #expect(await model.delete() == false)
        let course = await Self.course(app)
        #expect(course.layout?.page(FakeStudy.exam1)?.folders.count == 2, "nothing was deleted")
    }

    /// Its folders changed since she was warned: nothing is deleted, and the new warning names them.
    @Test func anExamPageThatChangedSinceTheWarningIsReadAgain() async throws {
        let app = Self.app()
        let model = DeleteModel(app: app, target: .examPage(id: FakeStudy.exam2, name: "Exam 2"))
        await model.load()
        #expect(model.warning?.message == "Its folder Week 3 stays, with its sets and your progress, under Folders. You can undo this for 30 days.")
        _ = try await app.client.updateCourseExam(id: FakeStudy.exam2, name: "Exam 2", folderIDs: [FakeStudy.week3, FakeStudy.weeks1to3])
        #expect(await model.delete() == false)
        #expect(model.problem == "Exam 2 changed since you were warned. Look again before deleting it.")
        #expect(model.warning?.message == "Its 2 folders stay, with their sets and your progress, under Folders: Week 3 and Weeks 1-3. You can undo this for 30 days.")
        #expect(await model.delete())
    }

    // MARK: A past exam

    @Test func aPastExamIsDeletedFromExamSetupAndUndoListsItAgain() async throws {
        let app = Self.app()
        let ref = CourseRef(id: FakeQBankServer.mentalHealthID, code: "NURS 310", title: "Mental Health")
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: ref))
        await setup.load()
        let exams = try #require(setup.setup?.exams)
        #expect(exams.count == 3)
        let newest = try #require(exams.first)
        let model = DeleteModel(app: app, target: .exam(id: newest.id))
        await model.load()
        #expect(model.warning?.title == "Delete this exam?")
        #expect(model.warning?.message.hasPrefix("Your ") == true)
        #expect(model.warning?.message.hasSuffix("You can undo this for 30 days.") == true)
        #expect(await model.delete())
        #expect(app.deletions.offer?.line == "Exam deleted.")
        await setup.load()
        #expect(setup.setup?.exams.map(\.id) == exams.dropFirst().map(\.id))

        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.back == "The exam is back.")
        await setup.load()
        #expect(setup.setup?.exams.map(\.id) == exams.map(\.id))
    }

    // MARK: Refusals

    /// An exam in progress asks the folder's questions: the warning says so, and Delete waits.
    @Test func aDeleteTheServerRefusesForNowSaysWhyAndWaits() async throws {
        let app = Self.app()
        _ = try await app.client.startExam(courseID: FakeQBankServer.mentalHealthID, folderIDs: [FakeStudy.week2])
        let model = DeleteModel(app: app, target: .folder(id: FakeStudy.week2, name: "Week 2"))
        await model.load()
        #expect(model.warning?.refusal == "An exam in progress asks questions from Week 2. Finish or leave that exam first.")
        #expect(!model.canDelete)
        #expect(await model.delete() == false)
        #expect(app.deletions.offer == nil)
        let course = await Self.course(app)
        #expect(course.folder(FakeStudy.week2) != nil, "nothing was deleted")
    }

    @Test func anExamStillGoingCannotBeDeleted() async throws {
        let app = Self.app()
        let running = try await app.client.startExam(courseID: FakeQBankServer.mentalHealthID, folderIDs: [FakeStudy.week1])
        let model = DeleteModel(app: app, target: .exam(id: running.id))
        await model.load()
        #expect(model.warning?.refusal == "This exam is still going. Finish or leave it, then delete it.")
        #expect(!model.canDelete)
    }

    /// What goes changed since she was warned: nothing is deleted, she reads why and the new
    /// warning, and Delete sends the new confirm.
    @Test func aWarningThatChangedIsReadAgainBeforeAnythingGoes() async throws {
        let server = StubServer()
        let preview = { (confirm: String, sets: String) in
            StubServer.Reply.ok(#"{"folderId":"f1","name":"Week 1","examPageId":null,"examPageName":null,"sets":[],"setCount":\#(sets.isEmpty ? 0 : 1),"questionCount":2,"answeredCount":0,"reviewCount":0,"pastExamCount":0,"progress":\#(Self.standing),"message":"Delete Week 1? \#(sets)You can undo this for 30 days.","refusal":null,"confirm":"\#(confirm)","undoDays":30}"#)
        }
        server.script("GET /api/folders/f1/delete-preview", [preview("aaaa", ""), preview("bbbb", "Its set goes with it: Late, 2 questions in all. ")])
        server.script("DELETE /api/folders/f1", [
            .error(409, "deletion_changed", "Week 1 changed since you were warned. Look again before deleting it."),
            StubServer.Reply(status: 204, body: ""),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = DeleteModel(app: app, target: .folder(id: "f1", name: "Week 1"))
        await model.load()
        #expect(model.warning?.message == "You can undo this for 30 days.")
        #expect(await model.delete() == false)
        #expect(model.problem == "Week 1 changed since you were warned. Look again before deleting it.")
        #expect(model.warning?.message == "Its set goes with it: Late, 2 questions in all. You can undo this for 30 days.")
        #expect(model.warning?.confirm == "bbbb")
        #expect(app.deletions.offer == nil)
        #expect(await model.delete())
        #expect(model.problem == nil)
        let confirms = server.requests.filter { $0.httpMethod == "DELETE" }.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(confirms == [[URLQueryItem(name: "confirm", value: "aaaa")], [URLQueryItem(name: "confirm", value: "bbbb")]])
        #expect(app.deletions.offer?.line == "Week 1 and its set deleted.")
    }

    /// The folder preview a stub server sends, with `warning` when it is given one.
    private static func folderPreview(name: String, message: String, warning: (title: String, body: String)?) -> StubServer.Reply {
        let warning = warning.map { #","warning":{"title":"\#($0.title)","body":"\#($0.body)"}"# } ?? ""
        return .ok(#"{"folderId":"f1","name":"\#(name)","examPageId":null,"examPageName":null,"sets":[],"setCount":0,"questionCount":0,"answeredCount":0,"reviewCount":0,"pastExamCount":0,"progress":\#(Self.standing),"message":"\#(message)"\#(warning),"refusal":null,"confirm":"aaaa","undoDays":30}"#)
    }

    /// The server splits its warning into the question and the rest: the confirmation shows them
    /// as sent, even where splitting `message` at its first question would stop inside the name.
    @Test func theServersWarningIsShownAsItSplitIt() async throws {
        let server = StubServer(["GET /api/folders/f1/delete-preview": Self.folderPreview(
            name: "Why? Because",
            message: "Delete Why? Because? It has no sets. You can undo this for 30 days.",
            warning: ("Delete Why? Because?", "It has no sets. You can undo this for 30 days.")
        )])
        let (app, _) = TestApp.make(server, account: .student())
        let model = DeleteModel(app: app, target: .folder(id: "f1", name: "Why? Because"))
        await model.load()
        #expect(model.title == "Delete Why? Because?")
        #expect(model.warning?.message == "It has no sets. You can undo this for 30 days.")
    }

    /// A server from before `warning` sends only `message`: the confirmation splits it at its
    /// question, and shows it whole under the target's question when it has none.
    @Test func aWarningWithoutItsPartsIsSplitAtItsQuestion() async throws {
        let server = StubServer()
        server.script("GET /api/folders/f1/delete-preview", [
            Self.folderPreview(name: "Week 1", message: "Delete Week 1? It has no sets. You can undo this for 30 days.", warning: nil),
            Self.folderPreview(name: "Week 1", message: "It has no sets.", warning: nil),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = DeleteModel(app: app, target: .folder(id: "f1", name: "Week 1"))
        await model.load()
        #expect(model.title == "Delete Week 1?")
        #expect(model.warning?.message == "It has no sets. You can undo this for 30 days.")
        await model.load()
        #expect(model.title == "Delete Week 1?")
        #expect(model.warning?.message == "It has no sets.")
    }

    @Test func undoThatComesTooLateSaysSoInTheServersWords() async throws {
        let server = StubServer(["POST /api/practice-sets/s1/undo-delete": .error(409, "undo_expired", "Heart A was deleted more than 30 days ago, so it can't be brought back.")])
        let (app, _) = TestApp.make(server, account: .student())
        app.deletions.deleted(.set(id: "s1", title: "Heart A"), line: "Heart A deleted.", back: "Heart A is back.")
        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.state == .failed("Heart A was deleted more than 30 days ago, so it can't be brought back."))
    }

    // MARK: Recently deleted

    @Test func recentlyDeletedListsWhatWentAndBringsItBack() async throws {
        let app = Self.app()
        let deleteSet = DeleteModel(app: app, target: .set(id: "mixed-v1", title: "Mixed Clinical Judgment"))
        await deleteSet.load()
        #expect(await deleteSet.delete())
        let deleteFolder = DeleteModel(app: app, target: .folder(id: FakeStudy.week3, name: "Week 3"))
        await deleteFolder.load()
        #expect(await deleteFolder.delete())

        let list = RecentlyDeletedModel(app: app, courseID: FakeQBankServer.mentalHealthID)
        await list.load()
        let deleted = try #require(list.deleted)
        #expect(deleted.folders.map(\.name) == ["Week 3"])
        #expect(deleted.folders.first.map(RecentlyDeletedWording.sets) == "Anxiety, Panic, and Anxiolytics, Depression and Antidepressants and Depression and Anxiety Exam")
        #expect(deleted.sets.map(\.title) == ["Mixed Clinical Judgment"])
        #expect(deleted.sets.first.map(RecentlyDeletedWording.set) == "Weeks 1-3 · 8 questions")
        #expect(deleted.exams.isEmpty)
        let folder = try #require(deleted.folders.first)
        #expect(RecentlyDeletedWording.window(deletedAt: folder.deletedAt, undoUntil: folder.undoUntil, now: folder.deletedAt).hasPrefix("Deleted today · until "))

        let revision = app.deletions.revision
        await list.bringBack(.folder(id: folder.id, name: folder.name), saying: "Week 3 and its 3 sets are back.")
        #expect(list.back == "Week 3 and its 3 sets are back.")
        #expect(list.problem == nil)
        #expect(app.deletions.revision == revision + 1, "the course reads itself again")
        #expect(list.deleted?.folders.isEmpty == true)
        #expect(list.deleted?.sets.map(\.title) == ["Mixed Clinical Judgment"])
        let course = await Self.course(app)
        #expect(course.layout?.page(FakeStudy.exam2)?.folders.map(\.name) == ["Week 3"], "back on Exam 2")
    }

    @Test func recentlyDeletedListsAnExamPageFirstAndBringsItBackWithItsFolders() async throws {
        let app = Self.app()
        let deleteFolder = DeleteModel(app: app, target: .folder(id: FakeStudy.weeks1to3, name: "Weeks 1-3"))
        await deleteFolder.load()
        #expect(await deleteFolder.delete())
        let deletePage = DeleteModel(app: app, target: .examPage(id: FakeStudy.exam1, name: "Exam 1"))
        await deletePage.load()
        #expect(await deletePage.delete())

        let list = RecentlyDeletedModel(app: app, courseID: FakeQBankServer.mentalHealthID)
        await list.load()
        let deleted = try #require(list.deleted)
        #expect(deleted.examPages.map(\.name) == ["Exam 1"])
        #expect(deleted.folders.map(\.name) == ["Weeks 1-3"])
        let page = try #require(deleted.examPages.first)
        #expect(RecentlyDeletedWording.folders(page) == "Week 1, Week 2")
        #expect(page.pastExamCount == 2)
        #expect(page.undoRefusal == nil)

        await list.bringBack(.examPage(id: page.id, name: page.name), saying: DeleteWording.back(.examPage(id: page.id, name: page.name)))
        #expect(list.back == "Exam 1 is back.")
        #expect(list.problem == nil)
        #expect(list.deleted?.examPages.isEmpty == true)
        let course = await Self.course(app)
        #expect(course.layout?.page(FakeStudy.exam1)?.folders.map(\.name) == ["Week 1", "Week 2"], "back on Exam 1")
    }

    /// Another page has its name now: the row says so, and Bring back is refused in the same words.
    @Test func anExamPageWhoseNameIsTakenSinceWaitsInRecentlyDeleted() async throws {
        let app = Self.app()
        let model = DeleteModel(app: app, target: .examPage(id: FakeStudy.exam2, name: "Exam 2"))
        await model.load()
        #expect(await model.delete())
        _ = try await app.client.createCourseExam(courseID: FakeQBankServer.mentalHealthID, name: "Exam 2", folderIDs: [])
        let list = RecentlyDeletedModel(app: app, courseID: FakeQBankServer.mentalHealthID)
        await list.load()
        let taken = "This course already has an exam named Exam 2. Rename one of them, then bring this one back."
        #expect(list.deleted?.examPages.first?.undoRefusal == taken)
        await list.bringBack(.examPage(id: FakeStudy.exam2, name: "Exam 2"), saying: "Exam 2 is back.")
        #expect(list.problem == taken)
    }

    /// The preview and the delete are at the page's own address, and the delete sends the preview's confirm.
    @Test func anExamPageIsDeletedWithItsPreviewsConfirm() async throws {
        let server = StubServer([
            "GET /api/course-exams/p1/delete-preview": .ok(#"{"examPageId":"p1","courseId":"c1","name":"Exam 2","folders":[{"id":"f1","name":"Week 3","setCount":1,"questionCount":2}],"folderCount":1,"setCount":1,"questionCount":2,"examQuestionCount":0,"answeredCount":0,"pastExamCount":0,"progress":\#(Self.standing),"message":"Delete Exam 2? Its folder Week 3 stays, with its sets and your progress, under Folders. You can undo this for 30 days.","refusal":null,"confirm":"page-token","undoDays":30}"#),
            "DELETE /api/course-exams/p1": StubServer.Reply(status: 204, body: ""),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = DeleteModel(app: app, target: .examPage(id: "p1", name: "Exam 2"))
        await model.load()
        #expect(model.warning?.message == "Its folder Week 3 stays, with its sets and your progress, under Folders. You can undo this for 30 days.")
        #expect(await model.delete())
        #expect(server.calls == ["GET /api/course-exams/p1/delete-preview", "DELETE /api/course-exams/p1"])
        let confirm = server.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(confirm == [URLQueryItem(name: "confirm", value: "page-token")])
        #expect(app.deletions.offer?.line == "Exam 2 deleted.")
    }

    @Test func undoOfAnExamPageTooLateSaysSoInTheServersWords() async throws {
        let server = StubServer(["POST /api/course-exams/p1/undo-delete": .error(409, "undo_expired", "Exam 2 was deleted more than 30 days ago, so it can't be brought back.")])
        let (app, _) = TestApp.make(server, account: .student())
        app.deletions.deleted(.examPage(id: "p1", name: "Exam 2"), line: "Exam 2 deleted.", back: "Exam 2 is back.")
        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.state == .failed("Exam 2 was deleted more than 30 days ago, so it can't be brought back."))
    }

    @Test func aSetWhoseFolderIsDeletedWaitsForTheFolder() async throws {
        let app = Self.app()
        let deleteSet = DeleteModel(app: app, target: .set(id: "depression-v1", title: "Depression and Antidepressants"))
        await deleteSet.load()
        #expect(await deleteSet.delete())
        let deleteFolder = DeleteModel(app: app, target: .folder(id: FakeStudy.week3, name: "Week 3"))
        await deleteFolder.load()
        #expect(deleteFolder.warning?.message.contains("Depression and Antidepressants") == false, "a set deleted before is not named again")
        #expect(await deleteFolder.delete())
        let list = RecentlyDeletedModel(app: app, courseID: FakeQBankServer.mentalHealthID)
        await list.load()
        #expect(list.deleted?.sets.first?.undoRefusal == "Its folder Week 3 is deleted. Bring the folder back first.")
    }

    // MARK: A course or topic

    @Test func aCoursesWarningAsksOnceInTheServersWords() async throws {
        let model = DeleteModel(app: Self.app(), target: .course(id: FakeQBankServer.fundamentalsID, name: "NURS 220"))
        #expect(model.title == "Delete NURS 220?", "before the warning arrives")
        await model.load()
        let warning = try #require(model.warning)
        #expect(warning.title == "Delete NURS 220 and its 146 questions?")
        #expect(warning.message == "You can bring it back for 30 days.")
        #expect(warning.refusal == nil)
        #expect(warning.deleted == "NURS 220 deleted.")
        #expect(warning.back == "NURS 220 is back.")
        #expect(model.canDelete)
    }

    @Test func aDeletedCourseLeavesHomeAndRecentlyDeletedBringsItBackWhole() async throws {
        let app = Self.app()
        let home = HomeModel(app: app)
        await home.load()
        #expect(home.recentlyDeleted?.courses.isEmpty == true)
        let model = DeleteModel(app: app, target: .course(id: FakeQBankServer.fundamentalsID, name: "NURS 220"))
        await model.load()
        #expect(await model.delete())
        #expect(app.deletions.offer?.line == "NURS 220 deleted.")
        await home.load()
        let semester1 = try #require(home.studiedSemesters.first)
        #expect(home.courses(in: semester1).map(\.code) == ["NURS 310"])
        #expect(home.recentlyDeleted?.courses.map(\.code) == ["NURS 220"])

        let list = DeletedCoursesModel(app: app)
        await list.load()
        let deleted = try #require(list.courses.first)
        #expect(list.topics.isEmpty)
        #expect(DeletedCoursesWording.held(deleted) == ["Fundamentals", "From Semester 1", "146 questions"])
        #expect(deleted.undoRefusal == nil)
        let revision = app.deletions.revision
        await list.bringBack(deleted)
        #expect(list.back == "NURS 220 is back.")
        #expect(list.problem == nil)
        #expect(list.deleted?.courses.isEmpty == true)
        #expect(app.deletions.revision > revision, "Home reads its courses again")
        await home.load()
        let back = try #require(home.studiedSemesters.first)
        #expect(home.courses(in: back).map(\.code) == ["NURS 310", "NURS 220"])
        #expect(home.courses(in: back).last?.questionCount == 146, "with everything in it")
    }

    @Test func undoOnTheBarBringsACourseBack() async throws {
        let app = Self.app()
        let model = DeleteModel(app: app, target: .course(id: FakeQBankServer.fundamentalsID, name: "NURS 220"))
        await model.load()
        #expect(await model.delete())
        await app.deletions.undo(with: app)
        #expect(app.deletions.offer?.state == .undone)
        #expect(app.deletions.offer?.back == "NURS 220 is back.")
        let catalog = try await app.client.catalog()
        #expect(catalog.course(id: FakeQBankServer.fundamentalsID) != nil)
    }

    @Test func aCourseWithAnExamGoingCannotBeDeletedYet() async throws {
        let app = Self.app(examInProgress: true)
        let model = DeleteModel(app: app, target: .course(id: FakeQBankServer.mentalHealthID, name: "NURS 310"))
        await model.load()
        #expect(model.warning?.refusal == "An exam in NURS 310 is still going. Finish or leave that exam first.")
        #expect(!model.canDelete)
        #expect(await model.delete() == false)
        #expect(try await app.client.catalog().course(id: FakeQBankServer.mentalHealthID) != nil)
    }

    @Test func aCourseWithASetBeingMadeCannotBeDeletedYet() async throws {
        let app = MakeQuestionsTests.app(maker: true)
        let model = DeleteModel(app: app, target: .course(id: FakeQBankServer.mentalHealthID, name: "NURS 310"))
        await model.load()
        #expect(model.warning?.refusal == "QBank is still making a set in NURS 310. Wait until it is filed, or cancel it, first.")
        #expect(!model.canDelete)
    }

    @Test func aCodeTakenSinceKeepsItInRecentlyDeletedAndSaysWhy() async throws {
        let app = Self.app()
        let model = DeleteModel(app: app, target: .course(id: FakeQBankServer.fundamentalsID, name: "NURS 220"))
        await model.load()
        #expect(await model.delete())
        _ = try await app.client.addCourse(semesterID: FakeQBankServer.semester1ID, code: "NURS 220", title: "Fundamentals again")
        let list = DeletedCoursesModel(app: app)
        await list.load()
        let deleted = try #require(list.courses.first)
        let taken = "Semester 1 already has a course with the code NURS 220. Rename one of them, then bring this one back."
        #expect(deleted.undoRefusal == taken)
        await list.bringBack(deleted)
        #expect(list.problem == taken, "the server refuses it in the same words")
        #expect(list.courses.map(\.id) == [FakeQBankServer.fundamentalsID])
    }

    @Test func aTopicIsDeletedAndListedUnderStudyTopics() async throws {
        let app = Self.app()
        let topic = try await app.client.createTopic(title: "Pharmacology")
        let model = DeleteModel(app: app, target: .course(id: topic.id, name: "Pharmacology"))
        await model.load()
        #expect(model.warning?.title == "Delete Pharmacology?")
        #expect(model.warning?.message == "You can bring it back for 30 days.")
        #expect(await model.delete())
        #expect(try await app.client.catalog().topics.isEmpty)
        let list = DeletedCoursesModel(app: app)
        await list.load()
        #expect(list.courses.isEmpty)
        let deleted = try #require(list.topics.first)
        #expect(DeletedCoursesWording.held(deleted) == ["0 questions"])
        _ = try await app.client.createTopic(title: "pharmacology")
        await list.load()
        #expect(list.topics.first?.undoRefusal == "You already have a topic named pharmacology. Rename one of them, then bring this one back.")
    }

    // MARK: Words

    @Test func homesRecentlyDeletedRowCountsWhatCanComeBack() {
        #expect(DeletedCoursesWording.entry(count: 1, undoDays: 30) == "1 item · Bring back for 30 days")
        #expect(DeletedCoursesWording.entry(count: 2, undoDays: 30) == "2 items · Bring back for 30 days")
    }

    @Test func theWarningSplitsAtItsQuestion() {
        let split = DeleteWording.split("Delete Week 1? Its 3 sets go with it: A, B and C, 10 questions in all. You can undo this for 30 days.")
        #expect(split?.title == "Delete Week 1?")
        #expect(split?.message == "Its 3 sets go with it: A, B and C, 10 questions in all. You can undo this for 30 days.")
        #expect(DeleteWording.split("No question here.") == nil)
        #expect(DeleteWording.deleted(.folder(id: "f", name: "Week 1")) == "Week 1 deleted.")
        #expect(DeleteWording.deleted(.folder(id: "f", name: "Week 1"), setCount: 1) == "Week 1 and its set deleted.")
        #expect(DeleteWording.back(.folder(id: "f", name: "Week 1")) == "Week 1 is back.")
        #expect(DeleteWording.question(.exam(id: "e")) == "Delete this exam?")
    }

    private static let standing = #"{"answeredCount":{"before":0,"after":0},"fullyRightCount":{"before":0,"after":0},"reviewCount":{"before":0,"after":0},"points":{"before":0,"after":0},"maxPoints":{"before":0,"after":0},"wrongCount":{"before":0,"after":0}}"#
}
