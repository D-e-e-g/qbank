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
    static let all: [SchemaStep] = [BankTablesStep.step]

    static func validate(_ steps: [SchemaStep]) throws(StoreError) {
        guard steps.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }) else { throw .invalidSteps }
    }

    static func version(of connection: SQLiteConnection) throws(StoreError) -> Int {
        try connection.run("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    /// Applies the steps the file has not had, or refuses a file that is ahead of them.
    static func upgrade(_ connection: SQLiteConnection, steps: [SchemaStep]) throws(StoreError) {
        let current = try version(of: connection)
        guard current <= steps.count else { throw .newerSchema(found: current, supported: steps.count) }
        for step in steps where step.number > current {
            try connection.run("BEGIN IMMEDIATE")
            do {
                for statement in step.statements { try connection.run(statement) }
                try connection.run("PRAGMA user_version = \(step.number)")
                try connection.run("COMMIT")
            } catch {
                _ = try? connection.run("ROLLBACK")
                throw error
            }
        }
    }
}
