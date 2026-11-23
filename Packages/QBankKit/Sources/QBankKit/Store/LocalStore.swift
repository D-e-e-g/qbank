import Foundation
import Synchronization

/// The phone's question bank: one SQLite file, or a private in-memory database for tests.
///
/// It is a small wrapper over the system SQLite library. Opening applies the numbered schema steps
/// the file has not seen yet (`SchemaSteps`), each in its own transaction, so a file made by any
/// earlier step is brought up to date and a failure leaves the file at the last step that finished.
/// Foreign keys are on. Everything runs under one lock, so a store can be shared across tasks.
/// The store is not re-entrant: inside a `transaction` or `read` body, use the `StoreTransaction`
/// it hands you, never the store itself, which would wait on its own lock forever.
/// Nothing in the app uses it yet.
public final class LocalStore: Sendable {
    /// The file, or nil for an in-memory store.
    public let fileURL: URL?
    private let connection: Mutex<SQLiteConnection>

    private init(fileURL: URL?, connection: sending SQLiteConnection) {
        self.fileURL = fileURL
        self.connection = Mutex(connection)
    }

    // MARK: Opening

    /// Opens the bank of `key` under `Application Support/QBankKit/Banks/<key>/`, making it when
    /// it does not exist.
    public static func standard(key: String) throws(StoreError) -> LocalStore {
        let root: URL
        do {
            root = try FileLocations.applicationSupport()
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
        return try open(directory: StoreFiles.directory(forKey: key, in: root))
    }

    /// Opens the bank of `key` under `root/Banks/<key>/`.
    public static func open(key: String, in root: URL) throws(StoreError) -> LocalStore {
        try open(directory: StoreFiles.directory(forKey: key, in: root))
    }

    /// Opens the bank file in `directory`, making the folder and the file when they do not exist.
    public static func open(directory: URL) throws(StoreError) -> LocalStore {
        try open(directory: directory, steps: SchemaSteps.all)
    }

    /// An empty bank in memory, gone when it is closed. For tests.
    public static func inMemory() throws(StoreError) -> LocalStore {
        try inMemory(steps: SchemaSteps.all)
    }

    static func open(directory: URL, steps: [SchemaStep]) throws(StoreError) -> LocalStore {
        try StoreFiles.prepare(directory: directory)
        let file = directory.appendingPathComponent(StoreFiles.fileName)
        let store = LocalStore(fileURL: file, connection: try SQLiteConnection(path: file.path))
        try store.configure(steps: steps)
        try StoreFiles.markFiles(at: file)
        return store
    }

    static func inMemory(steps: [SchemaStep]) throws(StoreError) -> LocalStore {
        let store = LocalStore(fileURL: nil, connection: try SQLiteConnection(path: ":memory:"))
        try store.configure(steps: steps)
        return store
    }

    private func configure(steps: [SchemaStep]) throws(StoreError) {
        try SchemaSteps.validate(steps)
        try connection.withLock { (connection) throws(StoreError) in
            // A file from a newer app is refused before anything about it is changed.
            try SchemaSteps.refuseNewer(connection, steps: steps)
            // One file with no side files to lose, and each commit on disk before it returns.
            try connection.run("PRAGMA journal_mode = DELETE")
            try connection.run("PRAGMA synchronous = FULL")
            try SchemaSteps.upgrade(connection, steps: steps)
            try connection.run("PRAGMA foreign_keys = ON")
        }
    }

    /// Closes the file. Every later call fails with `StoreError.closed`.
    public func close() {
        connection.withLock { $0.close() }
    }

    // MARK: Using

    /// The schema step the file is at.
    public var schemaVersion: Int {
        get throws(StoreError) {
            try connection.withLock { (connection) throws(StoreError) in try SchemaSteps.version(of: connection) }
        }
    }

    /// Runs `body` in one transaction: its changes all happen or, when it throws, none do. The
    /// error `body` threw is rethrown after the rollback. When SQLite has already rolled the
    /// transaction back on its own (a full disk, an I/O error), every later statement of the body
    /// and the commit throw `StoreError.rolledBack`, so nothing runs outside the transaction.
    public func transaction<Result: Sendable>(_ body: (StoreTransaction) throws -> Result) throws -> Result {
        try connection.withLock { connection in
            guard connection.isOpen else { throw StoreError.closed }
            try connection.run("BEGIN IMMEDIATE")
            let transaction = StoreTransaction(connection)
            defer { transaction.end() }
            do {
                let result = try body(transaction)
                guard connection.inTransaction else { throw StoreError.rolledBack }
                try connection.run("COMMIT")
                return result
            } catch {
                // A failed COMMIT can leave the transaction open; one SQLite ended has nothing to undo.
                if connection.inTransaction { _ = try? connection.run("ROLLBACK") }
                throw error
            }
        }
    }

    /// Runs `body` with writes refused, so it sees one consistent state of the bank.
    public func read<Result: Sendable>(_ body: (StoreTransaction) throws -> Result) throws -> Result {
        try connection.withLock { connection in
            guard connection.isOpen else { throw StoreError.closed }
            try connection.run("PRAGMA query_only = ON")
            try connection.run("BEGIN DEFERRED")
            let transaction = StoreTransaction(connection)
            defer {
                transaction.end()
                if connection.inTransaction { _ = try? connection.run("ROLLBACK") }
                _ = try? connection.run("PRAGMA query_only = OFF")
            }
            return try body(transaction)
        }
    }

    /// One statement in its own transaction, for a quick read or write.
    @discardableResult
    public func run(_ sql: String, _ bindings: [StoreValue] = []) throws -> [StoreRow] {
        try transaction { try $0.rows(sql, bindings) }
    }
}

/// What a transaction body works with. It is valid only while the body runs.
public final class StoreTransaction {
    private let connection: SQLiteConnection
    private var active = true
    private var savepoints = 0

    init(_ connection: SQLiteConnection) {
        self.connection = connection
    }

    func end() { active = false }

    private func checkOpen() throws(StoreError) {
        guard active else { throw .transactionEnded }
        guard connection.inTransaction else { throw .rolledBack }
    }

    /// Runs one statement and returns its rows, none for a write.
    @discardableResult
    public func rows(_ sql: String, _ bindings: [StoreValue] = []) throws(StoreError) -> [StoreRow] {
        try checkOpen()
        return try connection.run(sql, bindings)
    }

    /// Runs one statement and discards its rows.
    public func execute(_ sql: String, _ bindings: [StoreValue] = []) throws(StoreError) {
        try rows(sql, bindings)
    }

    /// The first column of the first row, or nil when there is no row.
    public func value(_ sql: String, _ bindings: [StoreValue] = []) throws(StoreError) -> StoreValue? {
        try rows(sql, bindings).first?[0]
    }

    /// Rows the last statement inserted, updated or deleted.
    public var changes: Int { connection.changes }

    /// Runs `body` as a step that can fail alone: when it throws, only its changes are undone, the
    /// error is rethrown, and the transaction goes on.
    public func savepoint<Result>(_ body: () throws -> Result) throws -> Result {
        try checkOpen()
        savepoints += 1
        let name = "sp\(savepoints)"
        try connection.run("SAVEPOINT \(name)")
        do {
            let result = try body()
            try connection.run("RELEASE \(name)")
            return result
        } catch {
            // When SQLite has rolled the whole transaction back, there is no savepoint left to undo.
            if connection.inTransaction {
                _ = try? connection.run("ROLLBACK TO \(name)")
                _ = try? connection.run("RELEASE \(name)")
            }
            throw error
        }
    }
}
