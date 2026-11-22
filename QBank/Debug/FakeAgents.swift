#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// The fake server's agent pairings and keys, answered the way the real routes answer them
/// (`apps/api/src/routes/agents.ts`): an agent waits under a code; she looks it up and approves or
/// denies it; an approved agent picks its key up on its next poll, a moment later here, and only
/// then is the key listed. Five codes that match nothing lock her answers for 15 minutes; a code
/// that matches clears the count. The codes here never run out: each look finds its agent a minute
/// into its 10 minutes, so a long look by hand still finds them. No key itself is ever made or sent.
nonisolated final class FakeAgents: Sendable {
    /// Her agent's key, made 45 days ago and last used an hour ago. It imported Mixed Clinical Judgment.
    static let macKey = (id: "fake-agent-key-mac", name: "My MacBook agent")
    /// An agent waiting to import sets and read progress.
    static let importCode = "KXPD-MWRT"
    static let importAgent = "Study laptop agent"
    /// An agent waiting to import sets and add, change, and delete her content.
    static let manageCode = "HZNB-QLVS"
    static let manageAgent = "Library desktop agent"
    /// The set her agent imported.
    static let importedSetID = "mixed-v1"
    /// How long after an approval the agent picks its key up, as on its next poll.
    static let pickupDelay: TimeInterval = 1.5

    /// The server's plain words for each scope (`AGENT_SCOPE_TEXT`).
    private static let scopeTexts = [
        "import": "Import question sets into your courses and topics, and see your courses, folders and sets to do it.",
        "read": "Read how you answered: where you stand by topic, your Review lists, your exams and your progress export. It changes nothing.",
        "manage": "Add, change and delete your courses, topics, folders and sets, as you can in QBank: make and rename them, move sets, replace or restore a set's questions, and set up exam and study pages. Anything it deletes goes to Recently deleted, where you can bring it back for 30 days. It never answers questions for you.",
    ]

    private struct Pairing {
        /// In capitals, without its dash, as the server compares codes.
        let userCode: String
        let name: String
        let scopes: [String]
        var status = "pending"
        /// Who approved it, and when, until the agent picks its key up.
        var approved: (email: String, at: Date)?
    }

    private struct Key {
        let id: String
        let email: String
        let name: String
        let scopes: [String]
        let createdAt: Date
        var lastUsedAt: Date?
        var revokedAt: Date?
    }

    private struct State {
        var pairings: [Pairing]
        /// Newest first, as the server lists them.
        var keys: [Key]
        /// Codes that matched nothing, by email, since the last that matched.
        var misses: [String: Int] = [:]
        var lockedUntil: [String: Date] = [:]
        var count = 0
    }

    private let state: Mutex<State>

    init(studentEmail: String, now: Date) {
        state = Mutex(
            State(
                pairings: [
                    Pairing(userCode: Self.normalized(Self.importCode), name: Self.importAgent, scopes: ["import", "read"]),
                    Pairing(userCode: Self.normalized(Self.manageCode), name: Self.manageAgent, scopes: ["import", "manage"]),
                ],
                keys: [
                    Key(
                        id: Self.macKey.id, email: studentEmail, name: Self.macKey.name, scopes: ["import", "read"],
                        createdAt: now.addingTimeInterval(-45 * 86_400), lastUsedAt: now.addingTimeInterval(-3600)
                    )
                ]
            ))
    }

    static func handles(_ path: String) -> Bool {
        path.hasPrefix("/api/agent-pairings/") || path == "/api/agent-keys" || path.hasPrefix("/api/agent-keys/")
    }

    /// The agent key that imported a set, as a set's `importedByAgent` names it, or nil.
    static func importer(ofSet id: String) -> [String: Any]? {
        id == importedSetID ? ["id": macKey.id, "name": macKey.name] : nil
    }

    /// The answer for a signed-in account that has its own password.
    func answer(method: String, path: String, body: [String: Any], email: String) -> (Int, [String: Any]) {
        let now = Date.now
        pickUpKeys(now: now)
        switch (method, path) {
        case ("POST", "/api/agent-pairings/lookup"):
            return byCode(body, email: email, now: now) { state, index in state.pairings[index] }
        case ("POST", "/api/agent-pairings/approve"), ("POST", "/api/agent-pairings/deny"):
            let approve = path.hasSuffix("/approve")
            return byCode(body, email: email, now: now) { state, index in
                state.pairings[index].status = approve ? "approved" : "denied"
                if approve { state.pairings[index].approved = (email, now) }
                return state.pairings[index]
            }
        case ("GET", "/api/agent-keys"):
            return (200, ["keys": state.withLock { state in state.keys.filter { $0.email == email }.map(Self.json) }])
        case ("POST", _) where path.hasPrefix("/api/agent-keys/") && path.hasSuffix("/revoke"):
            let id = String(path.dropFirst("/api/agent-keys/".count).dropLast("/revoke".count))
            let key = state.withLock { state -> Key? in
                guard let index = state.keys.firstIndex(where: { $0.id == id && $0.email == email }) else { return nil }
                // Revoking a revoked key changes nothing.
                if state.keys[index].revokedAt == nil { state.keys[index].revokedAt = now }
                return state.keys[index]
            }
            guard let key else { return failure(404, "agent_key_not_found", "You have no agent key with that id.") }
            return (200, Self.json(key))
        default:
            return failure(404, "request_refused", "That is not in the app.")
        }
    }

    /// The pairing waiting under the body's code, changed by `found`, as `byCode` does on the server:
    /// codes count like passwords, and five that match nothing lock her answers for a while.
    private func byCode(
        _ body: [String: Any], email: String, now: Date, found: (inout State, Int) -> Pairing
    ) -> (Int, [String: Any]) {
        let userCode = Self.normalized(body["userCode"] as? String ?? "")
        enum Outcome { case found(Pairing), missed, locked(Int) }
        let outcome = state.withLock { state -> Outcome in
            if let until = state.lockedUntil[email], until > now {
                return .locked(Int(until.timeIntervalSince(now).rounded(.up)))
            }
            if let index = state.pairings.firstIndex(where: { $0.userCode == userCode && $0.status == "pending" }) {
                state.misses[email] = nil
                return .found(found(&state, index))
            }
            let misses = state.misses[email, default: 0] + 1
            guard misses >= 5 else {
                state.misses[email] = misses
                return .missed
            }
            state.misses[email] = nil
            state.lockedUntil[email] = now.addingTimeInterval(900)
            return .locked(900)
        }
        switch outcome {
        case .found(let pairing):
            return (200, Self.json(pairing, now: now))
        case .missed:
            return failure(404, "pairing_not_found", "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.")
        case .locked(let seconds):
            let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
            var (status, body) = failure(429, "too_many_attempts", "Too many tries. Try again in \(minutes) \(minutes == 1 ? "minute" : "minutes").")
            body["retryAfterSeconds"] = seconds
            return (status, body)
        }
    }

    /// An approved agent polls and picks its key up: the key is made then, and listed from then on.
    private func pickUpKeys(now: Date) {
        state.withLock { state in
            for index in state.pairings.indices {
                guard let approved = state.pairings[index].approved, now >= approved.at.addingTimeInterval(Self.pickupDelay) else { continue }
                state.pairings[index].approved = nil
                state.count += 1
                let pairing = state.pairings[index]
                let key = Key(
                    id: "fake-agent-key-\(state.count)", email: approved.email, name: pairing.name, scopes: pairing.scopes,
                    createdAt: approved.at.addingTimeInterval(Self.pickupDelay)
                )
                state.keys.insert(key, at: 0)
            }
        }
    }

    /// "bcdf-ghjk " as the server keeps it: "BCDFGHJK".
    private static func normalized(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    private static func json(_ pairing: Pairing, now: Date) -> [String: Any] {
        let createdAt = now.addingTimeInterval(-60)
        return [
            "name": pairing.name, "scopes": pairing.scopes,
            "scopeTexts": pairing.scopes.map { ["scope": $0, "text": scopeTexts[$0] ?? $0] },
            "status": pairing.status,
            "createdAt": QBankJSON.formatDate(createdAt),
            "expiresAt": QBankJSON.formatDate(createdAt.addingTimeInterval(600)),
        ]
    }

    private static func json(_ key: Key) -> [String: Any] {
        [
            "id": key.id, "name": key.name, "scopes": key.scopes, "createdAt": QBankJSON.formatDate(key.createdAt),
            "lastUsedAt": key.lastUsedAt.map { QBankJSON.formatDate($0) as Any } ?? NSNull(),
            "revokedAt": key.revokedAt.map { QBankJSON.formatDate($0) as Any } ?? NSNull(),
        ]
    }

    private func failure(_ status: Int, _ code: String, _ message: String) -> (Int, [String: Any]) {
        (status, ["error": code, "message": message])
    }
}
#endif
