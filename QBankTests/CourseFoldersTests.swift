import Foundation
import QBankKit
import Testing
@testable import QBank

/// The course page's two lists, exam pages and folders: the web's folder rules
/// (`apps/web/src/course/folders.test.ts`), the server's rule for which page a past exam belongs to,
/// and her edits: rename, exam page, move, and order.
@MainActor
struct CourseFoldersTests {
    private func folder(_ name: String, _ sets: [(questions: Int, answered: Int, right: Int)], bank: Int = 0, page: String? = nil) throws -> Folder {
        let json = StudyBodies.folder(
            "id-\(name)", name, page: page, order: 1,
            sets: sets.enumerated().map { StudyBodies.set("\(name)-\($0.offset)", questions: $0.element.questions, answered: $0.element.answered, right: $0.element.right) },
            bank: bank
        )
        return try QBankJSON.decoder.decode(Folder.self, from: Data(json.utf8))
    }

    private func course(pages: [StudyBodies.Page] = [], badges: [String: String?] = [:]) throws -> CourseDetail {
        try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.course(pages: pages, badges: badges).utf8))
    }

    private func summary(_ json: String) throws -> ExamSummary {
        try QBankJSON.decoder.decode(ExamSummary.self, from: Data(json.utf8))
    }

    // MARK: Folders

    @Test func progressAddsUpTheSetsAndNamesTheState() throws {
        let fresh = FolderProgress(try folder("Week 1", [(14, 0, 0), (12, 0, 0)]))
        #expect(fresh == FolderProgress(try folder("Week 9", [(14, 0, 0), (12, 0, 0)])))
        #expect(fresh.state == .fresh)
        #expect(fresh.setCount == 2)
        #expect(fresh.questionCount == 26)
        #expect(FolderProgress(try folder("Week 3", [(15, 15, 12), (12, 7, 5)])).state == .started)
        #expect(FolderProgress(try folder("Week 1", [(14, 14, 12), (13, 13, 10)])).state == .done)
        let over = FolderProgress(try folder("Week 1", [(3, 5, 4)]))
        #expect(over.state == .done)
        #expect(over.answeredCount == 3)
        #expect(over.fullyRightCount == 3, "never past a set's size")
    }

    @Test func folderLinesMatchTheWeb() throws {
        let fresh = try folder("Week 4", [(14, 0, 0), (12, 0, 0)])
        #expect(FolderWording.meta(fresh) == "2 sets · 26 questions")
        #expect(FolderWording.state(FolderProgress(fresh)) == "Not started")
        let started = try folder("Week 3", [(15, 15, 12), (12, 7, 5)])
        #expect(FolderWording.meta(started) == "2 sets · 22 of 27 answered")
        #expect(FolderWording.state(FolderProgress(started)) == "22 of 27")
        let done = try folder("Week 1", [(14, 14, 12)])
        #expect(FolderWording.meta(done) == "1 set · 12 of 14 fully right")
        #expect(FolderWording.state(FolderProgress(done)) == "Done")
        let bankOnly = try folder("Week 8", [], bank: 1)
        #expect(FolderWording.meta(bankOnly) == "Exam twins only · 1 question")
        #expect(FolderWording.state(FolderProgress(bankOnly)) == "")
        #expect(FolderWording.meta(try folder("Unsorted", [])) == "Empty folder")
        #expect(FolderWording.examBank(try folder("Week 3", [(1, 0, 0)], bank: 27)) == "Exam twins: 27 questions, exams only")
        #expect(FolderWording.examBank(done) == "No exam bank yet · exams use practice questions")
    }

    // MARK: The course page

    @Test func dayOneHasNoExamPagesAndEveryFolderInHerOrder() throws {
        let layout = CourseLayout(course: try course(), sittings: [])
        #expect(layout.pages.isEmpty)
        #expect(layout.looseFolders.map(\.name) == ["Week 1", "Week 2", "Week 3"])
    }

    @Test func eachExamPageHoldsOnlyItsOwnFoldersInHerOrder() throws {
        let course = try course(pages: [("x2", "Exam 2", ["f3"]), ("x1", "Exam 1", ["f2", "f1"])])
        let layout = CourseLayout(course: course, sittings: [])
        #expect(layout.pages.map(\.exam.name) == ["Exam 2", "Exam 1"], "in the order she made them")
        let exam1 = try #require(layout.page("x1"))
        #expect(exam1.folders.map(\.name) == ["Week 2", "Week 1"], "her order, not the name's")
        #expect(exam1.progress.questionCount == 20)
        #expect(exam1.progress.answeredCount == 12)
        #expect(FolderWording.pageRow(exam1) == "2 folders · 20 questions")
        #expect(FolderWording.pageNote(exam1) == "2 folders · 3 practice sets · 20 questions")
        #expect(FolderWording.examTwins(exam1) == nil, "Week 1 and Week 2 have no exam twins")
        #expect(FolderWording.state(exam1.progress) == "12 of 20")
        #expect(layout.looseFolders.isEmpty, "a folder on a page is listed only there")
    }

    @Test func aFolderOnAPageThatIsGoneIsListedUnderFolders() throws {
        let json = StudyBodies.course().replacingOccurrences(of: #""id":"f2","name":"Week 2","examPageId":null"#, with: #""id":"f2","name":"Week 2","examPageId":"gone""#)
        let layout = CourseLayout(course: try QBankJSON.decoder.decode(CourseDetail.self, from: Data(json.utf8)), sittings: [])
        #expect(layout.looseFolders.map(\.id) == ["f1", "f2", "f3"])
    }

    @Test func anEmptyPageSaysSoAndOffersNoExam() throws {
        let page = try #require(CourseLayout(course: try course(pages: [("x1", "Exam 1", [])]), sittings: []).page("x1"))
        #expect(FolderWording.pageRow(page) == "No folders yet")
        #expect(FolderWording.pageNote(page) == "No folders yet")
        #expect(page.examQuestionCount == 0, "so it offers no Start exam")
        #expect(FolderWording.examDraw(try plan([])) == nil)
    }

    private func plan(_ folders: [StudyBodies.Draw], questions: Int? = nil, seconds: Int = 0) throws -> ExamPreview {
        try QBankJSON.decoder.decode(ExamPreview.self, from: Data(StudyBodies.preview(folders, questions: questions, seconds: seconds).utf8))
    }

    @Test func examDrawSaysHowManyComeFromTheFolders() throws {
        let two = try plan([("f2", "Week 2", 10, 10, "practice"), ("f3", "Week 3", 20, 20, "exam")])
        #expect(FolderWording.examDraw(two) == "All 30 questions in these 2 folders, or Wrong questions only.")
        let one = try plan([("f3", "Week 3", 20, 20, "exam")])
        #expect(FolderWording.examDraw(one) == "All 20 questions in this folder, or Wrong questions only.")
        let large = try plan([("a", "A", 30, 20, "practice"), ("b", "B", 30, 20, "practice")])
        #expect(FolderWording.examDraw(large) == "40 questions from the 60 in these 2 folders, or Wrong questions only.")
    }

    /// The count is the server's plan, so a change to its rules reaches the page without an update.
    @Test func examDrawFollowsTheServersCount() throws {
        let page = try plan([("f1", "Week 1", 17, 10, "exam"), ("f2", "Week 2", 26, 15, "practice")], questions: 25)
        #expect(FolderWording.examDraw(page) == "25 questions from the 43 in these 2 folders, or Wrong questions only.")
    }

    @Test func examTwinsSitBesideStartExamWhenAFolderHasThem() throws {
        let one = try #require(CourseLayout(course: try course(pages: [("x1", "Exam 1", ["f3"])]), sittings: []).page("x1"))
        #expect(FolderWording.examTwins(one) == "Exam twins: 20 in Week 3 · exams draw from these first")
        let week4 = try folder("Week 4", [(1, 0, 0)], bank: 14)
        let plain = try folder("Week 7", [(1, 0, 0)])
        let week5 = try folder("Week 5", [(1, 0, 0)], bank: 14)
        let week6 = try folder("Week 6", [(1, 0, 0)], bank: 13)
        let several = ExamPage(
            exam: CourseExam(id: "x", name: "Exam 2", sortOrder: 1, weekLabels: []),
            folders: [week4, plain, week5, week6],
            sittings: [],
            progress: FolderProgress(sets: [week4, plain, week5, week6].flatMap(\.sets))
        )
        #expect(FolderWording.examTwins(several) == "Exam twins: 41 in Week 4, Week 5 and Week 6 · exams draw from these first")
        let pair = ExamPage(
            exam: several.exam, folders: [week4, week5], sittings: [],
            progress: FolderProgress(sets: [week4, week5].flatMap(\.sets))
        )
        #expect(FolderWording.examTwins(pair) == "Exam twins: 28 in Week 4 and Week 5 · exams draw from these first")
    }

    @Test func aFolderSaysWhichPageItIsOn() throws {
        let course = try course(pages: [("x1", "Exam 1", ["f1"])])
        let onPage = try #require(course.folders.first { $0.id == "f1" })
        #expect(FolderWording.folderNote(onPage, page: course.exams.first) == "On Exam 1 · 1 set · 8 of 10 fully right")
        let loose = try #require(course.folders.first { $0.id == "f3" })
        #expect(FolderWording.folderNote(loose, page: nil) == "On no page · 1 set · 12 questions")
    }

    // MARK: Past exams

    @Test func pastExamsBelongToThePageHoldingAllTheirFolders() throws {
        let course = try course(pages: [("x1", "Exam 1", ["f1", "f2"]), ("x2", "Exam 2", ["f3"])])
        let sittings = [
            try summary(StudyBodies.summary("s1", weeks: ["Week 1", "Week 2"], folders: ["f1", "f2"], courseExam: "x1")),
            try summary(StudyBodies.summary("s2", weeks: ["Week 1"], folders: ["f1"], courseExam: "x1")),
            try summary(StudyBodies.summary("s3", weeks: ["Week 1", "Week 3"], folders: ["f1", "f3"])),
        ]
        let layout = CourseLayout(course: course, sittings: sittings)
        #expect(layout.page("x1")?.sittings.map(\.id) == ["s1", "s2"])
        #expect(layout.page("x2")?.sittings.isEmpty == true, "a sitting across two pages belongs to neither")
    }

    @Test func aSittingTheServerHasNotMatchedYetFollowsTheRule() throws {
        let course = try course(pages: [("x1", "Exam 1", ["f1", "f2"])])
        let stale = try summary(StudyBodies.summary("s1", weeks: ["Week 2"], folders: ["f2"], courseExam: nil))
        let gone = try summary(StudyBodies.summary("s2", weeks: ["Week 3"], folders: ["f3"], courseExam: "deleted"))
        let moved = try summary(StudyBodies.summary("s3", weeks: ["Week 1", "Week 3"], folders: ["f1", "f3"], courseExam: "x1"))
        let beforeFolders = try summary(StudyBodies.summary("s4", weeks: ["Week 1", "Week 2"]))
        #expect(CourseLayout.page(of: stale, in: course) == "x1")
        #expect(CourseLayout.page(of: gone, in: course) == nil)
        #expect(CourseLayout.page(of: moved, in: course) == nil, "x1 does not hold Week 3")
        #expect(CourseLayout.page(of: beforeFolders, in: course) == "x1", "an exam from before folders is matched by name")
    }

    // MARK: From a server before folders

    @Test func aCourseFromBeforeFoldersReadsEachWeekAsAFolder() throws {
        let course = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.legacyCourse(exams: [
            StudyBodies.courseExam("x1", "Exam 1", order: 1, weeks: ["Week 1", "Week 2"]),
        ]).utf8))
        #expect(course.folders.map(\.id) == ["Week 1", "Week 2", "Week 3"])
        #expect(course.folders.map(\.examPageID) == ["x1", "x1", nil])
        #expect(course.folders.last?.examBankCount == 20)
        let layout = CourseLayout(course: course, sittings: [])
        #expect(layout.page("x1")?.folders.map(\.name) == ["Week 1", "Week 2"])
        #expect(layout.looseFolders.map(\.name) == ["Week 3"])
    }

    // MARK: Her edits

    private func loaded(_ server: StubServer, account: Account = .student()) async -> CourseModel {
        let (app, _) = TestApp.make(server, account: account)
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        return model
    }

    private func body(_ request: URLRequest?) -> String {
        String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
    }

    @Test func renameSendsTheNameAndReadsTheCourseAgain() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "PATCH /api/folders/f3": .ok(StudyBodies.folder("f3", "Week Three", order: 3, sets: [], bank: 20)),
        ])
        let model = await loaded(server)
        let folder = try #require(model.folder("f3"))
        #expect(await model.rename(folder, to: "  Week Three ") == nil)
        let patch = try #require(server.requests.first { $0.httpMethod == "PATCH" })
        #expect(body(patch) == #"{"name":"Week Three"}"#)
        #expect(server.calls.filter { $0 == "GET /api/courses/c1" }.count == 2)
        #expect(await model.rename(folder, to: "Week 3") == nil, "the same name sends nothing")
        #expect(server.calls.filter { $0.hasPrefix("PATCH") }.count == 1)
    }

    @Test func aRefusedRenameIsSaidInTheServersWords() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "PATCH /api/folders/f3": .error(409, "request_refused", "NURS 101 already has a folder named Week 2."),
        ])
        let model = await loaded(server)
        #expect(await model.rename(try #require(model.folder("f3")), to: "week 2") == "NURS 101 already has a folder named Week 2.")
    }

    @Test func aFolderMovesToAnotherPageInOneCall() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1", "f2"]), ("x2", "Exam 2", ["f3"])])),
            "PATCH /api/folders/f2": .ok(StudyBodies.folder("f2", "Week 2", page: "x2", order: 2, sets: [])),
        ])
        let model = await loaded(server)
        #expect(await model.put(try #require(model.folder("f2")), on: .page("x2")) == nil)
        #expect(server.requests.filter { $0.httpMethod != "GET" }.map { body($0) } == [#"{"examPageId":"x2"}"#])
        #expect(await model.put(try #require(model.folder("f3")), on: .page("x2")) == nil, "already on that page")
        #expect(server.calls.filter { $0.hasPrefix("PATCH") }.count == 1)
    }

    @Test func aFolderGoesOnANewPageOrOnNone() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1"])])),
            "POST /api/courses/c1/course-exams": StubServer.Reply(status: 201, body: StudyBodies.courseExam("x2", "Exam 2", order: 2, weeks: ["Week 3"], folders: ["f3"])),
            "PATCH /api/folders/f1": .ok(StudyBodies.folder("f1", "Week 1", order: 3, sets: [])),
        ])
        let model = await loaded(server)
        #expect(model.nextPageName == "Page 2")
        #expect(await model.put(try #require(model.folder("f3")), on: .new(name: " Exam 2 ")) == nil)
        #expect(body(server.requests.first { $0.httpMethod == "POST" }) == #"{"folderIds":["f3"],"name":"Exam 2"}"#)
        #expect(await model.put(try #require(model.folder("f1")), on: .none) == nil)
        #expect(body(server.requests.first { $0.httpMethod == "PATCH" }) == #"{"examPageId":null}"#)
        #expect(await model.put(try #require(model.folder("f2")), on: .none) == nil, "already on none")
        #expect(server.requests.filter { $0.httpMethod != "GET" }.count == 2)
    }

    /// A page cannot be made holding another page's folder, so it is made empty and the folder
    /// moves onto it.
    @Test func aFolderLeavesItsPageForANewOne() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1", "f2"])])),
            "POST /api/courses/c1/course-exams": StubServer.Reply(status: 201, body: StudyBodies.courseExam("x2", "Exam 2", order: 2, weeks: [], folders: [])),
            "PATCH /api/folders/f2": .ok(StudyBodies.folder("f2", "Week 2", page: "x2", order: 1, sets: [])),
        ])
        let model = await loaded(server)
        #expect(await model.put(try #require(model.folder("f2")), on: .new(name: "Exam 2")) == nil)
        let edits = server.requests.filter { $0.httpMethod != "GET" }
        #expect(edits.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["POST /api/courses/c1/course-exams", "PATCH /api/folders/f2"])
        #expect(edits.map { body($0) } == [#"{"folderIds":[],"name":"Exam 2"}"#, #"{"examPageId":"x2"}"#])
    }

    @Test func movingSetsSendsEachOneAndTheFirstMakesANewFolder() async throws {
        let moved = StudyBodies.folder("f9", "Hard ones", order: 4, sets: [])
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "POST /api/practice-sets/w2a/move": .ok(moved),
            "POST /api/practice-sets/w2b/move": .ok(moved),
        ])
        let model = await loaded(server)
        let sets = try #require(model.folder("f2")?.sets)
        var destination = CourseModel.Destination.folder("f1")
        #expect(await model.move(sets, to: &destination) == nil)
        var moves = server.requests.filter { $0.url?.path().hasSuffix("/move") == true }
        #expect(moves.map { body($0) } == [#"{"folderId":"f1"}"#, #"{"folderId":"f1"}"#])

        destination = .newFolder(" Hard ones ")
        #expect(await model.move(sets, to: &destination) == nil)
        #expect(destination == .folder("f9"))
        moves = Array(server.requests.filter { $0.url?.path().hasSuffix("/move") == true }.dropFirst(2))
        #expect(moves.map { body($0) } == [#"{"newFolderName":"Hard ones"}"#, #"{"folderId":"f9"}"#], "the first set makes the folder, the rest follow it")
        #expect(!server.calls.contains("POST /api/courses/c1/folders"), "no empty folder is made first")
    }

    @Test func aMoveStopsAtARefusalAndStillReadsTheCourse() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "POST /api/practice-sets/w2a/move": .error(400, "request_refused", "That folder is not in this course."),
        ])
        let model = await loaded(server)
        let sets = try #require(model.folder("f2")?.sets)
        var destination = CourseModel.Destination.folder("f1")
        #expect(await model.move(sets, to: &destination) == "That folder is not in this course.")
        #expect(!server.calls.contains("POST /api/practice-sets/w2b/move"))
        let refused = try #require(server.calls.firstIndex(of: "POST /api/practice-sets/w2a/move"))
        #expect(server.calls[refused...].contains("GET /api/courses/c1"), "the course is read again after the refusal")
    }

    /// The first set made the new folder before the second failed: trying again moves the rest into
    /// that folder rather than asking for the same new name, which the server would refuse.
    @Test func aHalfDoneMoveToANewFolderGoesOnIntoIt() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "POST /api/practice-sets/w2a/move": .ok(StudyBodies.folder("f9", "Hard ones", order: 4, sets: [])),
            "POST /api/practice-sets/w2b/move": .error(503, "unavailable", "QBank is not reachable."),
        ])
        let model = await loaded(server)
        let sets = try #require(model.folder("f2")?.sets)
        var destination = CourseModel.Destination.newFolder("Hard ones")
        #expect(await model.move(sets, to: &destination) != nil)
        #expect(destination == .folder("f9"), "the folder the first set made")
    }

    @Test func herOrderIsSavedForOneList() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1", "f2"])])),
            "PUT /api/courses/c1/folder-order": .ok(#"{"folders":[]}"#),
        ])
        let model = await loaded(server)
        #expect(await model.saveOrder(page: "x1", folderIDs: ["f2", "f1"]) == nil)
        #expect(await model.saveOrder(page: nil, folderIDs: ["f3"]) == nil)
        let orders = server.requests.filter { $0.httpMethod == "PUT" }.map { body($0) }
        #expect(orders == [#"{"examPageId":"x1","folderIds":["f2","f1"]}"#, #"{"examPageId":null,"folderIds":["f3"]}"#])
    }

    @Test func aStaleOrderSaysWhyInTheServersWords() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "PUT /api/courses/c1/folder-order": .error(409, "request_refused", "The folders changed since this list was shown. Reload and try again."),
        ])
        let model = await loaded(server)
        #expect(await model.saveOrder(page: nil, folderIDs: ["f1"]) == "The folders changed since this list was shown. Reload and try again.")
    }

    @Test func withoutAConnectionNothingCanBeEdited() async throws {
        let server = StubServer(["GET /api/courses/c1": .ok(StudyBodies.course())])
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        let model = CourseModel(app: app, id: "c1")
        await model.load()
        #expect(model.canEdit)
        connection.update(isOnline: false)
        await model.load()
        #expect(!model.canEdit)
    }

    @Test func nextPageNameSkipsTakenOnes() {
        #expect(Wording.nextPageName(after: ["Exam 1"]) == "Page 2")
        #expect(Wording.nextPageName(after: ["Final", "page 2"]) == "Page 3")
    }

    @Test func anExamPagesStartButtonTicksItsFolders() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f2", "f1"])])),
        ])
        let model = await loaded(server)
        let page = try #require(model.layout?.page("x1"))
        #expect(model.examSetup(for: page) == ExamSetupRoute(
            course: CourseRef(id: "c1", code: "NURS 101", title: "Invented Basics"), folderIDs: ["f2", "f1"], examName: "Exam 1"
        ))
    }

    @Test func coursePageAndExamsLoadTogether() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(StudyBodies.course(pages: [("x1", "Exam 1", ["f1"])])),
            "GET /api/courses/c1/exams": .ok(StudyBodies.setup(
                folders: StudyBodies.threePools,
                inProgress: StudyBodies.summary("run", weeks: ["Week 1"], folders: ["f1"], courseExam: "x1", finished: false),
                exams: [StudyBodies.summary("s1", weeks: ["Week 1"], folders: ["f1"], courseExam: "x1")]
            )),
        ])
        let model = await loaded(server)
        #expect(model.sittings.map(\.id) == ["run", "s1"], "the running exam first")
        #expect(model.layout?.page("x1")?.sittings.map(\.id) == ["run", "s1"])
    }

    @Test func aCourseStillLoadsWhenItsExamsCannot() async throws {
        let server = StubServer(["GET /api/courses/c1": .ok(StudyBodies.legacyCourse(exams: nil))])
        let model = await loaded(server)
        #expect(model.course?.exams == [], "an older server sends no exams")
        #expect(model.layout?.looseFolders.count == 3)
        #expect(model.sittings.isEmpty)
        #expect(model.problem == nil)
    }

    // MARK: The page editor

    private func editor(_ server: StubServer, pages: [StudyBodies.Page], page: String?, badges: [String: String?] = [:]) throws -> EditExamPageModel {
        let (app, _) = TestApp.make(server, account: .student())
        return EditExamPageModel(app: app, course: try course(pages: pages, badges: badges), pageID: page)
    }

    /// An existing page ends with Delete for her; a new page, and the owner's read-only view, have none.
    @Test func onlyHerExistingPageOffersDelete() throws {
        let pages: [StudyBodies.Page] = [("x1", "Exam 1", ["f2"])]
        #expect(try editor(StubServer(), pages: pages, page: "x1").offersDelete)
        #expect(try editor(StubServer(), pages: pages, page: nil).offersDelete == false)
        let (owner, _) = TestApp.make(StubServer(), account: .admin)
        #expect(EditExamPageModel(app: owner, course: try course(pages: pages), pageID: "x1").offersDelete == false)
    }

    @Test func theEditorGreysFoldersOnOtherPages() throws {
        let model = try editor(StubServer(), pages: [("x1", "Exam 1", ["f2"]), ("x2", "Exam 2", ["f1"])], page: "x1")
        #expect(model.name == "Exam 1")
        #expect(model.chips.map(\.folder.name) == ["Week 2", "Week 3", "Week 1"], "its own, then free ones, then other pages'")
        #expect(model.chips.map(\.heldBy) == [nil, nil, "Exam 2"])
        #expect(model.line == "1 folder · 10 questions")
        let held = try #require(model.chips.last)
        model.toggle(held)
        #expect(!model.isPicked(held), "a folder on another page cannot be taken here")
        model.toggle(model.chips[1])
        #expect(model.line == "2 folders · 22 questions")
        #expect(model.hasChanges)
    }

    @Test func aNewPageIsNamedAndMadeWithItsFolders() async throws {
        let server = StubServer([
            "POST /api/courses/c1/course-exams": StubServer.Reply(status: 201, body: StudyBodies.courseExam("x9", "Exam 2", order: 2, weeks: ["Week 3"], folders: ["f3"])),
        ])
        let model = try editor(server, pages: [("x1", "Exam 1", ["f1"])], page: nil)
        #expect(model.isNew)
        #expect(model.name == "Page 2")
        #expect(model.line == "No folders yet")
        #expect(!model.offersBadge, "a new page asks nothing more")
        model.toggle(try #require(model.chips.first { $0.folder.id == "f3" }))
        #expect(await model.save() == .saved("x9"))
        #expect(String(decoding: server.requests.first?.httpBody ?? Data(), as: UTF8.self) == #"{"folderIds":["f3"],"name":"Page 2"}"#)
    }

    @Test func theEditorSavesOnlyAChangeAndSaysARefusal() async throws {
        let server = StubServer([
            "PUT /api/course-exams/x1": .error(409, "request_refused", "This course already has an exam named final."),
        ])
        let model = try editor(server, pages: [("x1", "Exam 1", ["f1"]), ("x2", "Final", [])], page: "x1")
        #expect(await model.save() == .cancelled, "nothing changed")
        #expect(server.requests.isEmpty)
        model.name = "  "
        #expect(await model.save() == nil)
        #expect(model.problem == "Page name is required.")
        model.name = "final"
        #expect(await model.save() == nil)
        #expect(model.problem == "This course already has an exam named final.")
    }

    /// The editor does not show order: a folder tapped off and on keeps its place, and a new one goes
    /// at the end.
    @Test func theEditorKeepsThePagesOrder() async throws {
        let server = StubServer([
            "PUT /api/course-exams/x1": .ok(StudyBodies.courseExam("x1", "Exam 1", order: 1, weeks: [], folders: ["f2", "f1", "f3"])),
        ])
        let model = try editor(server, pages: [("x1", "Exam 1", ["f2", "f1"])], page: "x1")
        let week2 = try #require(model.chips.first { $0.folder.id == "f2" })
        model.toggle(week2)
        model.toggle(week2)
        #expect(model.folderIDs == ["f2", "f1"])
        #expect(!model.hasChanges, "off and on again is no change")
        #expect(await model.save() == .cancelled)
        model.toggle(try #require(model.chips.first { $0.folder.id == "f3" }))
        #expect(await model.save() == .saved("x1"))
        #expect(String(decoding: server.requests.first?.httpBody ?? Data(), as: UTF8.self) == #"{"folderIds":["f2","f1","f3"],"name":"Exam 1"}"#)
    }

    /// Badge: a page that exists shows its badge, and Done sends the one she picks, or null for
    /// None, and leaves the badge out when she did not change it.
    @Test func theEditorSetsAndClearsThePagesBadge() async throws {
        let server = StubServer([
            "PUT /api/course-exams/x1": .ok(StudyBodies.courseExam("x1", "Exam 1", order: 1, weeks: [], folders: ["f1"], badge: "concept")),
        ])
        let model = try editor(server, pages: [("x1", "Exam 1", ["f1"])], page: "x1", badges: ["x1": "exam"])
        #expect(model.offersBadge)
        #expect(model.badge == .exam)
        #expect(!model.hasChanges)
        #expect(model.badgeChange == nil)
        model.badge = .concept
        #expect(model.hasChanges, "a badge alone is a change")
        #expect(await model.save() == .saved("x1"))
        model.badge = nil
        #expect(await model.save() == .saved("x1"))
        model.badge = .exam
        model.name = "Midterm"
        #expect(await model.save() == .saved("x1"))
        let bodies = server.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(bodies == [
            #"{"badge":"concept","folderIds":["f1"],"name":"Exam 1"}"#,
            #"{"badge":null,"folderIds":["f1"],"name":"Exam 1"}"#,
            #"{"folderIds":["f1"],"name":"Midterm"}"#,
        ])
    }

    @Test func aPageWithNoBadgeShowsNone() throws {
        let model = try editor(StubServer(), pages: [("x1", "Page 1", ["f1"])], page: "x1", badges: ["x1": String?.none])
        #expect(model.offersBadge)
        #expect(model.badge == nil)
        #expect(model.badgeChange == nil)
    }

    /// A server before badges sends no badge field and would drop one, so Badge waits for one that does.
    @Test func aServerBeforeBadgesIsOfferedNoBadge() throws {
        let model = try editor(StubServer(), pages: [("x1", "Exam 1", ["f1"])], page: "x1")
        #expect(!model.offersBadge)
        #expect(model.badgeChange == nil)
    }
}
