import Foundation

/// A JSON value as JavaScript's `JSON.parse` reads it. The import check is a port of the server's,
/// which runs in JavaScript, so the file is read the way JavaScript reads it: an object keeps the key
/// order JavaScript gives it, a number is a double, and a property that is not there is `nil`
/// (JavaScript's `undefined`).
enum JSNode: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSNode])
    case object(JSObject)

    var isString: Bool { if case .string = self { true } else { false } }

    /// The object, or nil for anything else, an array included (the server's `isRecord`).
    var record: JSObject? { if case .object(let object) = self { object } else { nil } }

    var list: [JSNode]? { if case .array(let items) = self { items } else { nil } }

    var text: String? { if case .string(let text) = self { text } else { nil } }

    /// The server's `isStr`: text with something in it besides white space.
    var filledText: String? {
        guard case .string(let text) = self, !JS.trim(text).isEmpty else { return nil }
        return text
    }
}

/// An object whose keys are kept in the order JavaScript lists them, and compared by their exact
/// characters, as JavaScript compares them (Swift would treat two spellings of "é" as one key).
struct JSObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var values: [JSNode] = []
    private var index: [[UInt8]: Int] = [:]

    subscript(key: String) -> JSNode? {
        guard let at = index[Array(key.utf8)] else { return nil }
        return values[at]
    }

    var entries: [(key: String, value: JSNode)] { Array(zip(keys, values)).map { (key: $0, value: $1) } }

    /// Sets a key; a key met twice keeps its first place and takes the last value, as in `JSON.parse`.
    mutating func set(_ key: String, _ value: JSNode) {
        let bytes = Array(key.utf8)
        if let at = index[bytes] {
            values[at] = value
        } else {
            index[bytes] = keys.count
            keys.append(key)
            values.append(value)
        }
    }

    /// JavaScript lists the keys that are array indexes first, in number order, then the rest as they came.
    func inJavaScriptOrder() -> JSObject {
        let numbered = keys.compactMap { key in JS.arrayIndex(key).map { (key: key, number: $0) } }
        if numbered.isEmpty { return self }
        var ordered = JSObject()
        for item in numbered.sorted(by: { $0.number < $1.number }) { ordered.set(item.key, self[item.key] ?? .null) }
        for key in keys where JS.arrayIndex(key) == nil { ordered.set(key, self[key] ?? .null) }
        return ordered
    }
}

/// The few things JavaScript does to a value that the check depends on, written out so the answers match.
enum JS {
    // MARK: Text

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// Whether `haystack` holds `needle`, as `includes` finds it: by characters as written, where Swift's `contains` also equates canonical forms.
    static func includes(_ haystack: [Unicode.Scalar], _ needle: String) -> Bool {
        let wanted = Array(needle.unicodeScalars)
        guard wanted.count <= haystack.count else { return wanted.isEmpty }
        return (0...(haystack.count - wanted.count)).contains { start in zip(haystack[start...], wanted).allSatisfy { $0 == $1 } }
    }

