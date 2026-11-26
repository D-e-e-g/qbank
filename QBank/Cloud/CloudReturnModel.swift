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
/// Settings offers it again until the next launch. While it runs, its screen covers the app.
///
/// For an account whose Cloud is not on that signs in on a phone with no bank of its own for the
/// person yet, it looks at whether QBank holds a bank for them (`lookForServerBank()`), and only then
/// offers, on one screen, to bring it to this phone. Bringing it is the same hand-back, into a fresh
/// file, in place of the bank this phone just made, which stays as it was, an earlier copy whose own
/// sets are offered to add next. Not now keeps the bank on this phone, and Settings offers QBank's.
/// Nothing in QBank is changed or deleted either way.
@Observable
final class CloudReturnModel {
    enum Phase: Equatable {
        case idle
        /// QBank holds this bank for an account whose Cloud is not on: the person decides whether it
        /// comes to this phone, in place of the one here.
        case offered(BankSummary)
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
    /// The bank QBank holds for an account whose Cloud is not on, found when it signed in on this phone
    /// with no bank of its own yet, as the person counts it: kept for Settings after they said not now.
    /// Nil once it is on this phone.
    private(set) var serverBank: BankSummary?
    /// True while the hand-back on screen brings QBank's bank in place of a bank on this phone, rather
    /// than back from QBank Cloud.
    private(set) var bringsHere = false

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

    /// Whether Settings offers to bring QBank's bank to this phone: the person said not now to it, and
    /// the bank on this phone is still the one in use.
    var offersServerBank: Bool {
        guard let app, app.kind == .free else { return false }
        return serverBank != nil && !isShown && !isRunning
    }

    /// After a Sign in with Apple for an account whose Cloud is not on, on a phone that had no bank of
    /// its own for the person: looks at whether QBank holds a bank for them, reading it without writing
    /// anywhere, and offers to bring it here only then. A look that fails says nothing.
    func lookForServerBank() async {
        guard let app, !isRunning, !isShown, let made = app.bankAdoption() else { return }
        isRunning = true
        let looked = await made.adoption.look()
        isRunning = false
        switch looked {
        case .success(let finding):
            guard finding.cloudHasBank, app.kind == .free, app.phoneKey == made.key, !isShown else { return }
            serverBank = finding.summary
            offerServerBank()
        case .failure(let failure):
            if case .notDownloaded(let error) = failure, error.needsSignIn { app.handle(error) }
        }
    }

    /// Offers QBank's bank again, as from Settings.
    func offerServerBank() {
        guard let serverBank, !isRunning else { return }
        isShown = true
        phase = .offered(serverBank)
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
        serverBank = nil
        guard !isRunning, !isReturning else { return }
        isShown = false
        phase = .idle
    }

    /// Brings the bank back now: on its own once Cloud has ended, or when the person asks. For a bank on
    /// this phone, brings QBank's bank in its place, only once a look found one and the person asked.
    func start() async {
        guard let app, !isRunning, app.kind == .store || serverBank != nil else { return }
        isRunning = true
        defer { isRunning = false }
        isPutOff = false
        bringsHere = app.kind == .free
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
        case .returned(_, let store, _):
            let summary = try? BankSummary.of(store)
            await app.bankReturnedToPhone(made.key, store: store)
            isDue = false
            serverBank = nil
            app.cloudAdopt.refreshOffer()
            // A sign-out during the hand-back already closed the screen.
            guard isShown else { return }
            phase = .returned(summary)
        case .failed(let failure, _):
            // A session that ended signs out, as everywhere; the bank stays in QBank Cloud.
            if case .notDownloaded(let error) = failure, error.needsSignIn, app.handle(error) { return }
            guard isShown else { return }
            phase = .failed(CloudReturnWording.problem(failure, bringsHere: bringsHere), canRetry: CloudReturnWording.canRetry(failure))
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
        serverBank = nil
        bringsHere = false
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
