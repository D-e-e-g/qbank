import Foundation
import Testing
@testable import QBankKit

/// The pinned OpenAPI file is the server's schema at the commit in `Fixtures/pin.json`.
/// Every live recording is from that commit, no other file claims one, every key the kit reads while decoding a recording is
/// a property of the schema, and every recorded response key is one that schema allows.
@Suite("Contract: pinned schema")
struct ContractSchemaTests {
    private static func pin() throws -> Pin {
        let url = try #require(Bundle.module.url(forResource: "pin", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Pin.self, from: Data(contentsOf: url))
    }

    private static func spec() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    @Test func onlyLiveRecordingsAreStampedWithThePinnedCommit() throws {
        let pin = try Self.pin()
        #expect(pin.repository == "D-e-e-g/qbank-server")
        #expect(pin.path == "apps/api/openapi.json")
        #expect(pin.commit.count == 40)
        #expect(pin.image.hasPrefix("ghcr.io/"))
        let fixtures = try Fixture.all()
        #expect(fixtures.count > 200)
        let live: Set<String> = ["topic", "topic-create", "topic-order", "semesters-with-topics", "place-topic"]
        for fixture in fixtures {
            if live.contains(fixture.name) {
                #expect(fixture.recordedFrom == pin.commit, "\(fixture.name) was recorded from \(fixture.recordedFrom ?? "nothing")")
            } else {
                #expect(fixture.recordedFrom == nil, "\(fixture.name) claims a live recording the recorder does not make")
            }
        }
    }

    /// The kit decodes recorded responses through a decoder that logs every key it asks for.
    /// `CourseExam.badge` is the case a route-only check misses: the kit reads it, so the pin must name it.
    @Test func everyKeyTheKitDecodesIsInThePinnedSchema() throws {
        let spec = try Self.spec()
        var badgeRead = false
        for (name, model) in Self.decodedResponses {
            let fixture = try Fixture.load(name)
            let schema = try #require(responseSchema(spec, method: fixture.request.method, path: fixture.request.path, status: fixture.response.status), "\(name) has no response schema")
            let log = KeyLog()
            _ = try model.init(from: RecordingDecoder(value: fixture.response.body, path: [], log: log))
            #expect(!log.reads.isEmpty, "\(name) decoded no keys")
            for read in log.reads where !schema.declares(read.key, at: read.path) && !Self.optionalLegacyReads.contains((read.path + [read.key]).joined(separator: ".")) {
                Issue.record("\(name): the kit reads \((read.path + [read.key]).joined(separator: ".")), which the pinned schema does not declare")
            }
            if name == "course-with-exams" {
                badgeRead = log.reads.contains { $0.key == "badge" }
            }
        }
        #expect(badgeRead, "decoding a course with exam pages never read badge")
    }

    /// Keys the kit reads only when present: a question's own week from before folders, and the
    /// folder of a By folder row, which `byWeek` and `byStep` rows share a type with but never carry.
    private static let optionalLegacyReads: Set<String> = [
        "questions.[].weekLabel",
        "result.byWeek.[].folderId",
        "result.byStep.[].folderId",
    ]

    private static let decodedResponses: [(String, any Decodable.Type)] = [
        ("agent-keys", AgentKeysResponse.self),
        ("attempt-saved", SavedAttempt.self),
        ("course", CourseDetail.self),
        ("course-with-exams", CourseDetail.self),
        ("course-after-exam-page-delete", CourseDetail.self),
        ("course-deleted", RecentlyDeleted.self),
        ("exam-ended", Exam.self),
        ("exam-setup-after", ExamSetup.self),
        ("exam-setup-course-exams", ExamSetup.self),
        ("exam-start", Exam.self),
        ("practice-set", PracticeSet.self),
        ("review", ReviewList.self),
        ("semesters", Catalog.self),
        ("semesters-edited", Catalog.self),
        ("semesters-with-topics", Catalog.self),
        ("terms", TermsResponse.self),
    ]

