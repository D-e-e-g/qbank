import Foundation
import QBankKit
import Testing
@testable import QBank

/// Select all that apply in the set editor, and a saved set opened in it: what the file says, what
/// the check refuses in her words, which sets open, that a question keeps its id through an edit, and
/// that saving replaces only the version of the set that was opened. Invented sets only.
@MainActor
struct WriteEditTests {
    // MARK: Select all that apply

    @Test func selectAllIsASataQuestionWithEveryMarkedChoiceRight() throws {
        let draft = Self.selectAllSet()
        let file = try Self.parsed(draft.file())
        let questions = try #require(file["questions"] as? [[String: Any]])
        #expect(questions[0]["type"] as? String == "sata")
        let options = try #require(questions[0]["options"] as? [[String: Any]])
        #expect(options.map { $0["t"] as? String } == ["A regular bedtime", "A dark room", "Coffee at night"])
        #expect(options.map { $0["ok"] as? Bool } == [true, true, nil])
        let report = ImportChecker.report(for: draft.file())
        #expect(report.ok)
        #expect(report.warnings.isEmpty)
        #expect(report.formats.map(\.type) == ["sata"])
    }

    @Test func selectAllNeedsAtLeastOneRightChoiceAndSaysSo() async throws {
        var draft = Self.selectAllSet()
        draft.questions[0].rightChoices = []
        #expect(draft.questions[0].problems == ["mark at least one right answer"])
        let report = ImportChecker.report(for: draft.file())
        #expect(!report.ok, "the import check refuses a select all with none right")
        #expect(report.errors == ["Question 1 (\(try #require(draft.questions[0].fileID))): select-all needs at least one correct option"])
    }

    @Test func selectAllMayHaveEveryChoiceRight() throws {
        var draft = Self.selectAllSet()
        draft.questions[0].rightChoices = [0, 1, 2]
        #expect(draft.questions[0].problems.isEmpty)
        #expect(ImportChecker.report(for: draft.file()).ok)
    }

    @Test func aRightChoiceLeftEmptyIsAProblem() {
        var question = Self.selectAllSet().questions[0]
        question.choices[1].text = " "
        #expect(question.problems == ["a right choice is empty"])
    }

    @Test func marksToggleInSelectAllAndMoveOneInSingleAnswer() {
        var question = Self.selectAllSet().questions[0]
        question.mark(2)
        #expect(question.rightChoices == [0, 1, 2])
        question.mark(0)
        #expect(question.rightChoices == [1, 2])
        question.kind = .single
        question.mark(2)
        question.mark(1)
        #expect(question.rightPositions == [1], "single answer has one right choice")
    }

    @Test func removingAChoiceMovesTheMarksWithTheirChoices() {
        var question = Self.selectAllSet().questions[0]
        question.choices.append(QuestionDraft.Choice(text: "A late workout"))
        question.rightChoices = [0, 2, 3]
        question.removeChoice(at: 1)
        #expect(question.rightChoices == [0, 1, 2])
        question.removeChoice(at: 0)
        #expect(question.rightChoices == [0, 1], "the removed choice's mark goes with it")
    }

    @Test func selectAllSavesWhatItSaysAndIsDetailedInDraftRows() {
        #expect(QuestionDraft.Kind.selectAll.label == "Select all")
        #expect(ImportChecker.report(for: Self.selectAllSet().file()).questionCount == 1)
    }

    // MARK: Ids stay with questions

    @Test func aQuestionKeepsItsFileIDThroughEveryEdit() throws {
        var draft = Self.selectAllSet()
        draft.questions.append(Self.single(id: "Q-two"))
        let first = try #require(draft.questions[0].fileID)
        draft.questions[0].ask = "Which habits help sleep most?"
        draft.questions.insert(Self.single(id: "Q-new"), at: 0)
        draft.questions.removeAll { $0.fileID == "Q-new" }
        let questions = try #require(try Self.parsed(draft.file())["questions"] as? [[String: Any]])
        #expect(questions.map { $0["id"] as? String } == [first, "Q-two"])
    }

