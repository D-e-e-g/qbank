import Foundation
import Testing
@testable import QBankDesign

/// The colors the highlighting design board added: two more highlighter colors, teal for exhibits,
/// a darker green for the Correct tag in light, and the result chart colors. The web's token files
/// do not carry them yet, so they are checked against the board's values here.
@Suite("Colors from the highlighting board")
struct BoardColorTests {
    @Test("Each board color has the board's value in light and dark")
    func boardValues() {
        let expected: [(QBankColorToken, UInt32, UInt32)] = [
            (.highlightBlue, 0xB9DBFA, 0x143A5C), (.highlightBlueText, 0x1C1B18, 0xD5E9F8),
            (.highlightPink, 0xFEBCCF, 0x632344), (.highlightPinkText, 0x1C1B18, 0xFBDCE8),
            (.exhibit, 0x08606F, 0x74CDE2), (.exhibitSoft, 0xD5F1F7, 0x0D2E35),
            (.correctText, 0x1F6B40, 0x7ACC98),
            (.chartCorrect, 0x1F6B40, 0x2F9463), (.chartPartial, 0xBD8412, 0xC49A2C), (.chartWrong, 0xB13A2E, 0xD8563F),
        ]
        #expect(Set(expected.map(\.0)) == QBankColorToken.boardOnly)
        for (token, light, dark) in expected {
            for palette in QBankPalette.allCases {
                #expect(token.value(palette: palette, appearance: .light) == QBankRGBA(light), "\(token.cssName) light \(palette.rawValue)")
                #expect(token.value(palette: palette, appearance: .dark) == QBankRGBA(dark), "\(token.cssName) dark \(palette.rawValue)")
            }
        }
    }

    @Test("Yellow is the web's highlight, and light marks keep the normal text color")
    func yellowIsTheWebHighlight() {
        #expect(QBankColorToken.highlight.value(appearance: .light) == QBankRGBA(0xFBE9A6))
        #expect(QBankColorToken.highlight.value(appearance: .dark) == QBankRGBA(0x4A3E14))
        #expect(QBankColorToken.highlightText.value(appearance: .dark) == QBankRGBA(0xF7EBBE))
        for token in [QBankColorToken.highlightText, .highlightBlueText, .highlightPinkText] {
            #expect(token.value(appearance: .light) == QBankColorToken.text1.value(appearance: .light))
        }
    }

    @Test("Every other token comes from the web")
    func webCasesLeaveOutTheBoard() {
        #expect(QBankColorToken.webCases.count + QBankColorToken.boardOnly.count == QBankColorToken.allCases.count)
        #expect(QBankColorToken.boardOnly.isDisjoint(with: QBankColorToken.webCases))
    }

    @Test("Words on every mark meet the text standard, light and dark")
    func marksAreReadable() {
        let pairs: [(QBankColorToken, QBankColorToken)] = [
            (.highlightText, .highlight), (.highlightBlueText, .highlightBlue), (.highlightPinkText, .highlightPink),
        ]
        for appearance in QBankAppearance.allCases {
            for (text, fill) in pairs {
                let ratio = text.value(appearance: appearance).contrast(with: fill.value(appearance: appearance))
                #expect(ratio >= 4.5, "\(text.cssName) on \(fill.cssName) \(appearance.rawValue): \(ratio)")
            }
            let teal = QBankColorToken.exhibit.value(appearance: appearance).contrast(with: QBankColorToken.exhibitSoft.value(appearance: appearance))
            #expect(teal >= 4.5, "teal header \(appearance.rawValue): \(teal)")
        }
        let correctTag = QBankColorToken.correctText.value(appearance: .light).contrast(with: QBankColorToken.correctSoft.value(appearance: .light))
        #expect(correctTag >= 4.5, "the Correct tag in light: \(correctTag)")
    }
}

private extension QBankRGBA {
    /// The WCAG contrast ratio of two opaque colors.
    func contrast(with other: QBankRGBA) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