    @Test func everyRecordedKeyIsInThePinnedSchema() throws {
        let spec = try Self.spec()
        for fixture in try Fixture.all() where fixture.response.body != .null {
            let schema = try #require(responseSchema(spec, method: fixture.request.method, path: fixture.request.path, status: fixture.response.status), "\(fixture.name) has no response schema")
            var extras: [String] = []
            schema.collectExtras(in: fixture.response.body, at: fixture.name, into: &extras)
            #expect(extras.isEmpty, "\(fixture.name): \(extras.joined(separator: ", "))")
        }
    }

    private struct Pin: Decodable {
        let repository: String
        let commit: String
        let path: String
        let image: String
    }
}

/// A resolved object schema. An empty `properties` map means the schema does not constrain keys
/// (a free-form value such as an answer body). `QuestionBody` keeps fields the file added.
private final class DocSchema {
    var properties: [String: DocSchema] = [:]
    var items: DocSchema?
    var variants: [DocSchema] = []
    var allowsExtraKeys = false
    var questionBody = false

    init() {}

    convenience init(_ value: JSONValue, spec: JSONValue) {
        var defining: [String: DocSchema] = [:]
        self.init(value, spec: spec, defining: &defining)
    }

    private init(_ value: JSONValue, spec: JSONValue, defining: inout [String: DocSchema]) {
        if let ref = value["$ref"]?.stringValue {
            let name = String(ref.split(separator: "/").last ?? "")
            if name == "QuestionBody" { questionBody = true }
            if let existing = defining[name] {
                properties = existing.properties
                items = existing.items
                variants = existing.variants
                allowsExtraKeys = existing.allowsExtraKeys
                questionBody = existing.questionBody || questionBody
                return
            }
            defining[name] = self
            if let target = spec["components"]?["schemas"]?[name] {
                fill(target, spec: spec, defining: &defining)
            }
            return
        }
        fill(value, spec: spec, defining: &defining)
    }

    private func fill(_ value: JSONValue, spec: JSONValue, defining: inout [String: DocSchema]) {
        if let parts = value["allOf"]?.arrayValue {
            for part in parts {
                let resolved = DocSchema(part, spec: spec, defining: &defining)
                properties.merge(resolved.properties) { _, new in new }
                if resolved.items != nil { items = resolved.items }
                allowsExtraKeys = allowsExtraKeys || resolved.allowsExtraKeys
                questionBody = questionBody || resolved.questionBody
            }
        }
        if let parts = value["oneOf"]?.arrayValue ?? value["anyOf"]?.arrayValue {
            variants = parts.map { DocSchema($0, spec: spec, defining: &defining) }
        }
        if let fields = value["properties"], case .object(let fields) = fields {
            for (key, field) in fields {
                properties[key] = DocSchema(field, spec: spec, defining: &defining)
            }
        }
        if let item = value["items"] {
            items = DocSchema(item, spec: spec, defining: &defining)
        }
        if value["additionalProperties"] != nil {
            allowsExtraKeys = true
        }
    }

    func declares(_ key: String, at path: [String]) -> Bool {
        var here = [self]
        for step in path {
            here = here.flatMap(\.alternatives).compactMap { step == "[]" ? $0.items : $0.properties[step] }
        }
        let candidates = here.flatMap(\.alternatives)
        if candidates.contains(where: { $0.allowsExtraKeys || $0.questionBody || $0.properties[key] != nil }) { return true }
        return candidates.allSatisfy { $0.properties.isEmpty }
    }

    private var alternatives: [DocSchema] {
        [self] + variants.flatMap(\.alternatives)
    }

