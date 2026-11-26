import Foundation

/// Anything that can send one answer. `QBankClient` is the real one.
public protocol AttemptSender: Sendable {
    func recordAttempt(_ attempt: AttemptSubmission) async throws(QBankError) -> SavedAttempt
}

extension QBankClient: AttemptSender {}

/// What happened to an answer handed to `AttemptQueue.submit`.
public enum SubmitOutcome: Sendable, Equatable {
    /// The server scored and saved it.
    case sent(SavedAttempt)
    /// It is saved on the phone and will be sent later. `reason` is why it could not go now.
    case queued(PendingAttempt, reason: QBankError)
}

/// An answer the queue removed without the server saving it, because sending it again cannot help:
/// the server refused it (a 4xx such as `exam_finished` or `attempt_conflict`), or answered in a
/// way the app cannot read.
public struct RefusedAttempt: Sendable, Equatable {
    public let attempt: PendingAttempt
    public let error: QBankError
}

/// The outcome of one pass over the queue.
public struct FlushReport: Sendable, Equatable {
    public var sent: [SavedAttempt] = []
    public var refused: [RefusedAttempt] = []
    /// Answers still waiting.
    public var remaining: Int = 0
    /// Why the pass stopped with answers still waiting, such as no connection or no session.
    public var stoppedBy: QBankError?

    public init(sent: [SavedAttempt] = [], refused: [RefusedAttempt] = [], remaining: Int = 0, stoppedBy: QBankError? = nil) {
        self.sent = sent
        self.refused = refused
        self.remaining = remaining
        self.stoppedBy = stoppedBy
    }
}

/// Answers made without signal, kept on the phone and sent in order when the connection is back.
///
/// Every answer carries its own `clientAttemptID`, and the server answers a repeated id with the
/// attempt it already saved. So an answer whose response was lost on the way back is simply sent
/// again: it is never counted twice, and nothing here needs to know whether the first send arrived.
///
/// Answers go out oldest first. A new answer joins the back of the queue while older ones wait,
/// so the server always sees her answers to a question in the order she gave them.
public actor AttemptQueue {
    private let store: any PendingAttemptStore
    private let sender: any AttemptSender
    private let now: @Sendable () -> Date
    private var attempts: [PendingAttempt]
    private var running: Task<FlushReport, Never>?

    public init(
        store: any PendingAttemptStore,
        sender: any AttemptSender,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws(StorageError) {
        self.store = store
        self.sender = sender
        self.now = now
        self.attempts = try store.load()
    }

    /// Every answer still waiting, oldest first.
    public var pending: [PendingAttempt] { attempts }

    /// How many answers are waiting, for one course or for all of them.
    public func pendingCount(courseID: String? = nil) -> Int {
        guard let courseID else { return attempts.count }
        return attempts.count { $0.courseID == courseID }
    }

    /// Saves an answer on the phone, then sends the queue, so an answer is never lost between
    /// her tap and the server's reply, even if the app is closed mid-send.
    ///
    /// - Returns: `.sent` when the server saved it, `.queued` when it waits on the phone.
    /// - Throws: The server's refusal when it answered that this answer cannot be saved,
    ///   or a storage error when the phone could not keep it.
    public func submit(_ submission: AttemptSubmission, courseID: String?) async throws(QBankError) -> SubmitOutcome {
        let pending: PendingAttempt
        do {
            pending = try enqueue(submission, courseID: courseID)
        } catch {
            throw .storage(error)
        }
        let report = await flush()
        if let saved = report.sent.first(where: { $0.clientAttemptID == pending.id }) {
            return .sent(saved)
        }
        if let refused = report.refused.first(where: { $0.attempt.id == pending.id }) {
            throw refused.error
        }
        if attempts.contains(where: { $0.id == pending.id }) {
            return .queued(pending, reason: report.stoppedBy ?? .transport(.notConnectedToInternet))
        }
        // Another pass sent it while this one waited. Send it again to get its receipt: the server
        // answers a repeated id with the attempt it saved.
        return .sent(try await sender.recordAttempt(submission))
    }

    /// Keeps an answer to send later. An id already waiting is not added twice.
    @discardableResult
    public func enqueue(_ submission: AttemptSubmission, courseID: String?) throws(StorageError) -> PendingAttempt {
        if let existing = attempts.first(where: { $0.id == submission.clientAttemptID }) {
            return existing
        }
        let pending = PendingAttempt(submission: submission, courseID: courseID, queuedAt: now())
        try store.save(attempts + [pending])
        attempts.append(pending)
        return pending
    }

    /// Sends the waiting answers, oldest first, until the queue is empty or one cannot go yet.
    /// A pass already running is joined rather than started twice.
    @discardableResult
    public func flush() async -> FlushReport {
        if let running {
            return await running.value
        }
        let task = Task { await self.sendWaiting() }
        running = task
        return await task.value
    }

    /// Forgets every waiting answer, such as when she signs out.
    public func removeAll() throws(StorageError) {
        try store.save([])
        attempts.removeAll()
    }

    private func sendWaiting() async -> FlushReport {
        defer { running = nil }
        var report = FlushReport()
        // Read the front of the live list each time, so answers added during the pass go out in it too.
        while let next = attempts.first {
            let delivery: Result<SavedAttempt, QBankError>
            do {
                delivery = .success(try await sender.recordAttempt(next.submission))
            } catch {
                delivery = .failure(error)
            }
            switch delivery {
            case .success(let saved):
                report.sent.append(saved)
            case .failure(let error) where Self.keepsWaiting(after: error):
                report.stoppedBy = error
                report.remaining = attempts.count
                return report
            case .failure(let error):
                report.refused.append(RefusedAttempt(attempt: next, error: error))
            }
            let rest = attempts.filter { $0.id != next.id }
            do {
                try store.save(rest)
            } catch {
                // The server has it or refused it. If the file still lists it, the next pass sends it
                // again and the server answers with what it saved, so stopping here loses nothing.
                attempts = rest
                report.stoppedBy = .storage(error)
                report.remaining = attempts.count
                return report
            }
            attempts = rest
        }
        report.remaining = 0
        return report
    }

    /// Whether an answer should stay on the phone after this error, rather than be dropped.
    /// It stays when trying again later can succeed without her changing the answer.
    static func keepsWaiting(after error: QBankError) -> Bool {
        switch error {
        case .transport, .cancelled, .notSignedIn, .storage:
            return true
        case .invalidRequest:
            return false
        case .server(let server):
            if server.status >= 500 || server.status == 429 || server.status == 401 { return true }
            // A temporary password: the answer goes once a new one is chosen. A store account
            // whose Cloud ended: the answer is kept in the bank once it is back on the phone.
            return server.code == .mustChangePassword || server.code == .cloudRequired
        case .unexpectedResponse(let status, _):
            // A 2xx the app cannot read means the server took it; anything else is a proxy or outage.
            return !(200..<300).contains(status)
        }
    }
}
