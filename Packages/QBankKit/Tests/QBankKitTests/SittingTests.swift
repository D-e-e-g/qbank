import Foundation
import Testing
@testable import QBankKit

@Suite("A practice set's sitting")
struct SittingTests {
    private static func set(_ name: String) throws -> PracticeSet {
        try Fixture.load(name).decodeBody(PracticeSet.self)
    }

    private static func rows(_ name: String) throws -> [PracticeSetSummary] {
        try Fixture.load(name).decodeBody(CourseDetail.self).folders.flatMap(\.sets)
    }

    private static func pending(
        _ question: String, at seconds: Double = 0, response: AnswerResponse = .single(choice: 0), fromReview: Bool = false, exam: String? = nil
    ) -> PendingAttempt {
        PendingAttempt(
            submission: AttemptSubmission(clientAttemptID: "waiting-\(question)", questionID: question, response: response, studySessionID: exam, fromReview: fromReview),
            courseID: "c1", queuedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        )
    }

    // MARK: Reading it

    @Test func aSetWithNothingToContinueHasNoSitting() throws {
        #expect(try Self.set("practice-set").sitting == nil)
        #expect(try Self.set("practice-set-after-start-over").sitting == nil)
        #expect(try Self.set("review-practice").sitting == nil)
    }

    @Test func aSetMidwayBeforeSittingsContinuesWithNoIdYet() throws {
        let set = try Self.set("practice-set-sitting-day-one")
        let sitting = try #require(set.sitting)
        #expect(sitting.id == nil)
        #expect(sitting.startedAt == nil)
        #expect(sitting.answeredQuestionIDs == [set.questions[0].id])
        #expect(sitting.answers.map(\.clientAttemptID) == ["aaaaaaaa-1111-4111-8111-111111111111"])
    }