    /// `String.prototype.trim`, which Swift's `.whitespacesAndNewlines` does not match.
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }), let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// Whether two strings have the same characters in the same form, as `===` says (Swift's `==` also equates canonical forms).
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// `Array.prototype.sort()` order on strings: by UTF-16 code unit.
    static func codeUnitOrder(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    /// The number a key stands for when JavaScript counts it an array index (`"0"`, `"12"`, not `"012"`), else nil.
    static func arrayIndex(_ key: String) -> UInt32? {
        guard key.utf8.count <= 10, key == "0" || (key.first != "0" && key.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }), !key.isEmpty else { return nil }
        guard let number = UInt32(key), number < UInt32.max else { return nil }
        return number
    }

    // MARK: Numbers

    /// `String(number)`: the shortest digits that read back, in JavaScript's layout.
    static func numberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let (digits, point) = decimal(abs(value))
        let count = digits.count
        let sign = value < 0 ? "-" : ""
        let body: String
        if count <= point && point <= 21 {
            body = digits + String(repeating: "0", count: point - count)
        } else if point > 0 && point <= 21 {
            body = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        } else if point > -6 && point <= 0 {
            body = "0." + String(repeating: "0", count: -point) + digits
        } else {
            let exponent = point - 1
            let tail = "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
            body = (count == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst())) + tail
        }
        return sign + body
    }

    /// The digits of a positive number and where its point goes: value = 0.digits x 10^point.
    private static func decimal(_ magnitude: Double) -> (digits: String, point: Int) {
        let text = "\(magnitude)"
        var mantissa = Substring(text)
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<marker]
            exponent = Int(text[text.index(after: marker)...]) ?? 0
        }
        var whole = mantissa
        var fraction: Substring = ""
        if let dot = mantissa.firstIndex(of: ".") {
            whole = mantissa[..<dot]
            fraction = mantissa[mantissa.index(after: dot)...]
        }
        var digits = String(whole) + String(fraction)
        var point = whole.count + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        return (digits, point)
    }

    /// `Number(text)` for text: white space around it is ignored, empty is 0, and what is not a number is NaN.
    static func number(of text: String) -> Double {
        let trimmed = trim(text)
        if trimmed.isEmpty { return 0 }
        switch trimmed {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        for (prefix, radix) in [("0x", 16), ("0X", 16), ("0b", 2), ("0B", 2), ("0o", 8), ("0O", 8)] where trimmed.hasPrefix(prefix) {
            let digits = trimmed.dropFirst(2)
            guard !digits.isEmpty else { return .nan }
            var total = 0.0
            for character in digits {
                guard let digit = character.hexDigitValue, digit < radix else { return .nan }
                total = total * Double(radix) + Double(digit)
            }
            return total
        }
        guard trimmed.wholeMatch(of: /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/) != nil else { return .nan }
        return Double(trimmed) ?? .nan
    }

    // MARK: Values

    /// `String(value)`. A missing property is "undefined"; a list is its items joined by commas; an object is "[object Object]".
    static func string(of node: JSNode?) -> String {
        switch node {
        case nil: "undefined"
        case .null?: "null"
        case .bool(let flag)?: flag ? "true" : "false"
        case .number(let number)?: numberString(number)
        case .string(let text)?: text
        case .array(let items)?: items.map { item -> String in if case .null = item { "" } else { string(of: item) } }.joined(separator: ",")
        case .object?: "[object Object]"
        }
    }

    /// `Number(value)`, which is what a comparison with a number turns each side into.
    static func number(of node: JSNode?) -> Double {
        switch node {
        case nil: .nan
        case .null?: 0
        case .bool(let flag)?: flag ? 1 : 0
        case .number(let number)?: number
        case .string(let text)?: number(of: text)
        case .array?: number(of: string(of: node))
        case .object?: .nan
        }
    }

    /// `a === b` for the values a file can hold: a list or an object is never the same as another.
    static func strictlyEqual(_ a: JSNode?, _ b: JSNode?) -> Bool {
        switch (a, b) {
        case (.null?, .null?): true
        case (.bool(let x)?, .bool(let y)?): x == y
        case (.number(let x)?, .number(let y)?): x == y
        case (.string(let x)?, .string(let y)?): same(x, y)
        default: false
        }
    }

    /// `JSON.stringify(value)` with no spacing.
    static func stringify(_ node: JSNode) -> String {
        switch node {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number.isFinite ? numberString(number) : "null"
        case .string(let text): quote(text)
        case .array(let items): "[" + items.map(stringify).joined(separator: ",") + "]"
        case .object(let object): "{" + object.entries.map { quote($0.key) + ":" + stringify($0.value) }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0..<0x20: out += "\\u" + String(format: "%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// `JSON.parse` failed. The message is the one V8 (Node 24, which runs the server) gives.
struct JSParseFailure: Error {
    let message: String
}

/// `JSON.parse`, with the messages of V8's own parser: which one it gives, and the position, line,
/// column and few characters of context it names. The server shows this message to the person in
/// the check's first error, so the phone words it the same.
struct JSParser {
    private enum Token {
        case string, number, trueWord, falseWord, nullWord, openBrace, openBracket, closeBrace, closeBracket, colon, comma, whitespace, illegal, end
    }

    /// Past this many levels of lists and objects the file is refused, so a hostile paste cannot exhaust the stack.
    static let maxDepth = 800

    private let units: [UInt16]
    private var position = 0

    private init(_ text: String) { units = Array(text.utf16) }

    static func parse(_ text: String) throws(JSParseFailure) -> JSNode {
        var parser = JSParser(text)
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.position < parser.units.count { throw parser.failure("Unexpected non-whitespace character after", joining: " JSON at position") }
        return value
    }

    // MARK: Values

    private mutating func value(depth: Int) throws(JSParseFailure) -> JSNode {
        skipWhitespace()
        if depth > Self.maxDepth { throw JSParseFailure(message: "The file is nested more than \(Self.maxDepth) levels deep") }
        switch peek {
        case .string:
            position += 1
            return .string(try string())
        case .number: return .number(try number())
        case .openBrace:
            position += 1
            return try object(depth: depth)
        case .openBracket:
            position += 1
            return try array(depth: depth)
        case .trueWord:
            try word("true")
            return .bool(true)
        case .falseWord:
            try word("false")
            return .bool(false)
        case .nullWord:
            try word("null")
            return .null
        default: throw unexpected()
        }
    }

    private mutating func object(depth: Int) throws(JSParseFailure) -> JSNode {
        var object = JSObject()
        skipWhitespace()
        if peek == .closeBrace {
            position += 1
            return .object(object)
        }
        var first = true
        while true {
            skipWhitespace()
            guard peek == .string else {
                throw failure(first ? "Expected property name or '}'" : "Expected double-quoted property name")
            }
            position += 1
            let key = try string()
            skipWhitespace()
            guard peek == .colon else { throw failure("Expected ':' after property name") }
            position += 1
            object.set(key, try value(depth: depth + 1))
            skipWhitespace()
            if peek == .comma {
                position += 1
                first = false
            } else if peek == .closeBrace {
                position += 1
                return .object(object.inJavaScriptOrder())
            } else {
                throw failure("Expected ',' or '}' after property value")
            }
        }
    }

    private mutating func array(depth: Int) throws(JSParseFailure) -> JSNode {
        var items: [JSNode] = []
        skipWhitespace()
        if peek == .closeBracket {
            position += 1
            return .array(items)
        }
        while true {
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            if peek == .comma {
                position += 1
            } else if peek == .closeBracket {
                position += 1
                return .array(items)
            } else {
                throw failure("Expected ',' or ']' after array element")
            }
        }
    }

    private mutating func word(_ word: String) throws(JSParseFailure) {
        let letters = Array(word.utf16)
        position += 1
        for letter in letters.dropFirst() {
            guard position < units.count else { throw unexpected() }
            guard units[position] == letter else { throw unexpected() }
            position += 1
        }
    }

    private mutating func number() throws(JSParseFailure) -> Double {
        let start = position
        if units[position] == 0x2D { position += 1 }
        if position < units.count, units[position] == 0x30 {
            position += 1
            if position < units.count, isDigit(units[position]) { throw failure("Unexpected number") }
        } else {
            let first = position
            skipDigits()
            if position == first { throw failure("No number after minus sign") }
        }
        if position < units.count, units[position] == 0x2E {
            position += 1
            guard position < units.count, isDigit(units[position]) else { throw failure("Unterminated fractional number") }
            skipDigits()
        }
        if position < units.count, units[position] == 0x65 || units[position] == 0x45 {
            position += 1
            if position < units.count, units[position] == 0x2B || units[position] == 0x2D { position += 1 }
            guard position < units.count, isDigit(units[position]) else { throw failure("Exponent part is missing a number") }
            skipDigits()
        }
        let text = String(decoding: units[start..<position], as: UTF16.self)
        return Double(text) ?? (text.hasPrefix("-") ? -.infinity : .infinity)
    }

    private mutating func string() throws(JSParseFailure) -> String {
        var out: [UInt16] = []
        while true {
            guard position < units.count else { throw failure("Unterminated string") }
            let unit = units[position]
            if unit == 0x22 {
                position += 1
                return String(decoding: out, as: UTF16.self)
            }
            if unit == 0x5C {
                position += 1
                guard position < units.count else { throw unexpected() }
                try escape(into: &out)
                position += 1
                continue
            }
            if unit < 0x20 { throw failure("Bad control character in string literal") }
            out.append(unit)
            position += 1
        }
    }

    /// One escape sequence, with `position` on the letter after the backslash. Leaves it on the last character read.
    private mutating func escape(into out: inout [UInt16]) throws(JSParseFailure) {
        let letter = units[position]
        // A character past Latin-1 is no escape and no known token: V8 names it as an unexpected one.
        if letter > 0xFF { throw unexpected() }
        switch letter {
        case 0x22, 0x5C, 0x2F: out.append(letter)
        case 0x62: out.append(0x08)
        case 0x66: out.append(0x0C)
        case 0x6E: out.append(0x0A)
        case 0x72: out.append(0x0D)
        case 0x74: out.append(0x09)
        case 0x75:
            var code: UInt16 = 0
            for _ in 0..<4 {
                position += 1
                guard position < units.count, let digit = hexValue(units[position]) else { throw failure("Bad Unicode escape") }
                code = code * 16 + digit
            }
            out.append(code)
        default: throw failure("Bad escaped character")
        }
    }

    // MARK: Reading

    private var peek: Token {
        guard position < units.count else { return .end }
        switch units[position] {
        case 0x22: return .string
        case 0x2D, 0x30...0x39: return .number
        case 0x74: return .trueWord
        case 0x66: return .falseWord
        case 0x6E: return .nullWord
        case 0x7B: return .openBrace
        case 0x5B: return .openBracket
        case 0x7D: return .closeBrace
        case 0x5D: return .closeBracket
        case 0x3A: return .colon
        case 0x2C: return .comma
        case 0x20, 0x09, 0x0A, 0x0D: return .whitespace
        default: return .illegal
        }
    }

    private mutating func skipWhitespace() {
        while peek == .whitespace { position += 1 }
    }

    private mutating func skipDigits() {
        while position < units.count, isDigit(units[position]) { position += 1 }
    }

    private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    private func hexValue(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x30...0x39: unit - 0x30
        case 0x41...0x46: unit - 0x41 + 10
        case 0x61...0x66: unit - 0x61 + 10
        default: nil
        }
    }

    // MARK: Messages

    /// A message that names where it happened: the position, then the line and column counted from 1.
    private func failure(_ what: String, joining place: String = " in JSON at position") -> JSParseFailure {
        var line = 1
        var lineStart = 0
        var at = 0
        while at < position {
            if units[at] == 0x0D, at < position - 1, units[at + 1] == 0x0A { at += 1 }
            if units[at] == 0x0D || units[at] == 0x0A {
                line += 1
                lineStart = at + 1
            }
            at += 1
        }
        let column = 1 + at - lineStart
        return JSParseFailure(message: "\(what)\(place) \(position) (line \(line) column \(column))")
    }

    /// The failure for the character at the position: the end of the text, a number or a string where none goes, or an unexpected character with some of the text around it.
    private func unexpected() -> JSParseFailure {
        switch peek {
        case .end: return JSParseFailure(message: "Unexpected end of JSON input")
        case .number: return failure("Unexpected number")
        case .string: return failure("Unexpected string")
        default: break
        }
        let whole = String(decoding: units, as: UTF16.self)
        if ["[object Object]", "NaN", "Infinity", "undefined"].contains(whole) {
            return JSParseFailure(message: "\"\(whole)\" is not valid JSON")
        }
        let character = String(decoding: [units[position]], as: UTF16.self)
        let reach = 10
        let length = units.count
        func slice(_ from: Int, _ to: Int) -> String { String(decoding: units[from..<to], as: UTF16.self) }
        let context: String
        if length < reach * 2 + 1 {
            context = "\"\(whole)\""
        } else if position < reach {
            context = "\"\(slice(0, position + reach))\"..."
        } else if position < length - reach {
            context = "...\"\(slice(position - reach, position + reach))\"..."
        } else {
            context = "...\"\(slice(position - reach, length))\""
        }
        return JSParseFailure(message: "Unexpected token '\(character)', \(context) is not valid JSON")
    }
}
