import Foundation
import Observation
import QBankKit

/// Settings' Connect an agent, as the web's: she enters the short code her own agent shows, sees
/// the agent's name and what it asks to do, and approves or denies it. The agent picks its key up
/// itself, so no key ever reaches the phone. Under it, her keys, each revocable for good.
@Observable
final class ConnectAgentModel {
    enum Stage: Equatable {
        /// The code field.
        case enter
        /// The agent waiting under `code`, for her to approve or deny.
        case found(code: String, pairing: AgentPairing)
        /// She answered: what came of it, over the code field again.
        case answered(approved: Bool, name: String)
    }

    /// After an approval, how many times the list is read again for the new key, `pickupInterval`
    /// apart: two minutes at 4 seconds, as on the web.
    static let pickupPolls = 30

    var code = ""
    private(set) var stage = Stage.enter
    /// True while a code is looked up or answered.
    private(set) var isBusy = false
    /// What went wrong with the code or the answer, in the server's words.
    private(set) var problem: String?
    /// Until when the server refuses codes after five that matched nothing. Continue waits for it.
    private(set) var lockedUntil: Date?
    /// Newest first, revoked ones included. Nil until the first load answers.
    private(set) var keys: [AgentKey]?
    /// Why the first load failed.
    private(set) var loadProblem: String?
    /// The key being revoked.
    private(set) var revokingID: String?
    private(set) var revokeProblem: String?
    /// "Revoked … It stopped working just now.", until she revokes another.
    private(set) var revoked: String?
    /// After an approval, the ids of the keys listed then, until a new one shows or the polls run out.
    private(set) var watching: Set<String>?

    /// False when she approved before her keys had loaded: there is no earlier list to tell a new key by.
    private var watchingFromLoadedList = true

    private let app: AppModel
    private let now: () -> Date
    private let pickupInterval: Duration

    init(app: AppModel, now: @escaping () -> Date = Date.init, pickupInterval: Duration = .seconds(4)) {
        self.app = app
        self.now = now
        self.pickupInterval = pickupInterval
    }

    /// The admin's keys reach the user account he looks after, and the scopes say so.
    var isAdmin: Bool {
        app.account?.role == .admin
    }

    var canContinue: Bool {
        !isBusy && lockedUntil == nil
    }

    func load() async {
        do {
            keys = try await app.client.agentKeys()
            loadProblem = nil
        } catch {
            if app.handle(error) { return }
            // A list already shown stays, as it was; only a first load says what went wrong.
            if keys == nil {
                loadProblem = Wording.problem(error)
            }
        }
    }

    /// She changed the code: what was said about the last one no longer applies, unless it is how
    /// long the lock lasts.
    func codeChanged() {
        guard lockedUntil == nil else { return }
        problem = nil
    }

    func lookUp() async {
        guard canContinue else { return }
        let userCode = AgentWording.cleanCode(code)
        guard !userCode.isEmpty else {
            problem = AgentWording.noCode
            return
        }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            stage = .found(code: userCode, pairing: try await app.client.agentPairing(code: userCode))
        } catch {
            report(error)
        }
    }

    func answer(approve: Bool) async {
        guard !isBusy, case .found(let userCode, _) = stage else { return }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            let pairing =
                approve
                ? try await app.client.approveAgentPairing(code: userCode)
                : try await app.client.denyAgentPairing(code: userCode)
            code = ""
            stage = .answered(approved: approve, name: pairing.name)
            if approve {
                watchingFromLoadedList = keys != nil
                watching = Set((keys ?? []).map(\.id))
            }
        } catch {
            // Run out or answered elsewhere meanwhile: back to the code, with the server's reason.
            stage = .enter
            report(error)
        }
    }

    /// After an approval the agent picks its key up on its next poll, and only then is it listed:
    /// reads the list again until a key that was not there shows, or the polls run out (all of them
    /// when there was no earlier list to compare against). The screen runs it while `watching` is
    /// set.
    func watchForPickup() async {
        guard let known = watching else { return }
        for _ in 0..<Self.pickupPolls {
            do {
                try await Task.sleep(for: pickupInterval)
            } catch {
                return
            }
            do {
                let listed = try await app.client.agentKeys()
                keys = listed
                loadProblem = nil
                if watchingFromLoadedList, listed.contains(where: { !known.contains($0.id) }) { break }
            } catch {
                if app.handle(error) { return }
            }
        }
        watching = nil
    }

    func revoke(_ key: AgentKey) async {
        guard revokingID == nil else { return }
        revokingID = key.id
        revoked = nil
        revokeProblem = nil
        defer { revokingID = nil }
        do {
            let row = try await app.client.revokeAgentKey(id: key.id)
            keys = keys?.map { $0.id == row.id ? row : $0 } ?? [row]
            revoked = AgentWording.revoked(key.name)
        } catch {
            if app.handle(error) { return }
            revokeProblem = Wording.problem(error)
        }
    }

    /// Lets her enter a code again once the lock's time has passed, and drops the line that said how
    /// long.
    func lockEnded() {
        guard let lockedUntil, now() >= lockedUntil else { return }
        self.lockedUntil = nil
        problem = nil
    }

    private func report(_ error: QBankError) {
        // An ended session signs her out; a temporary password leads to choosing a new one.
        if app.handle(error) { return }
        problem = Wording.problem(error)
        if case .server(let server) = error, server.code == .tooManyAttempts, let seconds = server.retryAfterSeconds {
            lockedUntil = now().addingTimeInterval(TimeInterval(seconds))
        }
    }
}
