import Foundation

/// A failure of the phone's bank file.
public enum StoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The key is not safe to use as a folder name.
    case invalidKey(String)
    /// SQLite refused or failed, with its result code and message.
    case sqlite(operation: String, code: Int32, message: String)
    /// The file is from a newer app than this one. It is left as it is.
    case newerSchema(found: Int, supported: Int)
    /// The numbered schema steps are not 1, 2, 3 and so on.
    case invalidSteps
    /// The folder or file could not be made, or its protection could not be set.
    case storage(operation: String, reason: String)
    /// The store was closed.
    case closed
    /// A row holds a value of a kind the store does not read.
    case unsupportedValue(column: String)
    /// The transaction this was called on has ended.
    case transactionEnded

    public var description: String {
        switch self {
        case .invalidKey(let key): "the bank key \"\(key)\" is not safe as a folder name"
        case .sqlite(let operation, let code, let message): "\(operation) failed: \(message) (\(code))"
        case .newerSchema(let found, let supported): "the bank file is at schema step \(found), newer than the step \(supported) this app knows"
        case .invalidSteps: "the schema steps are not numbered 1, 2, 3 and so on"
        case .storage(let operation, let reason): "\(operation) failed: \(reason)"
        case .closed: "the bank is closed"
        case .unsupportedValue(let column): "column \(column) holds a value of a kind the store does not read"
        case .transactionEnded: "the transaction has ended"
        }
    }
}
