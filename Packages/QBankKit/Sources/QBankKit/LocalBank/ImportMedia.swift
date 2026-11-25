import Foundation

/// Tables and images a question shows beside its stem and rationale: what makes one unreadable (the
/// import check refuses a file that holds one) and how a readable one is drawn (the set's questions
/// carry it). A port of the server's media rules, with the same words.
enum ImportMedia {
    static let imageMaxBytes = 300 * 1024
    static let imagesPerQuestion = 4

    private static let tableShape = "table needs \"rows\": a list of rows, each a list of cell texts"
    private static let imageKinds = ["image/png": "PNG", "image/jpeg": "JPEG", "image/webp": "WebP", "image/svg+xml": "SVG"]

    // MARK: Tables

    /// Why a question's table cannot be drawn, at its place below the table, or nil when it can (or there is none).
    static func tableFinding(_ value: JSNode?) -> ImportFinding? {
        guard let value, value != .null else { return nil }
        if case .failure(let problem) = parseTable(value) { return problem }
        return nil
    }

    /// The table a question body carries, as the set answers it; null when it has none or it cannot be drawn.
    static func readTable(_ value: JSNode?) -> JSONValue {
        guard case .success(let table) = parseTable(value) else { return .null }
        return .object(["caption": .optional(table.caption), "head": .array(table.head.map(JSONValue.string)), "rows": .array(table.rows.map { .array($0.map(JSONValue.string)) })])
    }

    private struct Table {
        let caption: String?
        let head: [String]
        let rows: [[String]]
    }

    private static func parseTable(_ value: JSNode?) -> Result<Table, ImportFinding> {
        guard let object = value?.record else { return .failure(ImportFinding(.tableShape, tableShape)) }
        let caption = object["caption"] ?? .null
        let head = object["head"] ?? .null
        if caption != .null, !caption.isString { return .failure(ImportFinding(.tableCaption, "table \"caption\" must be text", at: ["caption"])) }
        var headCells: [String] = []
        if head != .null {
            switch cells(of: head) {
            case .success(let cells): headCells = cells
            case .failure(let bad): return .failure(ImportFinding(.tableHead, "table \"head\" must be a list of cell texts", at: ["head"] + bad.at))
            }
        }
        let noRows = ImportFinding(.tableShape, tableShape, at: ["rows"])
        guard let rows = object["rows"]?.list, !rows.isEmpty else { return .failure(noRows) }
        var bodyRows: [[String]] = []
        for (index, row) in rows.enumerated() {
            switch cells(of: row) {
            case .success(let cells): bodyRows.append(cells)
            case .failure(let bad): return .failure(ImportFinding(.tableShape, tableShape, at: ["rows", String(index)] + bad.at))
            }
        }
        let width = max(headCells.count, bodyRows.map(\.count).max() ?? 0)
        if width == 0 { return .failure(noRows) }
        func pad(_ cells: [String]) -> [String] { cells.count < width ? cells + Array(repeating: "", count: width - cells.count) : cells }
        let trimmed = caption.text.map(JS.trim) ?? ""
        return .success(Table(caption: trimmed.isEmpty ? nil : trimmed, head: headCells.isEmpty ? [] : pad(headCells), rows: bodyRows.map(pad)))
    }

    /// Where the first cell that cannot be text is, below a row: empty when the row is not a list.
    private struct BadCell: Error {
        let at: [String]
    }

