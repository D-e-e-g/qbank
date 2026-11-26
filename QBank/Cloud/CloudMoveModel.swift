import Observation
import QBankKit

/// Moving a free account's bank to QBank Cloud once the server says Cloud is on (`docs/cloud.md`, the
/// hand-over), and the screen over the app that shows it.
///
/// The move itself is `BankMoveToCloud`: a lease on this phone, the whole bank uploaded as one archive,
/// the server's counts compared with the phone's table by table, and only then the switch, after which
/// the account is on the server and the bank file on this phone stays as it was, a safety copy. Any
/// other ending leaves the bank on this phone the authority, unchanged, and says why in plain words.
///
/// A move starts when a purchase or Restore turns Cloud on: once the plans sheet has closed (`isDue`),
/// or at once when it already has; when the person asks for it in Settings; and at launch, before
/// anything else, when the app was closed during one (`foundLeftOpen()`). While it runs, its screen covers the app and the
/// bank takes no writes. When QBank Cloud refuses the bank because it holds one for the account already,
/// as on a second device or after an upload whose answer was lost, that bank is the authority and the
/// person is asked about it (`CloudAdoptModel`).
@Observable
final class CloudMoveModel {
    enum Phase: Equatable {
        case idle
        /// The move is at this step.
        case moving(BankMoveToCloud.Step)
        /// The bank is in QBank Cloud, which holds every row this phone's bank does: the bank as the
        /// person counts it, when it could be read.
        case moved(BankSummary?)
        /// The bank stays on this phone, for the reason said; `canRetry` when trying again may help.
        case failed(String, canRetry: Bool)
    }

    private(set) var phase = Phase.idle
    /// Whether the move's screen is over the app: from the start of a move until its outcome is read.
    private(set) var isShown = false
    /// True once a purchase or Restore turned Cloud on with the bank on this phone: the move starts once
    /// the plans sheet has closed, so its screen does not open over the sheet.
    private(set) var isDue = false
    /// True while a move the app was closed during waits to be finished at launch.
    private(set) var isLeftOpen = false
    /// True while the move shown is one the app was closed during, run again from the start.
    private(set) var isResumed = false

    @ObservationIgnored weak var app: AppModel?
    /// True while `start()` runs a move, so one runs at a time.
    @ObservationIgnored private var isRunning = false
    /// True while the plans sheet is open, so a move Cloud turning on makes due waits for it to close.
    @ObservationIgnored private var plansAreOpen = false

    var isMoving: Bool {
        if case .moving = phase { return true }
        return false
    }

    /// Whether the bank on this phone can be moved now: a free account's, with Cloud on as the server
    /// last said, and no move already running or waiting.
    var isOffered: Bool {
        guard let app, app.kind == .free, !app.awaitsServer, app.cloud.status?.active == true, app.cloudAdopt.found == nil else { return false }
        return !isMoving && !isDue && !isLeftOpen
    }

    /// The server just said Cloud is on, after a purchase or Restore. With the plans sheet open the
    /// move waits for it to close, so its screen does not open over the sheet; the sheet may also have
    /// been closed while the purchase was on its way to the server, and then the move starts now.
    func cloudTurnedOn() {
        guard let app, app.kind == .free, !app.awaitsServer, !isMoving, !isRunning else { return }
        if plansAreOpen {
            isDue = true
        } else {
            Task { await start() }
        }
    }

    /// The person asked to move the bank from the plans sheet, which closes first.
    func ask() {
        guard isOffered else { return }
        isDue = true
    }

    /// The plans sheet opened.
    func plansOpened() {
        plansAreOpen = true
    }

    /// The plans sheet closed: a move that was due starts now.
    func plansClosed() async {
        plansAreOpen = false
        guard isDue else { return }
        await start()
    }

    /// The bank's record holds the lease of a move the app was closed during. Its screen shows at once,
    /// and `finishLeftOpen()` runs the move again from the start.
    func foundLeftOpen() {
        isLeftOpen = true
        isResumed = true
        isShown = true
        phase = .moving(.writing)
    }

    /// Finishes a move the app was closed during, before anything else. Its earlier upload may never
    /// have reached the server, so the whole move runs again: it switches only on counts that match,
    /// and any failure gives the lease back with the bank on this phone as it was.
    func finishLeftOpen() async {
        guard isLeftOpen else { return }
        isLeftOpen = false
        await start(resumed: true)
    }

    /// Moves the bank on this phone to QBank Cloud now. `resumed` when it runs again a move the app was
    /// closed during.
    func start(resumed: Bool = false) async {
        guard let app, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        isDue = false
        isResumed = resumed
        guard let made = app.bankMove() else {
            if isShown { phase = .failed(CloudMoveWording.notOnThisPhone, canRetry: false) }
            return
        }
        let (move, key) = made
        isShown = true
        phase = .moving(.writing)
        let outcome = await move.run { [weak self] step in
            await self?.show(step)
        }
        switch outcome {
        case .moved:
            let summary = app.phoneBankSummary()
            app.bankMovedToCloud(key)
            // A sign-out during the move, after a session ended, already closed the screen.
            guard isShown else { return }
            phase = .moved(summary)
        case .failed(let failure, _):
            // QBank Cloud holds a bank for the account already: that bank is the authority, and the
            // person is asked about it, the bank on this phone still as it was.
            if case .notStored(let error) = failure, error.serverCode == .bankNotEmpty {
                app.cloudAdopt.moveRefused()
                isShown = false
                isResumed = false
                phase = .idle
                return
            }
            // A session that ended signs out, as everywhere; the bank stays on this phone as it was.
            if case .notStored(let error) = failure, app.handle(error) { return }
            guard isShown else { return }
            phase = .failed(CloudMoveWording.problem(failure), canRetry: CloudMoveWording.canRetry(failure))
        }
    }

    /// The person read the outcome: the screen closes.
    func close() {
        guard !isMoving else { return }
        isShown = false
        isResumed = false
        phase = .idle
    }

    /// No one is signed in: nothing of a move is left to show.
    func reset() {
        isShown = false
        isDue = false
        isLeftOpen = false
        isResumed = false
        phase = .idle
    }

    private func show(_ step: BankMoveToCloud.Step) {
        guard isMoving else { return }
        phase = .moving(step)
    }
}
