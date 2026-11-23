import Foundation

/// One question the check accepted, in the form the bank stores it.
struct CheckedQuestion {
    let position: Int
    let publicId: String
    let type: String
    let topic: String
    let cj: String?
    let need: String?
    let difficulty: Double?
    /// The question's own week label, when the file set one. Otherwise the set's.
    let week: String?
    let stem: String
    let ask: String
    let rationale: String
    let takeaway: String
    let termKeys: [String]
    let source: String?
    /// In an exam set, the id of the practice question this one is the exam twin of.
    let twinOf: String?
    /// The format's own fields and anything else the file carried that is not a column.
    let body: JSObject
}

struct CheckedTerm {
    let key: String
    let term: String
    let meaning: String
}

/// What the import check made of a file: what the Import screen shows, and what an import stores.
struct ImportCheck {
    var ok: Bool
    /// Set when the file parsed. "Imported questions" when it gave no title.
    var title: String?
    var description = ""
    /// `exam` when the file says so, otherwise `practice`.
    var kind = "practice"
    var questions: [CheckedQuestion] = []
    var terms: [CheckedTerm] = []
    var formats: [ImportReport.Format] = []
    var warnings: [String] = []
    var errors: [String] = []

    static func failed(_ errors: [String]) -> ImportCheck { ImportCheck(ok: false, title: nil, errors: errors) }
}

/// The import check: a port of the server's `checkImport` (`packages/questions/src/import.ts`). It
/// finds the same errors and warnings, in the same order and the same words, for any file, so the
/// phone refuses and accepts exactly what the server does. `ImportParityTests` holds the cases.
public enum ImportChecker {
    /// The check as `POST /api/imports/check` answers it.
    public static func report(for source: String) -> ImportReport {
        let check = check(source)
        return ImportReport(
            ok: check.ok, title: check.title, description: check.description, kind: PracticeSet.Kind(rawValue: check.kind) ?? .practice,
            questionCount: check.questions.count, termCount: check.terms.count, formats: check.formats, errors: check.errors, warnings: check.warnings)
    }

    static let typeLabels: [(type: String, label: String)] = [
        ("single", "Single answer"), ("priority", "Priority / first action"), ("sata", "Select all that apply"), ("highlight", "Highlight"),
        ("order", "Ordered response"), ("match", "Matching"), ("matrix", "Matrix"), ("matrixmulti", "Matrix, check all that fit"),
        ("cloze", "Drop-down cloze"),
    ]

    /// Fields the question keeps in a column of its own. The rest of what a question carries stays in its body.
    private static let hoisted: Set<String> = ["id", "type", "topic", "cj", "need", "diff", "wk", "stem", "ask", "rationale", "takeaway", "terms", "src"]
    private static let warnedFields = ["cj", "need", "diff", "src"]
    private static let noQuestions = "No \"questions\" list was found."
    private static let duplicateColumn = "every column name must be different"

    /// The text the importer parses: trimmed, with one leading and one trailing fence removed.
    static func unwrap(_ raw: String) -> String {
        var text = Array(JS.trim(raw).unicodeScalars)
        if text.starts(with: "```".unicodeScalars) {
            var at = 3
            while at < text.count, (text[at].value >= 0x41 && text[at].value <= 0x5A) || (text[at].value >= 0x61 && text[at].value <= 0x7A) { at += 1 }
            while at < text.count, JS.isSpace(text[at]) { at += 1 }
            text.removeFirst(at)
        }
        var end = text.count
        while end > 0, JS.isSpace(text[end - 1]) { end -= 1 }
        if end >= 3, text[(end - 3)..<end].elementsEqual("```".unicodeScalars) { text.removeSubrange((end - 3)...) }
        return JS.trim(String(String.UnicodeScalarView(text)))
    }

    static func check(_ raw: String) -> ImportCheck {
        let parsed: JSNode
        do {
            parsed = try JSParser.parse(unwrap(raw))
        } catch {
            return .failed(["This is not valid JSON: \(error.message). Ask your AI chat to resend only the JSON block."])
        }
        let file: JSObject
        switch parsed {
        case .array(let items):
            var wrapper = JSObject()
            wrapper.set("title", .string("Imported questions"))
            wrapper.set("questions", .array(items))
            file = wrapper
        case .object(let object): file = object
        default: return .failed([noQuestions])
        }
        guard let nodes = file["questions"]?.list, !nodes.isEmpty else { return .failed([noQuestions]) }
        var run = Run(file: file, terms: file["terms"]?.record ?? JSObject())
        run.readKind()
        run.findUsedFields(nodes)
        for (index, node) in nodes.enumerated() { run.read(node, index) }
        return run.finish()
    }

