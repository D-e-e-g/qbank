import Foundation

/// The two hashes an import stores with a set, written the way the server writes them, so a set that
/// moves between the phone and the server keeps its identity: `fileHash` is the SHA-256 of the
/// file's text, and `contentHash` is the SHA-256 of a question's content with its keys in order.
enum ImportHash {
    static func fileHash(_ source: String) -> String { sha256(ImportChecker.unwrap(source)) }

    /// A question's identity. Its week and position are not part of it.
    static func contentHash(_ question: CheckedQuestion) -> String {
        let fields: [(key: String, value: String)] = [
            ("type", JS.quote(question.type)), ("topic", JS.quote(question.topic)), ("cj", optional(question.cj)), ("need", optional(question.need)),
            ("difficulty", question.difficulty.map { JS.stringify(.number($0)) } ?? "null"), ("stem", JS.quote(question.stem)),
            ("ask", JS.quote(question.ask)), ("rationale", JS.quote(question.rationale)), ("takeaway", JS.quote(question.takeaway)),
            ("termKeys", "[" + question.termKeys.map(JS.quote).joined(separator: ",") + "]"), ("source", optional(question.source)),
            ("body", stable(.object(question.body))),
        ]
        return sha256(object(fields))
    }

    private static func optional(_ text: String?) -> String { text.map(JS.quote) ?? "null" }

    private static func object(_ fields: [(key: String, value: String)]) -> String {
        "{" + fields.sorted { JS.codeUnitOrder($0.key, $1.key) }.map { JS.quote($0.key) + ":" + $0.value }.joined(separator: ",") + "}"
    }

    /// The server's `stable`: JSON with the keys of every object in order.
    static func stable(_ node: JSNode) -> String {
        switch node {
        case .array(let items): "[" + items.map(stable).joined(separator: ",") + "]"
        case .object(let record): object(record.entries.map { (key: $0.key, value: stable($0.value)) })
        default: JS.stringify(node)
        }
    }

    static func sha256(_ text: String) -> String { SHA256.hex(Array(text.utf8)) }
}

/// SHA-256 (FIPS 180-4), so the package needs no other library for the one hash the bank stores.
enum SHA256 {
    private static let rounds: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
        0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
        0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ message: [UInt8]) -> String {
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message + [0x80]
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
        for start in stride(from: 0, to: padded.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let at = start + index * 4
                words[index] = UInt32(padded[at]) << 24 | UInt32(padded[at + 1]) << 16 | UInt32(padded[at + 2]) << 8 | UInt32(padded[at + 3])
            }
            for index in 16..<64 {
                let first = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let second = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ first &+ words[index - 7] &+ second
            }
            var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
            for index in 0..<64 {
                let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let first = h &+ sum1 &+ choice &+ rounds[index] &+ words[index]
                let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = sum0 &+ majority
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ first, c, b, a, first &+ second)
            }
            for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] = state[index] &+ value }
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { value >> count | value << (32 - count) }
}
