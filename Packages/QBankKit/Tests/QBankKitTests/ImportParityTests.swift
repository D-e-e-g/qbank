import Foundation
import Testing

@testable import QBankKit

/// The import check against the real server's answers. `Fixtures/import-parity.json` holds each case as a file and what the server's
/// `checkImport` made of it (the report `POST /api/imports/check` answers, and for a file that passed, what an import stores from it),
/// recorded by running the server's own function on the same input, with the server commit it ran at. The cases are the server's own
/// `import.test.ts` (the three rule changes for questions on any subject included), its media rules, and files that reach the places where
/// JavaScript and Swift read a value differently. The tests read the file and hold no case of their own, so a corpus the server publishes
/// can take its place.
@Suite struct ImportParityTests {
    struct Case {
        let name: String
        let origin: String
        let source: String
        let report: JSONValue
        let stored: JSONValue?
    }

    static func load() throws -> (server: JSONValue, cases: [Case]) {
        let url = try #require(Bundle.module.url(forResource: "import-parity", withExtension: "json", subdirectory: "Fixtures"))
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let list = try #require(file["cases"]?.arrayValue)
        let cases = try list.map { item -> Case in
            Case(
                name: try #require(item["name"]?.stringValue), origin: try #require(item["origin"]?.stringValue), source: try #require(item["source"]?.stringValue),
                report: try #require(item["report"]), stored: item["stored"].flatMap { $0.isNull ? nil : $0 })
        }
        return (try #require(file["server"]), cases)
    }

    @Test func theFileNamesTheServerItWasRecordedFromAndHoldsTheServersOwnCases() throws {
        let (server, cases) = try Self.load()
        #expect(server["commit"]?.stringValue?.count == 40)
        #expect(server["repository"]?.stringValue == "D-e-e-g/qbank-server")
        #expect(cases.filter { $0.origin == "import.test.ts" }.count >= 40)
        #expect(cases.filter { $0.origin.hasPrefix("A11") }.count >= 15)
        #expect(cases.count >= 400)
        #expect(Set(cases.map(\.name)).count == cases.count, "every case has its own name")
    }

    @Test func everyFileGetsTheServersReport() throws {
        let (_, cases) = try Self.load()
        var wrong: [String] = []
        for item in cases where ImportChecker.report(for: item.source).wire != item.report {
            wrong.append("\(item.name)\n  server: \(Self.show(item.report))\n  phone:  \(Self.show(ImportChecker.report(for: item.source).wire))")
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(cases.count) differ:\n\(wrong.prefix(8).joined(separator: "\n"))")
    }

    @Test func everyFileThatPassesStoresWhatTheServerStores() throws {
        let (_, cases) = try Self.load()
        var wrong: [String] = []
        for item in cases {
            let check = ImportChecker.check(item.source)
            let phone = check.ok ? Self.stored(check, source: item.source) : nil
            if phone != item.stored { wrong.append("\(item.name)\n  server: \(Self.show(item.stored))\n  phone:  \(Self.show(phone))") }
        }
        #expect(wrong.isEmpty, "\(wrong.count) differ:\n\(wrong.prefix(5).joined(separator: "\n"))")
        #expect(cases.filter { $0.stored != nil }.count >= 100, "enough files pass for this to prove something")
    }

    /// The file's parts as an import stores them: the columns of each question, the file's and each question's hashes, and the set's counts.
    static func stored(_ check: ImportCheck, source: String) -> JSONValue {
        .object([
            "fileHash": .string(ImportHash.fileHash(source)), "stats": ImportWrite.stats(check).json,
            "questions": .array(
                check.questions.map { question in
                    .object([
                        "position": .int(question.position), "publicId": .string(question.publicId), "type": .string(question.type), "topic": .string(question.topic),
                        "cj": .optional(question.cj), "need": .optional(question.need), "difficulty": question.difficulty.map { JSNode.number($0).json } ?? .null,
                        "week": .optional(question.week), "stem": .string(question.stem), "ask": .string(question.ask), "rationale": .string(question.rationale),
                        "takeaway": .string(question.takeaway), "termKeys": .array(question.termKeys.map(JSONValue.string)), "source": .optional(question.source),
                        "twinOf": .optional(question.twinOf), "body": JSNode.object(question.body).json, "bodyKeys": .array(question.body.keys.map(JSONValue.string)),
                        "contentHash": .string(ImportHash.contentHash(question)), "table": ImportMedia.readTable(question.body["table"]),
                        "images": .array(ImportMedia.readImages(question.body["images"])),
                    ])
                }),
            "terms": .array(check.terms.map { .object(["key": .string($0.key), "term": .string($0.term), "meaning": .string($0.meaning)]) }),
        ])
    }

    static func show(_ value: JSONValue?) -> String {
        guard let value else { return "nothing" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return text.count > 600 ? "\(text.prefix(600))..." : text
    }
}
