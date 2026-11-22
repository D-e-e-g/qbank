import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// Make questions against recordings of the server's real routes and background runner, with the
/// server's own stand-in for Claude: each call sends what the recorded request sent, and each
/// recorded response decodes into the models.
@Suite("Contract: make questions")
struct MakeQuestionsContractTests {
    static let course = "c0000000-0000-4000-8000-000000000401"
    static let week4 = "f0000000-0000-4000-8000-000000000401"
    static let reference = "5e700000-0000-4000-8000-000000000401"
    static let notesJob = "a0b00000-0000-4000-8000-000000000401"
    static let copyJob = "a0b00000-0000-4000-8000-000000000403"
    static let stoppedJob = "a0b00000-0000-4000-8000-000000000404"

    // MARK: Who may make questions

    @Test func statusForAnAccountThatMayMakeQuestions() async throws {
        let fixture = try Fixture.load("question-maker")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let status = try await client.questionMakerStatus()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(status.available)
        #expect(status.reason == nil)
        #expect(status.dailyLimit == 4)
        #expect(status.nextAvailableAt == nil)
        #expect(status.defaultLevel == .exam)
        #expect(status.sampleSize == 5)
        #expect(status.range(of: .exam) == .init(level: .exam, minCount: 10, maxCount: 15, defaultCount: 15))
        #expect(status.range(of: .board) == .init(level: .board, minCount: 12, maxCount: 16, defaultCount: 15))
        #expect(status.limits == .init(photos: 20, photoBytes: 3_750_000, fileBytes: 20_000_000, textCharacters: 400_000))
        #expect(status.imageTypes.contains("image/jpeg"))
        #expect(status.fileTypes == ["application/pdf", "text/plain", "text/markdown"])
    }

