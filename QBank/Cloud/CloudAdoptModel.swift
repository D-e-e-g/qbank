import Observation
import QBankKit

/// Taking the bank QBank Cloud already holds for the account, on a second device, for a returning
/// subscriber, or after an upload whose answer was lost (`docs/cloud.md`, the hand-over's second row),
/// and offering this phone's own sets to it as new sets. One screen over the app shows each step.
///
/// QBank Cloud's bank is the authority. Nothing is uploaded and nothing is merged: the app reads QBank
/// Cloud's bank, says what it holds and what only this phone has, and switches to it only on the
/// person's tap (`BankAdoption`). The bank on this phone stays as it was, a safety copy. Its sets that
/// QBank Cloud does not hold are offered then, and from Settings later, and are added through the
/// import every set goes through, as new sets beside any of the same name, on the person's tap only.
/// Nothing on either side is removed or renamed.
///
/// It starts after a Sign in with Apple that the server answers with Cloud on, for a person whose bank
/// is on this phone (`check()`), and when QBank Cloud refuses the move of this phone's bank because it
/// holds one already (`moveRefused()`).
@Observable
final class CloudAdoptModel {
    /// What the look at QBank Cloud found: what its bank holds, and this phone's sets it does not.
    struct Found: Equatable {
        let counts: BankCounts
        /// QBank Cloud's bank as the person counts it.
        let summary: BankSummary
        let onlyOnPhone: [BankOffer.PhoneSet]
    }

    enum Phase: Equatable {
        case idle
        /// Reading QBank Cloud's bank, to compare it with this phone's.
        case looking
        /// QBank Cloud holds a bank: the person decides whether QBank uses it.
        case found(Found)
        /// QBank uses QBank Cloud's bank now, and this phone has no set it lacks.
        case adopted
        /// QBank uses QBank Cloud's bank now; these sets are only on this phone's safety copy.
        case offering([BankOffer.PhoneSet])
        /// Adding the sets offered to QBank Cloud: `done` of `total` so far.
        case adding(done: Int, total: Int)
        /// Every set offered is in QBank Cloud now, as a new set.
        case added(Int)
        /// It stopped, for the reason said; `retry` is what trying again does.
        case failed(String, retry: Retry?)
    }

    /// What trying again after a failure does.
    enum Retry: Equatable {
        case look, use, add
    }

    private(set) var phase = Phase.idle
    /// Whether the screen is over the app.
    private(set) var isShown = false
    /// What the last look found while the bank on this phone is still the one in use, so Settings
    /// offers QBank Cloud's bank after the person said not now. Nil once QBank uses it.
    private(set) var found: Found?
    /// How many of this phone's sets are offered to QBank Cloud, as the record beside the bank names
    /// them, once QBank uses QBank Cloud's bank. Read again when Settings shows.
    private(set) var offeredCount = 0

    @ObservationIgnored weak var app: AppModel?
    /// The adoption a look made, with the bank's key and what it found, for the person's tap.
    @ObservationIgnored private var looked: (adoption: BankAdoption, key: String, finding: BankAdoption.Finding)?
    @ObservationIgnored private var isRunning = false

    var isBusy: Bool {
        switch phase {
        case .looking, .adding: true
        default: false
        }
    }

    /// Whether Settings offers QBank Cloud's bank: a look found one and the bank on this phone is still
    /// the one in use.
    var isOffered: Bool {
        guard let app, app.kind == .free else { return false }
        return found != nil && !isShown
    }

    /// Whether Settings offers to add this phone's sets to QBank Cloud.
    var offersSets: Bool {
        guard let app, app.kind == .store else { return false }
        return offeredCount > 0 && !isShown
    }

    /// After a Sign in with Apple that the server answered with Cloud on, for a person whose bank is on
    /// this phone: looks at QBank Cloud, and asks the person only when it holds a bank. A look that
    /// fails says nothing; the move to QBank Cloud, offered in Settings, finds the same thing.
    func check() async {
        guard !isRunning, !isShown, case .found(let found)? = await look(), found.counts.values.values.contains(where: { $0 > 0 }) else { return }
        guard app?.kind == .free else { return }
        self.found = found
        isShown = true
        phase = .found(found)
    }

    /// QBank Cloud refused the move of this phone's bank because it holds one already: looks at it and
    /// asks the person. The move's screen closes as this one opens.
    func moveRefused() {
        guard !isRunning else { return }
        isShown = true
        phase = .looking
        Task { await ask() }
    }

    /// Looks at QBank Cloud again and asks the person, as from Settings.
    func ask() async {
        guard !isRunning else { return }
        isShown = true
        phase = .looking
        guard let result = await look() else {
            phase = .failed(CloudAdoptWording.notOnThisPhone, retry: nil)
            return
        }
        // A session that ended signed out, which closed the screen already.
        guard result != .idle, isShown else { return }
        phase = result
        if case .found(let found) = result { self.found = found }
    }

