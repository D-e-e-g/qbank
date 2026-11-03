import Foundation
import QBankKit
import Testing
@testable import QBank

@MainActor
struct PracticeModelTests {
    /// A set of two invented questions, listed out of order: a select-all at position 1 and a
    /// single answer at position 2.
    static func practiceSet(courseID: String = "c1", kind: String = "practice") -> String {
        #"""
        {"id":"set1","courseId":"\#(courseID)","title":"Invented set","weekLabel":"Week 1","kind":"\#(kind)","questions":[
         {"id":"q-single","publicId":"Q2","position":2,"type":"single","topic":"Invented single","cj":"Take action",
          "stem":"Stem two.","ask":"Which one?","rationale":"Because.","takeaway":"Remember.","terms":[],
          "body":{"options":[{"t":"Right","ok":true},{"t":"Wrong"},{"t":"Also wrong"}]}},
         {"id":"q-sata","publicId":"Q1","position":1,"type":"sata","topic":"","cj":null,
          "stem":"Stem one.","ask":"Which apply?","rationale":"Because.","takeaway":"Remember.","terms":[],
          "body":{"options":[{"t":"A","ok":true},{"t":"B"},{"t":"C","ok":true}]}}
        ]}
        """#
    }

    static func saved(
        id: String, question: String, status: String, points: Int, max: Int, guessed: Bool = false,
        label: String = "x", pointsText: String? = nil, ruleText: String? = nil
    ) -> String {
        let text = { (value: String?) in value.map { "\"\($0)\"" } ?? "null" }
        return #"{"clientAttemptId":"\#(id)","questionId":"\#(question)","courseId":"c1","status":"\#(status)","points":\#(points),"maxPoints":\#(max),"guessed":\#(guessed),"answeredAt":"2026-10-13T00:00:00.000Z","inReview":true,"label":"\#(label)","pointsText":\#(text(pointsText)),"ruleText":\#(text(ruleText)),"replayed":false}"#
    }

    /// A model whose shuffles keep the stored order, whose ids count up, and whose clock is under
    /// the test's control.
    static func model(
        _ server: StubServer,
        account: Account = .student(),
        storage: PhoneStorage = .memory(),
        connection: Connection = Connection(),
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }
    ) -> (PracticeModel, AppModel) {
        let (app, _) = TestApp.make(server, account: account, storage: storage, connection: connection)
        var next = 0
        let model = PracticeModel(
            app: app, source: .set(id: "set1"), courseID: "c1", title: "From the course",
            now: now,
            makeLayout: { body in
                switch body {
                case .single(let options), .priority(let options), .sata(let options): .options(order: Array(options.indices).reversed())
                default: .plain
                }
            },
            newAttemptID: {
                next += 1
                return "attempt-\(next)"
            }
        )
        return (model, app)
    }

    @Test func loadsTheSetInPracticeOrderWithOneShuffleAndIdPerQuestion() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet())])
        let (model, _) = Self.model(server)
        #expect(model.title == "From the course", "the Course screen's title shows while it loads")
        await model.load()
        #expect(model.phase == .answering)
        #expect(model.title == "Invented set")
        #expect(model.questions.map(\.id) == ["q-sata", "q-single"])
        #expect(model.attempts.map(\.clientAttemptID) == ["attempt-1", "attempt-2"])
        #expect(model.attempts.first?.layout == .options(order: [2, 1, 0]))
        #expect(model.attempts.first?.draft == .sata([]))
        #expect(model.countText == "1 of 2")
        #expect(model.progress == 0)
        #expect(!model.canCheck)
    }

    @Test func anExamBankIsNotPracticed() async {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet(kind: "exam"))])
        let (model, _) = Self.model(server)
        await model.load()
        #expect(model.phase == .failed("This set’s questions are asked only on exams."))
    }

    @Test func aSetFromAnotherCourseIsRefused() async {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet(courseID: "other"))])
        let (model, _) = Self.model(server)
        await model.load()
        #expect(model.phase == .failed("That set is not in this course."))
    }

    @Test func noSignalAndNothingSavedSaysSo() async {
        let server = StubServer(["GET /api/practice-sets/set1": .offline])
        let (model, _) = Self.model(server)
        await model.load()
        #expect(model.phase == .failed("No connection, and this set is not saved on this \(Device.noun) yet. Open it once with a connection to practice it offline."))
    }

    @Test func aSavedSetOpensWithoutSignal() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet())])
        let storage = PhoneStorage.memory()
        let (online, _) = Self.model(server, storage: storage)
        await online.load()

        server["GET /api/practice-sets/set1"] = .offline
        let (offline, _) = Self.model(server, storage: storage)
        await offline.load()
        #expect(offline.phase == .answering)
        #expect(offline.questions.map(\.id) == ["q-sata", "q-single"])

        let calls = server.calls.count
        let (noNetwork, _) = Self.model(server, storage: storage, connection: Connection(isOnline: false))
        await noNetwork.load()
        #expect(noNetwork.phase == .answering)
        #expect(server.calls.count == calls, "without a network path it does not try the server first")
    }

    @Test func anEndedSessionSignsOut() async {
        let server = StubServer(["GET /api/practice-sets/set1": .error(401, "unauthenticated", "Sign in to continue.")])
        let (model, app) = Self.model(server)
        await model.load()
        #expect(app.route == .signedOut)
        #expect(model.phase == .loading)
    }

    @Test func theOwnerCanLookButNotAnswer() async {
        let server = StubServer()
        let (model, _) = Self.model(server, account: .admin)
        await model.load()
        #expect(model.phase == .readOnly)
        #expect(server.requests.isEmpty)
    }

    @Test func checkSendsTheAnswerInStoredIndexesAndShowsTheServersScore() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            // The server's word wins, even where the phone would score it otherwise.
            "POST /api/attempts": StubServer.Reply(status: 201, body: Self.saved(id: "attempt-1", question: "q-sata", status: "partial", points: 1, max: 2, guessed: true)),
        ])
        let (model, _) = Self.model(server)
        await model.load()
        model.update(.sata([2, 0]))
        model.setGuessed(true)
        #expect(model.canCheck)
        await model.check()

        let sent = try #require(server.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["clientAttemptId"] as? String == "attempt-1")
        #expect(body["questionId"] as? String == "q-sata")
        #expect(body["guessed"] as? Bool == true)
        #expect((body["response"] as? [String: Any])?["picks"] as? [Int] == [2, 0])
        #expect((body["shuffle"] as? [String: Any])?["order"] as? [Int] == [2, 1, 0])

        #expect(model.attempt?.score == Score(points: 1, maxPoints: 2, status: .partial, answered: true))
        #expect(model.isRevealed)
        #expect(model.progress == 0.5)
        #expect(!model.canCheck)
        model.update(.sata([0]))
        #expect(model.attempt?.draft == .sata([2, 0]), "a checked answer cannot change")
    }

    @Test func aSentAnswerShowsTheServersWords() async throws {
        // Words the phone would never write, so only the server's can show.
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: Self.saved(
                id: "attempt-1", question: "q-sata", status: "partial", points: 1, max: 2,
                label: "Partly right", pointsText: "1 point of 2", ruleText: "A rule the server changed"
            )),
        ])
        let (model, _) = Self.model(server)
        await model.load()
        model.update(.sata([0]))
        await model.check()
        #expect(!model.isWaitingToSend)
        let feedback = try #require(model.attempt?.feedback)
        #expect(feedback.score == Score(points: 1, maxPoints: 2, status: .partial, answered: true))
        #expect(feedback.label == "Partly right")
        #expect(feedback.pointsText == "1 point of 2")
        #expect(feedback.ruleText == "A rule the server changed")

        model.next()
        model.update(.single(0))
        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: Self.saved(id: "attempt-2", question: "q-single", status: "correct", points: 1, max: 1, label: "Correct"))
        await model.check()
        #expect(model.attempt?.feedback?.pointsText == nil, "the server sends no point line for a single answer")
        #expect(model.attempt?.feedback?.ruleText == nil)
        model.next()
        #expect(model.result?.rows.map(\.mark) == ["Partly right", "Correct"], "the result lists the server's words too")
    }

    @Test func aWaitingAnswerShowsThePhonesWords() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": .offline,
        ])
        let (model, _) = Self.model(server)
        await model.load()
        model.update(.sata([0]))
        await model.check()
        #expect(model.isWaitingToSend)
        let feedback = try #require(model.attempt?.feedback)
        #expect(feedback.label == "Partly correct")
        #expect(feedback.pointsText == "1 of 2 points")
        #expect(feedback.ruleText == "+1 for each correct choice, -1 for each wrong one")
    }

    @Test func struckChoicesStayOnThePhoneAndEndWithTheAnswer() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: Self.saved(id: "attempt-1", question: "q-sata", status: "correct", points: 2, max: 2)),
        ])
        let (model, _) = Self.model(server)
        await model.load()
        model.update(.sata([0, 1]))
        model.toggleStrike(1)
        #expect(model.attempt?.struck == [1])
        #expect(model.attempt?.draft == .sata([0]), "striking her pick unpicks it")
        model.update(.sata([0, 1]))
        #expect(model.attempt?.draft == .sata([0]), "a struck choice cannot be picked")
        model.toggleStrike(1)
        #expect(model.attempt?.struck == [], "striking again restores it")
        model.update(.sata([0, 1]))
        #expect(model.attempt?.draft == .sata([0, 1]), "a restored choice can be picked again")
        model.update(.sata([0, 2]))
        model.toggleStrike(1)
        await model.check()

        let sent = try #require(server.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect((body["response"] as? [String: Any])?["picks"] as? [Int] == [0, 2])
        #expect(!String(decoding: sent, as: UTF8.self).lowercased().contains("stru"), "strikes are never sent")
        model.toggleStrike(2)
        #expect(model.attempt?.struck == [1], "a checked answer's strikes cannot change")
        model.next()
        #expect(model.attempt?.struck == [], "every question starts with nothing struck")
    }

    @Test func anAnswerWithoutSignalIsScoredOnThePhoneAndWaits() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": .offline,
        ])
        let (model, app) = Self.model(server)
        await model.load()
        model.update(.sata([0, 2]))
        await model.check()

        #expect(model.problem == nil)
        #expect(model.attempt?.score == Score(points: 2, maxPoints: 2, status: .correct, answered: true), "the phone's score, by the server's rules")
        #expect(model.isRevealed)
        #expect(model.isWaitingToSend)
        #expect(model.waitingCount == 1)
        #expect(app.offline?.waiting.map(\.id) == ["attempt-1"])
        #expect(app.offline?.waiting.first?.courseID == "c1")
        #expect(server.sentAttemptIDs == ["attempt-1"], "it tried once")

        // The connection is back: the same id is sent, and the answer stops waiting.
        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: Self.saved(id: "attempt-1", question: "q-sata", status: "correct", points: 2, max: 2))
        await app.offline?.send()
        #expect(server.sentAttemptIDs == ["attempt-1", "attempt-1"])
        #expect(!model.isWaitingToSend)
        #expect(model.waitingCount == 0)
        #expect(app.offline?.deliveries == 1)
        #expect(model.attempt?.score?.status == .correct)
    }

    @Test func withoutANetworkPathTheAnswerWaitsWithoutTryingTheServer() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet())])
        let connection = Connection()
        let (model, app) = Self.model(server, connection: connection)
        await model.load()
        connection.update(isOnline: false)
        model.update(.sata([0]))
        await model.check()
        #expect(model.attempt?.score == Score(points: 1, maxPoints: 2, status: .partial, answered: true))
        #expect(model.isWaitingToSend)
        #expect(server.sentAttemptIDs.isEmpty)

        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: Self.saved(id: "attempt-1", question: "q-sata", status: "partial", points: 1, max: 2))
        connection.update(isOnline: true)
        try await waitUntil { app.offline?.waiting.isEmpty == true }
        #expect(server.sentAttemptIDs == ["attempt-1"])
        #expect(!model.isWaitingToSend)
        #expect(model.attempt?.score?.status == .partial, "the score she saw stays")
    }

    @Test func anOnlineAnswerSendsTheOlderWaitingOnesFirst() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(Self.practiceSet())])
        let connection = Connection(isOnline: false)
        let (model, app) = Self.model(server, connection: connection)
        await model.load()
        model.update(.sata([0, 2]))
        await model.check()
        model.next()
        model.update(.single(0))
        server.script("POST /api/attempts", [
            StubServer.Reply(status: 201, body: Self.saved(id: "attempt-1", question: "q-sata", status: "correct", points: 2, max: 2)),
            StubServer.Reply(status: 201, body: Self.saved(id: "attempt-2", question: "q-single", status: "correct", points: 1, max: 1)),
        ])
        connection.update(isOnline: true)
        // The answer she checks while the first is still on its way joins the same pass, behind it.
        await model.check()
        try await waitUntil { app.offline?.waiting.isEmpty == true }
        #expect(server.sentAttemptIDs == ["attempt-1", "attempt-2"])
        #expect(model.attempt?.score == Score(points: 1, maxPoints: 1, status: .correct, answered: true))
    }

    @Test func aReplyTheAppCannotReadKeepsThePhonesScore() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: "{}"),
        ])
        let (model, _) = Self.model(server)
        await model.load()
        model.update(.sata([0, 2]))
        await model.check()
        #expect(model.problem == nil)
        #expect(model.attempt?.score == Score(points: 2, maxPoints: 2, status: .correct, answered: true))
        #expect(!model.isWaitingToSend)
    }

    @Test func anEndedSessionGoesToSignInAndTheAnswerWaitsForHer() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": .error(401, "unauthenticated", "Sign in to continue."),
        ])
        let storage = PhoneStorage.memory()
        let (model, app) = Self.model(server, storage: storage)
        await model.load()
        model.update(.sata([0]))
        await model.check()
        #expect(app.route == .signedOut)
        #expect(app.offline == nil)
        #expect(!model.isRevealed)

        let (again, _) = TestApp.make(server, account: .student(), storage: storage)
        #expect(again.offline?.waiting.map(\.id) == ["attempt-1"], "it goes once she is signed in again")
    }

    @Test func aRefusalIsSaidAndTheAnswerStaysOpen() async {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": .error(404, "request_refused", "That question is no longer in the set."),
        ])
        let (model, app) = Self.model(server)
        await model.load()
        model.update(.sata([0]))
        await model.check()
        #expect(model.problem == "That question is no longer in the set.")
        #expect(!model.isRevealed)
        #expect(model.canCheck, "she can try again")
        #expect(model.attempt?.clientAttemptID == "attempt-1", "a retry keeps the same id")
        #expect(app.offline?.waiting.isEmpty == true, "a refused answer does not wait")
        #expect(app.offline?.notSaved.isEmpty == true, "it is said on her screen, not listed again")
    }

    @Test func nextWalksTheSetThenShowsTheResult() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(Self.practiceSet()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: Self.saved(id: "a", question: "q", status: "partial", points: 1, max: 2)),
        ])
        let (model, _) = Self.model(server, now: { clock })
        await model.load()
        model.next()
        #expect(model.index == 0, "she checks before moving on")
        model.update(.sata([0]))
        await model.check()
        model.next()
        #expect(model.index == 1)
        #expect(model.countText == "2 of 2")
        #expect(model.isLast)
        model.update(.single(0))
        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: Self.saved(id: "b", question: "q", status: "correct", points: 1, max: 1))
        await model.check()
        #expect(model.progress == 1)
        clock = clock.addingTimeInterval(95)
        model.next()
        #expect(model.phase == .finished)
        let result = try #require(model.result)
        #expect(result.fullyRight == 1)
        #expect(result.partial == 1)
        #expect(result.points == 2)
        #expect(result.maxPoints == 3)
        #expect(result.elapsed == 95)
    }
}
