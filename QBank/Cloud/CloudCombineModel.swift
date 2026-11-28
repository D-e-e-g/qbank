import Observation
import QBankKit

/// Combining the bank on this phone with the bank QBank holds for the account (`docs/cloud.md`,
/// Combining two banks), and the screen over the app that shows it.
///
/// It is for a free account, whose bank is on this phone, when QBank's server holds a bank too, as
/// `GET /api/me/cloud` says by its stamp. With Cloud on it combines up (`BankCombineUp`): QBank
/// Cloud's bank is downloaded, the bank on this phone is combined into it and checked, the result is
/// stored in QBank Cloud, its counts are compared, and only then does QBank use QBank Cloud's bank,
/// the bank file on this phone staying as it was, the safety copy. With Cloud not on, when the bank
/// QBank holds is one this phone has not taken in, it combines down (`BankHandBack` combining): into a
/// fresh dated file, as the hand-back does, checked, and only then the bank in use; nothing is sent.
/// Any other ending leaves the bank on this phone the one in use, as it was, and says why.
///
/// A combine starts without asking first: after a Sign in with Apple for a person whose bank is on
/// this phone (`check()`), when Cloud turns on and QBank Cloud holds a bank already, or refuses a move
/// because it does (`moveRefused()`), and at launch when the app was closed during one
/// (`finishLeftOpen()`). While one is still to do, after a failure, Settings offers it in one row,
/// also after QBank is closed and opened again. While the server says combining is paused, none starts.
@Observable
final class CloudCombineModel {
    /// Which way a combine goes.
    enum Direction: Equatable {
        /// Into QBank Cloud, which this phone then uses.
        case up
        /// Into a fresh file on this phone, which it then uses.
        case down
    }

    /// The steps the screen lists. A combine down sends nothing, so it has no `sending`.
    enum Step: Hashable {
        case reading, combining, sending, checking

        init(_ step: BankCombineUp.Step) {
            switch step {
            case .reading: self = .reading
            case .combining: self = .combining
            case .sending: self = .sending
            case .checking: self = .checking
            }
        }

        init(_ step: BankHandBack.Step) {
            switch step {
            case .downloading: self = .reading
            case .combining, .writing: self = .combining
            case .checking: self = .checking
            }
        }
    }

    /// What a combine that switched did, as the person counts it.
    struct Combined: Equatable {
        let direction: Direction
        /// The one bank now.
        let summary: BankSummary
        /// The sets and answers only this phone had, which the bank gained.
        let addedSets: Int
        let addedAnswers: Int
        /// Whether a row both banks held differed, so the later change was kept.
        let changedInBoth: Bool
        /// Whether a change was not applied because its name was taken (WIN-14).
        let namesKept: Bool

        init(_ direction: Direction, _ ledger: BankCombine.Ledger) {
            self.direction = direction
            summary = ledger.combined
            addedSets = max(0, ledger.phone.sets - ledger.inBoth.sets)
            addedAnswers = max(0, ledger.phone.answers - ledger.inBoth.answers)
            changedInBoth = !ledger.changedInBoth.isEmpty
            namesKept = !ledger.namesKept.isEmpty
        }
    }

    enum Phase: Equatable {
        case idle
        /// The combine is at this step.
        case combining(Step)
        /// The two banks are one now.
        case combined(Combined)
        /// The bank on this phone stays the one in use, for the reason said; `canRetry` when trying
        /// again may help.
        case failed(String, canRetry: Bool)
    }

    private(set) var phase = Phase.idle
    /// Whether the combine's screen is over the app: from its start until its outcome is read.
    private(set) var isShown = false
    /// Which way the combine on screen goes.
    private(set) var direction = Direction.up
    /// The stamp of the bank QBank holds that this phone last took in, as the record beside the bank
    /// names it: read again whenever the server says what it holds.
    private(set) var takenIn: String?

    @ObservationIgnored weak var app: AppModel?
    /// True while `start()` runs a combine, so one runs at a time.
    @ObservationIgnored private var isRunning = false
    /// The combine the app was closed during, waiting to run again at launch.
    @ObservationIgnored private var leftOpen: Direction?

    var isCombining: Bool {
        if case .combining = phase { return true }
        return false
    }

    /// Which combine is still to do, as the server last said: up while Cloud is on and QBank Cloud
    /// holds a bank, down while Cloud is not on and QBank holds one this phone has not taken in. Nil
    /// for an account whose bank is not on this phone, and until the server has said.
    var due: Direction? {
        guard let app, app.kind == .free, !app.awaitsServer, let status = app.cloud.status, let stamp = app.cloud.bank?.stamp else { return nil }
        if status.active { return .up }
        return stamp != takenIn ? .down : nil
    }

    /// Whether Settings offers the combine: one is still to do, and none is on screen.
    var isOffered: Bool {
        due != nil && !isShown && !isRunning && leftOpen == nil
    }

    /// The server said what it holds: reads again which stamp this phone took in.
    func statusRead() {
        takenIn = app?.takenInStamp()
    }