    /// Every account may ask; the answer says why not in a sentence to show as it is.
    @Test(arguments: [
        ("question-maker-not-allowed", "Making questions is not available on this account. Import works on every account."),
        ("question-maker-not-set-up", "Making questions is not set up yet."),
        ("question-maker-daily-limit", "You have started 4 sets in the last 24 hours, the most for one day."),
    ])
    func statusSaysWhyNot(name: String, reason: String) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let status = try await client.questionMakerStatus()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(!status.available)
        #expect(status.reason == reason)
        let next = fixture.response.body["nextAvailableAt"]?.stringValue
        #expect(status.nextAvailableAt == next.flatMap(QBankJSON.parseDate))
    }

    /// The job routes refuse with a code and a sentence to show as it is.
    @Test(arguments: [
        ("question-jobs-not-allowed", ServerError.Code.notAllowed),
        ("question-jobs-not-set-up", .notSetUp),
    ])
    func jobRoutesRefuseAccountsAndServersThatCannot(name: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.questionJobs() }
        try expectRequest(transport.requests.first, matches: fixture)
        try Self.expect(error, is: fixture, code: code)
    }

    // MARK: Starting a set

    @Test func notesStartASetMeasuredAgainstHerReferenceSet() async throws {
        let fixture = try Fixture.load("question-job-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.startQuestionJob(
            NewQuestionJob(
                courseID: Self.course, folderID: Self.week4, materialKind: .notes,
                text: "Invented lecture notes for week 4.\nSlide 1: invented topics for a test.",
                level: .exam, count: 10, referenceSetID: Self.reference, examTwins: true
            ))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.id == Self.notesJob)
        #expect(job.status == .running)
        #expect(job.currentStep?.key == .read)
        #expect(job.reference == .init(id: Self.reference, title: "Invented exam review"))
        #expect(job.folder == .init(id: Self.week4, name: "Week 4"))
    }

    @Test func aFileStartsASetInANewFolderSheNames() async throws {
        let fixture = try Fixture.load("question-job-file-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.startQuestionJob(
            NewQuestionJob(
                courseID: Self.course, folderName: "Week 5", materialKind: .notes,
                file: .init(name: "Week 5 notes.md", mediaType: "text/markdown", data: Data("# Invented week 5 notes\n\n- Invented topic for a test.\n".utf8)),
                level: .course, count: 12, examTwins: false
            ))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.folder == .init(id: nil, name: "Week 5"))
        #expect(job.level == .course)
        #expect(!job.examTwins)
        #expect(job.steps.map(\.key) == [.read, .samples, .review, .write, .check, .file])
    }

    @Test func photosOfPracticeQuestionsStartACopy() async throws {
        let fixture = try Fixture.load("question-job-copy-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let sent = fixture.request.body?["material"]?["images"]?.arrayValue ?? []
        let images = sent.compactMap { $0["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } }.map {
            NewQuestionJob.Image(mediaType: "image/jpeg", data: $0)
        }
        #expect(images.count == 2)
        let job = try await client.startQuestionJob(
            NewQuestionJob(
                courseID: Self.course, folderID: Self.week4, materialKind: .questions, images: images, examTwins: true
            ))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.id == Self.copyJob)
        #expect(job.materialKind == .questions)
        #expect(job.count == nil)
        #expect(job.photoCount == 2)
    }

    @Test func pastTheDailyLimitTheServerSaysWhen() async throws {
        let fixture = try Fixture.load("question-job-daily-limit")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.startQuestionJob(
                NewQuestionJob(
                    courseID: Self.course, materialKind: .notes,
                    text: "Invented lecture notes for week 4.\nSlide 1: invented topics for a test.",
                    level: .exam, count: 15, examTwins: true
                ))
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try Self.expect(error, is: fixture, code: .dailyLimit)
    }

    // MARK: Her five samples

    @Test func aSetWaitsForHerCheckOfTheSamples() async throws {
        let fixture = try Fixture.load("question-job-samples")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.questionJob(id: Self.notesJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .waiting)
        #expect(job.waitingFor == .samples)
        #expect(job.currentStep == .init(key: .review, label: "Your check", state: .waiting))
        #expect(job.steps.map(\.label) == ["Read your material", "Write 5 samples", "Your check", "Write the rest", "Blind check", "Exam twins", "File the set"])
        #expect(job.course == .init(id: Self.course, code: "NURS 310", title: "Invented Mental Health"))
        // The job's times come in Postgres's own text, not ISO 8601.
        let created = try #require(fixture.response.body["createdAt"]?.stringValue)
        #expect(!created.contains("T"))
        #expect(job.createdAt == QBankJSON.parseDate(created))
        #expect(job.finishedAt == nil)
    }

    @Test func samplesReadAsQuestionsToPractice() async throws {
        let fixture = try Fixture.load("question-samples")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let samples = try await client.questionSamples(jobID: Self.notesJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(samples.round == 1)
        #expect(samples.note == nil)
        #expect(samples.canRevise)
        #expect(samples.questions.map(\.publicID) == ["A01", "A02", "A03", "A04", "A05"])
        #expect(samples.questions.map(\.position) == [1, 2, 3, 4, 5])
        let first = try #require(samples.questions.first)
        #expect(first.type == .single)
        #expect(first.clinicalJudgmentStep == "Analyze cues")
        guard case .single(let options) = first.body else {
            Issue.record("not a single-answer body: \(first.body)")
            return
        }
        #expect(options.count == 4)
        #expect(options.map(\.isCorrect) == [true, false, false, false])
    }

    @Test func herNotesOnOneSampleAreSentAndTheRedoSaysWhatChanged() async throws {
        let revise = try Fixture.load("question-samples-revise")
        let revised = try Fixture.load("question-samples-revised")
        let transport = try FixtureTransport([revise, revised])
        let (client, _) = TestClient.make(transport)
        let job = try await client.reviseSamples(jobID: Self.notesJob, changes: [SampleChange(questionID: "A02", note: "Make it about walking.")])
        try expectRequest(transport.requests.first, matches: revise)
        #expect(job.status == .running)
        let samples = try await client.questionSamples(jobID: Self.notesJob)
        try expectRequest(transport.requests.last, matches: revised)
        #expect(samples.round == 2)
        #expect(samples.note == "I rewrote A02 around the walk, as you asked.")
        #expect(samples.questions[1].stem.contains("after a walk"))
    }

    @Test func acceptingTheSamplesSendsHerWords() async throws {
        let fixture = try Fixture.load("question-samples-accept")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.acceptSamples(jobID: Self.notesJob, words: "Sample 3: Make the stem about day 3.")
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .running)
        #expect(job.waitingFor == nil)
    }

    @Test func theResultOnlyComesOnceTheSetIsFiled() async throws {
        let fixture = try Fixture.load("question-result-not-finished")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.questionResult(jobID: Self.notesJob) }
        try expectRequest(transport.requests.first, matches: fixture)
        try Self.expect(error, is: fixture, code: .wrongStep)
    }

    // MARK: The finished set

    @Test func aFinishedSetNamesItsSets() async throws {
        let fixture = try Fixture.load("question-job-done")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.questionJob(id: Self.notesJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .done)
        #expect(job.step == .done)
        #expect(job.steps.allSatisfy { $0.state == .done })
        #expect(job.sets.map(\.kind) == [.practice, .exam])
        #expect(job.finishedAt != nil)
    }

    @Test func theResultSaysWhereTheSetWentAndWhatTheBlindCheckDid() async throws {
        let fixture = try Fixture.load("question-result")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let result = try await client.questionResult(jobID: Self.notesJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(result.set.title == "Week 4 - Set 1: Invented topics")
        #expect(result.set.folderID == Self.week4)
        #expect(result.set.folderName == "Week 4")
        #expect(result.set.questionCount == 10)
        #expect(result.examSet?.title == "Week 4 - Set 1 exam: Invented topics")
        #expect(result.examSet?.folderID == Self.week4)
        #expect(result.blindCheck?.passed == 10)
        #expect(result.blindCheck?.questions.count == 10)
        #expect(result.blindCheck?.questions.allSatisfy { $0.outcome == .passed } == true)
        #expect(result.examBlindCheck?.passed == 10)
        #expect(result.suggestedAnswers.isEmpty)
    }

    // MARK: Copies from photos

    @Test func aCopyWaitsForHerCheck() async throws {
        let fixture = try Fixture.load("question-job-copies")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.questionJob(id: Self.copyJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .waiting)
        #expect(job.waitingFor == .copies)
        #expect(job.steps.map(\.label) == ["Copy the questions", "Your check", "Exam twins", "File the set"])
    }

    @Test func copiesSayWhereEachAnswerCameFrom() async throws {
        let fixture = try Fixture.load("question-copies")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let copies = try await client.questionCopies(jobID: Self.copyJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(copies.title == "Invented quiz")
        #expect(copies.photoCount == 2)
        #expect(copies.questions.map(\.id) == ["P01", "P02", "P03"])
        #expect(copies.questions.map(\.photo) == [1, 1, 2])
        #expect(copies.questions.map(\.answerFrom) == [.photo, .photo, .suggested])
        #expect(copies.questions.map(\.explanationsFrom) == [.photo, .qbank, .qbank])
        #expect(copies.questions.map(\.question.type) == [.single, .sata, .single])
        #expect(copies.questions.map(\.question.publicID) == ["P01", "P02", "P03"])
        // The set file form she can fix and send back: options at the top, the answer marked ok.
        let file = try #require(copies.questions.last?.file)
        #expect(file["id"] == .string("P03"))
        #expect(file["options"]?[0]?["ok"] == .bool(true))
        #expect(copies.unreadable == [.init(photo: 2, reason: "The bottom of photo 2 is blurry.")])
    }

    @Test func keptCopiesGoBackInHerOrderWithHerAnswer() async throws {
        let fixture = try Fixture.load("question-copies-accept")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let answered = try #require(fixture.request.body?["keep"]?[1]?["question"])
        let job = try await client.acceptCopies(jobID: Self.copyJob, keep: [KeptCopy(id: "P01"), KeptCopy(id: "P03", question: answered)])
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .running)
        // Her answer, B, is the one marked ok.
        #expect(answered["options"]?.arrayValue?.map { $0["ok"] } == [nil, .bool(true), nil, nil])
    }

    @Test func aFixTheImportCheckRefusesIsSaidInItsWords() async throws {
        let fixture = try Fixture.load("question-copies-accept-invalid")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let broken = try #require(fixture.request.body?["keep"]?[0]?["question"])
        let error = await #expect(throws: QBankError.self) {
            try await client.acceptCopies(jobID: Self.copyJob, keep: [KeptCopy(id: "P01", question: broken)])
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try Self.expect(error, is: fixture, code: .invalidRequest)
    }

    @Test func copiedQuestionsHaveNoBlindCheckAndNameTheSuggestedAnswers() async throws {
        let fixture = try Fixture.load("question-result-copies")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let result = try await client.questionResult(jobID: Self.copyJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(result.blindCheck == nil)
        #expect(result.suggestedAnswers == ["P03"])
        #expect(result.set.questionCount == 2)
        #expect(result.examSet?.questionCount == 2)
        #expect(result.examBlindCheck?.passed == 2)
    }

    // MARK: Her sets, and stopping one

    @Test func herSetsAreNewestFirst() async throws {
        let fixture = try Fixture.load("question-jobs")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let jobs = try await client.questionJobs()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(jobs.map(\.status) == [.cancelled, .done, .waiting, .done])
        #expect(jobs.map(\.materialKind) == [.notes, .questions, .notes, .notes])
    }

    @Test func stoppingASetCancelsIt() async throws {
        let fixture = try Fixture.load("question-job-cancel")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let job = try await client.cancelQuestionJob(id: Self.stoppedJob)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(job.status == .cancelled)
        #expect(job.steps.contains { $0.state == .cancelled })
        #expect(job.failure == nil)
    }

    @Test(arguments: [
        ("question-job-cancel-finished", ServerError.Code.wrongStep),
        ("question-job-not-found", "not_found"),
    ])
    func aSetThatEndedOrIsNotHersIsRefused(name: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/")[2])
        let error = await #expect(throws: QBankError.self) {
            if fixture.request.method == "POST" {
                _ = try await client.cancelQuestionJob(id: id)
            } else {
                _ = try await client.questionJob(id: id)
            }
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try Self.expect(error, is: fixture, code: code)
    }

    /// A refusal keeps the server's code, its status, and its sentence as it is.
    static func expect(_ error: QBankError?, is fixture: Fixture, code: ServerError.Code, sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard case .server(let server)? = error else {
            Issue.record("not a server error: \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(server.code == code, sourceLocation: sourceLocation)
        #expect(server.status == fixture.response.status, sourceLocation: sourceLocation)
        #expect(server.message == fixture.response.body["message"]?.stringValue, sourceLocation: sourceLocation)
    }
}

private extension JSONValue {
    /// The element of an array at `index`, or nil.
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
