import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One open SQLite database. Not thread safe: `LocalStore` keeps it behind a lock.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// Opens `path`, or a private in-memory database when it is `:memory:`.
    init(path: String) throws(StoreError) {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(opened)
            throw .sqlite(operation: "open the bank", code: code, message: message)
        }
        handle = opened
    }

    deinit { sqlite3_close_v2(handle) }

    var isOpen: Bool { handle != nil }

    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// Runs one statement and returns every row it produces.
    @discardableResult
    func run(_ sql: String, _ bindings: [StoreValue] = []) throws(StoreError) -> [StoreRow] {
        guard let handle else { throw .closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure("prepare", handle) }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32 =
                switch value {
                case .null: sqlite3_bind_null(statement, index)
                case .integer(let number): sqlite3_bind_int64(statement, index, number)
                case .real(let number): sqlite3_bind_double(statement, index, number)
                case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
                }
            guard bound == SQLITE_OK else { throw failure("bind", handle) }
        }

        let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [StoreRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw failure("run", handle) }
            var values: [StoreValue] = []
            for (index, column) in columns.enumerated() {
                let position = Int32(index)
                switch sqlite3_column_type(statement, position) {
                case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(statement, position)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, position)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(statement, position))))
                case SQLITE_NULL: values.append(.null)
                default: throw .unsupportedValue(column: column)
                }
            }
            rows.append(StoreRow(columns: columns, values: values))
        }
    }

    private func failure(_ operation: String, _ handle: OpaquePointer) -> StoreError {
        .sqlite(operation: operation, code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}
