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
    /// Set when the file parsed. "Imported questions" when it gave no title.
    let title: String?
    var description = ""
    /// `exam` when the file says so, otherwise `practice`.
    var kind = "practice"
    var questions: [CheckedQuestion] = []
    var terms: [CheckedTerm] = []
    var formats: [ImportReport.Format] = []
    /// Every error and warning, in the order the check found them.
    var issues: [ImportReport.Issue] = []

    /// The errors' sentences, in order. Any one of them blocks the import.
    var errors: [String] { issues.filter { $0.severity == .error }.map(\.message) }
    var warnings: [String] { issues.filter { $0.severity == .warning }.map(\.message) }
    var ok: Bool { errors.isEmpty }

    /// A file the check could not read questions from.
    static func failed(_ finding: ImportFinding) -> ImportCheck { ImportCheck(title: nil, issues: [finding.issue()]) }
}

extension ImportReport {
    /// The check as `POST /api/imports/check` answers it, with the questions and terms counted.
    init(_ check: ImportCheck) {
        self.init(
            ok: check.ok, title: check.title, description: check.description, kind: PracticeSet.Kind(rawValue: check.kind) ?? .practice,
            questionCount: check.questions.count, termCount: check.terms.count, formats: check.formats, errors: check.errors, warnings: check.warnings,
            issues: check.issues)
    }
}

/// The import check: a port of the server's `checkImport` (`packages/questions/src/import.ts`), for
/// a bank on the phone, which checks a file with no network. The server is the one judge of the
/// format: the port reports what it reports, in the same order, words, codes and places, and
/// `ImportParityTests` holds it to the cases the server generates.
public enum ImportChecker {
    /// The check as `POST /api/imports/check` answers it.
    public static func report(for source: String) -> ImportReport { ImportReport(check(source)) }

    static let typeLabels: [(type: String, label: String)] = [
        ("single", "Single answer"), ("priority", "Priority / first action"), ("sata", "Select all that apply"), ("highlight", "Highlight"),
        ("order", "Ordered response"), ("match", "Matching"), ("matrix", "Matrix"), ("matrixmulti", "Matrix, check all that fit"),
        ("cloze", "Drop-down cloze"),
    ]