    @Test func aSavedSittingCarriesEachAnswersVerdict() throws {
        let set = try Self.set("practice-set-sitting")
        let sitting = try #require(set.sitting)
        #expect(sitting.id != nil)
        #expect(sitting.startedAt != nil)
        #expect(sitting.answeredQuestionIDs == [set.questions[0].id, set.questions[1].id])
        let feedback = Feedback(try #require(sitting.answers.first))
        #expect(feedback.score == Score(points: 1, maxPoints: 1, status: .correct, answered: true))
        #expect(feedback.label == "Correct")
    }

    @Test func aRowSaysWhatItWouldContinue() throws {
        #expect(try Self.rows("course-sitting-day-one").first?.sitting == .init(answeredCount: 1))
        #expect(try Self.rows("course-sitting").first?.sitting == .init(answeredCount: 2))
        let after = try #require(try Self.rows("course-after-start-over").first)
        #expect(after.sitting == nil)
        #expect(after.answeredCount == 2, "Start over leaves every answer")
    }

    @Test func aCopySavedBeforeSittingsAndFieldsAddedLaterStillRead() throws {
        let question = #"{"id":"q1","publicId":"Q1","position":1,"type":"single","topic":"","cj":null,"stem":"S","ask":"A","rationale":"R","takeaway":"T","terms":[],"body":{"options":[{"t":"A","ok":true}]}}"#
        let older = #"{"id":"s1","courseId":"c1","title":"T","weekLabel":"W","kind":"practice","questions":[\#(question)]}"#
        #expect(try QBankJSON.decoder.decode(PracticeSet.self, from: Data(older.utf8)).sitting == nil)

        let answer = #"{"clientAttemptId":"a1","questionId":"q1","status":"correct","points":1,"maxPoints":1,"guessed":false,"answeredAt":"2026-11-01T00:00:00.000Z","inReview":false,"label":"Correct","pointsText":null,"ruleText":null,"response":{"type":"hotspot","x":3},"shuffle":{"kind":"later"},"addedLater":1}"#
        let newer = #"{"id":"s1","courseId":"c1","title":"T","weekLabel":"W","kind":"practice","questions":[\#(question)],"sitting":{"id":null,"startedAt":null,"answeredQuestionIds":["q1"],"answers":[\#(answer)],"addedLater":true}}"#
        let sitting = try #require(try QBankJSON.decoder.decode(PracticeSet.self, from: Data(newer.utf8)).sitting)
        #expect(sitting.answers.first?.questionID == "q1", "a response or shuffle in a shape this version does not know is not read")

        let olderRow = #"{"id":"s","title":"t","description":"","questionCount":2,"importedAt":"2026-10-12T09:00:00.000Z","activeSince":"2026-10-12T09:00:00.000Z","status":"imported","canRestore":false,"answeredCount":1,"fullyRightCount":0,"lastAnsweredAt":null,"questionIds":[]}"#
        #expect(try QBankJSON.decoder.decode(PracticeSetSummary.self, from: Data(olderRow.utf8)).sitting == nil)
    }

    @Test func theSittingSurvivesTheCopyOnThePhone() throws {
        let set = try Self.set("practice-set-sitting")
        let data = try QBankJSON.encoder.encode(set)
        #expect(try QBankJSON.decoder.decode(PracticeSet.self, from: data).sitting == set.sitting)
    }

    // MARK: Start over

    @Test func startOverEndsTheSittingOnceThenChangesNothing() async throws {
        let first = try Fixture.load("practice-set-start-over")
        let second = try Fixture.load("practice-set-start-over-nothing")
        let transport = try FixtureTransport([first, second])
        let (client, _) = TestClient.make(transport)
        let id = first.request.path.split(separator: "/").dropLast().last.map(String.init)!
        #expect(try await client.startPracticeSetOver(id: id))
        try expectRequest(transport.requests.first, matches: first)
        #expect(try await client.startPracticeSetOver(id: id) == false)
    }

    @Test func startOverOnASetThatIsNotHersIsRefused() async throws {
        let fixture = try Fixture.load("practice-set-start-over-not-found")
        let (client, _) = TestClient.make(try FixtureTransport([fixture]))
        let id = fixture.request.path.split(separator: "/").dropLast().last.map(String.init)!
        let error = await #expect(throws: QBankError.self) { try await client.startPracticeSetOver(id: id) }
        #expect(error?.serverCode == .requestRefused)
    }

    // MARK: What she sends

    @Test func aReviewAnswerSaysSoAndAPracticeOneSaysNothingNew() async throws {
        let review = try Fixture.load("attempt-from-review")
        let practice = try Fixture.load("attempt-opens-sitting")
        let transport = try FixtureTransport([review, practice])
        let (client, _) = TestClient.make(transport)
        for (fixture, fromReview) in [(review, true), (practice, false)] {
            let request = try #require(fixture.request.body)
            let id = try #require(request["clientAttemptId"]?.stringValue)
            let question = try #require(request["questionId"]?.stringValue)
            _ = try await client.recordAttempt(AttemptSubmission(
                clientAttemptID: id, questionID: question, response: .single(choice: 0),
                shuffle: .options(order: [1, 0, 2]), fromReview: fromReview
            ))
        }
        try expectRequest(transport.requests.first, matches: review)
        try expectRequest(transport.requests.last, matches: practice)
    }

    @Test func anAnswerLeftWaitingByAnOlderVersionStillReads() throws {
        let older = #"{"clientAttemptId":"a1","questionId":"q1","response":{"type":"single","choice":0},"guessed":false}"#
        let read = try QBankJSON.decoder.decode(AttemptSubmission.self, from: Data(older.utf8))
        #expect(read.fromReview == false)
        let again = try QBankJSON.decoder.decode(AttemptSubmission.self, from: QBankJSON.encoder.encode(AttemptSubmission(questionID: "q1", response: .single(choice: 0), fromReview: true)))
        #expect(again.fromReview)
    }

    // MARK: Her place on the phone

    @Test func waitingAnswersCountInTheSittingWithThePhonesScore() throws {
        let set = try Self.set("practice-set-sitting")
        let second = set.questions[1].id
        let counted = set.counting(waiting: [Self.pending(second, at: 100_000_000)])
        let sitting = try #require(counted.sitting)
        #expect(sitting.answeredQuestionIDs == [set.questions[0].id, second])
        #expect(sitting.id == set.sitting?.id)
        #expect(sitting.answers.count == 2)
        #expect(sitting.answers.last?.clientAttemptID == "waiting-\(second)")
        #expect(counted.run == .midway)
    }

    /// The server closes a sitting once it has an answer to every question, and the set is Done.
    @Test func aWaitingAnswerThatCompletesTheSittingMakesTheSetDone() throws {
        let set = try Self.set("practice-set-sitting")
        let counted = set.counting(waiting: [Self.pending(set.questions[2].id, at: 100_000_000)])
        #expect(counted.sitting == nil)
        #expect(counted.run == .done)
    }

    @Test func aSetWithNoSittingBeginsOneFromItsWaitingAnswers() throws {
        let set = try Self.set("practice-set-after-start-over")
        let counted = set.counting(waiting: [Self.pending(set.questions[0].id)])
        #expect(counted.sitting?.answeredQuestionIDs == [set.questions[0].id])
    }

    @Test func aWaitingAnswerReplacesAnEarlierOneToTheSameQuestion() throws {
        let set = try Self.set("practice-set-after-start-over")
        let id = set.questions[0].id
        let counted = set.counting(waiting: [Self.pending(id, at: 1), Self.pending(id, at: 2, response: .single(choice: 2))])
        #expect(counted.sitting?.answers.count == 1)
        #expect(counted.sitting?.answers.first?.answeredAt == Date(timeIntervalSince1970: 1_800_000_002))
    }

    @Test func reviewExamAndOtherSetsAnswersStayOutOfIt() throws {
        let set = try Self.set("practice-set-after-start-over")
        let id = set.questions[0].id
        #expect(set.counting(waiting: [Self.pending(id, fromReview: true)]).sitting == nil)
        #expect(set.counting(waiting: [Self.pending(id, exam: "e1")]).sitting == nil)
        #expect(set.counting(waiting: [Self.pending("another-set-q1")]).sitting == nil)
    }

    @Test func anAnswerFromBeforeTheSittingBeganStaysOutOfIt() throws {
        let set = try Self.set("practice-set-after-start-over")
        let earlier = Self.pending(set.questions[2].id, at: 0)
        let begun = set.counting(SittingAnswer(
            clientAttemptID: "a1", questionID: set.questions[0].id,
            feedback: Feedback(phone: Score(points: 1, maxPoints: 1, status: .correct, answered: true), type: .single),
            guessed: true, answeredAt: Date(timeIntervalSince1970: 1_800_000_100)
        ))
        #expect(begun.sitting?.answers.first?.guessed == true)
        #expect(begun.counting(waiting: [earlier]).sitting?.answeredQuestionIDs == [set.questions[0].id])
        let later = Self.pending(set.questions[2].id, at: 200)
        #expect(begun.counting(waiting: [later]).sitting?.answeredQuestionIDs == [set.questions[0].id, set.questions[2].id])
    }

    @Test func anAnswerToAQuestionNoLongerInTheSetIsNotCounted() throws {
        let set = try Self.set("practice-set-sitting")
        let answer = SittingAnswer(
            clientAttemptID: "a1", questionID: "gone",
            feedback: Feedback(phone: Score(points: 0, maxPoints: 1, status: .incorrect, answered: true), type: .single),
            guessed: false, answeredAt: .now
        )
        #expect(set.counting(answer) == set)
    }

    // MARK: Where she stands

    private static func row(json run: String?, answered: Int = 3, sitting: Int? = nil) throws -> PracticeSetSummary {
        let sitting = sitting.map { #","sitting":{"answeredCount":\#($0)}"# } ?? ""
        let run = run.map { #","run":"\#($0)""# } ?? ""
        let row = #"{"id":"s","title":"t","description":"","questionCount":12,"importedAt":"2026-10-12T09:00:00.000Z","activeSince":"2026-10-12T09:00:00.000Z","status":"imported","canRestore":false,"answeredCount":\#(answered),"fullyRightCount":0,"lastAnsweredAt":null,"questionIds":[]\#(sitting)\#(run)}"#
        return try QBankJSON.decoder.decode(PracticeSetSummary.self, from: Data(row.utf8))
    }

    /// Each run as the server sends it, on the set and on its course row: a new set, one midway
    /// with a sitting row or without one yet, one she started over, and a Done set with a retake open.
    @Test(arguments: [
        ("practice-set", "course", SetRun.new),
        ("practice-set-sitting-day-one", "course-sitting-day-one", .midway),
        ("practice-set-sitting", "course-sitting", .midway),
        ("practice-set-after-start-over", "course-after-start-over", .restarted),
        ("practice-set-done-retake", "course-done-retake", .done),
    ])
    func eachRunAsTheServerSendsIt(set: String, course: String, run: SetRun) throws {
        let practice = try Self.set(set)
        #expect(practice.run == run)
        #expect(try Self.rows(course).first { $0.id == practice.id }?.run == run)
        #expect((practice.sitting != nil) == (run == .midway), "a sitting comes exactly with Midway")
    }

    @Test(arguments: SetRun.allCases)
    func aRowAndTheSetReadTheServersRun(_ run: SetRun) throws {
        // The counts say something else on purpose: the run is what the row and the runner follow.
        #expect(try Self.row(json: run.rawValue, answered: 3, sitting: nil).run == run)
        let question = #"{"id":"q1","publicId":"Q1","position":1,"type":"single","topic":"","cj":null,"stem":"S","ask":"A","rationale":"R","takeaway":"T","terms":[],"body":{"options":[{"t":"A","ok":true}]}}"#
        let set = #"{"id":"s1","courseId":"c1","title":"T","weekLabel":"W","kind":"practice","questions":[\#(question)],"sitting":null,"run":"\#(run.rawValue)"}"#
        let read = try QBankJSON.decoder.decode(PracticeSet.self, from: Data(set.utf8))
        #expect(read.run == run)
        #expect(try QBankJSON.decoder.decode(PracticeSet.self, from: QBankJSON.encoder.encode(read)).run == run, "the copy on the phone keeps it")
        let row = try Self.row(json: run.rawValue)
        #expect(try QBankJSON.decoder.decode(PracticeSetSummary.self, from: QBankJSON.encoder.encode(row)).run == run)
    }

    /// Without `run`, from a server or a saved copy from before it, a row reads by the rule the app
    /// used then; the set itself leaves it to its row.
    @Test func aRowFromBeforeRunReadsItFromItsCounts() throws {
        #expect(try Self.row(json: nil, answered: 0).run == .new)
        #expect(try Self.row(json: nil, answered: 3, sitting: 3).run == .midway)
        #expect(try Self.row(json: nil, answered: 3).run == .restarted)
        #expect(try Self.row(json: nil, answered: 12).run == .done)
        #expect(try Self.row(json: nil, answered: 12, sitting: 1).run == .done, "Done comes first, as on the server")
        #expect(try Self.row(json: "later", answered: 3, sitting: 3).run == .midway, "a run this version does not know reads as if it were absent")
        let question = #"{"id":"q1","publicId":"Q1","position":1,"type":"single","topic":"","cj":null,"stem":"S","ask":"A","rationale":"R","takeaway":"T","terms":[],"body":{"options":[{"t":"A","ok":true}]}}"#
        let older = #"{"id":"s1","courseId":"c1","title":"T","weekLabel":"W","kind":"practice","questions":[\#(question)],"sitting":null}"#
        #expect(try QBankJSON.decoder.decode(PracticeSet.self, from: Data(older.utf8)).run == nil)
    }

    /// Bug (b): one answer on a Done set opened a sitting in the copy on the phone, so without a
    /// connection the set opened at question 2 where the server opens it at 1.
    @Test func anAnswerOnADoneSetLeavesTheCopyOnThePhoneDone() throws {
        var set = try Self.set("practice-set")
        set.run = .done
        let answer = SittingAnswer(
            clientAttemptID: "a1", questionID: set.questions[0].id,
            feedback: Feedback(phone: Score(points: 1, maxPoints: 1, status: .correct, answered: true), type: .single),
            guessed: false, answeredAt: .now
        )
        #expect(set.counting(answer) == set)
        #expect(set.counting(waiting: [Self.pending(set.questions[0].id), Self.pending(set.questions[1].id, at: 1)]) == set)
    }

    @Test(arguments: [SetRun.new, .restarted, .midway])
    func anAnswerOnASetNotDoneBeginsOrExtendsASitting(_ run: SetRun) throws {
        var set = try Self.set("practice-set")
        set.run = run
        let counted = set.counting(waiting: [Self.pending(set.questions[0].id)])
        #expect(counted.run == .midway)
        #expect(counted.sitting?.answeredQuestionIDs == [set.questions[0].id])
    }

    // MARK: Her row on the phone

    private static func row(questions: Int = 12, answered: Int, sitting: Int?, run: SetRun? = nil) -> PracticeSetSummary {
        let row = WaitingProgressTests.set("s", questions: questions, answered: answered)
        return PracticeSetSummary(
            id: row.id, title: row.title, description: row.description, questionCount: row.questionCount,
            importedAt: row.importedAt, activeSince: row.activeSince, status: row.status, canRestore: row.canRestore,
            answeredCount: row.answeredCount, fullyRightCount: row.fullyRightCount, lastAnsweredAt: row.lastAnsweredAt,
            questionIDs: row.questionIDs, importedByAgent: nil,
            sitting: sitting.map(PracticeSetSummary.Sitting.init(answeredCount:)), run: run
        )
    }

    private static func waiting(_ count: Int, from start: Int = 0, joins: Bool = true) -> WaitingProgress {
        WaitingProgress(answers: Dictionary(uniqueKeysWithValues: (start..<(start + count)).map {
            ("s-q\($0)", .init(status: .correct, answeredAt: WaitingProgressTests.day, joinsASitting: joins))
        }))
    }

    @Test func aRowsSittingCountsItsWaitingAnswers() {
        let night = Self.waiting(3, from: 7).counting(Self.row(answered: 7, sitting: 7, run: .midway))
        #expect(night.sitting?.answeredCount == 10)
        #expect(night.answeredCount == 10)
        #expect(night.run == .midway)
    }

    @Test func waitingAnswersThatFinishTheSittingMakeTheSetDone() {
        let counted = Self.waiting(5, from: 7).counting(Self.row(answered: 7, sitting: 7, run: .midway))
        #expect(counted.sitting == nil)
        #expect(counted.answeredCount == 12)
        #expect(counted.run == .done)
    }

    @Test(arguments: [SetRun.new, .restarted])
    func aSetThatOpensAtQuestionOneBeginsASittingFromItsWaitingAnswers(_ run: SetRun) {
        let counted = Self.waiting(2).counting(Self.row(answered: run == .new ? 0 : 5, sitting: nil, run: run))
        #expect(counted.sitting?.answeredCount == 2)
        #expect(counted.run == .midway)
    }

    /// Bug (a): the server's rule is that once every question has an answer there is nothing to
    /// continue, even with a retake under way. Answers waiting on the phone do not change that: the row
    /// said "3 of 12 answered · Continue" on a Done set.
    @Test func aRetakeWaitingOnThePhoneLeavesADoneSetDone() {
        let retake = Self.waiting(3).counting(Self.row(answered: 12, sitting: nil))
        #expect(retake.sitting == nil)
        #expect(retake.answeredCount == 12)
        #expect(retake.run == .done)
        let open = Self.waiting(3).counting(Self.row(answered: 12, sitting: 1, run: .done))
        #expect(open.sitting == nil, "a retake the server listed by mistake is not continued either")
        #expect(open.run == .done)
    }

    @Test func aWaitingReviewAnswerLeavesTheRowsSittingAsItIs() {
        let done = Self.waiting(1, joins: false).counting(Self.row(answered: 12, sitting: nil))
        #expect(done.sitting == nil)
        #expect(done.run == .done)
        let midway = Self.waiting(1, joins: false).counting(Self.row(answered: 7, sitting: 7, run: .midway))
        #expect(midway.sitting?.answeredCount == 7)
        #expect(midway.run == .midway)
        let restarted = Self.waiting(1, joins: false).counting(Self.row(answered: 7, sitting: nil, run: .restarted))
        #expect(restarted.sitting == nil)
        #expect(restarted.run == .restarted)
    }

    @Test func aRowWithNoWaitingAnswersKeepsItsSitting() {
        let row = Self.row(answered: 7, sitting: 7)
        #expect(WaitingProgress(answers: [:]).counting(row) == row)
    }

    @Test func aReviewAnswerOnlyEverJoinsWhenAnotherAnswerToItDoes() {
        let review = Self.pending("s-q0", at: 1, fromReview: true)
        let practice = Self.pending("s-q0", at: 2)
        #expect(WaitingProgress(pending: [review]) { _ in .correct }.answers["s-q0"]?.joinsASitting == false)
        #expect(WaitingProgress(pending: [practice, review]) { _ in .correct }.answers["s-q0"]?.joinsASitting == true)
    }
}
