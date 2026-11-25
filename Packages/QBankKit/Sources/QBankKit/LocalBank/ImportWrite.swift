import Foundation

/// Writing a checked file into the bank as a set: its row, its questions and its terms.
enum ImportWrite {
    /// Files the set. A replaced set stays, as an earlier version, with its folder, its questions and the progress on them; a question
    /// whose content the file did not change keeps its lineage, so the person's answers follow it into the new version.
    static func insertSet(
        _ call: BankCall, check: ImportCheck, source: String, title: String, courseID: String, folder: FolderRow, replacing: SetRow?
    ) throws -> (setID: String, lineageID: String) {
        let tx = call.tx
        let now = call.nowText
        let setId = call.newID()
        let lineageId = replacing?.lineageId ?? setId
        let sortOrder: Int
        if let replacing {
            sortOrder = replacing.sortOrder
            try tx.execute("UPDATE practice_set SET is_current = 0, replaced_at = ? WHERE id = ?", [.text(now), .text(replacing.id)])
        } else {
            sortOrder = try CatalogRules.nextSort(tx, "SELECT max(sort_order) FROM practice_set WHERE course_id = ?", [.text(courseID)])
        }
        try tx.execute(
            """
            INSERT INTO practice_set (id, course_id, lineage_id, title, description, week_label, folder_id, sort_order, imported_at, file_hash, stats, is_current, replaced_at, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, NULL, ?)
            """,
            [
                .text(setId), .text(courseID), .text(lineageId), .text(title), .text(check.description), .text(folder.name), .text(folder.id),
                .integer(Int64(sortOrder)), .text(now), .text(ImportHash.fileHash(source)), .text(JS.stringify(stats(check))), .text(check.kind),
            ])
        var previous: [String: (lineageId: String, contentHash: String)] = [:]
        if let replacing {
            for row in try tx.rows("SELECT public_id, lineage_id, content_hash FROM question WHERE set_id = ? ORDER BY position, id", [.text(replacing.id)]) {
                let key = row.string("public_id")
                if previous[key] == nil { previous[key] = (row.string("lineage_id"), row.string("content_hash")) }
            }
        }
        for question in check.questions {
            let hash = ImportHash.contentHash(question)
            let prior = previous[question.publicId]
            let lineage = prior?.contentHash == hash ? prior?.lineageId ?? call.newID() : call.newID()
            try insert(question, call: call, setID: setId, lineageID: lineage, hash: hash, folderName: folder.name)
        }
        for term in check.terms {
            try tx.execute(
                "INSERT INTO term (id, set_id, key, term, meaning) VALUES (?, ?, ?, ?, ?)",
                [.text(call.newID()), .text(setId), .text(term.key), .text(term.term), .text(term.meaning)])
        }
        return (setId, lineageId)
    }

    private static func insert(_ question: CheckedQuestion, call: BankCall, setID: String, lineageID: String, hash: String, folderName: String) throws {
        var difficulty: StoreValue = .null
        if let value = question.difficulty {
            // The server stores it as a 32-bit integer and fails the import for one that does not fit.
            guard abs(value) <= 2_147_483_647 else { throw BankRefusal.failed }
            difficulty = .integer(Int64(value))
        }
        try call.tx.execute(
            """
            INSERT INTO question (id, set_id, lineage_id, public_id, position, type, topic, cj, client_need, difficulty, week_label, stem, ask, body, rationale, takeaway, term_keys, source, content_hash, twin_of, twin_of_lineage_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            [
                .text(call.newID()), .text(setID), .text(lineageID), .text(question.publicId), .integer(Int64(question.position)), .text(question.type),
                .text(question.topic), .optional(question.cj), .optional(question.need), difficulty, .text(question.week ?? folderName), .text(question.stem),
                .text(question.ask), .text(JS.stringify(.object(question.body))), .text(question.rationale), .text(question.takeaway),
                .text(JS.stringify(.array(question.termKeys.map(JSNode.string)))), .optional(question.source), .text(hash), .optional(question.twinOf),
            ])
    }

    /// The counts stored with a set, from what the check found.
    static func stats(_ check: ImportCheck) -> JSNode {
        func tally(_ keys: [String]) -> [(key: String, count: Int)] {
            var counts: [(key: String, count: Int)] = []
            for key in keys {
                if let at = counts.firstIndex(where: { JS.same($0.key, key) }) { counts[at].count += 1 } else { counts.append((key, 1)) }
            }
            return counts
        }
        func object(_ keys: [String]) -> JSObject {
            var object = JSObject()
            for entry in tally(keys) { object.set(entry.key, .number(Double(entry.count))) }
            return object.inJavaScriptOrder()
        }
        let questions = check.questions
        var stats = JSObject()
        stats.set("questionCount", .number(Double(questions.count)))
        stats.set("termCount", .number(Double(check.terms.count)))
        stats.set("byType", .object(object(questions.map(\.type))))
        stats.set("byCj", .object(object(questions.compactMap { $0.cj.flatMap { $0.isEmpty ? nil : $0 } })))
        stats.set("byNeed", .object(object(questions.compactMap { $0.need.flatMap { $0.isEmpty ? nil : $0 } })))
        stats.set("byDifficulty", .object(object(questions.compactMap { $0.difficulty.map(JS.numberString) })))
        return .object(stats)
    }
}

extension JSNode {
    /// The value as the bank answers it. A number JSON cannot write (infinity) is null, as `JSON.stringify` makes it.
    var json: JSONValue {
        switch self {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): number.isFinite ? .number(number) : .null
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(\.json))
        case .object(let object): .object(Dictionary(object.entries.map { ($0.key, $0.value.json) }, uniquingKeysWith: { $1 }))
        }
    }
}

extension ImportReport {
    /// The check as `POST /api/imports/check` answers it: a file with no title answers null.
    var wire: JSONValue {
        .object([
            "ok": .bool(ok), "title": .optional(title), "description": .string(description), "kind": .string(kind.rawValue),
            "questionCount": .int(questionCount), "termCount": .int(termCount),
            "formats": .array(formats.map { .object(["type": .string($0.type), "label": .string($0.label), "count": .int($0.count)]) }),
            "errors": .array(errors.map(JSONValue.string)), "warnings": .array(warnings.map(JSONValue.string)), "issues": .array(issues.map(\.wire)),
        ])
    }
}

extension ImportReport.Issue {
    /// An issue as the check answers it: one with the file as a whole answers a null question, and a question with no id leaves it out.
    var wire: JSONValue {
        let about: JSONValue =
            question.map { question in
                var fields: [String: JSONValue] = ["index": .int(question.index)]
                if let id = question.id { fields["id"] = .string(id) }
                return .object(fields)
            } ?? .null
        return .object(["severity": .string(severity.rawValue), "code": .string(code), "question": about, "path": .string(path), "message": .string(message)])
    }
}
