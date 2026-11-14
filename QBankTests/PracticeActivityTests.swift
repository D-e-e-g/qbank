import Foundation
import QBankKit
import Testing
@testable import QBank

/// The practice runner does one thing at a time: a check and a start over never overlap, and a
/// score lands only on the attempt it was sent for. Invented questions only.
@MainActor
struct PracticeActivityTests {
    private static let setRoute = "GET /api/practice-sets/set1"
    private static let startOverRoute = "POST /api/practice-sets/set1/start-over"
    private static let attemptsRoute = "POST /api/attempts"

    /// A set of four left midway at question 3, with Start over and Check answer both answered.
    private static func midwayServer() -> StubServer {
        StubServer([
            setRoute: .ok(SetProgressTests.set(sitting: SetProgressTests.sitting([0, 1]), run: "midway")),
            startOverRoute: .ok(#"{"ended":true}"#),
            attemptsRoute: StubServer.Reply(
                status: 201, body: PracticeModelTests.saved(id: "attempt-1", question: "q2", status: "correct", points: 1, max: 1)
            ),
        ])
    }

    /// The audit's sequence: an answer picked, Start over confirmed and slow, Check answer tapped
    /// while it waits, the start-over reply first and the score after it. The score used to land on
    /// the new run's question 3 and in the copy on the phone.
    @Test func aCheckTappedWhileStartOverWaitsNeverScoresTheNewRun() async throws {
        let server = Self.midwayServer()
        let (model, app) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.index == 2)
        model.update(.single(0))
        #expect(model.canCheck)

        server.hold(Self.startOverRoute)
        let starting = Task { await model.startOver() }
        while !server.calls.contains(Self.startOverRoute) { await Task.yield() }
        #expect(model.activity == .startingOver)
        #expect(!model.canCheck, "Check answer waits while Start over is asking QBank")

        server.hold(Self.attemptsRoute)
        let returned = Locked(false)
        let checking = Task {
            await model.check()
            returned.value = true
        }
        try await waitUntil { returned.value || server.calls.contains(Self.attemptsRoute) }

        server.release(Self.startOverRoute)
        await starting.value
        server.release(Self.attemptsRoute)
        await checking.value

        #expect(server.sentAttemptIDs.isEmpty, "the previous run's answer never leaves the phone")
        #expect(model.activity == .idle)
        #expect(model.index == 0)
        #expect(model.attempts.allSatisfy { $0.feedback == nil }, "no question of the new run is revealed")
        #expect(model.answeredCount == 0)
        #expect(model.strip == [.current, .open, .open, .open])
        let copy = await app.offline?.saved(.practiceSet("set1"))?.value
        #expect(copy?.run == .restarted)
        #expect(copy?.sitting == nil, "the copy on the phone gains no answer from the previous run")
    }

    /// While an answer is on its way the question takes no other answer, no second check and no
    /// Start over, and its score lands on the attempt that was sent.
    @Test func theQuestionWaitsWhileAnAnswerIsOnItsWay() async throws {
        let server = Self.midwayServer()
        let (model, app) = PracticeModelTests.model(server)
        await model.load()
        model.update(.single(0))
        #expect(model.activity == .idle)
        #expect(!model.isBusy)

        server.hold(Self.attemptsRoute)
        let checking = Task { await model.check() }
        while !server.calls.contains(Self.attemptsRoute) { await Task.yield() }
        #expect(model.activity == .checking(attemptID: "attempt-1"))
        #expect(model.isBusy)
        #expect(!model.canCheck)
        model.update(.single(1))
        model.toggleStrike(1)
        model.setGuessed(true)
        #expect(model.attempt?.draft == .single(0), "the answer stays as it was sent")
        #expect(model.attempt?.struck.isEmpty == true)
        #expect(model.attempt?.guessed == false)
        await model.check()
        await model.startOver()
        #expect(server.calls.filter { $0 == Self.attemptsRoute }.count == 1, "one answer is sent once")
        #expect(!server.calls.contains(Self.startOverRoute), "Start over waits for the answer")

        server.release(Self.attemptsRoute)
        await checking.value
        #expect(model.activity == .idle)
        #expect(model.index == 2)
        #expect(model.attempt?.score?.status == .correct)
        #expect(server.sentAttemptIDs == ["attempt-1"])
        let copy = await app.offline?.saved(.practiceSet("set1"))?.value
        #expect(copy?.sitting?.answers.map(\.clientAttemptID).contains("attempt-1") == true, "the copy keeps the place past it")
    }

    /// While Start over asks, the question takes no answer and Next does nothing. A Start over that
    /// fails gives the question back as it was.
    @Test func theQuestionWaitsWhileStartOverAsks() async throws {
        let server = Self.midwayServer()
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        model.update(.single(0))

        // Without a connection: it waits, then says why and leaves the place as it was.
        server.script(Self.startOverRoute, [.offline])
        server.hold(Self.startOverRoute)
        let failing = Task { await model.startOver() }
        while !server.calls.contains(Self.startOverRoute) { await Task.yield() }
        #expect(model.activity == .startingOver)
        #expect(model.isBusy)
        model.update(.single(1))
        model.toggleStrike(1)
        model.setGuessed(true)
        await model.startOver()
        #expect(server.calls.filter { $0 == Self.startOverRoute }.count == 1, "one Start over asks once")
        server.release(Self.startOverRoute)
        await failing.value
        #expect(model.activity == .idle)
        #expect(model.problem == "Could not start over. Check your connection and try again.")
        #expect(model.index == 2)
        #expect(model.attempt?.draft == .single(0))
        #expect(model.attempt?.struck.isEmpty == true)
        #expect(model.attempt?.guessed == false)
        #expect(model.canCheck, "the question takes an answer again")

        // With one, from a checked question: Next waits too, and the set begins again.
        await model.check()
        #expect(model.isRevealed)
        server.hold(Self.startOverRoute)
        let starting = Task { await model.startOver() }
        while server.calls.filter({ $0 == Self.startOverRoute }).count < 2 { await Task.yield() }
        model.next()
        #expect(model.index == 2, "Next waits while Start over asks")
        server.release(Self.startOverRoute)
        await starting.value
        #expect(model.activity == .idle)
        #expect(model.index == 0)
        #expect(model.pickedUp == nil)
        #expect(model.attempts.allSatisfy { $0.feedback == nil })
    }
}
