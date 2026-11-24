import Foundation

/// One value of a JSON document, with the place it has in the text.
///
/// A bank archive carries a json field "unchanged" (`docs/on-phone-bank.md`, "Rows and fields"), so
/// the reader keeps each value's own text, not a re-encoding of it: key order, number spelling and
/// string escapes come back as they were written. That is why the archive has its own scanner
/// instead of `JSONSerialization`, which reorders keys and turns a number into a double.
struct ArchiveNode: Sendable {
    enum Kind: Sendable {
        case null
        case bool(Bool)
        /// The number's own text, in the form JSON allows.
        case number(String)
        case string(String)
        case array([ArchiveNode])
        case object([(key: String, value: ArchiveNode)])
    }

    let kind: Kind
    /// The bytes of the document this value is made of.
    let range: Range<Int>

    var isNull: Bool { if case .null = kind { true } else { false } }
    var isObject: Bool { if case .object = kind { true } else { false } }
    var isArray: Bool { if case .array = kind { true } else { false } }

    var string: String? { if case .string(let text) = kind { text } else { nil } }
    var bool: Bool? { if case .bool(let value) = kind { value } else { nil } }
    var items: [ArchiveNode]? { if case .array(let items) = kind { items } else { nil } }

    /// A whole number written without a fraction or an exponent, as the format's `int` is.
    var integer: Int64? {
        guard case .number(let text) = kind, !text.contains(where: { ".eE".contains($0) }) else { return nil }
        return Int64(text)
    }

    /// The object's fields by name, or nil when it is not an object or names a field twice.
    var fields: [String: ArchiveNode]? {
        guard case .object(let pairs) = kind else { return nil }
        var fields: [String: ArchiveNode] = [:]
        fields.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            if fields.updateValue(value, forKey: key) != nil { return nil }
        }
        return fields
    }
}

/// A document as scanned: its root value and the bytes the values' ranges point into.
struct ArchiveDocument: Sendable {
    let root: ArchiveNode
    let bytes: [UInt8]

    /// A value's text exactly as the document wrote it.
    func text(of node: ArchiveNode) -> String {
        String(decoding: bytes[node.range], as: UTF8.self)
    }
}

/// Reads strict JSON (RFC 8259) and nothing else: no comments, no trailing commas, no second value
/// after the first. A cut-off or hand-edited file fails here, before any rule of the format runs.
struct ArchiveScanner {
    private static let maxDepth = 128

    private let bytes: [UInt8]
    private var position = 0

    static func scan(_ data: Data) throws(BankArchiveError) -> ArchiveDocument {
        let bytes = [UInt8](data)
        guard String(validating: bytes, as: UTF8.self) != nil else { throw .unreadable("the file is not UTF-8 text") }
        var scanner = ArchiveScanner(bytes: bytes)
        scanner.skipSpace()
        let root = try scanner.value(depth: 0)
        scanner.skipSpace()
        guard scanner.position == bytes.count else { throw .unreadable("there is more after the end of the document") }
        return ArchiveDocument(root: root, bytes: bytes)
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func skipSpace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { position += 1 }
    }

    private func fail(_ reason: String) -> BankArchiveError { .unreadable("\(reason) at byte \(position)") }

    private mutating func value(depth: Int) throws(BankArchiveError) -> ArchiveNode {
        guard depth <= Self.maxDepth else { throw fail("the document nests too deeply") }
        let start = position
        guard let byte = peek else { throw fail("the document ends early") }
        let kind: ArchiveNode.Kind
        switch byte {
        case UInt8(ascii: "{"): kind = try object(depth: depth)
        case UInt8(ascii: "["): kind = try array(depth: depth)
        case UInt8(ascii: "\""): kind = .string(try string())
        case UInt8(ascii: "t"): try literal("true"); kind = .bool(true)
        case UInt8(ascii: "f"): try literal("false"); kind = .bool(false)
        case UInt8(ascii: "n"): try literal("null"); kind = .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): kind = .number(try number())
        default: throw fail("unexpected character")
        }
        return ArchiveNode(kind: kind, range: start..<position)
    }

    private mutating func literal(_ word: String) throws(BankArchiveError) {
        let expected = Array(word.utf8)
        guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else { throw fail("unexpected character") }
        position += expected.count
    }

    private mutating func object(depth: Int) throws(BankArchiveError) -> ArchiveNode.Kind {
        position += 1
        var pairs: [(key: String, value: ArchiveNode)] = []
        skipSpace()
        if peek == UInt8(ascii: "}") {
            position += 1
            return .object(pairs)
        }
        while true {
            skipSpace()
            guard peek == UInt8(ascii: "\"") else { throw fail("a field name was expected") }
            let key = try string()
            skipSpace()
            guard peek == UInt8(ascii: ":") else { throw fail("a colon was expected") }
            position += 1
            skipSpace()
            pairs.append((key, try value(depth: depth + 1)))
            skipSpace()
            switch peek {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"):
                position += 1
                return .object(pairs)
            default: throw fail("a comma or a closing brace was expected")
            }
        }
    }

    private mutating func array(depth: Int) throws(BankArchiveError) -> ArchiveNode.Kind {
        position += 1
        var items: [ArchiveNode] = []
        skipSpace()
        if peek == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try value(depth: depth + 1))
            skipSpace()
            switch peek {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"):
                position += 1
                return .array(items)
            default: throw fail("a comma or a closing bracket was expected")
            }
        }
    }

    /// `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`
    private mutating func number() throws(BankArchiveError) -> String {
        let start = position
        func digits(_ scanner: inout ArchiveScanner) -> Int {
            let begin = scanner.position
            while let byte = scanner.peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { scanner.position += 1 }
            return scanner.position - begin
        }
        if peek == UInt8(ascii: "-") { position += 1 }
        if peek == UInt8(ascii: "0") {
            position += 1
        } else if digits(&self) == 0 {
            throw fail("a digit was expected")
        }
        if peek == UInt8(ascii: ".") {
            position += 1
            if digits(&self) == 0 { throw fail("a digit was expected after the point") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            position += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { position += 1 }
            if digits(&self) == 0 { throw fail("a digit was expected in the exponent") }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func string() throws(BankArchiveError) -> String {
        position += 1
        var out: [UInt8] = []
        while true {
            guard let byte = peek else { throw fail("a string is not closed") }
            position += 1
            switch byte {
            case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
            case 0x00..<0x20: throw fail("a control character is in a string")
            case UInt8(ascii: "\\"): try escape(into: &out)
            default: out.append(byte)
            }
        }
    }

    private mutating func escape(into out: inout [UInt8]) throws(BankArchiveError) {
        guard let byte = peek else { throw fail("a string is not closed") }
        position += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(byte)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
            var unit = try hex4()
            if (0xD800...0xDBFF).contains(unit) {
                // A high surrogate must be followed by a low one.
                guard peek == UInt8(ascii: "\\"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "u") else { throw fail("a surrogate is alone") }
                position += 2
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw fail("a surrogate is alone") }
                unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(unit) {
                throw fail("a surrogate is alone")
            }
            guard let scalar = Unicode.Scalar(unit) else { throw fail("a character is not valid") }
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        default: throw fail("an escape is not valid")
        }
    }

    private mutating func hex4() throws(BankArchiveError) -> UInt32 {
        guard position + 4 <= bytes.count else { throw fail("a string is not closed") }
        var value: UInt32 = 0
        for byte in bytes[position..<position + 4] {
            guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { throw fail("a hex digit was expected") }
            value = value * 16 + UInt32(digit)
        }
        position += 4
        return value
    }
}
