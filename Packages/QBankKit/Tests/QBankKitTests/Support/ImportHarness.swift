import Foundation
import Testing

@testable import QBankKit

/// What the import and set tests share: a bank with one course, and question files built from invented data.
extension LocalBankHarness {
    /// A semester and a course in it, `NURS 101`. Returns the course's id.
    func makeCourse(number: Int = 1, code: String = "NURS 101") async throws -> String {
        var semester = try await send("POST", "/api/semesters", .object(["number": .number(Double(number))]))
        if semester.status == 409 {
            let listed = try await send("GET", "/api/semesters")
            semester = (200, try #require(listed.body["semesters"]?.arrayValue?.first { $0["number"] == .number(Double(number)) }))
        }
        let course = try await send(
            "POST", "/api/courses", .object(["semesterId": try #require(semester.body["id"]), "code": .string(code), "title": .string("Invented Nursing")]))
        #expect(course.status == 201)
        return try #require(course.body["id"]?.stringValue)
    }

    /// Imports a file into a course and returns the answer.
    func importFile(_ source: String, into course: String, folder: JSONValue? = nil, folderName: String? = nil, decision: String = "import", title: String? = nil)
        async throws -> (status: Int, body: JSONValue)
    {
        var body: [String: JSONValue] = ["source": .string(source), "courseId": .string(course), "decision": .string(decision)]
        if let folder { body["folderId"] = folder }
        if let folderName { body["folderName"] = .string(folderName) }
        if let title { body["title"] = .string(title) }
        return try await send("POST", "/api/imports", .object(body))
    }

    /// Every row of a table as text, for a before-and-after comparison.
    func rows(_ sql: String) throws -> [[StoreValue]] { try store.run(sql).map(\.values) }
}

/// A question file as text, written from invented parts.
enum Files {
    static func single(_ id: String, ask: String = "Which is right?", right: Int = 0, extra: [String: JSONValue] = [:]) -> JSONValue {
        var question: [String: JSONValue] = [
            "id": .string(id), "type": .string("single"), "ask": .string(ask),
            "options": .array((0..<3).map { .object(["t": .string("Choice \($0)")].merging($0 == right ? ["ok": .bool(true)] : [:]) { $1 }) }),
        ]
        for (key, value) in extra { question[key] = value }
        return .object(question)
    }

    static func make(_ title: String, _ questions: [JSONValue], terms: [String: [String]] = [:], kind: String? = nil, description: String? = nil) -> String {
        var file: [String: JSONValue] = ["title": .string(title), "questions": .array(questions)]
        if let description { file["desc"] = .string(description) }
        if let kind { file["kind"] = .string(kind) }
        if !terms.isEmpty { file["terms"] = .object(terms.mapValues { .array($0.map(JSONValue.string)) }) }
        return text(.object(file))
    }

    static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
