import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import QBankKit

/// A stand-in server that dedupes by clientAttemptId, as the real one does, and can be told to
/// drop the connection or refuse an answer.
final class FakeServer: AttemptSender {
    enum Mode: Sendable {
        case online
        case offline
        /// Saves the answer, then loses the reply on the way back.
        case loseReply
        case error(QBankError)
    }

    private struct State {
        var mode: Mode = .online
        var refusals: [String: QBankError] = [:]
        var saved: [String: SavedAttempt] = [:]
        var order: [String] = []
        var calls = 0
    }

    private let state = Mutex(State())
    /// Called before each answer is handled, so a test can hold a send open.
    let gate: (@Sendable () async -> Void)?

    init(mode: Mode = .online, gate: (@Sendable () async -> Void)? = nil) {
        state.withLock { $0.mode = mode }
        self.gate = gate
    }

    func set(_ mode: Mode) {
        state.withLock { $0.mode = mode }
    }

    func refuse(_ id: String, with error: QBankError) {
        state.withLock { $0.refusals[id] = error }
    }

    /// The answers the server saved, in the order it first saw them.
    var savedOrder: [String] { state.withLock { $0.order } }
    var calls: Int { state.withLock { $0.calls } }

    func recordAttempt(_ attempt: AttemptSubmission) async throws(QBankError) -> SavedAttempt {
        await gate?()
        let result: Result<SavedAttempt, QBankError> = state.withLock { state in
            state.calls += 1
            if let refusal = state.refusals[attempt.clientAttemptID] { return .failure(refusal) }
            switch state.mode {
            case .offline:
                return .failure(.transport(.notConnectedToInternet))
            case .error(let error):
                return .failure(error)
            case .online, .loseReply:
                let replayed = state.saved[attempt.clientAttemptID] != nil
                let saved = state.saved[attempt.clientAttemptID] ?? SavedAttempt.sample(id: attempt.clientAttemptID, questionID: attempt.questionID)
                if !replayed {
                    state.saved[attempt.clientAttemptID] = saved
                    state.order.append(attempt.clientAttemptID)
                }
                if case .loseReply = state.mode { return .failure(.transport(.networkConnectionLost)) }
                return .success(replayed ? SavedAttempt.replayOf(saved) : saved)
            }
        }
        return try result.get()
    }
}

extension SavedAttempt {
    static func sample(id: String, questionID: String) -> SavedAttempt {
        SavedAttempt(
            clientAttemptID: id, questionID: questionID, courseID: "course-1", status: .correct, points: 1,
            maxPoints: 1, guessed: false, answeredAt: Date(timeIntervalSince1970: 1_790_000_000), inReview: false,
            label: "Correct", pointsText: nil, ruleText: nil, replayed: false
        )
    }
}

func answer(_ id: String, question: String = "q1") -> AttemptSubmission {
    AttemptSubmission(clientAttemptID: id, questionID: question, response: .single(choice: 0))
}

@Suite("Offline answer queue")
struct AttemptQueueTests {
    @Test func onlineAnswerIsSentAtOnce() async throws {
        let server = FakeServer()
        let store = InMemoryPendingAttemptStore()
        let queue = try AttemptQueue(store: store, sender: server)
        let outcome = try await queue.submit(answer("a1"), courseID: "course-1")
        guard case .sent(let saved) = outcome else {
            Issue.record("Expected sent, got \(outcome)")
            return
        }
        #expect(saved.clientAttemptID == "a1")
        #expect(await queue.pending.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func answerWithoutSignalWaitsOnThePhone() async throws {
        let server = FakeServer(mode: .offline)
        let store = InMemoryPendingAttemptStore()
        let queue = try AttemptQueue(store: store, sender: server, now: { Date(timeIntervalSince1970: 100) })
        let outcome = try await queue.submit(answer("a1"), courseID: "course-1")
        guard case .queued(let pending, let reason) = outcome else {
            Issue.record("Expected queued, got \(outcome)")
            return
        }
        #expect(pending.id == "a1")
        #expect(pending.courseID == "course-1")
        #expect(pending.queuedAt == Date(timeIntervalSince1970: 100))
        #expect(reason == .transport(.notConnectedToInternet))
        #expect(try store.load().map(\.id) == ["a1"])
        #expect(await queue.pendingCount(courseID: "course-1") == 1)
        #expect(await queue.pendingCount(courseID: "course-2") == 0)
    }