    /// After a Sign in with Apple for a person whose bank is on this phone: asks the server what it
    /// holds, and combines when a combine is due and not paused. A server that cannot say says nothing;
    /// Settings asks it again.
    func check() async {
        guard let app, !isRunning, !isShown, (try? await app.cloud.read()) != nil, due != nil, app.cloud.bank?.combinePaused == false else { return }
        await start(reading: false)
    }

    /// QBank Cloud refused the move of this phone's bank because it holds one already: the two are
    /// combined instead. The move's screen gives way to this one.
    func moveRefused() async {
        guard !isRunning else { return }
        await start()
    }

    /// Whether a move to QBank Cloud, about to start, should be a combine up instead, because QBank
    /// Cloud holds a bank already: asks the server, and runs the combine when it should. A server that
    /// cannot say lets the move go on, which it refuses with `bank_not_empty` when it holds a bank.
    func takesOverMove() async -> Bool {
        guard let app, !isRunning, (try? await app.cloud.read()) != nil, due == .up else { return false }
        await start(reading: false)
        return true
    }

    /// The record beside the bank holds the lease of a combine the app was closed during. Its screen
    /// shows at once, and `finishLeftOpen()` runs it again from the start.
    func foundLeftOpen(_ direction: Direction) {
        leftOpen = direction
        self.direction = direction
        isShown = true
        phase = .combining(.reading)
    }

    /// Runs again a combine the app was closed during, before anything else. Its lease is let go of
    /// first, the bank on this phone still the one in use, so a combine that does not run, as while
    /// combining is paused, leaves the bank taking writes. The whole combine then runs again: it
    /// switches only once its checks hold.
    func finishLeftOpen() async {
        guard let app, let leftOpen else { return }
        self.leftOpen = nil
        if leftOpen == .up { app.letGoCombineLeftOpen() }
        await start()
    }

    /// Combines now, as the server says: asks it what it holds first, unless `reading` is false because
    /// it was just asked. Nothing starts while combining is paused, and nothing when no combine is due.
    func start(reading: Bool = true) async {
        guard let app, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        if reading {
            isShown = true
            phase = .combining(.reading)
            do {
                try await app.cloud.read()
            } catch {
                if app.handle(error) { return }
                guard isShown else { return }
                phase = .failed(CloudCombineWording.statusUnread, canRetry: true)
                return
            }
        }
        guard let direction = due else {
            close(force: true)
            return
        }
        guard app.cloud.bank?.combinePaused == false else {
            isShown = true
            phase = .failed(CloudCombineWording.paused, canRetry: false)
            return
        }
        self.direction = direction
        isShown = true
        phase = .combining(.reading)
        switch direction {
        case .up: await combineUp(app)
        case .down: await combineDown(app)
        }
    }

    private func combineUp(_ app: AppModel) async {
        guard let made = app.bankCombineUp() else {
            phase = .failed(CloudCombineWording.notOnThisPhone, canRetry: false)
            return
        }
        let outcome = await made.combine.run { [weak self] step in
            await self?.show(Step(step))
        }
        switch outcome {
        case .combined(let ledger, _, _):
            app.bankCombinedUp(made.key)
            // A sign-out during the combine, after a session ended, already closed the screen.
            guard isShown else { return }
            phase = .combined(Combined(.up, ledger))
        case .failed(let failure, _):
            // A session that ended signs out, as everywhere; the bank stays on this phone as it was.
            if case .notStored(let error) = failure, app.handle(error) { return }
            if case .notDownloaded(let error) = failure, error.needsSignIn, app.handle(error) { return }
            guard isShown else { return }
            phase = .failed(CloudCombineWording.problem(failure), canRetry: CloudCombineWording.canRetry(failure))
        }
    }

    private func combineDown(_ app: AppModel) async {
        guard let made = app.bankCombineDown() else {
            phase = .failed(CloudCombineWording.notOnThisPhone, canRetry: false)
            return
        }
        let outcome = await made.handBack.run { [weak self] step in
            await self?.show(Step(step))
        }
        switch outcome {
        case .returned(_, let store, _, let ledger):
            app.bankCombinedDown(made.key, store: store)
            statusRead()
            guard isShown else { return }
            if let ledger {
                phase = .combined(Combined(.down, ledger))
            } else {
                close(force: true)
            }
        case .failed(let failure, _):
            if case .notDownloaded(let error) = failure, error.needsSignIn, app.handle(error) { return }
            guard isShown else { return }
            phase = .failed(CloudCombineWording.problem(failure), canRetry: CloudCombineWording.canRetry(failure))
        }
    }

    /// The person read the outcome: the screen closes. A combine that failed stays offered in Settings.
    func close(force: Bool = false) {
        guard force || !isCombining else { return }
        isShown = false
        phase = .idle
    }

    /// No one is signed in: nothing of a combine is left to show.
    func reset() {
        isShown = false
        leftOpen = nil
        takenIn = nil
        phase = .idle
    }

    private func show(_ step: Step) {
        guard isCombining else { return }
        phase = .combining(step)
    }
}
