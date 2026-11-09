import Foundation
import QBankKit
import Testing
@testable import QBank

/// A set she left midway opens at the first question she has not answered, on the server's word and
/// the phone's own, and Start over begins it again. Invented questions only.
@MainActor
struct SetProgressTests {
    /// A set of `count` single-answer questions, q0 to q(count - 1), where the first choice is right.
    static func set(questions count: Int = 4, sitting: String = "null") -> String {
        let questions = (0..<count).map { index in
            #"{"id":"q\#(index)","publicId":"Q\#(index)","position":\#(index + 1),"type":"single","topic":"Invented \#(index)","cj":"Take action","stem":"Stem \#(index).","ask":"Which one?","rationale":"Because.","takeaway":"Remember.","terms":[],"body":{"options":[{"t":"Right","ok":true},{"t":"Wrong"}]}}"#
        }
        return #"{"id":"set1","courseId":"c1","title":"Shock and perfusion","weekLabel":"Week 6","kind":"practice","questions":[\#(questions.joined(separator: ","))],"sitting":\#(sitting)}"#
    }

    static func sitting(_ answered: [Int], id: String? = "s1", startedAt: String? = "2026-01-01T00:00:00.000Z", answeredAt: String = "2026-01-01T00:00:00.000Z") -> String {
        let answers = answered.map { index in
            #"{"clientAttemptId":"earlier-\#(index)","questionId":"q\#(index)","status":"correct","points":1,"maxPoints":1,"guessed":\#(index == 0),"answeredAt":"\#(answeredAt)","inReview":false,"label":"Server's word","pointsText":null,"ruleText":null,"response":{"type":"single","choice":0},"shuffle":null}"#
        }
        let ids = answered.map { #""q\#($0)""# }.joined(separator: ",")
        let quoted = { (value: String?) in value.map { #""\#($0)""# } ?? "null" }
        return #"{"id":\#(quoted(id)),"startedAt":\#(quoted(startedAt)),"answeredQuestionIds":[\#(ids)],"answers":[\#(answers.joined(separator: ","))]}"#
    }

    private static func saved(_ id: String, question: String) -> StubServer.Reply {
        StubServer.Reply(status: 201, body: PracticeModelTests.saved(id: id, question: question, status: "correct", points: 1, max: 1))
    }

    private static func bodies(_ server: StubServer) throws -> [[String: Any]] {
        try server.requests.filter { $0.url?.path() == "/api/attempts" }.map { request in
            let body = try #require(request.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    // MARK: Opening

    @Test func aSetLeftMidwayOpensAtItsFirstUnansweredQuestion() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 1])))])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.phase == .answering)
        #expect(model.index == 2)
        #expect(model.question?.id == "q2")
        #expect(model.countText == "3 of 4")
        #expect(model.progress == 0.5, "the earlier answers count in the bar")
        #expect(model.pickedUp?.number == 3)
        #expect(!model.showsNewRunNotice, "a set she is still in does not say a new run is starting")
        #expect(!model.isRevealed)
        #expect(model.canCheck == false)
    }

    @Test func aSetMidwayBeforeSittingsContinuesTheSameWay() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 1, 2], id: nil, startedAt: nil)))])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.index == 3)
        #expect(model.pickedUp?.number == 4)
        #expect(model.isLast)
    }

    @Test(arguments: ["null", #"{"id":"s1","startedAt":null,"answeredQuestionIds":["q0","q1","q2","q3"],"answers":[]}"#])
    func aSetWithNothingToContinueOpensFresh(sitting: String) async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set(sitting: sitting))])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.index == 0)
        #expect(model.pickedUp == nil)
        #expect(model.answeredCount == 0)
        #expect(model.progress == 0)
    }

    @Test func theRunNeverAsksAgainWhatTheSittingHasAndTheResultCountsIt() async throws {
        // A Review answer can leave a gap: q0 and q2 are answered, q1 and q3 are not.
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 2]))),
            "POST /api/attempts": Self.saved("attempt-1", question: "q1"),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.question?.id == "q1")
        #expect(!model.isLast)
        model.update(.single(0))
        await model.check()
        server["POST /api/attempts"] = Self.saved("attempt-2", question: "q3")
        model.next()
        #expect(model.question?.id == "q3", "q2 is already answered")
        #expect(model.isLast)
        #expect(model.pickedUp == nil, "the line stays with the question it picked up at")
        model.update(.single(0))
        await model.check()
        #expect(model.progress == 1)
        model.next()
        #expect(model.phase == .finished)

        let result = try #require(model.result)
        #expect(result.fullyRight == 4)
        #expect(result.elapsed == nil, "this opening's time would say little of the whole sitting")
        #expect(Wording.resultPoints(result).hasSuffix("points"))
        #expect(result.guessed == 1, "the earlier guess still counts as one")
        #expect(result.rows.map(\.mark) == ["Guessed - Server's word", "x", "Server's word", "x"])
        #expect(try Self.bodies(server).map { $0["questionId"] as? String } == ["q1", "q3"], "only what she answered this time is sent")
    }

    @Test func aQuestionThisVersionCannotShowStillLetsHerGoOn() async throws {
        let body = Self.set(questions: 2).replacingOccurrences(of: #""id":"q0","publicId":"Q0","position":1,"type":"single""#, with: #""id":"q0","publicId":"Q0","position":1,"type":"hotspot""#)
        let server = StubServer(["GET /api/practice-sets/set1": .ok(body)])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.attempt?.draft == .unsupported)
        model.next()
        #expect(model.question?.id == "q1")
    }

    // MARK: Start over

    @Test func startOverEndsTheSittingAndOpensAtQuestionOne() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 1]))),
            "POST /api/practice-sets/set1/start-over": .ok(#"{"ended":true}"#),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        await model.startOver()
        #expect(server.calls.contains("POST /api/practice-sets/set1/start-over"))
        #expect(model.index == 0)
        #expect(model.pickedUp == nil)
        #expect(model.answeredCount == 0)
        #expect(model.attempt?.feedback == nil)
        #expect(model.isLast == false)
        #expect(!model.showsNewRunNotice, "Start over of a set she has not finished says nothing")
    }

    @Test func startOverWithoutAConnectionLeavesHerPlaceAndSaysWhy() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 1]))),
            "POST /api/practice-sets/set1/start-over": .offline,
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        await model.startOver()
        #expect(model.index == 2)
        #expect(model.pickedUp?.number == 3)
        #expect(model.problem == "Could not start over. Check your connection and try again.")
    }

    @Test func startOverSendsWhatWaitsFirst() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set()),
            "POST /api/attempts": .offline,
        ])
        let storage = PhoneStorage.memory()
        let cached = PracticeModelTests.model(server, storage: storage).0
        await cached.load()
        let connection = Connection(isOnline: false)
        let (first, app) = PracticeModelTests.model(server, storage: storage, connection: connection)
        await first.load()
        first.update(.single(0))
        await first.check()
        #expect(app.offline?.waiting.count == 1)

        // Still waiting, and QBank cannot be reached: it stays where it is.
        let (held, _) = PracticeModelTests.model(server, storage: storage, connection: connection)
        await held.load()
        #expect(held.index == 1)
        await held.startOver()
        #expect(held.index == 1)
        #expect(held.problem != nil)
        #expect(!server.calls.contains("POST /api/practice-sets/set1/start-over"))

        // Back online: the answer goes, and then the sitting ends.
        server["POST /api/attempts"] = Self.saved("attempt-1", question: "q0")
        server["POST /api/practice-sets/set1/start-over"] = .ok(#"{"ended":true}"#)
        server["GET /api/practice-sets/set1"] = .ok(Self.set(sitting: Self.sitting([0])))
        connection.update(isOnline: true)
        let (back, backApp) = PracticeModelTests.model(server, storage: storage, connection: connection)
        await back.load()
        await back.startOver()
        #expect(back.index == 0)
        #expect(backApp.offline?.waiting.isEmpty == true)
        let posts = server.calls.filter { $0.hasPrefix("POST") }
        #expect(posts.first == "POST /api/attempts")
        #expect(posts.last == "POST /api/practice-sets/set1/start-over")
    }

    // MARK: What Review sends

    @Test func aReviewAnswerSaysSoAndAPracticeAnswerDoesNot() async throws {
        let review = PracticeModelTests.practiceSet().replacingOccurrences(of: #""title":"Invented set""#, with: #""title":"Review""#)
        let server = StubServer([
            "GET /api/courses/c1/review/practice": .ok(review),
            "GET /api/practice-sets/set1": .ok(Self.set()),
            "POST /api/attempts": Self.saved("attempt-1", question: "q-sata"),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let runner = PracticeModel(app: app, source: .review(filter: .all, questionID: nil), courseID: "c1", title: "Review")
        await runner.load()
        #expect(runner.pickedUp == nil)
        runner.update(.sata([0, 2]))
        await runner.check()
        #expect(try Self.bodies(server).last?["fromReview"] as? Bool == true)

        server["POST /api/attempts"] = Self.saved("attempt-1", question: "q0")
        let (practice, _) = PracticeModelTests.model(server)
        await practice.load()
        practice.update(.single(0))
        await practice.check()
        #expect(try Self.bodies(server).last?["fromReview"] == nil)
    }

    @Test func aReviewRunHasNoPlaceToKeep() async throws {
        let review = PracticeModelTests.practiceSet().replacingOccurrences(of: #""title":"Invented set""#, with: #""title":"Review""#)
        let server = StubServer([
            "GET /api/courses/c1/review/practice": .ok(review),
            "POST /api/attempts": .offline,
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let runner = PracticeModel(app: app, source: .review(filter: .all, questionID: nil), courseID: "c1", title: "Review")
        await runner.load()
        runner.update(.sata([0, 2]))
        await runner.check()
        #expect(app.offline?.waiting.first?.submission.fromReview == true)
        #expect(await app.offline?.saved(.practiceSet("c1")) == nil)
        #expect(await app.offline?.saved(.practiceSet("set1")) == nil)
    }

    // MARK: A night without signal

    @Test func waitingAnswersCountInThePlaceAfterARelaunchWithoutSignal() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set())])
        let storage = PhoneStorage.memory()
        let (model, _) = PracticeModelTests.model(server, storage: storage)
        await model.load()
        #expect(model.index == 0)

        let offline = Connection(isOnline: false)
        let (night, _) = PracticeModelTests.model(server, storage: storage, connection: offline)
        await night.load()
        for _ in 0..<2 {
            night.update(.single(0))
            await night.check()
            night.next()
        }
        #expect(night.index == 2)

        let (morning, app) = PracticeModelTests.model(server, storage: storage, connection: offline)
        await morning.load()
        #expect(morning.index == 2, "she picks up after the two that wait")
        #expect(morning.pickedUp?.number == 3)
        #expect(app.offline?.waiting.count == 2)
        morning.update(.single(0))
        await morning.check()
        morning.next()
        morning.update(.single(0))
        await morning.check()
        morning.next()
        let result = try #require(morning.result)
        #expect(result.fullyRight == 4, "the phone's score counts for the answers that wait")
    }

    @Test func anAnswerQBankAlreadyHasKeepsThePlaceWithoutSignalToo() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set()),
            "POST /api/attempts": Self.saved("attempt-1", question: "q0"),
        ])
        let storage = PhoneStorage.memory()
        let (model, _) = PracticeModelTests.model(server, storage: storage)
        await model.load()
        model.update(.single(0))
        await model.check()
        #expect(model.isRevealed)

        let (again, app) = PracticeModelTests.model(server, storage: storage, connection: Connection(isOnline: false))
        await again.load()
        #expect(app.offline?.waiting.isEmpty == true)
        #expect(again.index == 1)
        #expect(again.result == nil)
    }

    @Test func answersWaitingCountOverWhatTheServerSaysUntilItHasThem() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0])))])
        let storage = PhoneStorage.memory()
        let offline = Connection(isOnline: false)
        let (first, _) = PracticeModelTests.model(server, storage: storage)
        await first.load()
        let (night, _) = PracticeModelTests.model(server, storage: storage, connection: offline)
        await night.load()
        night.update(.single(0))
        await night.check()
        #expect(night.index == 1)

        // Online again, QBank answers before it has the answer that waits.
        server["POST /api/attempts"] = .offline
        let (again, _) = PracticeModelTests.model(server, storage: storage)
        await again.load()
        #expect(again.index == 2)
    }

    @Test func aFinishedRunOnThePhoneOpensFreshThenARetakeKeepsItsOwnPlace() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set(questions: 3))])
        let storage = PhoneStorage.memory()
        let offline = Connection(isOnline: false)
        let (first, _) = PracticeModelTests.model(server, storage: storage)
        await first.load()
        let (run, _) = PracticeModelTests.model(server, storage: storage, connection: offline)
        await run.load()
        for _ in 0..<3 {
            run.update(.single(0))
            await run.check()
            run.next()
        }
        #expect(run.phase == .finished)

        let later = { Date.now.addingTimeInterval(1_000) }
        let (retake, _) = PracticeModelTests.model(server, storage: storage, connection: offline, now: later)
        await retake.load()
        #expect(retake.index == 0, "a finished set opens fresh")
        #expect(retake.pickedUp == nil)
        #expect(retake.showsNewRunNotice)
        #expect(retake.answeredCount == 0)
        retake.update(.single(0))
        await retake.check()

        // The first run's answers still wait, but they are not this run's.
        let (again, app) = PracticeModelTests.model(server, storage: storage, connection: offline, now: later)
        await again.load()
        #expect(app.offline?.waiting.contains { $0.submission.questionID == "q2" } == true)
        #expect(again.index == 1)
        #expect(!again.showsNewRunNotice)
        #expect(again.answeredCount == 1)
    }

    // MARK: Her copy on the phone

    @Test func savingCoursesRefreshesASetOnlyWhenItsRowSaysItMoved() async throws {
        let row = Bodies.set(id: "set1", questionIDs: ["q0", "q1", "q2", "q3"])
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [row])),
            "GET /api/practice-sets/set1": .ok(Self.set()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let store = try #require(app.offline)
        let catalog = try Bodies.decodeCatalog(Bodies.semesters())
        store.saveCourses(in: catalog, force: true)
        await store.finishSavingCourses()
        #expect(server.calls.count { $0 == "GET /api/practice-sets/set1" } == 1)

        // Nothing moved: the copy stays.
        store.saveCourses(in: catalog, force: true)
        await store.finishSavingCourses()
        #expect(server.calls.count { $0 == "GET /api/practice-sets/set1" } == 1)

        // She got further on another device.
        let moved = row.replacingOccurrences(of: #""questionIds""#, with: #""sitting":{"answeredCount":2},"questionIds""#)
        server["GET /api/courses/c1"] = .ok(Bodies.courseDetail(sets: [moved]))
        server["GET /api/practice-sets/set1"] = .ok(Self.set(sitting: Self.sitting([0, 1])))
        store.saveCourses(in: catalog, force: true)
        await store.finishSavingCourses()
        #expect(server.calls.count { $0 == "GET /api/practice-sets/set1" } == 2)
        #expect(await store.saved(.practiceSet("set1"))?.value.sitting?.answeredQuestionIDs == ["q0", "q1"])
    }

    // MARK: Words

    @Test func theRowSaysContinueWhileThereIsASitting() throws {
        func row(answered: Int, sitting: String) throws -> PracticeSetSummary {
            try QBankJSON.decoder.decode(PracticeSetSummary.self, from: Data(#"""
            {"id":"s","title":"t","description":"","questionCount":12,"importedAt":"2026-10-12T09:00:00.000Z","activeSince":"2026-10-12T09:00:00.000Z","status":"imported","canRestore":false,"answeredCount":\#(answered),"fullyRightCount":3,"lastAnsweredAt":"2026-10-12T10:00:00.000Z","questionIds":[],"sitting":\#(sitting)}
            """#.utf8))
        }
        let now = try #require(QBankJSON.parseDate("2026-10-12T12:00:00.000Z"))
        #expect(Wording.status(try row(answered: 7, sitting: #"{"answeredCount":7}"#), now: now) == "7 of 12 answered · Continue")
        #expect(Wording.status(try row(answered: 12, sitting: #"{"answeredCount":1}"#), now: now) == "1 of 12 answered · Continue", "a retake")
        #expect(Wording.status(try row(answered: 7, sitting: #"{"answeredCount":7}"#), opens: false, now: now) == "7 of 12 answered", "a row that does not open the set")
        #expect(Wording.status(try row(answered: 7, sitting: "null"), now: now) == "7 of 12 answered", "after Start over")
        #expect(Wording.status(try row(answered: 12, sitting: "null"), now: now) == "Done today · 3 of 12 fully right")
    }

    @Test func theLineSaysWhereItPickedUp() throws {
        let now = try #require(QBankJSON.parseDate("2026-11-04T12:00:00.000Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(Wording.pickedUp(at: 8, answeredEarlier: 7, lastAnsweredAt: now, now: now, calendar: calendar) == "Picked up at 8 · 7 answered earlier")
        #expect(Wording.pickedUp(at: 8, answeredEarlier: 7, lastAnsweredAt: nil, now: now, calendar: calendar) == "Picked up at 8 · 7 answered earlier")
        let weeksAgo = try #require(QBankJSON.parseDate("2026-10-20T12:00:00.000Z"))
        let line = Wording.pickedUp(at: 8, answeredEarlier: 7, lastAnsweredAt: weeksAgo, now: now, calendar: calendar)
        #expect(line == "Picked up at 8 · last answered \(weeksAgo.formatted(.dateTime.month(.abbreviated).day()))")
    }

    @Test func startOverAsksInHerWords() {
        #expect(Wording.startOverMessage(answers: 7) == "Your 7 answers stay saved and still count. The set begins again at question 1.")
        #expect(Wording.startOverMessage(answers: 1) == "Your 1 answer stays saved and still counts. The set begins again at question 1.")
    }

    // MARK: A finished set opens as a new run

    @Test func aSetNotStartedShowsNoNotice() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.set())])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.index == 0)
        #expect(!model.showsNewRunNotice)
    }

    @Test func aSittingThatListsEveryQuestionShowsTheNotice() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set(sitting: Self.sitting([0, 1, 2, 3]))),
            "POST /api/attempts": Self.saved("attempt-1", question: "q0"),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.index == 0)
        #expect(model.pickedUp == nil)
        #expect(model.showsNewRunNotice)
        model.update(.single(0))
        await model.check()
        #expect(model.showsNewRunNotice, "checking the answer stays on question 1")
        #expect(model.canCheck == false)
        model.next()
        #expect(model.index == 1)
        #expect(!model.showsNewRunNotice)
    }

    @Test func aDoneRowWithNoSittingShowsTheNotice() async throws {
        let model = try await openRemembering(Self.row(answered: 4))
        #expect(model.index == 0)
        #expect(model.showsNewRunNotice)
    }

    @Test func aRetakeInProgressShowsNoNotice() async throws {
        let model = try await openRemembering(Self.row(answered: 4, sitting: #"{"answeredCount":1}"#), sitting: Self.sitting([0]))
        #expect(model.index == 1)
        #expect(model.pickedUp != nil)
        #expect(!model.showsNewRunNotice)
    }

    @Test func aSetLeftAfterStartOverShowsNoNotice() async throws {
        let model = try await openRemembering(Self.row(answered: 2))
        #expect(model.index == 0)
        #expect(!model.showsNewRunNotice)
    }

    @Test func reviewAndAnExamShowNoNotice() async throws {
        let done = Self.row(answered: 4)
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [done])),
            "GET /api/courses/c1/review/practice": .ok(Self.set()),
            "GET /api/practice-sets/set1": .ok(Self.set().replacingOccurrences(of: #""kind":"practice""#, with: #""kind":"exam""#)),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        _ = try await app.load(.course("c1")) { () async throws(QBankError) in try await app.client.course(id: "c1") }
        let review = PracticeModel(app: app, source: .review(filter: .all, questionID: nil), courseID: "c1", title: "Review")
        await review.load()
        #expect(review.phase == .answering)
        #expect(!review.showsNewRunNotice)
        let exam = PracticeModel(app: app, source: .set(id: "set1"), courseID: "c1", title: "Exam bank")
        await exam.load()
        #expect(exam.phase == .failed("This set’s questions are asked only on exams."))
        #expect(!exam.showsNewRunNotice)
    }

    /// The course row the runner reads, with this set's answers and, when given, a sitting to continue.
    private static func row(answered: Int, questions: Int = 4, sitting: String = "null") -> String {
        #"{"id":"set1","title":"t","description":"","questionCount":\#(questions),"importedAt":"2026-10-12T09:00:00.000Z","activeSince":"2026-10-12T09:00:00.000Z","status":"imported","canRestore":false,"answeredCount":\#(answered),"fullyRightCount":1,"lastAnsweredAt":"2026-10-12T10:00:00.000Z","questionIds":[],"sitting":\#(sitting)}"#
    }

    /// Opens the set after the course row is on the phone, as opening it from the course does.
    private func openRemembering(_ row: String, sitting: String = "null", questions: Int = 4) async throws -> PracticeModel {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.set(questions: questions, sitting: sitting)),
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [row])),
        ])
        let (model, app) = PracticeModelTests.model(server)
        _ = try await app.load(.course("c1")) { () async throws(QBankError) in try await app.client.course(id: "c1") }
        await model.load()
        return model
    }

    // MARK: The fake server

    @Test func theFakeServerKeepsSittingsByTheServersRules() async throws {
        let app = try #require(DebugLaunchScenario.makeModel(
            environment: [DebugLaunchScenario.scenarioKey: "signed-in"],
            phoneFolder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ))
        // Day one: answers from before, no row yet.
        let midway = try await app.client.practiceSet(id: "communication-v1")
        #expect(midway.sitting?.id == nil)
        #expect(midway.sitting?.answeredQuestionIDs.count == 9)

        // A Done set opens fresh, and a Review answer leaves it so.
        #expect(try await app.client.practiceSet(id: "rights-v1").sitting == nil)
        let review = AttemptSubmission(questionID: "rights-v1-q0", response: .single(choice: 0), fromReview: true)
        _ = try await app.client.recordAttempt(review)
        #expect(try await app.client.practiceSet(id: "rights-v1").sitting == nil)

        // Its first new answer is the retake.
        _ = try await app.client.recordAttempt(AttemptSubmission(questionID: "rights-v1-q0", response: .single(choice: 0)))
        let retake = try await app.client.practiceSet(id: "rights-v1")
        #expect(retake.sitting?.id != nil)
        #expect(retake.sitting?.answeredQuestionIDs == ["rights-v1-q0"])

        // Start over ends it, and says when there is nothing to end.
        #expect(try await app.client.startPracticeSetOver(id: "rights-v1"))
        #expect(try await app.client.practiceSet(id: "rights-v1").sitting == nil)
        #expect(try await app.client.startPracticeSetOver(id: "rights-v1") == false)
        #expect(try await app.client.startPracticeSetOver(id: "communication-v1"))
        #expect(try await app.client.practiceSet(id: "communication-v1").sitting == nil)
    }

    @Test func theFakeServersAnswersOutlastTheAppOnlyWhenKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launch = { (keep: Bool) in
            DebugLaunchScenario.makeModel(
                environment: [DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.keepServerAnswersKey: keep ? "1" : "0"],
                phoneFolder: folder
            )
        }
        let first = try #require(launch(false))
        _ = try await first.client.recordAttempt(AttemptSubmission(questionID: "mixed-v1-q0", response: .single(choice: 0)))
        let kept = try #require(launch(true))
        #expect(try await kept.client.practiceSet(id: "mixed-v1").sitting?.answeredQuestionIDs == ["mixed-v1-q0"])
        let fresh = try #require(launch(false))
        #expect(try await fresh.client.practiceSet(id: "mixed-v1").sitting == nil)
    }
}
