import Foundation
import QBankKit

/// The lines Connect an agent shows, worded as the web's `apps/web/src/agents/agents.ts` and
/// `AgentsScreen.tsx` word them, so the two apps never disagree. Always "agent", never a product's
/// name.
nonisolated enum AgentWording {
    /// The Settings row's line under "Connect an agent".
    static let settingsDetail = "Approve its code, and see your keys"
    static let intro = "Your agent shows you a short code. Enter it here to see what the agent asks to do, then approve or deny it. You never see or copy a key: the agent picks its own up."
    /// A non-breaking hyphen, so the example code never splits across lines.
    static let codeHint = "The code your agent shows you, such as BCDF\u{2011}GHJK. It lasts 10 minutes."
    static let noCode = "Enter the code your agent shows you."
    static let loadingKeys = "Loading your keys."
    static let noKeys = "No agent keys yet. When you approve an agent, its key shows here."
    static let keysFooter = "Each key works for this account only, and only for what it was approved to do. Revoking one stops it at once; what it imported or changed stays as it is."
    static let revokedKey = "Revoked: it never works again"
    /// The tag beside the scope that reaches the most: calm, never a warning.
    static let mostAccess = "Most access"

    /// The code as she typed or pasted it, trimmed and in capitals; the server takes any case, with
    /// or without its dash.
    static func cleanCode(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    struct ScopeWords: Equatable {
        let title: String
        let detail: String
    }

    /// What the admin's key reaches, whatever it asks for: an agent key reaches only its own
    /// account's content, and the server refuses every use of the admin's.
    static let adminKeyReach = "It reaches nothing. An agent key reaches only its own account's content, and the admin account has none."

    /// What a scope lets an agent do, in plain words, when the server has not described it.
    static func scopeWords(_ scope: AgentScope, admin: Bool) -> ScopeWords {
        if admin {
            return ScopeWords(title: adminScopeTitle(scope), detail: adminKeyReach)
        }
        let whose = "your account"
        switch scope {
        case .import:
            return ScopeWords(
                title: "Import question sets",
                detail: "Into the courses and topics of \(whose), reading them to file each set. It never replaces, moves, renames, or deletes a set."
            )
        case .read:
            return ScopeWords(
                title: "Read progress, read-only",
                detail: "Where you stand by topic, your Review lists, your exams, and your progress export. It changes nothing."
            )
        case .manage:
            return ScopeWords(
                title: "Add, change, and delete your content",
                detail: "The sets, questions, folders, courses, and topics of \(whose), as you can in QBank. Anything it deletes goes to Recently deleted, where Undo brings it back for 30 days."
            )
        default:
            // A scope added after this version: shown by its name, as the contract asks.
            return ScopeWords(title: scope.rawValue, detail: "QBank has not described this one here yet.")
        }
    }

    private static func adminScopeTitle(_ scope: AgentScope) -> String {
        switch scope {
        case .import: "Import question sets"
        case .read: "Read progress, read-only"
        case .manage: "Add, change, and delete content"
        default: scope.rawValue
        }
    }

    /// The scope that reaches the most: an agent with it adds, changes, and deletes her content.
    static func isStrongest(_ scope: AgentScope) -> Bool {
        scope == .manage
    }

    /// One scope a pairing asks for: a short title, the server's plain words when it sent them, and
    /// whether it is the one that reaches the most.
    struct AskedScope: Equatable, Identifiable {
        let scope: AgentScope
        let title: String
        let detail: String
        let isStrongest: Bool

        var id: String { scope.rawValue }
    }

    /// Each scope a pairing asks for, in its order.
    static func pairingScopes(_ pairing: AgentPairing, admin: Bool) -> [AskedScope] {
        pairing.scopes.map { scope in
            let words = scopeWords(scope, admin: admin)
            let text = pairing.scopeTexts.first { $0.scope == scope }?.text
            // The server describes what a user account's key does, which the admin's does not.
            return AskedScope(scope: scope, title: words.title, detail: admin ? words.detail : text ?? words.detail, isStrongest: isStrongest(scope))
        }
    }

    /// "Code BCDFGHJK · Works until 4:12 PM": the code as she entered it, and when it stops working.
    static func codeLine(_ code: String, _ pairing: AgentPairing) -> String {
        "Code \(code) · Works until \(pairing.expiresAt.formatted(date: .omitted, time: .shortened))"
    }

    /// What the key never does, under what it asks to do: deleting only when it asks to manage, and
    /// then with Undo.
    static func approvalNote(_ scopes: [AgentScope]) -> String {
        let ask = "Approve only a code your own agent is showing you now."
        if scopes.contains(.manage) {
            return "\(ask) Its key never answers questions for you, changes a password, or reaches your other keys, and what it deletes goes to Recently deleted."
        }
        return "\(ask) Its key never changes a password, deletes anything, or reaches your other keys."
    }

    static func approved(_ name: String) -> String {
        "Approved \(name). It picks up its key within a few seconds, and then it shows under Your keys."
    }

    static func denied(_ name: String) -> String {
        "Denied \(name). No key was made."
    }

    /// "Can import sets", "Can import sets and read progress": a key's scopes in a few words, for its
    /// row. Manage reaches everything import does, so a key with it says what it changes, and where
    /// what it deletes goes.
    static func scopesLine(_ scopes: [AgentScope]) -> String {
        let manage = scopes.contains(.manage)
        let verbs = scopes
            .filter { $0 != .manage && !(manage && $0 == .import) }
            .map { scope in scope == .import ? "import sets" : scope == .read ? "read progress" : scope.rawValue }
        if manage {
            let others = verbs.isEmpty ? "" : "\(listed(verbs)), and "
            return "Can \(others)add, change, and delete your sets, questions, folders, courses, and topics. What it deletes goes to Recently deleted."
        }
        if verbs.isEmpty { return "Can do nothing" }
        return "Can \(listed(verbs))"
    }

    private static func listed(_ words: [String]) -> String {
        guard let last = words.last, words.count > 1 else { return words.first ?? "" }
        return "\(words.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// "Made Oct 25 · Last used today", "Made today · Never used", or "Made Oct 25 · Revoked Oct 26".
    static func keyDates(_ key: AgentKey, now: Date = .now, calendar: Calendar = .current) -> String {
        let made = "Made \(Wording.when(key.createdAt, now: now, calendar: calendar))"
        if let revokedAt = key.revokedAt {
            return "\(made) · Revoked \(Wording.when(revokedAt, now: now, calendar: calendar))"
        }
        return "\(made) · \(key.lastUsedAt.map { "Last used \(Wording.when($0, now: now, calendar: calendar))" } ?? "Never used")"
    }

    static func revokeTitle(_ name: String) -> String {
        "Revoke \(name)?"
    }

    /// What revoking a key leaves behind: what it imported, and for a key that manages, what it
    /// changed and deleted.
    static func revokeMessage(_ scopes: [AgentScope]) -> String {
        let left = scopes.contains(.manage)
            ? "What it imported or changed stays as it is, and what it deleted stays in Recently deleted."
            : "The sets it imported stay where they are."
        return "Its key stops working at once and for good. \(left) To connect this agent again, approve a new code from it."
    }

    static func revoked(_ name: String) -> String {
        "Revoked \(name). It stopped working just now."
    }

    /// The line under a set her agent imported. The frozen view says it as she reads it.
    static let importedBy = "Imported by your agent"
}