    func collectExtras(in body: JSONValue, at path: String, into extras: inout [String]) {
        if questionBody {
            guard case .object(let object) = body else { return }
            let chosen = variants.max { score($0, object) < score($1, object) }
            for (key, value) in object {
                if let property = chosen?.properties[key] {
                    property.collectExtras(in: value, at: "\(path).\(key)", into: &extras)
                }
            }
            return
        }
        if !variants.isEmpty {
            switch body {
            case .object(let object):
                let chosen = variants.max { score($0, object) < score($1, object) } ?? self
                if chosen !== self {
                    chosen.collectExtras(in: body, at: path, into: &extras)
                }
            case .array(let values):
                guard let itemSchema = variants.first(where: { $0.items != nil })?.items ?? items else { return }
                for value in values {
                    itemSchema.collectExtras(in: value, at: "\(path)[]", into: &extras)
                }
            default:
                break
            }
            return
        }
        switch body {
        case .array(let values):
            guard let items else { return }
            for value in values {
                items.collectExtras(in: value, at: "\(path)[]", into: &extras)
            }
        case .object(let object):
            // No declared properties: the schema leaves the value open, as an answer body does.
            guard !properties.isEmpty else { return }
            for (key, value) in object {
                if let property = properties[key] {
                    property.collectExtras(in: value, at: "\(path).\(key)", into: &extras)
                } else if !allowsExtraKeys {
                    extras.append("\(path).\(key) is not in the pinned schema")
                }
            }
        default:
            break
        }
    }

    private func score(_ schema: DocSchema, _ object: [String: JSONValue]) -> Int {
        if schema.questionBody { return score(schema.variants.max { score($0, object) < score($1, object) } ?? schema, object) }
        if !schema.variants.isEmpty {
            return schema.variants.map { score($0, object) }.max() ?? 0
        }
        return object.keys.filter { schema.properties[$0] != nil }.count
    }
}

private func responseSchema(_ spec: JSONValue, method: String, path: String, status: Int) -> DocSchema? {
    guard case .object(let paths)? = spec["paths"] else { return nil }
    let template = paths.keys.first { $0 == path } ?? paths.keys.first { matches(template: $0, path: path) }
    guard let operation = template.flatMap({ paths[$0]?[method.lowercased()] }),
          let response = operation["responses"]?[String(status)] else { return nil }
    let documented = dereference(response, spec: spec)
    guard let schema = documented["content"]?["application/json"]?["schema"]
        ?? documented["content"]?["application/problem+json"]?["schema"] else { return nil }
    return DocSchema(schema, spec: spec)
}

/// A response may itself be a `$ref` to a component response, or, for an error, to a schema.
private func dereference(_ response: JSONValue, spec: JSONValue) -> JSONValue {
    guard let ref = response["$ref"]?.stringValue else { return response }
    let name = String(ref.split(separator: "/").last ?? "")
    if ref.contains("/responses/"), let target = spec["components"]?["responses"]?[name] {
        return target
    }
    if let schema = spec["components"]?["schemas"]?[name] {
        return .object(["content": .object(["application/json": .object(["schema": schema])])])
    }
    return response
}

private func matches(template: String, path: String) -> Bool {
    let left = template.split(separator: "/")
    let right = path.split(separator: "/")
    guard left.count == right.count else { return false }
    return zip(left, right).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
}

private final class KeyLog {
    var reads: [(path: [String], key: String)] = []
}

private struct ReadError: Error {}

/// A decoder over a recorded body that logs each key a model asks for, present or not.
private struct RecordingDecoder: Decoder {
    let value: JSONValue
    let path: [String]
    let log: KeyLog
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else { throw ReadError() }
        return KeyedDecodingContainer(RecordingKeyed<Key>(object: object, path: path, log: log))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let values) = value else { throw ReadError() }
        return RecordingUnkeyed(values: values, path: path + ["[]"], log: log)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        RecordingSingle(value: value, path: path, log: log)
    }
}

private func readValue<T: Decodable>(_ type: T.Type, from value: JSONValue, path: [String], log: KeyLog) throws -> T {
    if type == Date.self {
        return try QBankJSON.decoder.decode(T.self, from: JSONEncoder().encode(value))
    }
    return try T(from: RecordingDecoder(value: value, path: path, log: log))
}