    /// The state of one check: what the file says, and what has been found so far.
    private struct Run {
        let file: JSObject
        let terms: JSObject
        var kind: String?
        var used: Set<String> = []
        var errors: [String] = []
        var warnings: [String] = []
        var questions: [CheckedQuestion] = []

        init(file: JSObject, terms: JSObject) {
            self.file = file
            self.terms = terms
        }

        // MARK: The file

        mutating func readKind() {
            switch file["kind"] {
            case nil, .null?: kind = "practice"
            case .string(let name)? where name == "practice" || name == "exam": kind = name
            case let other?: errors.append("The set's \"kind\" must be \"practice\" or \"exam\" (found \(JS.stringify(other)))")
            }
        }

        /// A field is used when any question in the file carries it. Only then is a question without it worth a warning.
        mutating func findUsedFields(_ nodes: [JSNode]) {
            for node in nodes {
                guard let record = node.record else { continue }
                for field in warnedFields where carries(record, field) { used.insert(field) }
            }
        }

        private func carries(_ record: JSObject, _ field: String) -> Bool {
            if field == "diff" {
                switch record["diff"] {
                case nil, .null?, .string("")?: return false
                default: return true
                }
            }
            return record[field]?.filledText != nil
        }

        // MARK: A question

        mutating func read(_ node: JSNode, _ index: Int) {
            let tag = Self.tag(node, index)
            let record: JSObject
            switch node {
            case .object(let object): record = object
            case .array: record = JSObject()
            default:
                errors.append("\(tag)not an object")
                return
            }
            guard let type = record["type"]?.text, typeLabels.contains(where: { $0.type == type }) else {
                errors.append("\(tag)unknown type \"\(JS.string(of: record["type"]))\"")
                return
            }
            let ask = record["ask"]?.filledText
            if ask == nil { errors.append("\(tag)missing ask") }
            // A missing or blank section is empty text. One that is present but not text is a mistake in the file, so it is refused rather than dropped.
            for field in ["stem", "rationale", "takeaway"] {
                if let value = record[field], value != .null, !value.isString { errors.append("\(tag)\(field) must be text") }
            }
            let stopped = checkFormat(record, type: type, ask: ask, tag: tag)
            if let problem = ImportMedia.tableProblem(record["table"]) { errors.append("\(tag)\(problem)") }
            for problem in ImportMedia.imageProblems(record["images"]) { errors.append("\(tag)\(problem)") }
            let twinOf = Self.twinOfValue(record["twinOf"])
            if let raw = record["twinOf"], raw != .null {
                if twinOf == nil {
                    errors.append("\(tag)\"twinOf\" must be the id of its practice question")
                } else if kind != "exam" {
                    warnings.append("\(tag)\"twinOf\" is only read in an exam set (\"kind\": \"exam\")")
                }
            }
            if stopped { return }
            let termKeys = readTerms(record, tag: tag)
            for field in warnedFields where used.contains(field) && !carries(record, field) { warnings.append("\(tag)missing \(field)") }
            // A question with no ask is listed above as an error. It is not stored.
            guard let ask else { return }
            var body = JSObject()
            for (key, value) in record.entries where !hoisted.contains(key) { body.set(key, value) }
            questions.append(
                CheckedQuestion(
                    position: index + 1, publicId: Self.publicID(record["id"], index), type: type, topic: Self.trimmed(record["topic"]) ?? "",
                    cj: Self.trimmed(record["cj"]), need: Self.trimmed(record["need"]), difficulty: Self.finiteInteger(record["diff"]),
                    week: Self.trimmed(record["wk"]), stem: Self.text(record["stem"]), ask: JS.trim(ask), rationale: Self.text(record["rationale"]),
                    takeaway: Self.text(record["takeaway"]), termKeys: termKeys, source: Self.trimmed(record["src"]),
                    twinOf: kind == "exam" ? twinOf : nil, body: body))
        }

