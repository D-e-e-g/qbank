#if DEBUG
import Foundation
import QBankKit

/// The fake server's importer check: the main rules and words of the server's `checkImport`
/// (`packages/questions/src/import.ts`), enough for Import to show a ready file, its formats, the
/// errors that block a file, and warnings. Nothing here reads a real file.
nonisolated struct FakeImportCheck {
    static let labels: [QuestionType: String] = [
        .single: "Single answer", .priority: "Priority / first action", .sata: "Select all that apply",
        .order: "Ordered response", .match: "Matching", .matrix: "Matrix",
        .matrixmulti: "Matrix, check all that fit", .highlight: "Highlight", .cloze: "Drop-down cloze",
    ]

    let title: String?
    let description: String
    let kind: String
    let questionCount: Int
    let termCount: Int
    let formats: [(type: QuestionType, count: Int)]
    let errors: [String]
    let warnings: [String]

    var ok: Bool { errors.isEmpty }

    /// `POST /api/imports/check`'s answer.
    var json: [String: Any] {
        [
            "ok": ok, "title": title.map { $0 as Any } ?? NSNull(), "description": description, "kind": kind,
            "questionCount": questionCount, "termCount": termCount,
            "formats": formats.map { ["type": $0.type.rawValue, "label": Self.labels[$0.type] ?? $0.type.rawValue, "count": $0.count] },
            "errors": errors, "warnings": warnings,
        ]
    }

    init(source raw: String) {
        // A fenced block from an AI chat is tolerated.
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/^```[a-zA-Z]*\s*/, with: "")
            .replacing(/```\s*$/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            self.init(errors: ["This is not valid JSON. Ask your AI chat to resend only the JSON block."])
            return
        }
        let object: [String: Any]
        if let list = parsed as? [Any] {
            object = ["title": "Imported questions", "questions": list]
        } else if let dictionary = parsed as? [String: Any] {
            object = dictionary
        } else {
            self.init(errors: ["No \"questions\" list was found."])
            return
        }
        guard let questions = object["questions"] as? [Any], !questions.isEmpty else {
            self.init(errors: ["No \"questions\" list was found."])
            return
        }
        let terms = object["terms"] as? [String: Any] ?? [:]
        var errors: [String] = []
        var warnings: [String] = []
        var counts: [QuestionType: Int] = [:]
        var kind = "practice"
        if let given = object["kind"] {
            if let name = given as? String, name == "practice" || name == "exam" {
                kind = name
            } else {
                errors.append("The set's \"kind\" must be \"practice\" or \"exam\" (found \(given))")
            }
        }
        for (index, item) in questions.enumerated() {
            let id = ((item as? [String: Any])?["id"]).map { " (\($0))" } ?? ""
            let tag = "Question \(index + 1)\(id): "
            guard let question = item as? [String: Any] else {
                errors.append("\(tag)not an object")
                continue
            }
            guard let type = (question["type"] as? String).flatMap(QuestionType.init(rawValue:)) else {
                errors.append("\(tag)unknown type \"\(question["type"].map { "\($0)" } ?? "undefined")\"")
                continue
            }
            for field in ["stem", "ask", "rationale", "takeaway"] where (question[field] as? String)?.isEmpty ?? true {
                errors.append("\(tag)missing \(field)")
            }
            if [.single, .priority, .sata].contains(type) {
                let options = question["options"] as? [[String: Any]] ?? []
                let oks = options.count { $0["ok"] as? Bool == true }
                if options.count < 3 {
                    errors.append("\(tag)needs at least 3 options")
                } else if type != .sata, oks != 1 {
                    errors.append("\(tag)needs exactly one option with \"ok\": true (found \(oks))")
                } else if type == .sata, oks < 1 || oks == options.count {
                    errors.append("\(tag)select-all needs some correct and some incorrect options")
                }
            }
            for term in question["terms"] as? [String] ?? [] where !(terms[term] is [Any]) {
                warnings.append("\(tag)term \"\(term)\" has no definition and will be skipped")
            }
            for field in ["cj", "need", "src"] where (question[field] as? String)?.isEmpty ?? true {
                warnings.append("\(tag)missing \(field)")
            }
            if question["diff"] == nil {
                warnings.append("\(tag)missing diff")
            }
            counts[type, default: 0] += 1
        }
        let ok = errors.isEmpty
        self.init(
            title: (object["title"] as? String).map { $0.trimmingCharacters(in: .whitespaces) } ?? "Imported questions",
            description: object["desc"] as? String ?? "",
            kind: kind,
            questionCount: ok ? questions.count : 0,
            termCount: ok ? terms.values.count { $0 is [Any] } : 0,
            formats: ok ? QuestionType.allCases.compactMap { type in counts[type].map { (type, $0) } } : [],
            errors: errors,
            warnings: warnings
        )
    }

    private init(errors: [String]) {
        self.init(title: nil, description: "", kind: "practice", questionCount: 0, termCount: 0, formats: [], errors: errors, warnings: [])
    }

    private init(
        title: String?, description: String, kind: String, questionCount: Int, termCount: Int,
        formats: [(type: QuestionType, count: Int)], errors: [String], warnings: [String]
    ) {
        self.title = title
        self.description = description
        self.kind = kind
        self.questionCount = questionCount
        self.termCount = termCount
        self.formats = formats
        self.errors = errors
        self.warnings = warnings
    }

    /// A small question file for UI tests and review: three invented questions in two formats.
    static func sampleFile(title: String = "Invented Sleep and Rest", questions: Int = 3) -> String {
        let items = (0..<questions).map { index -> [String: Any] in
            let options: [[String: Any]] = index % 3 == 1
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
