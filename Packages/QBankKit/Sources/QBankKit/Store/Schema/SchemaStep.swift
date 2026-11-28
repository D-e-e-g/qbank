import Foundation

/// One numbered change to the bank file's shape. Steps are Swift source, applied in order, each in
/// one transaction, and the file records the last one that finished in SQLite's `user_version`.
/// A step that has shipped is never edited: a change is a new step after it.
struct SchemaStep: Sendable {
    let number: Int
    let name: String
    let statements: [String]
}

enum SchemaSteps {
    /// Every step, oldest first.
    static let all: [SchemaStep] = [BankTablesStep.step, BankChangeTimeStep.step]

    static func validate(_ steps: [SchemaStep]) throws(StoreError) {
        guard steps.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }) else { throw .invalidSteps }
    }

    static func version(of connection: SQLiteConnection) throws(StoreError) -> Int {
        try connection.run("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    /// Refuses a file that is ahead of the steps this app knows.
    static func refuseNewer(_ connection: SQLiteConnection, steps: [SchemaStep]) throws(StoreError) {
        let current = try version(of: connection)
        guard current <= steps.count else { throw .newerSchema(found: current, supported: steps.count) }
    }

    /// Applies the steps the file has not had, or refuses a file that is ahead of them.
    ///
    /// Each step runs with foreign keys off, as SQLite's table rebuild needs
    /// (https://www.sqlite.org/lang_altertable.html#otheralter): with them on, dropping a parent
    /// table deletes through `ON DELETE SET NULL` (taking every folder off its page) or fails on a
    /// reference. Before the step commits, `foreign_key_check` must find no row naming a row that
    /// is not there. Foreign keys are on again after every step, whether it finished or not.
    static func upgrade(_ connection: SQLiteConnection, steps: [SchemaStep]) throws(StoreError) {
        try refuseNewer(connection, steps: steps)
        let current = try version(of: connection)
        for step in steps where step.number > current {
            // The pragma is a no-op inside a transaction, so it is set before the step begins.
            try connection.run("PRAGMA foreign_keys = OFF")
            defer { _ = try? connection.run("PRAGMA foreign_keys = ON") }
            try connection.run("BEGIN IMMEDIATE")
            do throws(StoreError) {
                for statement in step.statements { try connection.run(statement) }
                guard try connection.run("PRAGMA foreign_key_check").isEmpty else { throw .foreignKeyCheckFailed(step: step.number) }
                try connection.run("PRAGMA user_version = \(step.number)")
                try connection.run("COMMIT")
            } catch {
                if connection.inTransaction { _ = try? connection.run("ROLLBACK") }
                throw error
            }
        }
    }
}