    @Test func waitingAnswersGoOutInOrderWhenSignalReturns() async throws {
        let server = FakeServer(mode: .offline)
        let store = InMemoryPendingAttemptStore()
        let queue = try AttemptQueue(store: store, sender: server)
        for id in ["a1", "a2", "a3"] {
            _ = try await queue.submit(answer(id), courseID: "course-1")
        }
        #expect(await queue.pendingCount() == 3)
        server.set(.online)
        let report = await queue.flush()
        #expect(report.sent.map(\.clientAttemptID) == ["a1", "a2", "a3"])
        #expect(report.remaining == 0)
        #expect(report.stoppedBy == nil)
        #expect(server.savedOrder == ["a1", "a2", "a3"])
        #expect(try store.load().isEmpty)
    }

    @Test func newAnswerWaitsBehindOlderOnes() async throws {
        let server = FakeServer(mode: .offline)
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        _ = try await queue.submit(answer("older", question: "q1"), courseID: nil)
        server.set(.online)
        let outcome = try await queue.submit(answer("newer", question: "q1"), courseID: nil)
        guard case .sent(let saved) = outcome else {
            Issue.record("Expected sent")
            return
        }
        #expect(saved.clientAttemptID == "newer")
        #expect(server.savedOrder == ["older", "newer"])
    }

    @Test func lostReplyIsSentAgainAndCountedOnce() async throws {
        let server = FakeServer(mode: .loseReply)
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        let first = try await queue.submit(answer("a1"), courseID: nil)
        guard case .queued = first else {
            Issue.record("Expected queued")
            return
        }
        server.set(.online)
        let report = await queue.flush()
        #expect(report.sent.first?.replayed == true)
        #expect(server.savedOrder == ["a1"])
        #expect(await queue.pending.isEmpty)
    }

    @Test func refusedAnswerIsDroppedAndTheRestGoOn() async throws {
        let server = FakeServer(mode: .offline)
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        for id in ["a1", "a2", "a3"] {
            _ = try await queue.submit(answer(id), courseID: nil)
        }
        let finished = QBankError.server(ServerError(status: 409, code: .examFinished, message: "This exam has ended."))
        server.refuse("a2", with: finished)
        server.set(.online)
        let report = await queue.flush()
        #expect(report.sent.map(\.clientAttemptID) == ["a1", "a3"])
        #expect(report.refused.map(\.attempt.id) == ["a2"])
        #expect(report.refused.first?.error == finished)
        #expect(await queue.pending.isEmpty)
    }

    @Test func submitReportsARefusal() async throws {
        let server = FakeServer()
        let invalid = QBankError.server(ServerError(status: 400, code: .invalidResponse, message: "Cannot score."))
        server.refuse("a1", with: invalid)
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        let error = await #expect(throws: QBankError.self) { try await queue.submit(answer("a1"), courseID: nil) }
        #expect(error == invalid)
        #expect(await queue.pending.isEmpty)
    }