    private static func cells(of value: JSNode) -> Result<[String], BadCell> {
        guard let items = value.list else { return .failure(BadCell(at: [])) }
        var cells: [String] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .null: cells.append("")
            case .string(let text): cells.append(JS.trim(text))
            case .number(let number): cells.append(JS.numberString(number))
            case .bool(let flag): cells.append(flag ? "true" : "false")
            case .array, .object: return .failure(BadCell(at: [String(index)]))
            }
        }
        return .success(cells)
    }

    // MARK: Images

    /// Every reason a question's images cannot be drawn, each at its place below the list. Empty when they all can (or there are none).
    static func imageFindings(_ value: JSNode?) -> [ImportFinding] {
        guard let value, value != .null else { return [] }
        guard let items = value.list else { return [ImportFinding(.imagesNotList, "\"images\" must be a list")] }
        var found: [ImportFinding] = []
        if items.count > imagesPerQuestion {
            found.append(ImportFinding(.imagesOver, "has \(items.count) images; the limit is \(imagesPerQuestion)"))
        }
        for (index, item) in items.enumerated() {
            if case .failure(let problem) = parseImage(item, index + 1) { found.append(problem.below([String(index)])) }
        }
        return found
    }

    /// The images a question body carries that are safe to draw, at most four, as the set answers them.
    static func readImages(_ value: JSNode?) -> [JSONValue] {
        guard let items = value?.list else { return [] }
        var images: [JSONValue] = []
        for (index, item) in items.enumerated() {
            if images.count == imagesPerQuestion { break }
            if case .success(let image) = parseImage(item, index + 1) {
                images.append(.object(["url": .string(image.url), "alt": .string(image.alt), "caption": .optional(image.caption), "at": .string(image.at)]))
            }
        }
        return images
    }

    private struct Image {
        let url: String
        let alt: String
        let caption: String?
        let at: String
    }

    /// The image, or why it cannot be drawn, at its place below the image.
    private static func parseImage(_ value: JSNode, _ number: Int) -> Result<Image, ImportFinding> {
        let name = "image \(number) "
        func refuse(_ rule: FormatRule, _ words: String, at place: [String] = []) -> Result<Image, ImportFinding> {
            .failure(ImportFinding(rule, name + words, at: place))
        }
        guard let object = value.record else { return refuse(.imageNotObject, "is not an object") }
        guard let alt = object["alt"]?.filledText else { return refuse(.imageNeedsAlt, "needs \"alt\": a short description of what it shows", at: ["alt"]) }
        let caption = object["caption"] ?? .null
        if caption != .null, !caption.isString { return refuse(.imageCaption, "\"caption\" must be text", at: ["caption"]) }
        let placed = object["at"] ?? .null
        let at = placed == .null ? "stem" : (placed.text ?? "")
        if at != "stem" && at != "rationale" { return refuse(.imageAt, "\"at\" must be \"stem\" or \"rationale\"", at: ["at"]) }
        let source = object["src"] ?? .null
        let markup = object["svg"] ?? .null
        if (source != .null) == (markup != .null) {
            return refuse(.imageSource, "needs either \"src\" (a base64 data URL) or \"svg\" (SVG markup), not both")
        }
        let url: String
        if markup != .null {
            guard let svg = markup.text else { return refuse(.imageSvgText, "\"svg\" must be text", at: ["svg"]) }
            if let problem = svgProblem(svg, bytes: svg.utf8.count) { return .failure(problem.below(["svg"], prefix: name)) }
            url = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(JS.trim(svg))
        } else {
            guard let src = source.text else { return refuse(.imageSrcText, "\"src\" must be text", at: ["src"]) }
            if let problem = dataURLProblem(JS.trim(src)) { return .failure(problem.below(["src"], prefix: name)) }
            url = JS.trim(src)
        }
        let trimmedCaption = caption.text.map(JS.trim) ?? ""
        return .success(Image(url: url, alt: JS.trim(alt), caption: trimmedCaption.isEmpty ? nil : trimmedCaption, at: at))
    }

    // MARK: Data URLs

    /// `/^data:([^;,]+)((?:;[^;,]*)*),(.*)$/s`: the type, the parameters after it, and the payload.
    private static func splitDataURL(_ src: String) -> (type: String, params: String, payload: String)? {
        guard src.hasPrefix("data:") else { return nil }
        let rest = Array(src.dropFirst(5))
        var at = 0
        while at < rest.count, rest[at] != ";", rest[at] != "," { at += 1 }
        guard at > 0 else { return nil }
        let type = String(rest[0..<at])
        let paramsStart = at
        while at < rest.count, rest[at] == ";" {
            at += 1
            while at < rest.count, rest[at] != ";", rest[at] != "," { at += 1 }
        }
        guard at < rest.count, rest[at] == "," else { return nil }
        return (type, String(rest[paramsStart..<at]), String(rest[(at + 1)...]))
    }

    /// Why `src` is not an image the screens can draw, in words that follow the image's name, or nil when it is.
    private static func dataURLProblem(_ src: String) -> ImportFinding? {
        guard let parts = splitDataURL(src) else { return ImportFinding(.srcNotDataURL, "\"src\" must be a data URL such as data:image/png;base64,...") }
        let type = parts.type.lowercased()
        let params = parts.params.lowercased().split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let payload = parts.payload
        guard let kind = imageKinds[type] else { return ImportFinding(.imageTypeNotAccepted, "must be PNG, JPEG, WebP, or SVG (found \(type))") }
        if !params.contains("base64") {
            return ImportFinding(.srcNotBase64, "\"src\" must be base64 (data:\(type);base64,...). Put SVG markup in \"svg\" instead")
        }
        let letters = Array(payload.utf8)
        if letters.isEmpty || !isBase64(letters) || letters.count % 4 == 1 { return ImportFinding(.srcBadBase64, "\"src\" is not valid base64") }
        let padding = payload.hasSuffix("==") ? 2 : (payload.hasSuffix("=") ? 1 : 0)
        let bytes = letters.count * 3 / 4 - padding
        if bytes > imageMaxBytes { return sizeProblem(bytes) }
        if type == "image/svg+xml" {
            return svgProblem(String(String.UnicodeScalarView(decodeBase64(letters).map { Unicode.Scalar($0) })), bytes: bytes)
        }
        return startsLike(type, decodeBase64(Array(letters.prefix(16)))) ? nil : ImportFinding(.imageNotReal, "is not a real \(kind) file")
    }

    /// `/^[A-Za-z0-9+/]+={0,2}$/`
    private static func isBase64(_ letters: [UInt8]) -> Bool {
        var at = 0
        while at < letters.count, base64Value(letters[at]) != nil { at += 1 }
        guard at > 0 else { return false }
        let padding = letters.count - at
        return padding <= 2 && letters[at...].allSatisfy { $0 == 0x3D }
    }

    private static func base64Value(_ letter: UInt8) -> Int? {
        switch letter {
        case 0x41...0x5A: Int(letter) - 0x41
        case 0x61...0x7A: Int(letter) - 0x61 + 26
        case 0x30...0x39: Int(letter) - 0x30 + 52
        case 0x2B: 62
        case 0x2F: 63
        default: nil
        }
    }

    /// The bytes of a payload already known to be base64.
    private static func decodeBase64(_ letters: [UInt8]) -> [UInt8] {
        let clean = letters.filter { $0 != 0x3D }
        var bytes = [UInt8](repeating: 0, count: clean.count * 3 / 4)
        var bits = 0
        var count = 0
        var at = 0
        for letter in clean {
            bits = ((bits << 6) | (base64Value(letter) ?? 0)) & 0xFFFF
            count += 6
            if count >= 8 {
                count -= 8
                bytes[at] = UInt8((bits >> count) & 0xFF)
                at += 1
            }
        }
        return bytes
    }

    private static func startsLike(_ type: String, _ head: [UInt8]) -> Bool {
        func at(_ index: Int) -> Int { index < head.count ? Int(head[index]) : -1 }
        switch type {
        case "image/png": return at(0) == 0x89 && at(1) == 0x50 && at(2) == 0x4E && at(3) == 0x47
        case "image/jpeg": return at(0) == 0xFF && at(1) == 0xD8 && at(2) == 0xFF
        default: return at(0) == 0x52 && at(1) == 0x49 && at(2) == 0x46 && at(3) == 0x46 && at(8) == 0x57 && at(9) == 0x45 && at(10) == 0x42 && at(11) == 0x50
        }
    }

    private static func sizeProblem(_ bytes: Int) -> ImportFinding {
        ImportFinding(.imageTooBig, "is \(Int((Double(bytes) / 1024).rounded(.up))) KB; the limit is \(imageMaxBytes / 1024) KB")
    }

    // MARK: SVG

    private static func svgProblem(_ svg: String, bytes: Int) -> ImportFinding? {
        if bytes > imageMaxBytes { return sizeProblem(bytes) }
        let text = Array(svg.lowercased().unicodeScalars)
        func has(_ word: String) -> Bool { JS.includes(text, word) }
        if !has("<svg") { return ImportFinding(.svgNoElement, "SVG markup must contain an <svg> element") }
        let words = ["<script", "<foreignobject", "<!entity", "javascript:", "@import"]
        if words.contains(where: has) || hasEventHandler(text) || hasLink(text) || hasURLFunction(text) {
            return ImportFinding(.svgUnsafe, "SVG has a script, an event handler, or a link to another file; remove it")
        }
        return nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { JS.isSpace(scalar) }

    private static func matches(_ text: [Unicode.Scalar], at index: Int, _ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard index >= 0, index + scalars.count <= text.count else { return false }
        return zip(text[index...], scalars).allSatisfy { $0 == $1 }
    }

    /// Whether the scalar at `index` sits inside a tag that started with `<` and has not reached `>`: `<[^>]*` before it.
    private static func insideTag(_ text: [Unicode.Scalar], _ index: Int) -> Bool {
        var at = index - 1
        while at >= 0 {
            if text[at] == ">" { return false }
            if text[at] == "<" { return true }
            at -= 1
        }
        return false
    }

    /// `/<[^>]*\son[a-z]+\s*=/`
    private static func hasEventHandler(_ text: [Unicode.Scalar]) -> Bool {
        for start in text.indices where isSpace(text[start]) && matches(text, at: start + 1, "on") && insideTag(text, start) {
            var at = start + 3
            let letters = at
            while at < text.count, text[at].value >= 0x61, text[at].value <= 0x7A { at += 1 }
            guard at > letters else { continue }
            while at < text.count, isSpace(text[at]) { at += 1 }
            if at < text.count, text[at] == "=" { return true }
        }
        return false
    }

    /// `/<[^>]*\s(?:xlink:)?(?:href|src)\s*=\s*["']?\s*(?!#|data:image\/)[^\s"'>]/`
    private static func hasLink(_ text: [Unicode.Scalar]) -> Bool {
        for start in text.indices where isSpace(text[start]) && insideTag(text, start) {
            var at = start + 1
            if matches(text, at: at, "xlink:") { at += 6 }
            if matches(text, at: at, "href") {
                at += 4
            } else if matches(text, at: at, "src") {
                at += 3
            } else {
                continue
            }
            while at < text.count, isSpace(text[at]) { at += 1 }
            guard at < text.count, text[at] == "=" else { continue }
            if pointsOutside(text, after: at + 1, closers: ">") { return true }
        }
        return false
    }

    /// `/url\(\s*["']?\s*(?!#|data:image\/)[^\s"')]/`
    private static func hasURLFunction(_ text: [Unicode.Scalar]) -> Bool {
        for start in text.indices where matches(text, at: start, "url(") {
            if pointsOutside(text, after: start + 4, closers: ")") { return true }
        }
        return false
    }

    /// After white space and one optional quote and more white space: a character that begins neither `#` nor `data:image/` and is not white space, a quote or `closer`.
    private static func pointsOutside(_ text: [Unicode.Scalar], after index: Int, closers: String) -> Bool {
        var at = index
        while at < text.count, isSpace(text[at]) { at += 1 }
        if at < text.count, text[at] == "\"" || text[at] == "'" { at += 1 }
        while at < text.count, isSpace(text[at]) { at += 1 }
        guard at < text.count else { return false }
        let scalar = text[at]
        if scalar == "#" || matches(text, at: at, "data:image/") { return false }
        return !isSpace(scalar) && scalar != "\"" && scalar != "'" && !closers.unicodeScalars.contains(scalar)
    }

    // MARK: Text

    /// `encodeURIComponent`: every byte except letters, digits and - _ . ! ~ * ' ( ) as %XX.
    private static func encodeURIComponent(_ text: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        var out = ""
        for byte in text.utf8 {
            if safe.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
