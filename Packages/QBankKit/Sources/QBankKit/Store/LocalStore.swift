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
/// A free account's bank is one. While it moves, `holdWrites()` stops every write until
/// `releaseWrites()`, and reads go on.
public final class LocalStore: Sendable {
    /// The file, or nil for an in-memory store.
    public let fileURL: URL?
    private let connection: Mutex<SQLiteConnection>
    /// True while the bank is held: every transaction is refused before it begins.
    private let held = Mutex(false)

    private init(fileURL: URL?, connection: sending SQLiteConnection) {
        self.fileURL = fileURL
        self.connection = Mutex(connection)
    }

    // MARK: Opening

    /// The name of a bank's first file in its folder. A bank that came back from QBank Cloud is in a
    /// fresh file beside it, which the bank's hand-over record names (`BankHandover.bankFile`).
    public static let firstFile = "bank.sqlite"

    /// Opens the bank file `file` of `key` under `Application Support/QBankKit/Banks/<key>/`, making
    /// the first file when it does not exist.
    public static func standard(key: String, file: String = LocalStore.firstFile) throws(StoreError) -> LocalStore {
        try open(directory: StoreFiles.directory(forKey: key, in: try applicationSupport()), file: file)
    }

    /// Opens the bank file `file` of `key` under `root/Banks/<key>/`.
    public static func open(key: String, in root: URL, file: String = LocalStore.firstFile) throws(StoreError) -> LocalStore {
        try open(directory: StoreFiles.directory(forKey: key, in: root), file: file)
    }

