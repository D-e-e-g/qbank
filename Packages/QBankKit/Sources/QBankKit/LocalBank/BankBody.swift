import Foundation

/// A request body read against the contract's schema. A field of the wrong kind, a required field
/// that is missing, or an id that is not a UUID is `invalid_request` before any rule runs, as on
/// the server. A field the contract does not name is ignored.
struct BankBody {
    /// A field that may be left out, or null: which of the three the request sent.
    enum Patch<Value> {
        case absent
        case null
        case value(Value)

        var isAbsent: Bool { if case .absent = self { true } else { false } }
    }

    private let fields: [String: JSONValue]

    init(_ body: JSONValue?) throws {
        guard case .object(let fields)? = body else { throw BankRefusal.invalidRequest }
        self.fields = fields
    }

    /// A field as sent, whatever it holds, or nil when the request left it out.
    func value(_ key: String) -> JSONValue? { fields[key] }

    // MARK: Required

    func string(_ key: String) throws -> String { try text(fields[key]) }
    func integer(_ key: String) throws -> Int { try whole(fields[key]) }
    func uuid(_ key: String) throws -> String { try id(fields[key]) }
    func uuids(_ key: String, max: Int) throws -> [String] { try list(fields[key], max: max, id) }

    // MARK: Optional (left out is fine, null is not)

    func optionalString(_ key: String) throws -> String? { try fields[key].map(text) }
    func optionalBool(_ key: String) throws -> Bool? { try fields[key].map(flag) }
    /// A bool that is false when left out (a null is not a bool).
    func bool(_ key: String, default fallback: Bool) throws -> Bool { try optionalBool(key) ?? fallback }
    func optionalUUID(_ key: String) throws -> String? { try fields[key].map(id) }
    func optionalUUIDs(_ key: String, max: Int) throws -> [String]? { try fields[key].map { try list($0, max: max, id) } }
    func optionalStrings(_ key: String, max: Int) throws -> [String]? { try fields[key].map { try list($0, max: max, text) } }

    /// A nested object that may be left out, read against its own fields.
    func optionalObject(_ key: String) throws -> BankBody? { try fields[key].map { try BankBody($0) } }

    /// A text that may be left out and is one of `choices` when sent.
    func optionalChoice(_ key: String, _ choices: [String]) throws -> String? {
        guard let value = try optionalString(key) else { return nil }
        guard choices.contains(value) else { throw BankRefusal.invalidRequest }
        return value
    }

    // MARK: Nullable

    func nullableString(_ key: String) throws -> Patch<String> { try patch(key, text) }
    func nullableUUID(_ key: String) throws -> Patch<String> { try patch(key, id) }
    /// A required key whose value may be null.
    func requiredNullableUUID(_ key: String) throws -> String? {
        switch try nullableUUID(key) {
        case .absent: throw BankRefusal.invalidRequest
        case .null: nil
        case .value(let value): value
        }
    }

    private func patch<Value>(_ key: String, _ read: (JSONValue) throws -> Value) throws -> Patch<Value> {
        guard let value = fields[key] else { return .absent }
        if value.isNull { return .null }
        return .value(try read(value))
    }

    // MARK: Kinds

    private func text(_ value: JSONValue?) throws -> String {
        guard case .string(let text)? = value else { throw BankRefusal.invalidRequest }
        return text
    }

    private func flag(_ value: JSONValue) throws -> Bool {
        guard case .bool(let flag) = value else { throw BankRefusal.invalidRequest }
        return flag
    }

    private func whole(_ value: JSONValue?) throws -> Int {
        guard case .number(let number)? = value, number.isFinite, number == number.rounded(), abs(number) < 9e15 else { throw BankRefusal.invalidRequest }
        return Int(number)
    }

    private func id(_ value: JSONValue?) throws -> String {
        guard case .string(let text)? = value, BankBody.isUUID(text) else { throw BankRefusal.invalidRequest }
        return text
    }

    private func list<Item>(_ value: JSONValue?, max: Int, _ read: (JSONValue?) throws -> Item) throws -> [Item] {
        guard case .array(let items)? = value, items.count <= max else { throw BankRefusal.invalidRequest }
        var result: [Item] = []
        for item in items { result.append(try read(item)) }
        return result
    }

    /// A UUID as the server's schema takes one: version 1 to 8 and the RFC variant, or the nil or max UUID.
    static func isUUID(_ text: String) -> Bool {
        text.wholeMatch(of: /(?i)([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|0{8}-0{4}-0{4}-0{4}-0{12}|f{8}-f{4}-f{4}-f{4}-f{12})/) != nil
    }

    /// A path's id, which the server's schema checks the same way.
    static func pathID(_ call: BankCall, _ name: String = "id") throws -> String {
        guard let value = call.params[name], isUUID(value) else { throw BankRefusal.invalidRequest }
        return value
    }
}