    @Test func newQuestionsGetDifferentIDsAndAnOldDraftIsNumberedByPlace() throws {
        #expect(QuestionDraft().fileID != QuestionDraft().fileID)
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"single","ask":"","choices":[],"explanation":""}"#
        let question = try JSONDecoder().decode(QuestionDraft.self, from: Data(old.utf8))
        #expect(question.fileID == nil)
        #expect(question.rightChoices.isEmpty)
        var draft = SetDraft(title: "Invented Old")
        draft.questions = [question]
        let questions = try #require(try Self.parsed(draft.file())["questions"] as? [[String: Any]])
        #expect(questions[0]["id"] as? String == "W1")
    }

    @Test func aDraftSurvivesBeingKeptAndReadAgain() throws {
        var draft = Self.selectAllSet()
        draft.editing = EditedSet(setID: "s1", courseID: "c1", folderID: "f1", activeSince: Self.openedVersion)
        let kept = try JSONDecoder().decode(SetDraft.self, from: JSONEncoder().encode(draft))
        #expect(kept == draft)
    }

    // MARK: Opening a saved set

    @Test func aSavedSetOpensWithItsIDsAndEveryRightChoice() throws {
        let draft = try Self.opened(Self.savedSet()).get()
        #expect(draft.title == "Invented Sleep")
        #expect(draft.editing == EditedSet(setID: "s1", courseID: "c1", folderID: "f1", activeSince: Self.openedVersion))
        #expect(draft.questions.map(\.fileID) == ["Q1", "Q2", "Q3"])
        #expect(draft.questions.map(\.kind) == [.single, .selectAll, .trueFalse])
        #expect(draft.questions[1].rightChoices == [0, 1])
        #expect(draft.questions[0].explanation == "A steady schedule sets the body clock.")
        #expect(draft.questions[2].rightTrueFalse == 1)
    }

    @Test func aSetThatIsOpenedAndNotChangedMakesTheSameQuestionsItHad() throws {
        let draft = try Self.opened(Self.savedSet()).get()
        let file = try Self.parsed(draft.file())
        let saved = try #require(try Self.parsed(Self.savedFile)["questions"] as? [[String: Any]])
        let written = try #require(file["questions"] as? [[String: Any]])
        #expect(NSArray(array: written).isEqual(to: saved), "word for word, so the bank sees the same questions")
        #expect(ImportChecker.report(for: draft.file()).ok)
    }

    @Test func changingOneQuestionLeavesTheOthersAndTheirIDsAsTheyWere() throws {
        var draft = try Self.opened(Self.savedSet()).get()
        draft.questions[0].ask = "Which habit helps sleep best?"
        draft.questions.append(QuestionDraft())
        let written = try #require(try Self.parsed(draft.file())["questions"] as? [[String: Any]])
        let saved = try #require(try Self.parsed(Self.savedFile)["questions"] as? [[String: Any]])
        #expect(written.prefix(3).map { $0["id"] as? String } == ["Q1", "Q2", "Q3"])
        #expect(NSArray(array: Array(written[1...2])).isEqual(to: Array(saved[1...2])))
        #expect(written[0]["ask"] as? String == "Which habit helps sleep best?")
    }

    @Test(arguments: [
        #""stem":"A client has a finding.","#, #""topic":"Sleep","#, #""takeaway":"Keep a schedule.","#, #""cj":"Analyze cues","#,
        #""terms":[{"key":"k","term":"T","meaning":"M"}],"#,
    ])
    func aSetWithPartsTheEditorCannotKeepIsNotOpened(extra: String) {
        let refusal = Self.opened(Self.savedSet(first: extra)).failure
        #expect(refusal?.message == WriteEdit.unsupported)
    }

    @Test func aSetWithAPictureATableANoteOrAnotherFormatIsNotOpened() {
        for body in [
            #""table":{"head":["A"],"rows":[["1"]]},"options":[{"t":"A","ok":true},{"t":"B"}]"#,
            #""options":[{"t":"A","ok":true,"why":"Because."},{"t":"B"}]"#,
            #""options":[{"t":"A","ok":false},{"t":"B","ok":true}]"#,
            #""options":[{"t":"A","ok":true}]"#,
            #""options":[{"t":"A","ok":true},{"t":" B "}]"#,
        ] {
            let set = Self.savedSet(firstBody: body)
            #expect(Self.opened(set).failure?.message == WriteEdit.unsupported, "\(body)")
        }
        let order = Self.savedSet(first: "", type: "order", firstBody: #""items":[{"t":"A"},{"t":"B"},{"t":"C"}]"#)
        #expect(Self.opened(order).failure?.message == WriteEdit.unsupported)
    }

    @Test func anExamSetIsNotOpened() {
        #expect(Self.opened(Self.savedSet(kind: "exam")).failure?.message == WriteEdit.examSet)
    }

    // MARK: Saving an edit

    @Test func savingAnEditReplacesTheSetItWasOpenedFromAndForgetsTheDraft() async throws {
        let (server, model, app) = try Self.editing(conflictSetID: "s1")
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Which habit helps sleep best?" }
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import", "replace"])
        #expect(try Self.importBodies(server).allSatisfy { $0["courseId"] as? String == "c1" && $0["folderId"] as? String == "f1" })
        #expect(try Self.importBodies(server).allSatisfy { $0["title"] as? String == "Invented Sleep" })
        #expect(try Self.importBodies(server).last?["source"] as? String == model.draft.file())
        #expect(model.importing.done?.set.kind == .replaced)
        #expect(app.drafts.draft(id: model.draft.id) == nil)
    }

    @Test func anotherSetOfTheSameNameIsNeverReplaced() async throws {
        let (server, model, app) = try Self.editing(conflictSetID: "someone-elses")
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import"], "nothing was written")
        #expect(model.problem == WriteWording.otherSetNamed)
        #expect(model.importing.done == nil)
        #expect(model.importing.conflict == nil)
        #expect(app.drafts.draft(id: model.draft.id) != nil, "her edits are kept")
    }

    @Test func anEditOfASetDeletedSinceSavesNothingUntilSheSavesItAsANewSet() async throws {
        let (server, model, app) = try Self.editing(course: StudyBodies.course(), imports: [Self.importedNew])
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Which habit helps sleep best?" }
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).isEmpty, "no separate set is made unasked")
        #expect(model.outdated == .deleted)
        #expect(model.importing.done == nil)
        #expect(app.drafts.draft(id: model.draft.id)?.editing != nil, "her changes are kept")
        await model.saveAsNewSet()
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import"])
        #expect(try Self.importBodies(server).first?["folderId"] as? String == "f1", "filed where the set was")
        #expect(model.importing.done?.set.kind == .imported)
        #expect(model.outdated == nil)
        #expect(app.drafts.draft(id: model.draft.id) == nil)
    }

    @Test func anEditOfASetReplacedSinceIsNotSavedOverItUnasked() async throws {
        let (server, model, app) = try Self.editing(conflictSetID: "s1", version: "2026-10-05T00:00:00.000Z")
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Which habit helps sleep best?" }
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).isEmpty, "the newer version is left as it is")
        #expect(model.outdated == .changed(activeSince: Self.newerVersion, folderID: "f1"))
        #expect(app.drafts.draft(id: model.draft.id) != nil, "her changes are kept")
        await model.saveAnyway()
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import", "replace"])
        #expect(try Self.importBodies(server).last?["source"] as? String == model.draft.file())
        #expect(model.importing.done?.set.kind == .replaced)
        #expect(app.drafts.draft(id: model.draft.id) == nil)
    }

    @Test func anEditOfASetMovedSinceIsNotSavedAsANewSetInTheFolderItLeft() async throws {
        let (server, model, app) = try Self.editing(conflictSetID: "s1", folder: "f2")
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Which habit helps sleep best?" }
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).isEmpty, "nothing is filed in the folder the set left")
        #expect(model.outdated == .changed(activeSince: Self.openedVersion, folderID: "f2"))
        #expect(app.drafts.draft(id: model.draft.id) != nil, "her changes are kept")
        await model.saveAnyway()
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import", "replace"])
        #expect(try Self.importBodies(server).allSatisfy { $0["folderId"] as? String == "f2" }, "saved where the set is now")
        #expect(model.importing.done?.set.kind == .replaced)
    }

    @Test func aMovedSetOpensIntoTheFolderItIsInNow() async throws {
        let (server, _, app) = try Self.editing(conflictSetID: "s1", folder: "f2")
        server["GET /api/practice-sets/s1"] = .ok(Self.savedSetBody())
        let draft = try await WriteEdit.open(setID: "s1", courseID: "c1", client: app.client).get()
        #expect(draft.editing?.folderID == "f2")
    }

    @Test func aKeptEditOfASetReplacedSinceIsToldWhenItOpens() async throws {
        let (_, model, _) = try Self.editing(conflictSetID: "s1", version: "2026-10-05T00:00:00.000Z")
        let replaced = await model.checkEdited()
        #expect(!replaced)
        #expect(model.outdated == .changed(activeSince: Self.newerVersion, folderID: "f1"))
        let (_, current, _) = try Self.editing(conflictSetID: "s1")
        let unchanged = await current.checkEdited()
        #expect(unchanged)
        #expect(current.outdated == nil, "the version she opened is still the set's current one")
    }

    @Test func aFailedReadOfTheSetIsNoLongerSaidOnceTheSetIsRead() async throws {
        let (server, model, _) = try Self.editing(conflictSetID: "s1")
        server.script("GET /api/courses/c1", [StubServer.Reply(status: 500, body: "{}"), .ok(Self.courseWithSavedSet(version: "2026-10-01T00:00:00.000Z"))])
        let failed = await model.checkEdited()
        #expect(!failed)
        #expect(model.problem != nil, "the failed read is said")
        let read = await model.checkEdited()
        #expect(read)
        #expect(model.problem == nil, "the set was read, so the failed read is no longer said")
    }

    @Test func openingTheCurrentVersionDiscardsHerChangesAndEditsWhatTheSetIsNow() async throws {
        let (server, model, app) = try Self.editing(conflictSetID: "s1", version: "2026-10-05T00:00:00.000Z")
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Her change" }
        let id = model.draft.id
        await model.checkEdited()
        server["GET /api/practice-sets/s1"] = .ok(Self.savedSetBody(firstAsk: "Which habit helps sleep now?"))
        await model.openCurrent()
        #expect(model.outdated == nil)
        #expect(model.draft.questions.map(\.ask) == ["Which habit helps sleep now?", "Which habits help sleep?", "Naps at 6 PM make it easier to fall asleep."])
        #expect(model.draft.editing?.activeSince == Self.newerVersion)
        #expect(app.drafts.draft(id: id) == nil, "her changes are discarded")
        await Self.save(model, on: server)
        #expect(try Self.importBodies(server).map { $0["decision"] as? String } == ["import", "replace"])
    }

    @Test func openingASetRecordsTheVersionTheCourseSaysIsCurrentNotTheFolderRows() async throws {
        let (server, _, app) = try Self.editing(conflictSetID: "s1", version: "2026-10-05T00:00:00.000Z")
        server["GET /api/practice-sets/s1"] = .ok(Self.savedSetBody())
        let draft = try await WriteEdit.open(setID: "s1", courseID: "c1", client: app.client).get()
        #expect(draft.editing == EditedSet(setID: "s1", courseID: "c1", folderID: "f1", activeSince: Self.newerVersion))
        let reads = server.calls.filter { $0 == "GET /api/courses/c1" || $0 == "GET /api/practice-sets/s1" }
        #expect(reads == ["GET /api/courses/c1", "GET /api/practice-sets/s1"], "the version is read before the questions")
        let model = WriteModel(app: app, draft: draft)
        let current = await model.checkEdited()
        #expect(current)
        #expect(model.outdated == nil, "a set opened as it is now is not said to have changed since")
    }

    @Test func aSetNoLongerInItsCourseIsNotOpened() async throws {
        let (server, _, app) = try Self.editing(course: StudyBodies.course(), imports: [])
        let opened = try await WriteEdit.open(setID: "s1", courseID: "c1", client: app.client)
        #expect(opened.failure?.message == WriteEdit.missing)
        #expect(!server.calls.contains("GET /api/practice-sets/s1"))
    }

    @Test func aKeptEditComesBackForTheSameSetAndIsListedWithAChangesNote() throws {
        let (_, model, app) = try Self.editing(conflictSetID: "s1")
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Changed" }
        #expect(app.drafts.drafts.first { $0.editing?.setID == "s1" }?.questions == model.draft.questions)
        #expect(WriteWording.detail(model.draft) == "Changes to a saved set · 3 questions")
        #expect(model.isEditing)
    }

    // MARK: Helpers

    private static func selectAllSet() -> SetDraft {
        var question = QuestionDraft()
        question.kind = .selectAll
        question.ask = "Which habits help sleep?"
        question.choices = ["A regular bedtime", "A dark room", "Coffee at night"].map { QuestionDraft.Choice(text: $0) }
        question.rightChoices = [0, 1]
        var draft = SetDraft(title: "Invented Sleep")
        draft.questions = [question]
        return draft
    }

    private static func single(id: String) -> QuestionDraft {
        var question = QuestionDraft()
        question.fileID = id
        question.ask = "Is rest good?"
        question.choices = ["Yes", "No"].map { QuestionDraft.Choice(text: $0) }
        question.rightChoice = 0
        return question
    }

    /// Three hand-written questions, as the editor files them: single, select all, true or false.
    static let savedFile = """
        {"title":"Invented Sleep","questions":[
        {"id":"Q1","type":"single","ask":"Which habit helps sleep?","options":[{"t":"A regular bedtime","ok":true},{"t":"An evening nap"},{"t":"Coffee at night"}],"rationale":"A steady schedule sets the body clock."},
        {"id":"Q2","type":"sata","ask":"Which habits help sleep?","options":[{"t":"A regular bedtime","ok":true},{"t":"A dark room","ok":true},{"t":"Coffee at night"}]},
        {"id":"Q3","type":"single","ask":"Naps at 6 PM make it easier to fall asleep.","options":[{"t":"True"},{"t":"False","ok":true}]}
        ]}
        """

    /// The set as `GET /api/practice-sets/{id}` serves it for the file above, with `first` as extra
    /// fields on its first question and `firstBody` as its body.
    private static func savedSet(first: String = "", type: String = "single", kind: String = "practice", firstBody: String? = nil) -> PracticeSet {
        // swiftlint:disable:next force_try
        try! QBankJSON.decoder.decode(PracticeSet.self, from: Data(savedSetBody(first: first, type: type, kind: kind, firstBody: firstBody).utf8))
    }

    private static func savedSetBody(
        first: String = "", type: String = "single", kind: String = "practice", firstBody: String? = nil, firstAsk: String = "Which habit helps sleep?"
    ) -> String {
        func question(_ id: String, _ position: Int, _ type: String, ask: String, rationale: String = "", extra: String = "", body: String) -> String {
            #"{"id":"\#(id.lowercased())","publicId":"\#(id)","position":\#(position),"type":"\#(type)","topic":"\#(extra.contains("\"topic\"") ? "Sleep" : "")","cj":\#(extra.contains("cj") ? "\"Analyze cues\"" : "null"),"stem":"\#(extra.contains("\"stem\"") ? "A client has a finding." : "")","ask":"\#(ask)","rationale":"\#(rationale)","takeaway":"\#(extra.contains("takeaway") ? "Keep a schedule." : "")","body":{\#(body)},"images":[],"terms":\#(extra.contains("terms") ? #"[{"key":"k","term":"T","meaning":"M"}]"# : "[]")}"#
        }
        let questions = [
            question(
                "Q1", 1, type, ask: firstAsk, rationale: "A steady schedule sets the body clock.", extra: first,
                body: firstBody ?? #""options":[{"t":"A regular bedtime","ok":true},{"t":"An evening nap"},{"t":"Coffee at night"}]"#),
            question("Q2", 2, "sata", ask: "Which habits help sleep?", body: #""options":[{"t":"A regular bedtime","ok":true},{"t":"A dark room","ok":true},{"t":"Coffee at night"}]"#),
            question("Q3", 3, "single", ask: "Naps at 6 PM make it easier to fall asleep.", body: #""options":[{"t":"True"},{"t":"False","ok":true}]"#),
        ]
        return #"{"id":"s1","courseId":"c1","title":"Invented Sleep","weekLabel":"Unsorted","folderId":"f1","kind":"\#(kind)","questions":[\#(questions.joined(separator: ","))],"sitting":null,"run":"new"}"#
    }

    /// The set row's `activeSince` when she opened it, 2026-10-01T00:00:00Z, and a later one.
    static let openedVersion = Date(timeIntervalSince1970: 1_790_812_800)
    static let newerVersion = Date(timeIntervalSince1970: 1_791_158_400)

    /// `GET /api/courses/c1` with the saved set current since `version`, in Week 1 (`f1`) or in
    /// Week 2 (`f2`).
    private static func courseWithSavedSet(version: String, folder: String = "f1") -> String {
        StudyBodies.course()
            .replacingOccurrences(of: folder == "f1" ? #""id":"w1""# : #""id":"w2a""#, with: #""id":"s1""#)
            .replacingOccurrences(of: #""activeSince":"2026-10-01T00:00:00.000Z""#, with: #""activeSince":"\#(version)""#)
    }

    private static let importedNew = StubServer.Reply(status: 201, body: ImportModelTests.imported(kind: "imported", folder: "f1", folderName: "Week 1"))

    private static func opened(_ set: PracticeSet) -> Result<SetDraft, WriteEdit.Refusal> {
        WriteEdit.draft(editing: set, folderID: "f1", activeSince: openedVersion)
    }

    private static func parsed(_ file: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
    }

    /// A model editing the saved set, which the course has current since `version`. The first
    /// import answers with a conflict naming `conflictSetID`; the second replaces.
    private static func editing(conflictSetID: String, version: String = "2026-10-01T00:00:00.000Z", folder: String = "f1") throws -> (StubServer, WriteModel, AppModel) {
        let conflict = ImportModelTests.conflict.replacingOccurrences(of: "\"old1\"", with: "\"\(conflictSetID)\"")
        return try editing(
            course: courseWithSavedSet(version: version, folder: folder),
            imports: [StubServer.Reply(status: 409, body: conflict), StubServer.Reply(status: 201, body: ImportModelTests.imported(kind: "replaced", folder: "f1", folderName: "Week 1"))]
        )
    }

    /// A model editing the saved set, in the course `course` answers with, and the imports answered with `imports`.
    private static func editing(course: String, imports: [StubServer.Reply]) throws -> (StubServer, WriteModel, AppModel) {
        let draft = try opened(savedSet()).get()
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(course),
        ])
        server.script("POST /api/imports", imports)
        let (app, _) = TestApp.make(server, account: .student(), defaults: TestApp.freshDefaults())
        app.drafts.keep(draft)
        let model = WriteModel(app: app, draft: draft)
        return (server, model, app)
    }

    private static func save(_ model: WriteModel, on server: StubServer) async {
        await model.importing.load()
        let report = ImportChecker.report(for: model.draft.file())
        let body = (try? JSONEncoder().encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        server["POST /api/imports/check"] = .ok(body)
        await model.save()
    }

    private static func importBodies(_ server: StubServer) throws -> [[String: Any]] {
        var bodies: [[String: Any]] = []
        for request in server.requests where request.httpMethod == "POST" && request.url?.path() == "/api/imports" {
            let data = try #require(request.httpBody)
            bodies.append(try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        return bodies
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