    @Test(arguments: [
        QBankError.server(ServerError(status: 503, code: .authUnavailable, message: "Down.")),
        .server(ServerError(status: 401, code: .unauthenticated, message: "Sign in.")),
        .server(ServerError(status: 403, code: .mustChangePassword, message: "New password.")),
        .server(ServerError(status: 429, code: .tooManyAttempts, message: "Later.")),
        .unexpectedResponse(status: 502, detail: "Bad Gateway"),
        .notSignedIn,
        .cancelled,
    ])
    func answerWaitsThroughErrorsThatPass(error: QBankError) async throws {
        let server = FakeServer(mode: .error(error))
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        _ = try await queue.submit(answer("a1"), courseID: nil)
        _ = try await queue.submit(answer("a2"), courseID: nil)
        let report = await queue.flush()
        #expect(report.stoppedBy == error)
        #expect(report.remaining == 2)
        #expect(await queue.pending.map(\.id) == ["a1", "a2"])
    }

    @Test func unreadableSuccessIsNotSentAgain() async throws {
        let server = FakeServer(mode: .error(.unexpectedResponse(status: 201, detail: "not JSON")))
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        await #expect(throws: QBankError.self) { try await queue.submit(answer("a1"), courseID: nil) }
        #expect(await queue.pending.isEmpty)
    }

    @Test func sameAnswerIsQueuedOnce() async throws {
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: FakeServer(mode: .offline))
        try await queue.enqueue(answer("a1"), courseID: nil)
        try await queue.enqueue(answer("a1"), courseID: nil)
        #expect(await queue.pendingCount() == 1)
    }

    @Test func waitingAnswersSurviveARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QBankKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePendingAttemptStore(fileURL: directory.appendingPathComponent("pending-attempts.json"))
        let submission = AttemptSubmission(
            clientAttemptID: "a1", questionID: "q1", response: .match(choices: ["Class A", nil]),
            guessed: true, shuffle: .match(choices: ["Class B", "Class A"]), studySessionID: nil
        )
        do {
            let queue = try AttemptQueue(store: store, sender: FakeServer(mode: .offline))
            _ = try await queue.submit(submission, courseID: "course-1")
        }
        let server = FakeServer()
        let reopened = try AttemptQueue(store: store, sender: server)
        #expect(await reopened.pending.map(\.submission) == [submission])
        let report = await reopened.flush()
        #expect(report.sent.map(\.clientAttemptID) == ["a1"])
        #expect(try store.load().isEmpty)
    }

    @Test func missingFileIsAnEmptyQueue() throws {
        let store = FilePendingAttemptStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json"))
        #expect(try store.load().isEmpty)
    }

    @Test func concurrentFlushesSendEachAnswerOnce() async throws {
        let server = FakeServer(mode: .offline, gate: { try? await Task.sleep(for: .milliseconds(5)) })
        let queue = try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: server)
        for index in 0..<5 {
            try await queue.enqueue(answer("a\(index)"), courseID: nil)
        }
        server.set(.online)
        async let first = queue.flush()
        async let second = queue.flush()
        let reports = await [first, second]
        #expect(server.calls == 5)
        #expect(server.savedOrder == ["a0", "a1", "a2", "a3", "a4"])
        #expect(reports.allSatisfy { $0.remaining == 0 })
    }

    @Test func signOutClearsWaitingAnswers() async throws {
        let store = InMemoryPendingAttemptStore()
        let queue = try AttemptQueue(store: store, sender: FakeServer(mode: .offline))
        _ = try await queue.submit(answer("a1"), courseID: nil)
        try await queue.removeAll()
        #expect(await queue.pending.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func storageFailureKeepsTheAnswerFromBeingLostSilently() async throws {
        let queue = try AttemptQueue(store: BrokenPendingStore(), sender: FakeServer())
        let error = await #expect(throws: QBankError.self) { try await queue.submit(answer("a1"), courseID: nil) }
        guard case .storage? = error else {
            Issue.record("Expected a storage error")
            return
        }
    }
}

struct BrokenPendingStore: PendingAttemptStore {
    func load() throws(StorageError) -> [PendingAttempt] { [] }

    func save(_ attempts: [PendingAttempt]) throws(StorageError) {
        throw StorageError(operation: "save unsent answers", reason: "disk full")
    }
}
