import Foundation

/// A bank counted as the person counts it, for a screen to show: the sets they can open, the questions
/// in those sets, and every answer they gave. A set's earlier versions, and a set deleted or in a
/// deleted course or folder, are not counted. A move between this phone and QBank Cloud does not check
/// these: it compares every row of all twelve tables (`BankCounts`).
public struct BankSummary: Sendable, Equatable, Codable {
    public let sets: Int
    public let questions: Int
    public let answers: Int

    public init(sets: Int, questions: Int, answers: Int) {
        self.sets = sets
        self.questions = questions
        self.answers = answers
    }

    /// The sets a person can open, as `s`, with their course `c` and folder `f`: a set's current
    /// version, not deleted, and not in a deleted course or folder. The sets Home lists.
    static let openSets = """
        practice_set s
        JOIN course c ON c.id = s.course_id
        LEFT JOIN folder f ON f.id = s.folder_id
        """
    static let isOpen = "s.is_current = 1 AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND f.deleted_at IS NULL"

    /// The summary of the bank in `store`, read in one transaction.
    public static func of(_ store: LocalStore) throws -> BankSummary {
        try store.read { tx in
            let sets = try tx.rows(
                """
                SELECT count(*) AS sets, coalesce(sum((SELECT count(*) FROM question q WHERE q.set_id = s.id)), 0) AS questions
                FROM \(openSets) WHERE \(isOpen)
                """)
            let answers = try tx.rows("SELECT count(*) AS answers FROM attempt")
            return BankSummary(
                sets: sets.first?.int("sets") ?? 0, questions: sets.first?.int("questions") ?? 0, answers: answers.first?.int("answers") ?? 0)
        }
    }

    /// The summary of `bank`.
    public static func of(_ bank: LocalBank) throws -> BankSummary {
        try of(bank.store)
    }
}
