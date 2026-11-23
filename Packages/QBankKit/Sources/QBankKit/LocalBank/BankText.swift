import Foundation

/// The text rules the server's writes share: what a name has to be, a date, a week's order. Lengths
/// count UTF-16 units, as the server's do.
enum BankText {
    /// The text trimmed, refused when blank (`<label> is required.`) or past `maxLength` (`<label> is too long.`).
    static func required(_ value: String, _ label: String, _ maxLength: Int) throws -> String {
        let text = JS.trim(value)
        if text.isEmpty { throw BankRefusal.refused(400, "\(label) is required.") }
        if text.utf16.count > maxLength { throw BankRefusal.refused(400, "\(label) is too long.") }
        return text
    }

    /// A date such as `2026-09-01`, or nil for none.
    static func date(_ value: String?, _ label: String) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { throw BankRefusal.refused(400, "\(label) has to be a date like 2026-09-01.") }
        return value
    }

    static func sameName(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// JavaScript's `a.localeCompare(b)`: language order, ignoring case first.
    static func localeCompare(_ a: String, _ b: String) -> Int {
        switch a.compare(b, options: [], range: nil, locale: Locale(identifier: "en")) {
        case .orderedAscending: -1
        case .orderedSame: 0
        case .orderedDescending: 1
        }
    }

    /// Week order, which a course's folders start in: the first number in the name, then the name.
    static func compareWeeks(_ a: String, _ b: String) -> Int {
        let byNumber = rank(a) - rank(b)
        return byNumber == 0 ? localeCompare(a, b) : byNumber
    }

    private static func rank(_ label: String) -> Int {
        guard let match = label.firstMatch(of: /\d+/) else { return Int.max }
        return Int(match.output) ?? Int.max
    }

    /// "Week 3", "Week 3 and Week 4", "Week 2, Week 3 and Week 4".
    static func list(_ labels: [String]) -> String {
        guard labels.count > 1 else { return labels.joined() }
        return "\(labels.dropLast().joined(separator: ", ")) and \(labels[labels.count - 1])"
    }
}

extension StoreRow {
    /// A column that is never null.
    func string(_ column: String) -> String { text(column) ?? "" }
    func integer(_ column: String) -> Int { int(column) ?? 0 }
    func flag(_ column: String) -> Bool { bool(column) ?? false }
}
