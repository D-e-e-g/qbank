import Foundation
import Testing
@testable import QBankKit

/// The pinned OpenAPI file is the server's schema at the commit in `Fixtures/pin.json`.
/// Every recording is from that commit, every key a file-level model decodes is a property
/// of the schema with the same name, and every recorded response key is one that schema allows.
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

    @Test func everyRecordingIsFromThePinnedCommit() throws {
        let pin = try Self.pin()
        #expect(pin.repository == "D-e-e-g/qbank-server")
        #expect(pin.path == "apps/api/openapi.json")
        #expect(pin.commit.count == 40)
        #expect(pin.image.hasPrefix("ghcr.io/"))
        let fixtures = try Fixture.all()
        #expect(fixtures.count > 200)
        for name in ["topic", "topic-create", "topic-order", "semesters-with-topics", "place-topic"] {
            #expect(fixtures.contains { $0.name == name }, "\(name) was not recorded")
        }
        for fixture in fixtures {
            #expect(fixture.recordedFrom == pin.commit, "\(fixture.name) was recorded from \(fixture.recordedFrom)")
        }
    }

    /// `CourseExam.badge` is the case a route-only check misses: the kit reads it, so the pin must name it.
    @Test func everyKeyTheKitDecodesIsInThePinnedSchema() throws {
        let spec = try Self.spec()
        let schemas = try #require(spec["components"]?["schemas"])
        let keys = try ModelKeys.fileLevelDecodeKeys()
        #expect(keys["CourseExam"]?.contains("badge") == true, "CourseExam decodes badge")
        var checked = 0
        for (name, decoded) in keys.sorted(by: { $0.key < $1.key }) {
            guard let schema = schemas[name] else { continue }
            let resolved = DocSchema(schema, spec: spec)
            guard !resolved.properties.isEmpty else { continue }
            checked += 1
            for key in decoded.sorted() where resolved.properties[key] == nil {
                Issue.record("\(name) decodes \(key), which \(name) in the pinned schema does not declare")
            }
        }
        #expect(checked > 10, "the schema named too few of the kit's models")
    }

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

