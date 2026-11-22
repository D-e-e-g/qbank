import Foundation
import QBankKit
import Testing
@testable import QBank

/// Make questions end to end against the fake server's question maker, which follows the server's
/// rules and words, and the bodies the app sends, against a stub.
@MainActor
struct MakeQuestionsTests {
    static let writingJob = "a0b10000-0000-4000-8000-000000000001"
    static let copyJob = "a0b10000-0000-4000-8000-000000000002"

    /// The app signed in on the fake server, as the maker or as a student it does not allow.
    static func app(maker: Bool = true, setUp: Bool = true, online: Bool = true) -> AppModel {
        let server = FakeQBankServer(signedIn: true, as: maker ? FakeQBankServer.maker : FakeQBankServer.student, makerIsSetUp: setUp)
        let session = maker ? FakeQBankServer.storedMakerSession() : FakeQBankServer.storedStudentSession()
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
            transport: server,
            sessionStore: InMemorySessionStore(session)
        )
        let defaults = TestApp.freshDefaults()
        return AppModel(
            client: client,
            look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)),
            storage: .memory(),
            connection: Connection(isOnline: online)
        )
    }

    // MARK: The hub

    @Test func aStudentTheServerDoesNotAllowSeesImportOnly() async {
        let hub = AddModel(app: Self.app(maker: false))
        await hub.load()
        #expect(!hub.canMake)
        #expect(hub.makeNote == "Making questions is not available on this account. Import works on every account.")
        #expect(hub.inProgress.isEmpty)
    }

    @Test func aServerNotSetUpSaysSoInItsWords() async {
        let hub = AddModel(app: Self.app(setUp: false))
        await hub.load()
        #expect(!hub.canMake)
        #expect(hub.makeNote == "Making questions is not set up yet.")
        #expect(hub.inProgress.isEmpty)
    }

    @Test func theMakerSeesHerSetsInProgressAndWhatIsLeftToday() async {
        let hub = AddModel(app: Self.app())
        await hub.load()
        #expect(hub.canMake)
        #expect(hub.makeNote == "1 of 3 sets left today")
        #expect(hub.inProgress.map(MakeWording.title) == ["Questions from your photos", "Schizophrenia and Antipsychotics"])
        #expect(hub.inProgress.map(MakeWording.progress) == ["NURS 310 · Week 3 · Questions to check", "NURS 310 · Week 4 · 9 of 15 written"])
    }

    @Test func withoutAConnectionMakeQuestionsStaysHidden() async {
        let hub = AddModel(app: Self.app(online: false))
        await hub.load()
        #expect(hub.status == nil)
        #expect(!hub.canMake)
    }

    @Test func theDailyLimitIsSaidAsTheServerSaysIt() async throws {
        let app = Self.app()
        let hub = AddModel(app: app)
        await hub.load()
        let make = try await Self.pasted(app, status: hub.status)
        #expect(await make.start() != nil, "the third set today")
        await hub.load()
        #expect(!hub.canMake)
        #expect(hub.makeNote == "You have started 3 sets in the last 24 hours, the most for one day.")
        #expect(await make.start() == nil)
        #expect(make.problem == "You have started 3 sets in the last 24 hours, the most for one day. You can start another in 3 hours.")
    }

    @Test func aStoppedSetLeavesInProgress() async {
        let app = Self.app()
        let model = JobModel(app: app, id: Self.writingJob, pollInterval: .zero)
        #expect(await model.cancel())
        #expect(model.job?.status == .cancelled)
        let hub = AddModel(app: app)
        await hub.load()
        #expect(hub.inProgress.map(\.id) == [Self.copyJob])
    }

    // MARK: Writing from notes

    /// Her pasted notes, for her course she studied last, into Unsorted.
    static func pasted(_ app: AppModel, status: QuestionMakerStatus?) async throws -> MakeModel {
        let make = MakeModel(app: app, status: status)
        await make.load()
        make.source = .paste
        make.text = "Invented notes on antipsychotics: positive and negative symptoms, clozapine and the ANC."
        #expect(make.canGoOn)
        return make
    }

    @Test func notesAreWrittenAfterSheChecksFiveSamples() async throws {
        let app = Self.app()
        let hub = AddModel(app: app)
        await hub.load()
        let make = try await Self.pasted(app, status: hub.status)
        let started = try #require(await make.start())
        #expect(started.status == .running)
        #expect(started.folder.name == "Unsorted")

        let model = JobModel(app: app, id: started.id, pollInterval: .zero)
        await model.follow()
        #expect(model.job?.waitingFor == .samples)
        let samples = try #require(model.samples)
        #expect(samples.questions.map(\.id) == ["A01", "A02", "A03", "A04", "A05"])
        #expect(samples.questions.map(\.position) == [1, 2, 3, 4, 5])
        #expect(model.restCount == 10)

        let third = samples.questions[2]
        model.mark(third, .change)
        #expect(!model.canRevise, "a note says what to change")
        model.notes[third.id] = "Make the stem about a client on day 3 of haloperidol."
        #expect(model.canRevise)
        await model.reviseSamples()
        #expect(model.problem == nil)
        await model.follow()
        #expect(model.samples?.round == 2)
        #expect(model.samples?.note == "Wrote them again from your notes.")
        #expect(model.verdict(third) == .notChecked, "new samples start unchecked")

        model.mark(samples.questions[0], .looksRight)
        await model.acceptSamples()
        #expect(model.job?.step == .write)
        await model.follow()
        #expect(model.job?.status == .done)
        let result = try #require(model.result)
        #expect(result.set.questionCount == 15)
        #expect(result.set.folderName == "Unsorted")
        #expect(result.examSet?.questionCount == 15)
        #expect(MakeWording.blindCheck(try #require(result.blindCheck)) == "14 of 15 passed the blind check · 1 fixed")
        #expect(MakeWording.finished(result, course: "NURS 310") == "“Unsorted Practice” · 15 questions in NURS 310, Unsorted.")

        let course = CourseModel(app: app, id: FakeQBankServer.mentalHealthID)
        await course.load()
        let unsorted = try #require(course.course?.folders.first { $0.name == "Unsorted" })
        #expect(unsorted.sets.map(\.title) == ["Unsorted Practice"], "filed where she picked")
        #expect(unsorted.examBankCount == 15)
    }

    @Test func theSetBeingWrittenGoesOnUntilItIsFiled() async throws {
        let app = Self.app()
        let model = JobModel(app: app, id: Self.writingJob, pollInterval: .zero)
        await model.load()
        let job = try #require(model.job)
        #expect(MakeWording.headline(job) == "12 of 15 written", "each read moves the fake on")
        #expect(MakeWording.fraction(job) == 0.8, "the bar beside it counts the same questions")
        #expect(job.steps.map(\.label) == ["Read your material", "Write 5 samples", "Your check", "Write the rest", "Blind check", "Exam twins", "File the set"])
        #expect(job.steps.map(\.state) == [.done, .done, .done, .current, .todo, .todo, .todo])
        await model.follow()
        #expect(model.job?.status == .done)
        #expect(model.result?.set.folderName == "Week 4", "a folder named for the set is made when it is filed")
    }

    // MARK: Copying from photos

    @Test func copiesAreCheckedThenFiled() async throws {
        let app = Self.app()
        let model = JobModel(app: app, id: Self.copyJob, pollInterval: .zero)
        await model.follow()
        let copies = try #require(model.copies)
        #expect(copies.questions.map(\.id) == ["P01", "P02", "P03"])
        #expect(copies.unreadable == [QuestionCopies.Unreadable(photo: 2, reason: "The bottom of photo 2 is blurry.")])
        let first = copies.questions[0], second = copies.questions[1], third = copies.questions[2]
        #expect(MakeWording.answer(first, chosen: nil) == "Answer from the photo: A")
        #expect(MakeWording.answer(third, chosen: nil) == "No answer in the photo · QBank suggests A, check it")

        model.setAnswer(first, [1])
        #expect(model.answer(first) == [1])
        #expect(MakeWording.answer(first, chosen: model.answer(first)) == "Your answer: B")
        model.setAnswer(first, MakeWording.key(first.question))
        #expect(model.answer(first) == nil, "the answer copied clears hers")
        model.setSkipped(second, true)
        #expect(model.keptCount == 2)

        await model.acceptCopies()
        #expect(model.problem == nil)
        #expect(model.job?.step == .twins)
        await model.follow()
        let result = try #require(model.result)
        #expect(result.set.questionCount == 2)
        #expect(result.blindCheck == nil, "she checked them herself")
        #expect(result.suggestedAnswers == ["P03"])
    }

    @Test func aWrongAnswerSheSetsIsRefusedInTheCheckersWords() async throws {
        let app = Self.app()
        let model = JobModel(app: app, id: Self.copyJob, pollInterval: .zero)
        await model.follow()
        let first = try #require(model.copies?.questions.first)
        model.setAnswer(first, [0, 1])
        await model.acceptCopies()
        #expect(model.problem?.contains("exactly one option") == true)
        #expect(model.job?.waitingFor == .copies, "still waiting for her")
    }

    @Test func herAnswerGoesBackInTheSetFile() {
        let file = JSONValue.object([
            "id": .string("P01"),
            "options": .array([
                .object(["t": .string("A"), "ok": .bool(true)]),
                .object(["t": .string("B")]),
                .object(["t": .string("C"), "why": .string("Because.")]),
            ]),
        ])
        let fixed = JobModel.file(file, answering: [2])
        #expect(
            fixed
                == .object([
                    "id": .string("P01"),
                    "options": .array([
                        .object(["t": .string("A")]),
                        .object(["t": .string("B")]),
                        .object(["t": .string("C"), "why": .string("Because."), "ok": .bool(true)]),
                    ]),
                ]))
    }

    // MARK: What she picks

    @Test func theLevelKeepsTheCountInItsRange() async {
        let app = Self.app()
        let hub = AddModel(app: app)
        await hub.load()
        let make = MakeModel(app: app, status: hub.status)
        #expect(make.level == .exam)
        #expect(make.countRange == 10...15)
        #expect(make.count == 15)
        make.referenceSetID = "set"
        make.level = .board
        #expect(make.countRange == 12...16)
        #expect(make.referenceSetID == nil, "a reference set is only for exam level")
        make.count = 16
        make.level = .exam
        #expect(make.count == 15)
    }

    @Test func referencesAreHerPracticeSetsByCourse() async throws {
        let app = Self.app()
        let make = MakeModel(app: app, status: nil)
        await make.loadReferences()
        let groups = try #require(make.references)
        #expect(groups.map(\.title) == ["NURS 310", "NURS 220"])
        let first = try #require(groups.first?.sets.first)
        make.referenceSetID = first.id
        #expect(make.referenceTitle == first.title)
    }

    @Test func notesAreSentWithTheirLevelCountAndReference() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(StudyBodies.course(id: "c1")),
            "POST /api/question-jobs": StubServer.Reply(status: 202, body: Self.job()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let make = MakeModel(app: app, status: nil)
        await make.load()
        make.source = .paste
        make.text = "  Invented notes.  "
        make.referenceSetID = "ref1"
        make.destination.folder = .new
        make.destination.newFolderName = "Week 4"
        #expect(await make.start()?.id == "job1")
        let body = try Self.body(server, "/api/question-jobs")
        #expect(body["courseId"] as? String == "c1")
        #expect(body["folderName"] as? String == "Week 4")
        #expect(body["folderId"] == nil)
        #expect(body["materialKind"] as? String == "notes")
        #expect(body["material"] as? [String: String] == ["text": "Invented notes."])
        #expect(body["level"] as? String == "exam")
        #expect(body["count"] as? Int == 15)
        #expect(body["referenceSetId"] as? String == "ref1")
        #expect(body["examTwins"] as? Bool == true)
    }

    @Test func photosOfQuestionsAreCopiedWithoutALevel() async throws {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(StudyBodies.course(id: "c1")),
            "POST /api/question-jobs": StubServer.Reply(status: 202, body: Self.job()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let make = MakeModel(app: app, status: nil)
        await make.load()
        make.holding = .questions
        make.add(photo: Data([0xFF, 0xD8, 0xFF, 0x01]))
        make.examTwins = false
        #expect(make.copies)
        #expect(make.photoLine == "1 photo · quiz, worksheet, or review book pages, up to 20.")
        _ = await make.start()
        let body = try Self.body(server, "/api/question-jobs")
        #expect(body["materialKind"] as? String == "questions")
        #expect(body["material"] as? [String: [[String: String]]] == ["images": [["mediaType": "image/jpeg", "data": "/9j/AQ=="]]])
        #expect(body["level"] == nil)
        #expect(body["count"] == nil)
        #expect(body["examTwins"] as? Bool == false)
    }

    @Test func herNotesOnTheSamplesAreSentAsTheServerTakesThem() async throws {
        let server = StubServer([
            "GET /api/question-jobs/job1": .ok(Self.job(status: "waiting", waitingFor: "samples")),
            "GET /api/question-jobs/job1/samples": .ok(Self.samples),
            "POST /api/question-jobs/job1/samples/revise": StubServer.Reply(status: 202, body: Self.job()),
            "POST /api/question-jobs/job1/samples/accept": StubServer.Reply(status: 202, body: Self.job()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let model = JobModel(app: app, id: "job1")
        await model.load()
        let question = try #require(model.samples?.questions.last)
        model.mark(question, .change)
        model.notes[question.id] = " Ask about day 3. "
        await model.reviseSamples()
        let revise = try Self.body(server, "/api/question-jobs/job1/samples/revise")
        #expect(revise["changes"] as? [[String: String]] == [["questionId": "A02", "note": "Ask about day 3."]])
        #expect(revise["note"] == nil)

        await model.acceptSamples()
        let accept = try Self.body(server, "/api/question-jobs/job1/samples/accept")
        #expect(accept["words"] as? String == "Sample 2: Ask about day 3.")
    }

    @Test func aSampleOpensInTheRunnerAndHerAnswerIsNeverSent() async throws {
        let server = StubServer(["GET /api/question-jobs/job1/samples": .ok(Self.samples)])
        let (app, _) = TestApp.make(server, account: .student())
        let model = PracticeModel(app: app, source: .sample(jobID: "job1", sampleID: "A02"), courseID: "c1", title: "Sample 2")
        await model.load()
        #expect(model.phase == .answering)
        #expect(model.questions.map(\.id) == ["A02"])
        model.update(.single(0))
        await model.check()
        #expect(model.attempts.first?.score?.status == .correct)
        #expect(!server.calls.contains { $0.hasPrefix("POST /api/attempts") })
    }

    // MARK: Words

    @Test func wording() {
        #expect(MakeWording.allowance(started: 0, limit: 3) == "3 of 3 sets left today")
        #expect(MakeWording.allowance(started: 4, limit: 3) == "0 of 3 sets left today")
        #expect(MakeWording.writingTime(count: 15) == "About 20 minutes to write")
        #expect(MakeWording.writingTime(count: 10) == "About 15 minutes to write")
        #expect(MakeWording.letters([2, 0, 3]) == "A, C, D")
        #expect(MakeWording.letters([]) == nil)
        let check = QuestionResult.BlindCheck(passed: 15, fixed: 0, removed: 0, questions: [], changeList: "")
        #expect(MakeWording.blindCheck(check) == "15 of 15 passed the blind check")
        let mixed = QuestionResult.BlindCheck(passed: 12, fixed: 2, removed: 1, questions: [], changeList: "")
        #expect(MakeWording.blindCheck(mixed) == "12 of 15 passed the blind check · 2 fixed, 1 removed")
    }

    // MARK: Bodies

    static func body(_ server: StubServer, _ path: String) throws -> [String: Any] {
        let request = try #require(server.requests.last { $0.httpMethod == "POST" && $0.url?.path() == path })
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func job(status: String = "running", waitingFor: String? = nil) -> String {
        #"""
        {"id":"job1","status":"\#(status)","step":"\#(waitingFor == nil ? "read" : "review")","waitingFor":\#(waitingFor.map { "\"\($0)\"" } ?? "null"),
         "steps":[{"key":"read","label":"Read your material","state":"current","done":null,"total":null}],
         "course":{"id":"c1","code":"NURS 101","title":"Invented"},"folder":{"id":null,"name":"Unsorted"},
         "materialKind":"notes","level":"exam","reference":null,"count":15,"examTwins":true,"title":null,"photoCount":0,"sets":[],
         "createdAt":"2026-10-15T12:00:00.000Z","updatedAt":"2026-10-15T12:00:00.000Z","finishedAt":null,"failure":null,"warnings":[],
         "usage":{"calls":0,"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}}
        """#
    }

    static let samples = #"""
        {"round":1,"note":null,"canRevise":true,"questions":[
         {"id":"A01","type":"single","topic":"Invented one","cj":"Take action","need":null,"difficulty":null,"stem":"Stem.","ask":"Which?",
          "rationale":"Because.","takeaway":"Remember.","body":{"options":[{"t":"Right","ok":true},{"t":"Wrong"}]},"table":null,"images":[],
          "terms":[],"source":null,"twinOf":null},
         {"id":"A02","type":"single","topic":"Invented two","cj":null,"need":null,"difficulty":2,"stem":"Stem two.","ask":"Which?",
          "rationale":"Because.","takeaway":"Remember.","body":{"options":[{"t":"Right","ok":true},{"t":"Wrong"}]},"table":null,"images":[],
          "terms":[{"key":"anc","term":"ANC","meaning":"Absolute neutrophil count."}],"source":"Slide 4","twinOf":null}
        ]}
        """#
}