    /// The person said yes: QBank uses QBank Cloud's bank from now on. The bank on this phone stays as
    /// it was, its writes held, and the sets only it has are offered next.
    func use() {
        guard let app, let looked, app.phoneKey == looked.key else {
            phase = .failed(CloudAdoptWording.notOnThisPhone, retry: nil)
            return
        }
        switch looked.adoption.adopt(looked.finding) {
        case .success:
            self.looked = nil
            found = nil
            app.bankAdopted(looked.key)
            showOffer()
        case .failure(let failure):
            phase = .failed(CloudAdoptWording.problem(failure), retry: CloudAdoptWording.canRetry(failure) ? .use : nil)
        }
    }

    /// Offers this phone's sets again, as from Settings.
    func offerSets() {
        guard !isRunning else { return }
        isShown = true
        showOffer()
    }

    /// Adds every set offered to QBank Cloud as a new set, one import at a time, into the course or
    /// topic and folder of the same name. The record beside the bank keeps offering only the ones that
    /// did not go.
    func add() async {
        guard let app, !isRunning, let offer = app.phoneOffer(), !offer.sets.isEmpty else {
            showOffer()
            return
        }
        isRunning = true
        defer { isRunning = false }
        let total = offer.sets.count
        phase = .adding(done: 0, total: total)
        let client = app.client
        var added: Set<String> = []
        var problem: String?
        do {
            let catalog = try await client.catalog()
            for set in offer.sets {
                let request = try BankOffer.importRequest(for: set, from: offer.store, into: catalog)
                guard case .imported = try await client.importSet(request) else {
                    problem = CloudAdoptWording.notAdded
                    break
                }
                added.insert(set.id)
                phase = .adding(done: added.count, total: total)
            }
        } catch let error as QBankError {
            // A session that ended signs out, and Cloud that ended brings the bank back; either covers this.
            if app.handle(error) {
                isShown = false
                phase = .idle
                return
            }
            problem = Wording.problem(error) ?? CloudAdoptWording.notAdded
        } catch {
            problem = CloudAdoptWording.notAdded
        }
        let kept = (try? offer.record.save(try offer.record.load().offering(offer.ids.filter { !added.contains($0) }))) != nil
        refreshOffer()
        if let problem {
            phase = .failed(CloudAdoptWording.someAdded(added.count, of: total, problem: problem), retry: .add)
        } else if !kept {
            phase = .failed(CloudAdoptWording.addedNotNoted(added.count), retry: nil)
        } else {
            phase = .added(added.count)
        }
    }

    /// Tries again what failed.
    func retry(_ retry: Retry) async {
        switch retry {
        case .look: await ask()
        case .use: use()
        case .add: await add()
        }
    }

    /// The person closed the screen. What was found stays for Settings.
    func close() {
        guard !isBusy else { return }
        isShown = false
        phase = .idle
    }

    /// Reads again how many sets are offered, as Settings shows them.
    func refreshOffer() {
        offeredCount = app?.phoneOffer()?.sets.count ?? 0
    }

    /// No one is signed in: nothing found is left.
    func reset() {
        isShown = false
        found = nil
        offeredCount = 0
        looked = nil
        phase = .idle
    }

    /// Downloads QBank Cloud's bank and compares it with this phone's. Nil when there is no bank on
    /// this phone to compare.
    private func look() async -> Phase? {
        guard let app, let made = app.bankAdoption() else { return nil }
        isRunning = true
        defer { isRunning = false }
        switch await made.adoption.look() {
        case .success(let finding):
            looked = (made.adoption, made.key, finding)
            return .found(Found(counts: finding.counts, summary: finding.summary, onlyOnPhone: finding.onlyOnPhone))
        case .failure(let failure):
            if case .notDownloaded(let error) = failure, error.needsSignIn, app.handle(error) { return .idle }
            return .failed(CloudAdoptWording.problem(failure), retry: .look)
        }
    }

    /// The sets offered now, or that QBank uses QBank Cloud's bank when there are none.
    private func showOffer() {
        let sets = app?.phoneOffer()?.sets ?? []
        offeredCount = sets.count
        phase = sets.isEmpty ? .adopted : .offering(sets)
    }
}

/// This phone's sets offered to QBank Cloud once QBank uses QBank Cloud's bank, read from the safety
/// copy, opened only to read, with the record beside it that names them.
struct PhoneOffer {
    /// The sets offered that the safety copy holds, in the order Home lists them.
    let sets: [BankOffer.PhoneSet]
    /// Every set the record offers.
    let ids: [String]
    /// The safety copy, which nothing writes to.
    let store: LocalStore
    let record: BankHandoverRecord
}