/// File-level Decodable models and the JSON keys they read. Nested types keep their own names,
/// so a deletion preview's `Folder` is not the course `Folder` schema.
private enum ModelKeys {
    static func fileLevelDecodeKeys() throws -> [String: Set<String>] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/QBankKit", isDirectory: true)
        var keys: [String: Set<String>] = [:]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (name, decoded) in Parser(text).fileLevelTypes() {
                keys[name, default: []].formUnion(decoded)
            }
        }
        return keys
    }

    private struct Parser {
        let text: String
        var index: String.Index
        var depth = 0

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        private struct Frame {
            var name: String
            var bodyDepth: Int
            var decodable: Bool
            var fileLevel: Bool
            var keys: Set<String> = []
            var properties: Set<String> = []
            var sawCodingKeys = false
        }

        func fileLevelTypes() -> [String: Set<String>] {
            var parser = self
            var stack: [Frame] = []
            var found: [String: Set<String>] = [:]
            var previous = ""
            func finishClosed() {
                while let frame = stack.last, frame.bodyDepth > parser.depth {
                    stack.removeLast()
                    let decoded = frame.sawCodingKeys ? frame.keys : frame.properties
                    if frame.fileLevel && frame.decodable && !decoded.isEmpty {
                        found[frame.name, default: []].formUnion(decoded)
                    }
                }
            }
            while parser.index < parser.text.endIndex {
                parser.skipTrivia()
                guard parser.index < parser.text.endIndex else { break }
                let character = parser.text[parser.index]
                if character == "{" {
                    parser.depth += 1
                    parser.advance()
                    continue
                }
                if character == "}" {
                    parser.depth -= 1
                    parser.advance()
                    finishClosed()
                    continue
                }
                guard let word = parser.readIdentifier() else {
                    parser.advance()
                    continue
                }
                if word == "enum", parser.peekIdentifier() == "CodingKeys", let frame = stack.indices.last {
                    parser.skipTrivia()
                    _ = parser.readIdentifier()
                    parser.skipUntilBrace()
                    stack[frame].sawCodingKeys = true
                    stack[frame].keys.formUnion(parser.readCodingKeys())
                    previous = word
                    continue
                }
                if word == "let" || word == "var" {
                    if word == "let", previous != "static", let frame = stack.indices.last, stack[frame].bodyDepth == parser.depth {
                        parser.skipTrivia()
                        if let name = parser.readIdentifier() {
                            parser.skipTrivia()
                            if parser.index < parser.text.endIndex, parser.text[parser.index] == ":" {
                                stack[frame].properties.insert(name)
                            }
                        }
                    }
                    previous = word
                    continue
                }
                if word == "struct" || word == "enum" || word == "class" || word == "extension" {
                    parser.skipTrivia()
                    let name = parser.readIdentifier() ?? ""
                    let fileLevel = parser.depth == 0
                    let header = parser.headerUntilBrace()
                    let decodable = header.contains("Decodable") || header.contains("Codable")
                    if word != "extension" {
                        stack.append(Frame(name: name, bodyDepth: parser.depth, decodable: decodable, fileLevel: fileLevel))
                    }
                    previous = word
                    continue
                }
                previous = word
            }
            return found
        }

        private mutating func readCodingKeys() -> Set<String> {
            var keys: Set<String> = []
            let body = depth
            while index < text.endIndex, depth >= body {
                skipTrivia()
                guard index < text.endIndex else { break }
                if text[index] == "{" {
                    depth += 1
                    advance()
                    continue
                }
                if text[index] == "}" {
                    depth -= 1
                    advance()
                    if depth < body { break }
                    continue
                }
                guard readIdentifier() == "case" else { continue }
                while index < text.endIndex {
                    skipTrivia()
                    guard let name = readIdentifier() else { break }
                    skipTrivia()
                    if index < text.endIndex, text[index] == "=" {
                        advance()
                        skipTrivia()
                        if let literal = readString() {
                            keys.insert(literal)
                        } else {
                            keys.insert(name)
                        }
                    } else {
                        keys.insert(name)
                    }
                    skipTrivia()
                    if index < text.endIndex, text[index] == "," {
                        advance()
                        continue
                    }
                    break
                }
            }
            return keys
        }

        private mutating func headerUntilBrace() -> String {
            let start = index
            while index < text.endIndex, text[index] != "{" {
                if text[index] == "\"" {
                    _ = readString()
                    continue
                }
                advance()
            }
            let header = String(text[start..<index])
            if index < text.endIndex, text[index] == "{" {
                depth += 1
                advance()
            }
            return header
        }

        private mutating func skipUntilBrace() {
            while index < text.endIndex, text[index] != "{" {
                advance()
            }
            if index < text.endIndex {
                depth += 1
                advance()
            }
        }

        private mutating func skipTrivia() {
            while index < text.endIndex {
                if text[index].isWhitespace {
                    advance()
                } else if text[index] == "/", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                    while index < text.endIndex, text[index] != "\n" { advance() }
                } else if text[index] == "/", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "*" {
                    advance()
                    advance()
                    while index < text.endIndex {
                        if text[index] == "*", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                            advance()
                            advance()
                            break
                        }
                        advance()
                    }
                } else {
                    break
                }
            }
        }

        private mutating func readIdentifier() -> String? {
            skipTrivia()
            guard index < text.endIndex else { return nil }
            let first = text[index]
            guard first == "_" || first.isLetter else { return nil }
            let start = index
            advance()
            while index < text.endIndex {
                let character = text[index]
                if character == "_" || character.isLetter || character.isNumber { advance() } else { break }
            }
            return String(text[start..<index])
        }

        private func peekIdentifier() -> String? {
            var copy = self
            return copy.readIdentifier()
        }

        private mutating func readString() -> String? {
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            advance()
            var value = ""
            while index < text.endIndex, text[index] != "\"" {
                if text[index] == "\\" {
                    advance()
                    if index < text.endIndex {
                        value.append(text[index])
                        advance()
                    }
                } else {
                    value.append(text[index])
                    advance()
                }
            }
            if index < text.endIndex { advance() }
            return value
        }

        private mutating func advance() {
            if index < text.endIndex { index = text.index(after: index) }
        }
    }
}
