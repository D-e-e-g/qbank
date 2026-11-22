import Foundation

/// One value in a row or one bound to a statement. The store's tables use only null, integers and
/// text (`docs/on-phone-bank.md`, "How values are stored"); a real number appears only as the
/// result of an expression such as `avg`.
public enum StoreValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func bool(_ value: Bool) -> StoreValue { .integer(value ? 1 : 0) }

    public static func optional(_ value: String?) -> StoreValue { value.map(StoreValue.text) ?? .null }

    public static func optional(_ value: Int?) -> StoreValue { value.map { .integer(Int64($0)) } ?? .null }
}

extension StoreValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// One row of a result, its values by column name.
public struct StoreRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [StoreValue]

    public subscript(_ column: String) -> StoreValue {
        columns.firstIndex(of: column).map { values[$0] } ?? .null
    }

    public subscript(_ index: Int) -> StoreValue { values[index] }

    public func text(_ column: String) -> String? {
        if case .text(let value) = self[column] { value } else { nil }
    }

    public func int(_ column: String) -> Int? {
        if case .integer(let value) = self[column] { Int(value) } else { nil }
    }

    public func bool(_ column: String) -> Bool? {
        int(column).map { $0 != 0 }
    }
}