    /// Opens the bank file `file` in `directory`, making the folder, and the first file, when they do
    /// not exist. A later file that is missing does not open.
    public static func open(directory: URL, file: String = LocalStore.firstFile) throws(StoreError) -> LocalStore {
        try StoreFiles.validate(fileName: file)
        // Only the first file is made on first use. A later file is one a hand-back wrote and checked;
        // when it is missing, an empty bank in its place would hide that, so it does not open.
        guard file == firstFile || FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
            throw .storage(operation: "open the bank", reason: "\(file) is not in the bank's folder")
        }
        return try open(directory: directory, steps: SchemaSteps.all, file: file)
    }

    /// Makes `file`, a new, empty bank file of `key` under `Application Support/QBankKit/Banks/<key>/`,
    /// beside the bank's other files. A file already there is refused, never overwritten.
    public static func createStandard(key: String, file: String) throws(StoreError) -> LocalStore {
        try create(directory: StoreFiles.directory(forKey: key, in: try applicationSupport()), file: file)
    }

    /// Makes `file`, a new, empty bank file of `key` under `root/Banks/<key>/`, refusing one already there.
    public static func create(key: String, in root: URL, file: String) throws(StoreError) -> LocalStore {
        try create(directory: StoreFiles.directory(forKey: key, in: root), file: file)
    }

    /// Opens the bank file `file` of `key` under `Application Support/QBankKit/Banks/<key>/` to read it
    /// only (`readOnly(directory:file:)`).
    public static func readOnlyStandard(key: String, file: String) throws(StoreError) -> LocalStore {
        try readOnly(directory: StoreFiles.directory(forKey: key, in: try applicationSupport()), file: file)
    }

    /// Opens the bank file `file` of `key` under `root/Banks/<key>/` to read it only.
    public static func readOnly(key: String, in root: URL, file: String) throws(StoreError) -> LocalStore {
        try readOnly(directory: StoreFiles.directory(forKey: key, in: root), file: file)
    }

    /// Opens an existing bank file to read it and nothing else, such as a safety copy: no schema step
    /// runs and no mark is set, so the file stays byte for byte as it was. Every write is refused. A
    /// file from a newer app is refused, as at any opening.
    public static func readOnly(directory: URL, file: String) throws(StoreError) -> LocalStore {
        try StoreFiles.validate(fileName: file)
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .storage(operation: "open the bank to read it", reason: "\(file) is not in the bank's folder")
        }
        let store = LocalStore(fileURL: url, connection: try SQLiteConnection(path: url.path, readOnly: true))
        try store.connection.withLock { (connection) throws(StoreError) in try SchemaSteps.refuseNewer(connection, steps: SchemaSteps.all) }
        store.holdWrites()
        return store
    }

    /// Whether the bank of `key` under `root/Banks/<key>/` has ever been made on this phone: its folder
    /// holds a bank file or a hand-over record. Nothing is made or opened to find out.
    public static func exists(key: String, in root: URL) throws(StoreError) -> Bool {
        let directory = try StoreFiles.directory(forKey: key, in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in name == "handover.json" || (try? StoreFiles.validate(fileName: name)) != nil }
    }

    /// Whether the bank of `key` under `Application Support/QBankKit/Banks/<key>/` was ever made.
    public static func existsStandard(key: String) throws(StoreError) -> Bool {
        try exists(key: key, in: try applicationSupport())
    }

    /// Takes away `file` of `key` under `root/Banks/<key>/`, with what SQLite kept beside it: a fresh
    /// file a hand-back began writing and never made the bank (`BankHandBack`). Any other name is
    /// refused, so a bank's first file can never go this way.
    public static func removeUnused(key: String, in root: URL, file: String) throws(StoreError) {
        try StoreFiles.validate(fileName: file)
        guard file != firstFile else { throw .invalidFileName(file) }
        StoreFiles.removeUnused(try StoreFiles.directory(forKey: key, in: root).appendingPathComponent(file))
    }

    /// The same, under `Application Support/QBankKit/Banks/<key>/`.
    public static func removeUnusedStandard(key: String, file: String) throws(StoreError) {
        try removeUnused(key: key, in: try applicationSupport(), file: file)
    }

    /// An empty bank in memory, gone when it is closed. For tests.
    public static func inMemory() throws(StoreError) -> LocalStore {
        try inMemory(steps: SchemaSteps.all)
    }

    static func open(directory: URL, steps: [SchemaStep], file name: String = LocalStore.firstFile) throws(StoreError) -> LocalStore {
        try StoreFiles.prepare(directory: directory)
        let file = directory.appendingPathComponent(name)
        let store = LocalStore(fileURL: file, connection: try SQLiteConnection(path: file.path))
        try store.configure(steps: steps)
        try StoreFiles.markFiles(at: file)
        return store
    }

    private static func create(directory: URL, file: String) throws(StoreError) -> LocalStore {
        try StoreFiles.validate(fileName: file)
        let url = directory.appendingPathComponent(file)
        guard !(([""] + StoreFiles.sideFileSuffixes).contains { FileManager.default.fileExists(atPath: url.path + $0) }) else { throw .fileExists(file) }
        return try open(directory: directory, steps: SchemaSteps.all, file: file)
    }

    private static func applicationSupport() throws(StoreError) -> URL {
        do {
            return try FileLocations.applicationSupport()
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
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

    // MARK: Holding

    /// Refuses every write from now on, with `StoreError.writesHeld`, until `releaseWrites()`, so the
    /// bank stays exactly as it is while it moves. A write already running finishes first: this waits
    /// for it, so once it returns nothing changes the bank. Reads go on. The hold lasts as long as this
    /// store does; what outlasts the app is the lease in the bank's hand-over record (`BankHandover`).
    public func holdWrites() {
        connection.withLock { _ in held.withLock { $0 = true } }
    }

    /// Takes writes again.
    public func releaseWrites() {
        held.withLock { $0 = false }
    }

    /// Whether writes are held.
    public var holdsWrites: Bool {
        held.withLock { $0 }
    }

    // MARK: Erasing

    /// Erases the bank of `key` under `Application Support/QBankKit/Banks/<key>/`: its folder, with
    /// the bank file and anything kept beside it. Only deleting the account does this. A bank that
    /// is not there is already erased. Close a bank of `key` that is open first.
    public static func erase(key: String) throws(StoreError) {
        let root: URL
        do {
            root = try FileLocations.applicationSupport()
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
        try erase(key: key, in: root)
    }

    /// Erases the bank of `key` under `root/Banks/<key>/`, as `erase(key:)` does.
    public static func erase(key: String, in root: URL) throws(StoreError) {
        let directory = try StoreFiles.directory(forKey: key, in: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw .storage(operation: "erase the bank", reason: error.localizedDescription)
        }
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
    /// and the commit throw `StoreError.rolledBack`, so nothing runs outside the transaction. While
    /// writes are held it throws `StoreError.writesHeld` before anything begins.
    public func transaction<Result: Sendable>(_ body: (StoreTransaction) throws -> Result) throws -> Result {
        try connection.withLock { connection in
            guard connection.isOpen else { throw StoreError.closed }
            guard !held.withLock({ $0 }) else { throw StoreError.writesHeld }
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