        /// The format's own rules. True when the question has no usable body, so nothing more is said of it.
        private mutating func checkFormat(_ record: JSObject, type: String, ask: String?, tag: String) -> Bool {
            switch type {
            case "single", "priority", "sata": return checkChoices(record, type: type, tag: tag)
            case "order":
                if let items = record["items"]?.list, items.count >= 3, items.allSatisfy({ $0.record?["t"]?.filledText != nil }) { return false }
                errors.append("\(tag)needs 3+ items with text \"t\", listed in the correct order")
                return true
            case "match":
                if let pairs = record["pairs"]?.list, pairs.count >= 2, pairs.allSatisfy({ $0.record?["l"]?.filledText != nil && $0.record?["r"]?.filledText != nil }) {
                    return false
                }
                errors.append("\(tag)needs 2+ pairs with \"l\" and \"r\"")
                return true
            case "matrix": return checkMatrix(record, tag: tag)
            case "matrixmulti":
                let problem = Self.matrixMultiProblem(record["columns"], record["rows"])
                if let problem { errors.append("\(tag)\(problem)") }
                // A warning, not a refusal: the ask should say a row can fit more than one column.
                if let ask, !JS.includes(Array(ask.lowercased().unicodeScalars), "more than one") {
                    warnings.append("\(tag)the ask does not say a row can fit more than one column")
                }
                return problem != nil
            case "highlight":
                let segments = record["segments"]?.list ?? []
                let marked = segments.map { $0.record?["ok"] == .bool(true) }
                if segments.count >= 3, marked.contains(true), !marked.allSatisfy({ $0 }) { return false }
                errors.append("\(tag)needs 3+ segments, some with \"ok\": true and some without")
                return true
            default: return checkCloze(record, tag: tag)
            }
        }

        private mutating func checkChoices(_ record: JSObject, type: String, tag: String) -> Bool {
            guard let options = record["options"]?.list, options.count >= 2 else {
                errors.append("\(tag)needs at least 2 options")
                return true
            }
            let right = options.filter { $0.record?["ok"] == .bool(true) }.count
            if options.contains(where: { $0.record?["t"]?.filledText == nil }) { errors.append("\(tag)every option needs text \"t\"") }
            if type != "sata", right != 1 { errors.append("\(tag)needs exactly one option with \"ok\": true (found \(right))") }
            // Every option may be correct. Only a select-all with none correct is refused.
            if type == "sata", right < 1 { errors.append("\(tag)select-all needs at least one correct option") }
            return false
        }

        private mutating func checkMatrix(_ record: JSObject, tag: String) -> Bool {
            let columns = record["columns"]
            var stopped = false
            if let names = columns?.list, names.count >= 2, let rows = record["rows"]?.list, !rows.isEmpty {
                if Self.hasDuplicateColumn(names) {
                    errors.append("\(tag)\(duplicateColumn)")
                    stopped = true
                } else if rows.contains(where: { row in
                    row.record?["t"]?.filledText == nil || !names.contains { JS.strictlyEqual($0, row.record?["ans"]) }
                }) {
                    errors.append("\(tag)every row needs text \"t\" and an \"ans\" that matches a column name")
                    stopped = true
                }
            } else {
                errors.append("\(tag)needs columns and rows")
                stopped = true
            }
            // A warning, not a refusal: files that already carry such a column keep importing.
            if Self.hasCatchAllColumn(columns) { warnings.append("\(tag)If a row can fit more than one column, use matrixmulti") }
            return stopped
        }

        private mutating func checkCloze(_ record: JSObject, tag: String) -> Bool {
            let cloze = record["cloze"]?.record
            let holes = cloze?["text"]?.filledText.map(Self.placeholders) ?? -1
            guard let cloze, let blanks = cloze["blanks"]?.list, holes == blanks.count else {
                errors.append("\(tag)cloze text needs one {0}, {1}... placeholder per blank")
                return true
            }
            let bad = blanks.contains { blank in
                guard let blank = blank.record, let options = blank["opts"]?.list, options.count >= 2 else { return true }
                // The same comparison the runner uses, including its coercions.
                let answer = JS.number(of: blank["ans"])
                return !(answer >= 0 && answer < Double(options.count))
            }
            if bad {
                errors.append("\(tag)every blank needs \"opts\" and an \"ans\" index")
                return true
            }
            return false
        }

        private mutating func readTerms(_ record: JSObject, tag: String) -> [String] {
            var keys: [String] = []
            for term in record["terms"]?.list ?? [] {
                let name = JS.string(of: term)
                if terms[name]?.list == nil {
                    warnings.append("\(tag)term \"\(name)\" has no definition and will be skipped")
                } else if let key = term.text {
                    keys.append(key)
                }
            }
            return keys
        }

        // MARK: The result

        func finish() -> ImportCheck {
            var checked = ImportCheck(ok: errors.isEmpty, title: Self.trimmed(file["title"]) ?? "Imported questions", warnings: warnings, errors: errors)
            checked.description = Self.trimmed(file["desc"]) ?? ""
            checked.kind = kind ?? "practice"
            guard errors.isEmpty else { return checked }
            checked.questions = questions
            checked.terms = terms.entries.compactMap { key, value in
                guard let items = value.list else { return nil }
                let name = items.first?.filledText.map(JS.trim)
                return CheckedTerm(key: key, term: name ?? key, meaning: items.dropFirst().first?.text.map(JS.trim) ?? "")
            }
            checked.formats = typeLabels.compactMap { entry in
                let count = questions.filter { $0.type == entry.type }.count
                return count > 0 ? ImportReport.Format(type: entry.type, label: entry.label, count: count) : nil
            }
            return checked
        }

