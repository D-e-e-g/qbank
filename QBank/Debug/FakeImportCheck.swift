#if DEBUG
import Foundation
import QBankKit

/// The fake server's importer check. It is QBankKit's own `ImportChecker`, the port of the server's `checkImport` that the
/// on-phone bank answers with, so a UI test sees the real verdicts, counts and words. Nothing here reads a real file.
nonisolated struct FakeImportCheck {
    let title: String?
    let description: String
    let kind: String
    let questionCount: Int
    let termCount: Int
    let formats: [(type: QuestionType, count: Int)]
    let errors: [String]
    let warnings: [String]
    let issues: [ImportReport.Issue]
    private let labels: [String: String]

    var ok: Bool { errors.isEmpty }

    /// `POST /api/imports/check`'s answer.
    var json: [String: Any] {
        [
            "ok": ok, "title": title.map { $0 as Any } ?? NSNull(), "description": description, "kind": kind,
            "questionCount": questionCount, "termCount": termCount,
            "formats": formats.map { ["type": $0.type.rawValue, "label": labels[$0.type.rawValue] ?? $0.type.rawValue, "count": $0.count] },
            "errors": errors, "warnings": warnings, "issues": issues.map(Self.json),
        ]
    }

    private static func json(_ issue: ImportReport.Issue) -> [String: Any] {
        let question: Any =
            issue.question.map { question in
                var fields: [String: Any] = ["index": question.index]
                fields["id"] = question.id
                return fields
            } ?? NSNull()
        return ["severity": issue.severity.rawValue, "code": issue.code, "question": question, "path": issue.path, "message": issue.message]
    }

    init(source: String) {
        let report = ImportChecker.report(for: source)
        title = report.title
        description = report.description
        kind = report.kind.rawValue
        questionCount = report.questionCount
        termCount = report.termCount
        formats = report.formats.compactMap { format in QuestionType(rawValue: format.type).map { ($0, format.count) } }
        labels = Dictionary(report.formats.map { ($0.type, $0.label) }, uniquingKeysWith: { first, _ in first })
        errors = report.errors
        warnings = report.warnings
        issues = report.issues
    }

    /// A small question file for UI tests and review: three invented questions in two formats.
    static func sampleFile(title: String = "Invented Sleep and Rest", questions: Int = 3) -> String {
        let items = (0..<questions).map { index -> [String: Any] in
            let options: [[String: Any]] =
                index % 3 == 1
                ? [["t": "Dim the lights", "ok": true], ["t": "Limit caffeine", "ok": true], ["t": "Nap at noon"], ["t": "Keep a screen on"]]
                : [["t": "Keep a regular bedtime", "ok": true], ["t": "Nap in the evening"], ["t": "Drink coffee at night"], ["t": "Exercise at midnight"]]
            return [
                "id": "S\(index + 1)", "type": index % 3 == 1 ? "sata" : "single", "topic": "Invented rest topic \(index + 1)",
                "cj": "Take action", "need": "Basic care and comfort", "diff": 2, "src": "Invented notes",
                "stem": "An invented client has trouble sleeping.", "ask": "Which advice helps?",
                "options": options, "rationale": "Invented rationale.", "takeaway": "Invented takeaway.", "terms": ["sleep-hygiene"],
            ]
        }
        let file: [String: Any] = [
            "title": title, "desc": "Invented practice questions.",
            "terms": ["sleep-hygiene": ["Sleep hygiene", "Habits that help sleep."]], "questions": items,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
