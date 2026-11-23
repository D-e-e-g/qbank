import Foundation

/// Filing a sample set into a bank that has nothing in it yet, so a new person can practice at once.
///
/// The set is an ordinary one: it goes in through the bank's own import, into a topic made for it,
/// so the person can open, replace and delete it like any set they import. A bank that has ever held
/// a semester, course, topic or set is left alone, even when all of it was deleted since, so the
/// sample comes once and never back.
extension LocalBank {
    /// Files `source`, a question file, as the first set of a new topic named `topic`, and returns
    /// true. Returns false, changing nothing, when the bank is not new. Throws when the file does not
    /// pass the import, in which case nothing is filed either.
    @discardableResult
    public func fileSampleSet(_ source: String, inTopic topic: String) throws -> Bool {
        guard try isNew() else { return false }
        let body = try JSONEncoder().encode(JSONValue.object(["source": .string(source), "newTopic": .object(["title": .string(topic)])]))
        let url = URL(string: "bank:///api/imports")!
        let answer: BankAnswer
        do {
            answer = try respond(method: "POST", url: url, body: body)
        } catch let refusal as BankRefusal {
            throw SampleSetError.refused(status: refusal.status, message: refusal.message)
        }
        guard answer.status == 201 else {
            throw SampleSetError.refused(status: answer.status, message: answer.body?["message"]?.stringValue)
        }
        return true
    }

    /// Whether nothing has ever been in the bank: no semester, course, topic or set, deleted ones included.
    func isNew() throws -> Bool {
        try store.read { tx in
            for table in ["semester", "course", "practice_set"] {
                if try tx.rows("SELECT 1 FROM \(table) LIMIT 1").first != nil { return false }
            }
            return true
        }
    }
}

/// Why the bank refused to file the sample set.
public enum SampleSetError: Error, Sendable, Equatable {
    case refused(status: Int, message: String?)
}
