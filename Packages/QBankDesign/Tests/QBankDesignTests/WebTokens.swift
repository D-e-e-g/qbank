import Foundation
@testable import QBankDesign

/// Reads the web app's token stylesheets in `Fixtures/web-tokens` and resolves
/// custom properties the way a browser does for `<html data-palette data-theme>`.
struct WebTokens {
    /// Declarations per selector, for example `:root` or `[data-theme="dark"]`.
    /// Rules inside `@media` are left out.
    let blocks: [String: [String: String]]

    init(file name: String) throws {
        guard let url = Bundle.module.url(forResource: name, withExtension: "css", subdirectory: "Fixtures/web-tokens") else {
            throw WebTokenError.missingFixture(name)
        }
        let css = try String(contentsOf: url, encoding: .utf8)
        blocks = WebTokens.parse(css)
    }

    private static func parse(_ source: String) -> [String: [String: String]] {
        var css = source
        while let start = css.range(of: "/*"), let end = css.range(of: "*/", range: start.upperBound..<css.endIndex) {
            css.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // Top-level rules only: an @media rule and everything inside it is skipped.
        var blocks: [String: [String: String]] = [:]
        var depth = 0
        var prelude = ""
        var body = ""
        for character in css {
            switch character {
            case "{":
                depth += 1
                if depth == 1 { body = "" } else { body.append(character) }
            case "}":
                depth -= 1
                if depth == 0 {
                    let selector = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !selector.hasPrefix("@") {
                        blocks[selector, default: [:]].merge(declarations(body)) { _, new in new }
                    }
                    prelude = ""
                } else {
                    body.append(character)
                }
            default:
                if depth == 0 { prelude.append(character) } else { body.append(character) }
            }
        }
        return blocks
    }

    private static func declarations(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in body.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasPrefix("--") else { continue }
            result[name] = value
        }
        return result
    }

    /// The custom properties in effect on `<html data-palette="…" data-theme="…">`.
    func properties(palette: QBankPalette, appearance: QBankAppearance) -> [String: String] {
        var properties = blocks[":root"] ?? [:]
        // Palette rules come before theme rules in the stylesheet, so themes win.
        properties.merge(blocks["[data-palette=\"\(palette.rawValue)\"]"] ?? [:]) { _, new in new }
        properties.merge(blocks["[data-theme=\"\(appearance.rawValue)\"]"] ?? [:]) { _, new in new }
        return properties
    }

    /// Follows `var(--…)` references to a literal value.
    static func resolve(_ name: String, in properties: [String: String]) throws -> String {
        guard var value = properties[name] else { throw WebTokenError.undefined(name) }
        var seen: Set<String> = [name]
        while value.hasPrefix("var(") {
            let reference = String(value.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespaces)
            guard seen.insert(reference).inserted, let next = properties[reference] else {
                throw WebTokenError.undefined(reference)
            }
            value = next
        }
        return value
    }

    func color(_ name: String, palette: QBankPalette, appearance: QBankAppearance) throws -> QBankRGBA {
        try WebTokens.color(WebTokens.resolve(name, in: properties(palette: palette, appearance: appearance)))
    }

    /// Parses `#RRGGBB` or `rgba(r, g, b, a)`.
    static func color(_ literal: String) throws -> QBankRGBA {
        if literal.hasPrefix("#"), literal.count == 7, let hex = UInt32(literal.dropFirst(), radix: 16) {
            return QBankRGBA(hex)
        }
        if literal.hasPrefix("rgba("), literal.hasSuffix(")") {
            let parts = literal.dropFirst(5).dropLast().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 4, let r = UInt8(parts[0]), let g = UInt8(parts[1]), let b = UInt8(parts[2]),
                let a = Double(parts[3])
            {
                return QBankRGBA(red: r, green: g, blue: b, alpha: a)
            }
        }
        throw WebTokenError.unparsable(literal)
    }

    /// Parses a `12px` or `180ms` length to its number.
    static func number(_ literal: String, unit: String) throws -> Double {
        guard literal.hasSuffix(unit), let value = Double(literal.dropLast(unit.count)) else {
            throw WebTokenError.unparsable(literal)
        }
        return value
    }

    /// Parses a CSS `box-shadow` list. `none` is an empty list.
    static func shadows(_ literal: String) throws -> [(x: Double, y: Double, blur: Double, spread: Double, color: QBankRGBA)] {
        if literal == "none" { return [] }
        return try literal.components(separatedBy: "), ").map { layer in
            let layer = layer.hasSuffix(")") ? layer : layer + ")"
            guard let colorStart = layer.range(of: "rgba(") else { throw WebTokenError.unparsable(layer) }
            let lengths = try layer[..<colorStart.lowerBound].split(separator: " ").map { part in
                part == "0" ? 0 : try number(String(part), unit: "px")
            }
            let color = try color(String(layer[colorStart.lowerBound...]))
            guard lengths.count == 3 || lengths.count == 4 else { throw WebTokenError.unparsable(layer) }
            return (lengths[0], lengths[1], lengths[2], lengths.count == 4 ? lengths[3] : 0, color)
        }
    }
}

enum WebTokenError: Error {
    case missingFixture(String)
    case undefined(String)
    case unparsable(String)
}