    /// Fields the question keeps in a column of its own. The rest of what a question carries stays in its body.
    private static let hoisted: Set<String> = ["id", "type", "topic", "cj", "need", "diff", "wk", "stem", "ask", "rationale", "takeaway", "terms", "src"]
    private static let warnedFields = ["cj", "need", "diff", "src"]
    private static let noQuestions = "No \"questions\" list was found."

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
            return .failed(ImportFinding(.notJSON, "This is not valid JSON: \(error.message). Ask your AI chat to resend only the JSON block."))
        }
        let file: JSObject
        // A bare list is the questions themselves, so a question's place in the file starts at its index.
        var listAt = ["questions"]
        switch parsed {
        case .array(let items):
            var wrapper = JSObject()
            wrapper.set("title", .string("Imported questions"))
            wrapper.set("questions", .array(items))
            file = wrapper
            listAt = []
        case .object(let object): file = object
        default: return .failed(ImportFinding(.noQuestions, noQuestions))
        }
        guard let nodes = file["questions"]?.list, !nodes.isEmpty else { return .failed(ImportFinding(.noQuestions, noQuestions, at: listAt)) }
        var run = Run(file: file, listAt: listAt, terms: file["terms"]?.record ?? JSObject())
        run.readKind()
        run.findUsedFields(nodes)
        for (index, node) in nodes.enumerated() { run.read(node, index) }
        return run.finish()
    }

    /// The state of one check: what the file says, and what has been found so far.
    private struct Run {
        let file: JSObject
        /// The steps down to the list of questions.
        let listAt: [String]
        let terms: JSObject
        var kind: String?
        var used: Set<String> = []
        var issues: [ImportReport.Issue] = []
        var questions: [CheckedQuestion] = []

        init(file: JSObject, listAt: [String], terms: JSObject) {
            self.file = file
            self.listAt = listAt
            self.terms = terms
        }

        // MARK: The file

        mutating func readKind() {
            switch file["kind"] {
            case nil, .null?: kind = "practice"
            case .string(let name)? where name == "practice" || name == "exam": kind = name
            case let other?:
                let message = "The set's \"kind\" must be \"practice\" or \"exam\" (found \(JS.stringify(other)))"
                issues.append(ImportFinding(.badKind, message, at: ["kind"]).issue())
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

        /// Checks one question. Each finding is placed below the question, and its sentence follows the question's tag.
        mutating func read(_ node: JSNode, _ index: Int) {
            var found: [ImportFinding] = []
            if let checked = examine(node, index, &found) { questions.append(checked) }
            let question = Self.question(node, index)
            let tag = "Question \(index + 1)\(question.id.map { " (\($0))" } ?? ""): "
            issues += found.map { $0.below(listAt + [String(index)], prefix: tag).issue(about: question) }
        }

        /// What is wrong with a question goes to `found`. The result is the question as an import stores it, or nil when there is nothing to store.
        private func examine(_ node: JSNode, _ index: Int, _ found: inout [ImportFinding]) -> CheckedQuestion? {
            let record: JSObject
            switch node {
            case .object(let object): record = object
            case .array: record = JSObject()
            default:
                found.append(ImportFinding(.notAnObject, "not an object"))
                return nil
            }
            guard let type = record["type"]?.text, typeLabels.contains(where: { $0.type == type }) else {
                // A list gets here too, and has no "type" to point to.
                let place = node.record == nil ? [] : ["type"]
                found.append(ImportFinding(.unknownType, "unknown type \"\(JS.string(of: record["type"]))\"", at: place))
                return nil
            }
            let ask = record["ask"]?.filledText
            if ask == nil { found.append(ImportFinding(.missingField, "missing ask", at: ["ask"])) }
            // A missing or blank section is empty text. One that is present but not text is a mistake in the file, so it is refused rather than dropped.
            for field in ["stem", "rationale", "takeaway"] {
                if let value = record[field], value != .null, !value.isString { found.append(ImportFinding(.notText, "\(field) must be text", at: [field])) }
            }
            let stopped = checkFormat(record, type: type, ask: ask, &found)
            if let problem = ImportMedia.tableFinding(record["table"]) { found.append(problem.below(["table"])) }
            found += ImportMedia.imageFindings(record["images"]).map { $0.below(["images"]) }
            let twinOf = Self.twinOfValue(record["twinOf"])
            if let raw = record["twinOf"], raw != .null {
                if twinOf == nil {
                    found.append(ImportFinding(.twinOfNotAnID, "\"twinOf\" must be the id of its practice question", at: ["twinOf"]))
                } else if kind != "exam" {
                    found.append(ImportFinding(.twinOfIgnored, "\"twinOf\" is only read in an exam set (\"kind\": \"exam\")", at: ["twinOf"]))
                }
            }
            if stopped { return nil }
            let termKeys = readTerms(record, &found)
            for field in warnedFields where used.contains(field) && !carries(record, field) {
                found.append(ImportFinding(.missingUsedField, "missing \(field)", at: [field]))
            }
            // A question with no ask is listed above as an error. It is not stored.
            guard let ask else { return nil }
            var body = JSObject()
            for (key, value) in record.entries where !hoisted.contains(key) { body.set(key, value) }
            return CheckedQuestion(
                position: index + 1, publicId: Self.publicID(record["id"], index), type: type, topic: Self.trimmed(record["topic"]) ?? "",
                cj: Self.trimmed(record["cj"]), need: Self.trimmed(record["need"]), difficulty: Self.finiteInteger(record["diff"]),
                week: Self.trimmed(record["wk"]), stem: Self.text(record["stem"]), ask: JS.trim(ask), rationale: Self.text(record["rationale"]),
                takeaway: Self.text(record["takeaway"]), termKeys: termKeys, source: Self.trimmed(record["src"]),
                twinOf: kind == "exam" ? twinOf : nil, body: body)
        }

        /// The format's own rules. True when the question has no usable body, so nothing more is said of it.
        private func checkFormat(_ record: JSObject, type: String, ask: String?, _ found: inout [ImportFinding]) -> Bool {
            switch type {
            case "single", "priority", "sata": return checkChoices(record, type: type, &found)
            case "order":
                guard let place = Self.listProblem(record["items"], min: 3, fields: ["t"]) else { return false }
                found.append(ImportFinding(.itemsShape, "needs 3+ items with text \"t\", listed in the correct order", at: ["items"] + place))
                return true
            case "match":
                guard let place = Self.listProblem(record["pairs"], min: 2, fields: ["l", "r"]) else { return false }
                found.append(ImportFinding(.pairsShape, "needs 2+ pairs with \"l\" and \"r\"", at: ["pairs"] + place))
                return true
            case "matrix": return checkMatrix(record, &found)
            case "matrixmulti":
                let problem = Self.matrixMultiFinding(record["columns"], record["rows"])
                if let problem { found.append(problem) }
                // A warning, not a refusal: the ask should say a row can fit more than one column.
                if let ask, !JS.includes(Array(ask.lowercased().unicodeScalars), "more than one") {
                    found.append(ImportFinding(.matrixMultiAsk, "the ask does not say a row can fit more than one column", at: ["ask"]))
                }
                return problem != nil
            case "highlight":
                let segments = record["segments"]?.list ?? []
                let marked = segments.map { $0.record?["ok"] == .bool(true) }
                if segments.count >= 3, marked.contains(true), !marked.allSatisfy({ $0 }) { return false }
                found.append(ImportFinding(.segmentsShape, "needs 3+ segments, some with \"ok\": true and some without", at: ["segments"]))
                return true
            default: return checkCloze(record, &found)
            }
        }

        private func checkChoices(_ record: JSObject, type: String, _ found: inout [ImportFinding]) -> Bool {
            guard let options = record["options"]?.list, options.count >= 2 else {
                found.append(ImportFinding(.optionsMin, "needs at least 2 options", at: ["options"]))
                return true
            }
            let right = options.filter { $0.record?["ok"] == .bool(true) }.count
            if let place = Self.firstWithout(options, ["t"]) {
                found.append(ImportFinding(.optionNeedsText, "every option needs text \"t\"", at: ["options"] + place))
            }
            if type != "sata", right != 1 {
                found.append(ImportFinding(.exactlyOneCorrect, "needs exactly one option with \"ok\": true (found \(right))", at: ["options"]))
            }
            // Every option may be correct. Only a select-all with none correct is refused.
            if type == "sata", right < 1 {
                found.append(ImportFinding(.sataNeedsCorrect, "select-all needs at least one correct option", at: ["options"]))
            }
            return false
        }

        private func checkMatrix(_ record: JSObject, _ found: inout [ImportFinding]) -> Bool {
            let columns = record["columns"]
            let problem = Self.matrixFinding(columns, record["rows"])
            if let problem { found.append(problem) }
            // A warning, not a refusal: files that already carry such a column keep importing.
            if let place = Self.catchAllColumn(columns) {
                found.append(ImportFinding(.matrixCatchAll, "If a row can fit more than one column, use matrixmulti", at: ["columns", String(place)]))
            }
            return problem != nil
        }

        private func checkCloze(_ record: JSObject, _ found: inout [ImportFinding]) -> Bool {
            let cloze = record["cloze"]?.record
            let holes = cloze?["text"]?.filledText.map(Self.placeholders) ?? -1
            guard let cloze, let blanks = cloze["blanks"]?.list, holes == blanks.count else {
                let place = cloze == nil ? ["cloze"] : ["cloze", cloze?["blanks"]?.list == nil ? "blanks" : "text"]
                found.append(ImportFinding(.clozeHoles, "cloze text needs one {0}, {1}... placeholder per blank", at: place))
                return true
            }
            for (index, blank) in blanks.enumerated() {
                var field: [String] = []
                if let blank = blank.record {
                    if let options = blank["opts"]?.list, options.count >= 2 {
                        // The same comparison the runner uses, including its coercions.
                        let answer = JS.number(of: blank["ans"])
                        if answer >= 0 && answer < Double(options.count) { continue }
                        field = ["ans"]
                    } else {
                        field = ["opts"]
                    }
                }
                found.append(ImportFinding(.clozeBlank, "every blank needs \"opts\" and an \"ans\" index", at: ["cloze", "blanks", String(index)] + field))
                return true
            }
            return false
        }

        private func readTerms(_ record: JSObject, _ found: inout [ImportFinding]) -> [String] {
            var keys: [String] = []
            for (index, term) in (record["terms"]?.list ?? []).enumerated() {
                let name = JS.string(of: term)
                if terms[name]?.list == nil {
                    found.append(ImportFinding(.termUndefined, "term \"\(name)\" has no definition and will be skipped", at: ["terms", String(index)]))
                } else if let key = term.text {
                    keys.append(key)
                }
            }
            return keys
        }

        // MARK: The result

        func finish() -> ImportCheck {
            var checked = ImportCheck(title: Self.trimmed(file["title"]) ?? "Imported questions", issues: issues)
            checked.description = Self.trimmed(file["desc"]) ?? ""
            checked.kind = kind ?? "practice"
            guard checked.ok else { return checked }
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

        /// A question by its place in the file's list and the id it gives, a text or a number.
        static func question(_ node: JSNode, _ index: Int) -> ImportReport.Issue.Question {
            switch node.record?["id"] {
            case .string?, .number?: ImportReport.Issue.Question(index: index, id: JS.string(of: node.record?["id"]))
            default: ImportReport.Issue.Question(index: index, id: nil)
            }
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

        // MARK: Lists

        /// The place of the first entry that is not an object with each of `fields` as text: the entry when it is not an object, or else
        /// its first field that is not text. Nil when every entry has them all.
        static func firstWithout(_ list: [JSNode], _ fields: [String]) -> [String]? {
            for (index, entry) in list.enumerated() {
                guard let record = entry.record else { return [String(index)] }
                if let field = fields.first(where: { record[$0]?.filledText == nil }) { return [String(index), field] }
            }
            return nil
        }

        /// Where a list of at least `min` entries, each with every one of `fields` as text, falls short, below the list: empty for the list
        /// itself. Nil when it is one.
        static func listProblem(_ value: JSNode?, min: Int, fields: [String]) -> [String]? {
            guard let list = value?.list, list.count >= min else { return [] }
            return firstWithout(list, fields)
        }

        // MARK: Matrix columns

        /// Where the first column that stands for several of the others is, such as "Both" or "All of the above".
        static func catchAllColumn(_ columns: JSNode?) -> Int? {
            let names: Set<String> = ["both", "either", "either class", "all", "all of these", "all of the above"]
            return columns?.list?.firstIndex { $0.text.map { names.contains(JS.trim($0).lowercased()) } ?? false }
        }

        /// Where the first column with the name of one before it is. Names are compared as written, the way a row's "ans" is matched to
        /// one; a column that is not text has no name.
        static func duplicatedColumn(_ columns: [JSNode]) -> Int? {
            var seen: Set<[UInt8]> = []
            return columns.firstIndex { column in column.filledText.map { !seen.insert(Array($0.utf8)).inserted } ?? false }
        }

        private static func duplicateFinding(_ place: Int) -> ImportFinding {
            ImportFinding(.duplicateColumn, "every column name must be different", at: ["columns", String(place)])
        }

        /// What a matrix question must have before it is stored. Nil when it passes.
        static func matrixFinding(_ columns: JSNode?, _ rows: JSNode?) -> ImportFinding? {
            let shape = "needs columns and rows"
            guard let names = columns?.list, names.count >= 2 else { return ImportFinding(.matrixShape, shape, at: ["columns"]) }
            guard let rowList = rows?.list, !rowList.isEmpty else { return ImportFinding(.matrixShape, shape, at: ["rows"]) }
            if let place = duplicatedColumn(names) { return duplicateFinding(place) }
            for (index, row) in rowList.enumerated() {
                let record = row.record
                if record?["t"]?.filledText != nil, names.contains(where: { JS.strictlyEqual($0, record?["ans"]) }) { continue }
                let field = record.map { [$0["t"]?.filledText == nil ? "t" : "ans"] } ?? []
                return ImportFinding(.matrixRow, "every row needs text \"t\" and an \"ans\" that matches a column name", at: ["rows", String(index)] + field)
            }
            return nil
        }

        /// What a matrixmulti question must have before it is stored. Nil when it passes.
        static func matrixMultiFinding(_ columns: JSNode?, _ rows: JSNode?) -> ImportFinding? {
            func shape(_ place: [String]) -> ImportFinding { ImportFinding(.matrixMultiShape, "needs 2 or more columns and at least 1 row", at: place) }
            guard let list = columns?.list, list.count >= 2 else { return shape(["columns"]) }
            if let untitled = list.firstIndex(where: { $0.filledText == nil }) { return shape(["columns", String(untitled)]) }
            guard let rowList = rows?.list, !rowList.isEmpty else { return shape(["rows"]) }
            if let place = duplicatedColumn(list) { return duplicateFinding(place) }
            let names = list.compactMap(\.filledText)
            var rightBoxes = 0
            for (index, row) in rowList.enumerated() {
                let place = ["rows", String(index)]
                let rowShape = "every row needs text \"t\" and an \"ans\" list of column names"
                guard let record = row.record else { return ImportFinding(.matrixMultiRow, rowShape, at: place) }
                guard record["t"]?.filledText != nil else { return ImportFinding(.matrixMultiRow, rowShape, at: place + ["t"]) }
                guard let answers = record["ans"]?.list else { return ImportFinding(.matrixMultiRow, rowShape, at: place + ["ans"]) }
                if answers.isEmpty { return ImportFinding(.matrixMultiNoRight, "every row needs at least one right column", at: place + ["ans"]) }
                var seen: Set<[UInt8]> = []
                for (answer, entry) in answers.enumerated() {
                    let at = place + ["ans", String(answer)]
                    guard let name = entry.text, names.contains(where: { JS.same($0, name) }) else {
                        return ImportFinding(.matrixMultiAnsName, "every \"ans\" entry must name a column", at: at)
                    }
                    if !seen.insert(Array(name.utf8)).inserted { return ImportFinding(.matrixMultiAnsTwice, "an \"ans\" entry must appear once in that row", at: at) }
                }
                rightBoxes += names.filter { seen.contains(Array($0.utf8)) }.count
            }
            return rightBoxes == names.count * rowList.count ? ImportFinding(.matrixMultiAllRight, "not every box can be right", at: ["rows"]) : nil
        }
    }
}