private func readScalar<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private struct RecordingKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: JSONValue]
    let path: [String]
    let log: KeyLog
    var codingPath: [any CodingKey] { [] }
    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    private func read(_ key: Key) throws -> JSONValue {
        log.reads.append((path, key.stringValue))
        guard let value = object[key.stringValue] else { throw ReadError() }
        return value
    }

    func contains(_ key: Key) -> Bool {
        log.reads.append((path, key.stringValue))
        return object[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        log.reads.append((path, key.stringValue))
        return object[key.stringValue].map(\.isNull) ?? true
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let value = try read(key)
        return try readValue(type, from: value, path: path + [key.stringValue], log: log)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try readScalar(type, from: read(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try readScalar(type, from: read(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try readScalar(type, from: read(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try readScalar(type, from: read(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try readScalar(type, from: read(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try readScalar(type, from: read(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try readScalar(type, from: read(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try readScalar(type, from: read(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try readScalar(type, from: read(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try readScalar(type, from: read(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try readScalar(type, from: read(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try readScalar(type, from: read(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try readScalar(type, from: read(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try readScalar(type, from: read(key)) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try RecordingDecoder(value: read(key), path: path + [key.stringValue], log: log).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try RecordingDecoder(value: read(key), path: path + [key.stringValue], log: log).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { RecordingDecoder(value: .object(object), path: path, log: log) }
    func superDecoder(forKey key: Key) throws -> any Decoder {
        try RecordingDecoder(value: read(key), path: path + [key.stringValue], log: log)
    }
}

private struct RecordingSingle: SingleValueDecodingContainer {
    let value: JSONValue
    let path: [String]
    let log: KeyLog
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { value.isNull }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try readValue(type, from: value, path: path, log: log) }
    func decode(_ type: Bool.Type) throws -> Bool { try readScalar(type, from: value) }
    func decode(_ type: String.Type) throws -> String { try readScalar(type, from: value) }
    func decode(_ type: Double.Type) throws -> Double { try readScalar(type, from: value) }
    func decode(_ type: Float.Type) throws -> Float { try readScalar(type, from: value) }
    func decode(_ type: Int.Type) throws -> Int { try readScalar(type, from: value) }
    func decode(_ type: Int8.Type) throws -> Int8 { try readScalar(type, from: value) }
    func decode(_ type: Int16.Type) throws -> Int16 { try readScalar(type, from: value) }
    func decode(_ type: Int32.Type) throws -> Int32 { try readScalar(type, from: value) }
    func decode(_ type: Int64.Type) throws -> Int64 { try readScalar(type, from: value) }
    func decode(_ type: UInt.Type) throws -> UInt { try readScalar(type, from: value) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try readScalar(type, from: value) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try readScalar(type, from: value) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try readScalar(type, from: value) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try readScalar(type, from: value) }
}

private struct RecordingUnkeyed: UnkeyedDecodingContainer {
    let values: [JSONValue]
    let path: [String]
    let log: KeyLog
    var currentIndex = 0
    var codingPath: [any CodingKey] { [] }
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    private mutating func next() throws -> JSONValue {
        guard !isAtEnd else { throw ReadError() }
        defer { currentIndex += 1 }
        return values[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw ReadError() }
        if values[currentIndex].isNull {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try readValue(type, from: next(), path: path, log: log) }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try readScalar(type, from: next()) }
    mutating func decode(_ type: String.Type) throws -> String { try readScalar(type, from: next()) }
    mutating func decode(_ type: Double.Type) throws -> Double { try readScalar(type, from: next()) }
    mutating func decode(_ type: Float.Type) throws -> Float { try readScalar(type, from: next()) }
    mutating func decode(_ type: Int.Type) throws -> Int { try readScalar(type, from: next()) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try readScalar(type, from: next()) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try readScalar(type, from: next()) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try readScalar(type, from: next()) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try readScalar(type, from: next()) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try readScalar(type, from: next()) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try readScalar(type, from: next()) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try readScalar(type, from: next()) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try readScalar(type, from: next()) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try readScalar(type, from: next()) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try RecordingDecoder(value: next(), path: path, log: log).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try RecordingDecoder(value: next(), path: path, log: log).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder { RecordingDecoder(value: try next(), path: path, log: log) }
}
