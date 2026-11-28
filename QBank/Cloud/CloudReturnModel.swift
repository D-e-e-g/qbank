import Observation
import QBankKit

/// Bringing a store account's bank back from QBank Cloud to this phone once Cloud has ended
/// (`docs/cloud.md`, the hand-over's third row), and the screen over the app that shows it.
///
/// The hand-back itself is `BankHandBack`: the whole bank downloaded into a fresh file, its counts
/// compared with the download's table by table, the answers this phone was still waiting to send kept
/// in it, and only then the switch, after which the bank is on this phone again and QBank Cloud's copy
/// is left as it is. Any other ending leaves QBank Cloud's bank the one in use, every file on this
/// phone as it was, and says why in plain words.
///
/// It starts on its own once QBank's server says Cloud has ended for an account whose bank is in QBank
/// Cloud (`cloudEnded()`): when the session or Cloud's state says so, or when a request is refused with
/// `cloud_required`. It starts once per launch on its own: after the person put off one that failed,
/// Settings offers it again until the next launch. While it runs, its screen covers the app. A bank
/// QBank holds that this phone's own bank meets is combined with it instead (`CloudCombineModel`).
@Observable
final class CloudReturnModel {
    enum Phase: Equatable {
        case idle
        /// The hand-back is at this step.
        case returning(BankHandBack.Step)
        /// The bank is on this phone again, which holds these counts, the same as QBank Cloud's.
        case returned(BankSummary?)
        /// QBank Cloud's bank stays in use, for the reason said; `canRetry` when trying again may help.
        case failed(String, canRetry: Bool)
    }

    private(set) var phase = Phase.idle
    /// Whether the hand-back's screen is over the app: from its start until its outcome is read.
    private(set) var isShown = false
    /// True once Cloud has ended for the account while its bank is in QBank Cloud, until it is back.
    private(set) var isDue = false

    @ObservationIgnored weak var app: AppModel?
    /// True while `start()` runs a hand-back, so one runs at a time.
    @ObservationIgnored private var isRunning = false
    /// True once the person closed a hand-back that failed: it waits for them, in Settings.
    @ObservationIgnored private var isPutOff = false

    var isReturning: Bool {
        if case .returning = phase { return true }
        return false
    }

    /// Whether Settings offers to bring the bank back: Cloud has ended, the bank is still in QBank
    /// Cloud, and no hand-back is running or on screen.
    var isOffered: Bool {
        guard let app, app.kind == .store else { return false }
        return isDue && !isShown && !isRunning
    }

    /// QBank's server said Cloud has ended for the account signed in. For a store account whose bank
    /// is in QBank Cloud the bank comes back now, unless the person put off a hand-back that failed.
    /// Returns whether the hand-back's screen is over the app.
    @discardableResult
    func cloudEnded() -> Bool {
        guard let app, app.kind == .store else { return false }
        isDue = true
        guard !isShown else { return true }
        guard !isPutOff, !isRunning else { return false }
        isShown = true
        phase = .returning(.downloading)
        Task { await start() }
        return true
    }

    /// QBank's server said Cloud is on again, as after a purchase: the bank stays in QBank Cloud.
    func cloudTurnedOn() {
        isDue = false
        isPutOff = false
        guard !isRunning, !isReturning else { return }
        isShown = false
        phase = .idle
    }

    /// Brings the bank back now: on its own once Cloud has ended, or when the person asks.
    func start() async {
        guard let app, !isRunning, app.kind == .store else { return }
        isRunning = true
        defer { isRunning = false }
        isPutOff = false
        guard let made = app.bankHandBack() else {
            if isShown { phase = .failed(CloudReturnWording.notInCloud, canRetry: false) }
            return
        }
        isShown = true
        phase = .returning(.downloading)
        let outcome = await made.handBack.run { [weak self] step in
            await self?.show(step)
        }
        switch outcome {
        case .returned(_, let store, _, _):
            let summary = try? BankSummary.of(store)
            await app.bankReturnedToPhone(made.key, store: store)
            isDue = false
            // A sign-out during the hand-back already closed the screen.
            guard isShown else { return }
            phase = .returned(summary)
        case .failed(let failure, _):
            // A session that ended signs out, as everywhere; the bank stays in QBank Cloud.
            if case .notDownloaded(let error) = failure, error.needsSignIn, app.handle(error) { return }
            guard isShown else { return }
            phase = .failed(CloudReturnWording.problem(failure), canRetry: CloudReturnWording.canRetry(failure))
        }
    }

    /// The person read the outcome: the screen closes. A hand-back that failed waits for them then.
    func close() {
        guard !isReturning else { return }
        if case .failed = phase { isPutOff = true }
        isShown = false
        phase = .idle
    }

    /// No one is signed in: nothing of a hand-back is left to show.
    func reset() {
        isShown = false
        isDue = false
        isPutOff = false
        phase = .idle
    }

    private func show(_ step: BankHandBack.Step) {
        guard isReturning else { return }
        phase = .returning(step)
    }
}

/// The answers a store account was waiting to send to QBank Cloud, kept in the bank that came back to
/// this phone: the local engine records each once, by its `clientAttemptId`, as the server does, so
/// keeping one twice changes nothing.
nonisolated enum HandBackAnswers {
    /// Records each of `waiting` in the bank in `store`, through `client`'s routing to it. An answer the
    /// bank refuses for good, as QBank Cloud would have, is left out, as the answer queue leaves out one
    /// QBank refuses; any other failure throws, and the hand-back keeps QBank Cloud's bank.
    static func keep(_ waiting: [PendingAttempt], in store: LocalStore, through client: QBankClient) async throws {
        guard !waiting.isEmpty else { return }
        let bank = client.routingBank(to: LocalBank(store: store))
        for pending in waiting {
            do {
                _ = try await bank.recordAttempt(pending.submission)
            } catch {
                if case .server(let refusal) = error, (400..<500).contains(refusal.status) { continue }
                throw error
            }
        }
    }
}
