import Foundation

/// What every delete shares, whatever it hides: the Undo window, the `confirm` a preview hands out and
/// the delete checks, and the warning's split into a question and the rest. A delete hides rows and
/// never removes one: it marks every row it hides with the time and one delete id, every read leaves
/// marked rows out, and Undo clears exactly that delete's marks for 30 days. Nothing is deleted except
/// by the person's own confirmed request.
enum DeleteMarks {
    /// How long Undo can bring a delete back. After that it stays hidden: nothing is removed on its own.
    static let undoDays = 30
    static let undoSeconds = Double(undoDays) * 24 * 60 * 60

    /// A refusal that names its own code, as the delete routes do where most routes say `request_refused`.
    static func refusal(_ status: Int, _ code: String, _ message: String) -> BankRefusal { BankRefusal(status: status, code: code, message: message) }

    /// Refuses a delete she has not confirmed, or one whose warning no longer matches what it would delete.
    static func confirmed(_ confirm: String?, expected: String, name: String, unconfirmed: String? = nil) throws {
        guard let confirm else {
            throw refusal(409, "confirmation_required", unconfirmed ?? "Look at what goes with \(name) and confirm it before deleting it.")
        }
        if confirm != expected { throw refusal(409, "deletion_changed", "\(name) changed since you were warned. Look again before deleting it.") }
    }

    /// A short fingerprint of what a delete would take, which its preview hands out and the delete checks: the first 16 hex digits of
    /// the SHA-256 of the parts, one to a line.
    static func token(_ head: [String?], _ tail: [String] = []) -> String {
        String(SHA256.hex(Array((head.map { $0 ?? "" } + tail).joined(separator: "\n").utf8)).prefix(16))
    }

    /// Strings in JavaScript's default order (by UTF-16 code unit), so a token is made of the same ordering the server's is.
    static func sorted(_ parts: [String]) -> [String] { parts.sorted { JS.codeUnitOrder($0, $1) } }

    /// Whether Undo has run out for a delete made at `deletedAt`.
    static func expired(_ deletedAt: String?, now: Date) -> Bool {
        guard let deletedAt, let date = QBankJSON.parseDate(deletedAt) else { return false }
        return now.timeIntervalSince(date) > undoSeconds
    }

    /// When Undo runs out.
    static func undoUntil(_ deletedAt: String) -> String {
        QBankJSON.formatDate((QBankJSON.parseDate(deletedAt) ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(undoSeconds))
    }

    /// The oldest delete time Recently deleted still lists.
    static func since(_ now: Date) -> String { QBankJSON.formatDate(now.addingTimeInterval(-undoSeconds)) }

    /// "1 set", "3 sets".
    static func countOf(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// `message` split the way the web splits it: the "?" after the doomed name's last character. The question is the title and the rest the body.
    static func warning(_ message: String, doomed: String) -> JSONValue {
        let text = JS.trim(message)
        let from = text.range(of: doomed, options: .literal)
        let searchFrom = from?.upperBound ?? text.startIndex
        guard let mark = text.range(of: "?", options: .literal, range: searchFrom..<text.endIndex) else {
            return .object(["title": .string("Delete?"), "body": .string(text)])
        }
        return .object(["title": .string(String(text[..<mark.upperBound])), "body": .string(JS.trim(String(text[mark.upperBound...])))])
    }

    /// `?, ?, ?` for a list of that many bindings.
    static func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ", ") }

    /// Whether a text is in the form of a UUID, whatever its version (the form an exam's question ids are held in).
    static func isUUID(_ text: String) -> Bool { BankBody.isAnyUUID(text) }
}
