import Foundation
import Testing

@testable import QBankKit

/// The import check against the server's own cases. `Fixtures/import-cases.json` is the conformance corpus the server generates
/// (`packages/questions/conformance/import-cases.json`), copied byte for byte: each case is a name, the text handed to the server's
/// `checkImport`, and everything it reported. `Fixtures/import-cases.pin.json` names the server commit and the copy's hash, and
/// `test/record-contract.sh` writes both with the rest of the pinned contract. The tests hold no case of their own.
@Suite struct ImportParityTests {
    struct Case {
        let name: String
        let input: String
        let report: [String: JSONValue]
    }

    private struct CorpusPin: Decodable {
        let repository: String
        let commit: String
        let path: String
        let sha256: String
    }

    private static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func cases() throws -> [Case] {
        let list = try #require(try JSONDecoder().decode(JSONValue.self, from: data("import-cases")).arrayValue)
        return try list.map { item in
            guard case .object(let report)? = item["report"] else { throw CocoaError(.coderValueNotFound) }
            return Case(name: try #require(item["name"]?.stringValue), input: try #require(item["input"]?.stringValue), report: report)
        }
    }

    @Test func theCorpusIsTheOneAtTheContractsCommit() throws {
        let contract = try JSONDecoder().decode(ContractSchemaTests.Pin.self, from: Self.data("pin"))
        let corpus = try JSONDecoder().decode(CorpusPin.self, from: Self.data("import-cases.pin"))
        #expect(corpus.commit == contract.commit, "re-pin both with test/record-contract.sh")
        #expect(corpus.repository == contract.repository)
        #expect(corpus.path == "packages/questions/conformance/import-cases.json")
        #expect(corpus.sha256 == SHA256.hex(Array(try Self.data("import-cases"))), "the corpus is a copy of the server's file and is not edited here")
        let cases = try Self.cases()
        #expect(!cases.isEmpty)
        #expect(Set(cases.map(\.name)).count == cases.count, "every case has its own name")
    }

    /// Everything the server's check reports: the verdict, the set, every question and term it would store, the counts by format,
    /// and the errors, warnings and issues in order.
    @Test func everyCaseGetsTheServersCheck() throws {
        let cases = try Self.cases()
        var wrong: [String] = []
        for item in cases {
            let phone = Self.checked(ImportChecker.check(item.input))
            for key in Set(phone.keys).union(item.report.keys).sorted() where phone[key] != item.report[key] {
                wrong.append("\(item.name): \(key)\n  server: \(Self.show(item.report[key]))\n  phone:  \(Self.show(phone[key]))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) differences:\n\(wrong.prefix(8).joined(separator: "\n"))")
    }

    /// `POST /api/imports/check` answers the same report with the questions and terms counted instead of listed.
    @Test func everyCaseIsAnsweredAsTheCheckRouteAnswersIt() throws {
        var wrong: [String] = []
        for item in try Self.cases() {
            var expected = item.report
            expected["questions"] = nil
            expected["terms"] = nil
            expected["questionCount"] = .int(try #require(item.report["questions"]?.arrayValue).count)
            expected["termCount"] = .int(try #require(item.report["terms"]?.arrayValue).count)
            let phone = ImportChecker.report(for: item.input).wire
            if phone != .object(expected) { wrong.append("\(item.name)\n  server: \(Self.show(.object(expected)))\n  phone:  \(Self.show(phone))") }
        }
        #expect(wrong.isEmpty, "\(wrong.count) differ:\n\(wrong.prefix(5).joined(separator: "\n"))")
    }

    /// The contract lists every rule of the format. A rule the server adds fails here at the next pin, whether or not a case reaches it.
    @Test func thePhoneHasEveryRuleTheContractDescribes() throws {
        let contract = try JSONDecoder().decode(JSONValue.self, from: Self.data("openapi"))
        let described = try #require(contract["x-question-format"]?["descriptor"]?["rules"]?.arrayValue)
        let server = try described.map { rule in "\(try #require(rule["code"]?.stringValue)) \(try #require(rule["severity"]?.stringValue))" }
        let phone = FormatRule.allCases.map { "\($0.rawValue) \($0.severity.rawValue)" }
        #expect(phone.sorted() == server.sorted())
    }

    /// An import also stores a hash of each question and the set's counts, which no check reports and no answer carries. A bank
    /// archive the server wrote holds both beside the columns they are made from.
    @Test func theHashesAndCountsAnImportStoresAreTheServers() throws {
        let url = try #require(Bundle.module.url(forResource: "server-bank", withExtension: "json", subdirectory: "Fixtures/bank-archive"))
        let bank = try LocalStore.inMemory()
        _ = try BankArchive.read(Data(contentsOf: url), into: bank)
        let sets = try bank.run("SELECT id, stats FROM practice_set ORDER BY id")
        var questionCount = 0
        for set in sets {
            let id = try #require(set.text("id"))
            let questions = try bank.run("SELECT * FROM question WHERE set_id = ? ORDER BY position", [.text(id)]).map(Self.question)
            let terms = try bank.run("SELECT key, term, meaning FROM term WHERE set_id = ?", [.text(id)])
                .map { CheckedTerm(key: $0.string("key"), term: $0.string("term"), meaning: $0.string("meaning")) }
            let hashes = try bank.run("SELECT content_hash FROM question WHERE set_id = ? ORDER BY position", [.text(id)]).map { $0.string("content_hash") }
            #expect(questions.map(ImportHash.contentHash) == hashes, "set \(id)")
            let stored = try JSParser.parse(try #require(set.text("stats")))
            #expect(ImportWrite.stats(ImportCheck(title: nil, questions: questions, terms: terms)).json == stored.json, "set \(id)")
            questionCount += questions.count
        }
        #expect(!sets.isEmpty && questionCount > 0, "the recording has sets to compare")
    }

    /// A stored question, as the check hands it to an import.
    private static func question(_ row: StoreRow) throws -> CheckedQuestion {
        let body = try #require(try JSParser.parse(row.string("body")).record)
        let termKeys = try #require(try JSParser.parse(row.string("term_keys")).list).compactMap(\.text)
        return CheckedQuestion(
            position: try #require(row.int("position")), publicId: row.string("public_id"), type: row.string("type"), topic: row.string("topic"),
            cj: row.text("cj"), need: row.text("client_need"), difficulty: row.int("difficulty").map(Double.init), week: row.text("week_label"),
            stem: row.string("stem"), ask: row.string("ask"), rationale: row.string("rationale"), takeaway: row.string("takeaway"), termKeys: termKeys,
            source: row.text("source"), twinOf: row.text("twin_of"), body: body)
    }

    /// The phone's check in the shape the corpus keeps the server's.
    private static func checked(_ check: ImportCheck) -> [String: JSONValue] {
        guard case .object(var report) = ImportReport(check).wire else { return [:] }
        report["questionCount"] = nil
        report["termCount"] = nil
        report["questions"] = .array(
            check.questions.map { question in
                .object([
                    "position": .int(question.position), "publicId": .string(question.publicId), "type": .string(question.type), "topic": .string(question.topic),
                    "cj": .optional(question.cj), "need": .optional(question.need), "difficulty": question.difficulty.map { JSNode.number($0).json } ?? .null,
                    "week": .optional(question.week), "stem": .string(question.stem), "ask": .string(question.ask), "rationale": .string(question.rationale),
                    "takeaway": .string(question.takeaway), "termKeys": .array(question.termKeys.map(JSONValue.string)), "source": .optional(question.source),
                    "twinOf": .optional(question.twinOf), "body": JSNode.object(question.body).json,
                ])
            })
        report["terms"] = .array(check.terms.map { .object(["key": .string($0.key), "term": .string($0.term), "meaning": .string($0.meaning)]) })
        return report
    }

    private static func show(_ value: JSONValue?) -> String {
        guard let value else { return "nothing" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return text.count > 600 ? "\(text.prefix(600))..." : text
    }
}
