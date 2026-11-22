import Foundation

/// Column definitions for the bank tables, one function per kind of value in
/// `docs/on-phone-bank.md` ("How values are stored"). Each one writes the column's name, its
/// SQLite type, its nullability and a CHECK that the stored text has the kind's exact form, so the
/// file refuses a value the server's API would never send. Each CHECK lets a NULL through, since SQLite would otherwise read a comparison with NULL as
/// unknown and an expression such as `date(NULL) IS NOT NULL` as false; NOT NULL is stated apart.
enum Column {
    /// A lowercase UUID, `8-4-4-4-12`.
    static func id(_ name: String, null: Bool = false, key: Bool = false, references: String? = nil, onDelete: String? = nil) -> String {
        let hex = "[0-9a-f]"
        let pattern = [8, 4, 4, 4, 12].map { String(repeating: hex, count: $0) }.joined(separator: "-")
        var definition = "\(name) TEXT\(null ? "" : " NOT NULL")\(key ? " PRIMARY KEY" : "") CHECK (\(name) GLOB '\(pattern)')"
        if let references { definition += " REFERENCES \(references)" }
        if let onDelete { definition += " ON DELETE \(onDelete)" }
        return definition
    }

    /// UTC with milliseconds, `YYYY-MM-DDTHH:MM:SS.sssZ`: fixed width, so text order is time order.
    static func time(_ name: String, null: Bool = false) -> String {
        let digits = { (count: Int) in String(repeating: "[0-9]", count: count) }
        let pattern = "\(digits(4))-\(digits(2))-\(digits(2))T\(digits(2)):\(digits(2)):\(digits(2)).\(digits(3))Z"
        return "\(name) TEXT\(null ? "" : " NOT NULL") CHECK (\(name) IS NULL OR (\(name) GLOB '\(pattern)' AND datetime(\(name)) IS NOT NULL))"
    }

    /// `YYYY-MM-DD`.
    static func date(_ name: String, null: Bool = false) -> String {
        let digits = { (count: Int) in String(repeating: "[0-9]", count: count) }
        let pattern = "\(digits(4))-\(digits(2))-\(digits(2))"
        return "\(name) TEXT\(null ? "" : " NOT NULL") CHECK (\(name) IS NULL OR (\(name) GLOB '\(pattern)' AND date(\(name)) IS NOT NULL))"
    }

    static func bool(_ name: String) -> String {
        "\(name) INTEGER NOT NULL CHECK (\(name) IN (0, 1))"
    }

    static func int(_ name: String, null: Bool = false, check: String? = nil) -> String {
        "\(name) INTEGER\(null ? "" : " NOT NULL")\(check.map { " CHECK (\($0))" } ?? "")"
    }

    static func text(_ name: String, null: Bool = false, oneOf values: [String]? = nil) -> String {
        let list = values.map { " CHECK (\(name) IN (\($0.map { "'\($0)'" }.joined(separator: ", "))))" } ?? ""
        return "\(name) TEXT\(null ? "" : " NOT NULL")\(list)"
    }

    enum Shape: String {
        case object, array
    }

    /// One JSON value stored as text. `shape` limits it to an object or a list.
    static func json(_ name: String, _ shape: Shape? = nil, null: Bool = false) -> String {
        let kind = shape.map { " AND json_type(\(name)) = '\($0.rawValue)'" } ?? ""
        return "\(name) TEXT\(null ? "" : " NOT NULL") CHECK (\(name) IS NULL OR (json_valid(\(name))\(kind)))"
    }

    /// The two marks a delete leaves on a row, both null or both set.
    static let deletion = [time("deleted_at", null: true), id("deletion_id", null: true), "CHECK ((deleted_at IS NULL) = (deletion_id IS NULL))"]
}

extension SchemaStep {
    /// `CREATE TABLE`, strict so a column holds only its declared type.
    static func table(_ name: String, _ definitions: [String]) -> String {
        "CREATE TABLE \(name) (\n    " + definitions.joined(separator: ",\n    ") + "\n) STRICT"
    }
}
