import Foundation
import QBankKit
import Testing
@testable import QBank

/// The set editor's model: the question file a draft makes, the import check's words when it is
/// wrong, saving through Import, and drafts kept on the phone. Invented sets only.
@MainActor
struct WriteModelTests {
    // MARK: The file a draft makes

    @Test func aDraftMakesAQuestionFileThatPassesTheImportCheckWithNoWarning() throws {
        let report = ImportChecker.report(for: Self.written().file())
        #expect(report.ok)
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.title == "Invented Sleep")
        #expect(report.questionCount == 2)
        #expect(report.formats.map(\.type) == ["single"])
    }

    @Test func theFileHoldsTheChoicesInOrderWithTheRightOneMarked() throws {
        let file = try Self.parsed(Self.written().file())
        #expect(file["title"] as? String == "Invented Sleep")
        let questions = try #require(file["questions"] as? [[String: Any]])
        #expect(questions.map { $0["id"] as? String } == ["W1", "W2"])
        #expect(questions.map { $0["type"] as? String } == ["single", "single"])
        #expect(questions[0]["ask"] as? String == "Which habit helps sleep?")
        let options = try #require(questions[0]["options"] as? [[String: Any]])
        #expect(options.map { $0["t"] as? String } == ["A regular bedtime", "An evening nap", "Coffee at night"])
        #expect(options.map { $0["ok"] as? Bool } == [true, nil, nil])
        #expect(questions[0]["rationale"] as? String == "A steady schedule sets the body clock.")
        #expect(questions[1]["rationale"] == nil, "no explanation, no rationale")
    }

    @Test func trueOrFalseIsASingleAnswerQuestionWithTheTwoChoices() throws {
        let file = try Self.parsed(Self.written().file())
        let questions = try #require(file["questions"] as? [[String: Any]])
        let options = try #require(questions[1]["options"] as? [[String: Any]])
        #expect(options.map { $0["t"] as? String } == ["True", "False"])
        #expect(options.map { $0["ok"] as? Bool } == [nil, true])
    }

    @Test func textIsTrimmedAndQuotesAreEscaped() throws {
        var draft = SetDraft(title: "  Invented \"Quoted\" Set  ")
        draft.questions[0].ask = "  Is \"rest\" good?\n"
        draft.questions[0].kind = .trueFalse
        draft.questions[0].right = 0
        let file = try Self.parsed(draft.file())
        #expect(file["title"] as? String == "Invented \"Quoted\" Set")
        let questions = try #require(file["questions"] as? [[String: Any]])
        #expect(questions[0]["ask"] as? String == "Is \"rest\" good?")
        #expect(ImportChecker.report(for: draft.file()).ok)
    }

    @Test func blankChoicesAreLeftOutOfTheFile() throws {
        var draft = Self.written()
        draft.questions[0].choices.append(QuestionDraft.Choice(text: "  "))
        draft.questions[0].choices.insert(QuestionDraft.Choice(), at: 1)
        let file = try Self.parsed(draft.file())
        let questions = try #require(file["questions"] as? [[String: Any]])
        let options = try #require(questions[0]["options"] as? [[String: Any]])
        #expect(options.map { $0["t"] as? String } == ["A regular bedtime", "An evening nap", "Coffee at night"])
        #expect(ImportChecker.report(for: draft.file()).ok)
    }

    // MARK: What the check refuses, in the editor's words

    @Test(arguments: [
        (Mistake.noQuestionText, "Question 1: write the question"),
        (.nothingMarked, "Question 1: mark the right answer"),
        (.rightChoiceBlank, "Question 1: the right choice is empty"),
        (.oneChoice, "Question 1: write at least two choices"),
    ])
    func whatIsWrongIsSaidInTheEditorsWords(mistake: Mistake, line: String) async throws {
        let (server, model) = Self.app()
        model.edit { $0.title = "Invented Sleep" }
        let id = model.draft.questions[0].id
        model.editQuestion(id: id) { Self.fill(&$0, mistake: mistake) }
        await Self.save(model, on: server)
        let report = try #require(model.report)
        #expect(!report.ok, "the import check refuses it")
        #expect(model.problems == [line])
        #expect(model.problems(inQuestion: id) == [String(line.dropFirst("Question 1: ".count))], "said with the question too")
        #expect(!model.problems.joined().contains("W1"), "no file ids")
        #expect(!server.calls.contains("POST /api/imports"), "a set the check refuses is not filed")
        #expect(model.importing.done == nil)
        model.editQuestion(id: id) { $0.explanation = "Invented." }
        #expect(model.problems.isEmpty, "a change needs a new check")
        #expect(model.problems(inQuestion: id).isEmpty)
    }

    @Test func theProblemsNameEachQuestionByItsNumber() async throws {
        var draft = Self.written()
        draft.questions[1].right = nil
        draft.questions.append(QuestionDraft())
        let (server, model) = Self.app(draft)
        await Self.save(model, on: server)
        #expect(
            model.problems == [
                "Question 2: mark the right answer",
                "Question 3: write the question",
                "Question 3: write at least two choices",
                "Question 3: mark the right answer",
            ])
        #expect(model.problems(inQuestion: draft.questions[0].id).isEmpty)
    }

    @Test func aRefusalTheEditorCannotSayIsShownInTheChecksWords() async throws {
        let (server, model) = Self.app(Self.written())
        server["POST /api/imports/check"] = .ok(
            #"{"ok":false,"title":"Invented Sleep","description":"","kind":"practice","questionCount":0,"termCount":0,"formats":[],"errors":["Invented server rule"],"warnings":[]}"#)
        await model.save()
        #expect(model.problems == ["Invented server rule"])
        #expect(!server.calls.contains("POST /api/imports"))
    }

    @Test func nothingChangesWhileTheSetIsCheckedOrFiled() async throws {
        let (server, model, app) = Self.appWithPhone(Self.written())
        await model.importing.load()
        let written = model.draft
        let report = ImportChecker.report(for: written.file())
        server["POST /api/imports/check"] = .ok(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        server.hold("POST /api/imports/check")
        server.hold("POST /api/imports")
        let saving = Task { await model.save() }
        while !server.calls.contains("POST /api/imports/check") { await Task.yield() }
        model.editQuestion(id: written.questions[1].id) { $0.right = nil }
        model.edit { $0.title = "Invented edit while checking" }
        #expect(model.draft == written, "the check judges what she wrote")
        server.release("POST /api/imports/check")
        while !server.calls.contains("POST /api/imports") { await Task.yield() }
        model.addQuestion()
        #expect(model.draft == written, "what is filed is what she wrote")
        server.release("POST /api/imports")
        await saving.value
        #expect(try Self.importBody(server)["source"] as? String == written.file())
        #expect(model.importing.done?.set.title == "Invented Sleep")
        #expect(app.drafts.draft(id: written.id) == nil)
    }

    @Test func aSetWithoutANameIsNotSent() async throws {
        let (server, model) = Self.app(Self.written(title: ""))
        await Self.save(model, on: server)
        #expect(model.titleProblem == "Give the set a name.")
        #expect(server.requests.isEmpty)
        model.edit { $0.title = "Invented Sleep" }
        #expect(model.titleProblem == nil, "typing a name clears it")
    }

    // MARK: Saving through Import

    @Test func savingChecksTheFileThenFilesItAndForgetsTheDraft() async throws {
        let (server, model, app) = Self.appWithPhone(Self.written())
        await model.importing.load()
        await Self.save(model, on: server)
        #expect(server.calls.filter { $0.hasPrefix("POST /api/imports") } == ["POST /api/imports/check", "POST /api/imports"])
        let body = try Self.importBody(server)
        #expect(body["source"] as? String == model.draft.file(), "the same file the check judged")
        #expect(body["title"] as? String == "Invented Sleep")
        #expect(body["courseId"] as? String == "c1")
        #expect(body["decision"] as? String == "import")
        #expect(model.importing.done?.set.title == "Invented Sleep")
        #expect(app.drafts.draft(id: model.draft.id) == nil, "saved, so no draft is left")
    }

    @Test func aSetOfTheSameNameAsksAndTheAnswerFilesIt() async throws {
        let (server, model, app) = Self.appWithPhone(Self.written())
        server.script("POST /api/imports", [StubServer.Reply(status: 409, body: ImportModelTests.conflict), StubServer.Reply(status: 201, body: ImportModelTests.imported(kind: "replaced"))])
        await model.importing.load()
        await Self.save(model, on: server)
        #expect(model.importing.conflict != nil)
        #expect(app.drafts.draft(id: model.draft.id) != nil, "nothing is lost while she decides")
        await model.commit(.replace)
        #expect(try Self.importBody(server)["decision"] as? String == "replace")
        #expect(model.importing.done?.set.kind == .replaced)
        #expect(app.drafts.draft(id: model.draft.id) == nil)
    }

    @Test func aRefusedSaveKeepsTheDraftAndSaysWhy() async throws {
        let (server, model, app) = Self.appWithPhone(Self.written())
        server["POST /api/imports"] = .error(400, "request_refused", "Choose a course.")
        await Self.save(model, on: server)
        #expect(model.problem == "Choose a course.")
        #expect(model.importing.done == nil)
        #expect(app.drafts.draft(id: model.draft.id) != nil)
    }

    @Test func writingAnotherSetStartsAFreshOneInTheSameCourse() async throws {
        let (server, model, _) = Self.appWithPhone(Self.written())
        await model.importing.load()
        await Self.save(model, on: server)
        let first = model.draft.id
        await model.startAnother()
        #expect(model.draft.id != first)
        #expect(model.draft.title.isEmpty)
        #expect(model.draft.questions.count == 1)
        #expect(model.importing.done == nil)
        #expect(model.importing.destination.courseID == "c1")
    }

    // MARK: Editing

    @Test func editsAreNotSentAnywhere() async throws {
        let (server, model) = Self.app()
        model.edit { $0.title = "Invented Sleep" }
        model.addQuestion()
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Invented?" }
        #expect(server.requests.isEmpty)
    }

    @Test func choicesComeAndGoWithinTwoToSix() throws {
        var question = QuestionDraft()
        #expect(question.choices.count == 4)
        question.addChoice()
        question.addChoice()
        #expect(question.choices.count == 6)
        #expect(!question.canAddChoice)
        question.addChoice()
        #expect(question.choices.count == 6)
        while question.canRemoveChoice { question.removeChoice(at: 0) }
        #expect(question.choices.count == 2)
        question.removeChoice(at: 0)
        #expect(question.choices.count == 2)
    }

    @Test func theMarkFollowsItsChoiceWhenAnEarlierOneGoes() throws {
        var question = QuestionDraft()
        question.right = 2
        question.removeChoice(at: 0)
        #expect(question.right == 1)
        question.removeChoice(at: 1)
        #expect(question.right == nil, "the marked choice is gone")
    }

    @Test func eachKindKeepsItsOwnRightAnswer() throws {
        var question = QuestionDraft()
        question.right = 1
        question.kind = .trueFalse
        #expect(question.right == nil)
        question.right = 0
        question.kind = .single
        #expect(question.right == 1)
        #expect(question.choiceTexts.count == 4)
        question.kind = .trueFalse
        #expect(question.choiceTexts == ["True", "False"])
    }

    @Test func removingEveryQuestionLeavesOneToWrite() throws {
        let (_, model) = Self.app()
        model.removeQuestion(id: model.draft.questions[0].id)
        #expect(model.draft.questions.count == 1)
        model.addQuestion()
        #expect(model.draft.questions.count == 2)
        model.removeQuestion(id: model.draft.questions[0].id)
        #expect(model.draft.questions.count == 1)
    }

    // MARK: Drafts on the phone

    @Test func aDraftIsKeptOnThePhoneAndComesBack() throws {
        let defaults = TestApp.freshDefaults()
        let (_, model, app) = Self.appWithPhone(SetDraft(), defaults: defaults)
        #expect(app.drafts.drafts.isEmpty, "an empty editor leaves nothing")
        model.edit { $0.title = "Invented Sleep" }
        model.editQuestion(id: model.draft.questions[0].id) { $0.ask = "Which habit helps?" }
        let relaunched = WriteDraftStore(defaults: defaults)
        relaunched.open(accountID: "a1")
        #expect(relaunched.drafts.map(\.title) == ["Invented Sleep"])
        #expect(relaunched.draft(id: model.draft.id)?.questions[0].ask == "Which habit helps?")
        #expect(WriteWording.name(relaunched.drafts[0]) == "Invented Sleep")
        #expect(WriteWording.detail(relaunched.drafts[0]) == "1 question")
    }

    @Test func aDraftWithNoQuestionWrittenSaysSo() throws {
        var draft = SetDraft(title: "Invented Sleep")
        #expect(WriteWording.detail(draft) == "No questions yet")
        draft.questions[0].ask = "  \n"
        draft.questions[0].choices[0].text = " "
        #expect(draft.questions[0].isBlank, "spaces are not writing")
        #expect(WriteWording.detail(draft) == "No questions yet")
        #expect(SetDraft(title: " ", questions: draft.questions).isBlank)
        draft.questions.append(Self.written().questions[0])
        #expect(WriteWording.detail(draft) == "1 question")
        #expect(WriteWording.detail(Self.written()) == "2 questions")
    }

    @Test func eachAccountSeesOnlyItsOwnDrafts() async throws {
        let defaults = TestApp.freshDefaults()
        let (server, model, app) = Self.appWithPhone(Self.written(), defaults: defaults)
        server["POST /api/sign-out"] = .ok(#"{"status":"signed_out"}"#)
        #expect(app.drafts.drafts.map(\.id) == [model.draft.id])
        await app.signOut()
        #expect(app.drafts.drafts.isEmpty, "no one is signed in")

        let (other, _) = TestApp.make(server, account: .admin, defaults: defaults)
        #expect(other.drafts.drafts.isEmpty, "another account on this phone sees none of hers")
        other.drafts.keep(SetDraft(title: "Invented other"))

        let (back, _) = TestApp.make(server, account: .student(), defaults: defaults)
        #expect(back.drafts.drafts.map(\.id) == [model.draft.id], "a sign-out keeps them for her")
    }

    @Test func deletingTheAccountDeletesItsDrafts() async throws {
        let defaults = TestApp.freshDefaults()
        let (server, _, app) = Self.appWithPhone(Self.written(), defaults: defaults)
        let (other, _) = TestApp.make(server, account: .admin, defaults: defaults)
        other.drafts.keep(SetDraft(title: "Invented other"))
        server["DELETE /api/me"] = .ok(#"{"status":"deleted"}"#)
        try await app.deleteAccount(password: "invented-password")
        #expect(app.drafts.drafts.isEmpty)
        #expect(defaults.data(forKey: WriteDraftStore.key(for: "a1")) == nil)
        let (back, _) = TestApp.make(server, account: .student(), defaults: defaults)
        #expect(back.drafts.drafts.isEmpty, "the account is gone, and so are its drafts")
        #expect(defaults.data(forKey: WriteDraftStore.key(for: "a2")) != nil, "another account's drafts stay")
    }

    @Test func clearingADraftForgetsItAndDiscardingRemovesIt() throws {
        let defaults = TestApp.freshDefaults()
        let (_, model, app) = Self.appWithPhone(SetDraft(), defaults: defaults)
        model.edit { $0.title = "Invented Sleep" }
        #expect(app.drafts.drafts.count == 1)
        model.edit { $0.title = "" }
        #expect(app.drafts.drafts.isEmpty, "a draft with nothing in it is not kept")
        model.edit { $0.title = "Invented Sleep" }
        model.discard()
        let relaunched = WriteDraftStore(defaults: defaults)
        relaunched.open(accountID: "a1")
        #expect(relaunched.drafts.isEmpty)
        #expect(defaults.data(forKey: WriteDraftStore.key(for: "a1")) == nil)
    }

    @Test func theNewestDraftIsListedFirst() throws {
        let store = WriteDraftStore(defaults: TestApp.freshDefaults())
        store.open(accountID: "a1")
        store.keep(SetDraft(title: "Invented first"))
        store.keep(SetDraft(title: "Invented second"))
        #expect(store.drafts.map(\.title) == ["Invented second", "Invented first"])
        #expect(WriteWording.name(SetDraft()) == "Untitled set")
    }

    // MARK: Helpers

    enum Mistake: CaseIterable {
        case noQuestionText
        case nothingMarked
        case rightChoiceBlank
        case oneChoice
    }

    /// A question that is right apart from `mistake`.
    private static func fill(_ question: inout QuestionDraft, mistake: Mistake) {
        question.ask = mistake == .noQuestionText ? "" : "Which habit helps sleep?"
        for (position, text) in ["A regular bedtime", "An evening nap", "Coffee at night", "A late workout"].enumerated() {
            question.choices[position].text = text
        }
        question.right = 0
        if mistake == .nothingMarked { question.right = nil }
        if mistake == .rightChoiceBlank { question.choices[0].text = " " }
        if mistake == .oneChoice {
            for position in 1..<question.choices.count { question.choices[position].text = "" }
        }
    }

    /// Two written questions: a single-answer one with an explanation, and a true-or-false one without.
    static func written(title: String = "Invented Sleep") -> SetDraft {
        var draft = SetDraft(title: title)
        var single = QuestionDraft()
        single.ask = "Which habit helps sleep?"
        single.choices = ["A regular bedtime", "An evening nap", "Coffee at night"].map { QuestionDraft.Choice(text: $0) }
        single.right = 0
        single.explanation = "A steady schedule sets the body clock."
        var trueFalse = QuestionDraft()
        trueFalse.kind = .trueFalse
        trueFalse.ask = "Naps at 6 PM make it easier to fall asleep."
        trueFalse.right = 1
        draft.questions = [single, trueFalse]
        return draft
    }

    private static func parsed(_ file: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
    }

    private static func app(_ draft: SetDraft = SetDraft()) -> (StubServer, WriteModel) {
        let (server, model, _) = appWithPhone(draft)
        return (server, model)
    }

    /// A model on course c1. The check answers as the real import check does, and an import files the set.
    private static func appWithPhone(_ draft: SetDraft, defaults: UserDefaults = TestApp.freshDefaults()) -> (StubServer, WriteModel, AppModel) {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(StudyBodies.course()),
            "POST /api/imports": StubServer.Reply(status: 201, body: ImportModelTests.imported()),
        ])
        let (app, _) = TestApp.make(server, account: .student(), defaults: defaults)
        app.drafts.keep(draft)
        let model = WriteModel(app: app, draft: draft)
        return (server, model, app)
    }

    /// Saves with the check answering as the real import check does for the draft as it stands.
    private static func save(_ model: WriteModel, on server: StubServer) async {
        let report = ImportChecker.report(for: model.draft.file())
        let body = (try? JSONEncoder().encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        server["POST /api/imports/check"] = .ok(body)
        await model.save()
    }

    private static func importBody(_ server: StubServer) throws -> [String: Any] {
        let request = server.requests.last { $0.httpMethod == "POST" && $0.url?.path() == "/api/imports" }
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