        // MARK: Reading values

        /// `Question 3 (Q7): `, naming the question by position and, when it has one, its id.
        static func tag(_ node: JSNode, _ index: Int) -> String {
            var id = ""
            if let raw = node.record?["id"] {
                switch raw {
                case .string, .number: id = " (\(JS.string(of: raw)))"
                default: break
                }
            }
            return "Question \(index + 1)\(id): "
        }

        static func publicID(_ id: JSNode?, _ index: Int) -> String {
            if let text = id?.text, !JS.trim(text).isEmpty { return JS.trim(text) }
            if case .number(let number)? = id, number.isFinite { return JS.numberString(number) }
            return "Q\(index + 1)"
        }

        /// A practice question's id, written the way `publicID` reads ids.
        static func twinOfValue(_ value: JSNode?) -> String? {
            if let text = value?.text, !JS.trim(text).isEmpty { return JS.trim(text) }
            if case .number(let number)? = value, number.isFinite { return JS.numberString(number) }
            return nil
        }

        static func trimmed(_ node: JSNode?) -> String? { node?.filledText.map(JS.trim) }

        /// A section's text, trimmed. Empty when the file left it out.
        static func text(_ node: JSNode?) -> String { node?.text.map(JS.trim) ?? "" }

        static func finiteInteger(_ node: JSNode?) -> Double? {
            switch node {
            case .number(let number)?: return number.isFinite && number == number.rounded(.towardZero) ? number : nil
            case .string(let text)?:
                let digits = JS.trim(text)
                let body = digits.hasPrefix("-") ? digits.dropFirst() : Substring(digits)
                return !body.isEmpty && body.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } ? JS.number(of: digits) : nil
            default: return nil
            }
        }

        /// `(text.match(/\{\d+\}/g) ?? []).length`
        static func placeholders(_ text: String) -> Int {
            let scalars = Array(text.unicodeScalars)
            var count = 0
            var at = 0
            while at < scalars.count {
                if scalars[at] == "{" {
                    var end = at + 1
                    while end < scalars.count, scalars[end].value >= 0x30, scalars[end].value <= 0x39 { end += 1 }
                    if end > at + 1, end < scalars.count, scalars[end] == "}" {
                        count += 1
                        at = end + 1
                        continue
                    }
                }
                at += 1
            }
            return count
        }

        // MARK: Matrix columns

        static func hasCatchAllColumn(_ columns: JSNode?) -> Bool {
            let names: Set<String> = ["both", "either", "either class", "all", "all of these", "all of the above"]
            return columns?.list?.contains { $0.text.map { names.contains(JS.trim($0).lowercased()) } ?? false } ?? false
        }

        /// Whether two columns have the same name as written, the way a row's "ans" is matched to one.
        static func hasDuplicateColumn(_ columns: [JSNode]) -> Bool {
            let names = columns.compactMap(\.filledText)
            return Set(names.map { Array($0.utf8) }).count != names.count
        }

        /// What a matrixmulti question must have before it is stored. Nil when it passes; the text is the refusal, without the question's tag.
        static func matrixMultiProblem(_ columns: JSNode?, _ rows: JSNode?) -> String? {
            guard let list = columns?.list, list.count >= 2, list.allSatisfy({ $0.filledText != nil }), let rowList = rows?.list, !rowList.isEmpty else {
                return "needs 2 or more columns and at least 1 row"
            }
            let names = list.compactMap(\.filledText)
            if hasDuplicateColumn(list) { return duplicateColumn }
            var rightBoxes = 0
            for row in rowList {
                guard let record = row.record, record["t"]?.filledText != nil, let answers = record["ans"]?.list else {
                    return "every row needs text \"t\" and an \"ans\" list of column names"
                }
                if answers.isEmpty { return "every row needs at least one right column" }
                var seen: Set<[UInt8]> = []
                for entry in answers {
                    guard let name = entry.text, names.contains(where: { JS.same($0, name) }) else { return "every \"ans\" entry must name a column" }
                    if !seen.insert(Array(name.utf8)).inserted { return "an \"ans\" entry must appear once in that row" }
                }
                rightBoxes += names.filter { seen.contains(Array($0.utf8)) }.count
            }
            return rightBoxes == names.count * rowList.count ? "not every box can be right" : nil
        }
    }
}
