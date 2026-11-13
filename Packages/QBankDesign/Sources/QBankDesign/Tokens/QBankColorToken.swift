/// Light or dark. Dark is a full second palette, not inverted colors.
public enum QBankAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

/// The semantic colors, with the web's names (`--text-1` is `text1`).
/// Screens use these, never the raw ramps, so the palette and dark mode keep working.
public enum QBankColorToken: String, CaseIterable, Sendable {
    // Surfaces
    case bg
    case bgSidebar
    case surface
    case surfaceRaised
    case surfaceSunken
    case surfacePressed
    case overlay
    case material
    // Text
    case text1
    case text2
    case text3
    case text4
    case textOnTint
    // Lines
    case separator
    case separatorStrong
    case focusRing
    // Accent
    case tint
    case tintPressed
    case tintSoft
    case tintSoftBorder
    // Answer states: each has a text/icon color, a soft fill and a border
    case correct
    case correctSoft
    case correctBorder
    case partial
    case partialSoft
    case partialBorder
    case wrong
    case wrongSoft
    case wrongBorder
    case guess
    case guessSoft
    case guessBorder
    // Highlight passage, timer, progress
    case highlight
    case highlightText
    case timerNormal
    case timerLow
    case timerLowSoft
    case progressTrack
    case progressFill
    // From the highlighting design board, not in the web's token files yet (see `boardOnly`).
    /// The blue highlighter, behind words.
    case highlightBlue
    case highlightBlueText
    /// The pink highlighter, behind words.
    case highlightPink
    case highlightPinkText
    /// Teal for what is read rather than answered: exhibit table headers and captions.
    case exhibit
    case exhibitSoft
    /// The Correct tag's words, darker than `correct` in light so small text stays readable.
    case correctText
    /// Result chart segments: fully right, partly right, missed. Each passes a red-green color-blind check.
    case chartCorrect
    case chartPartial
    case chartWrong

    /// The colors the highlighting design board added, with the board's values. The web's token
    /// files do not define them yet, so only `webCases` is checked against the web.
    public static let boardOnly: Set<QBankColorToken> = [
        .highlightBlue, .highlightBlueText, .highlightPink, .highlightPinkText, .exhibit, .exhibitSoft,
        .correctText, .chartCorrect, .chartPartial, .chartWrong,
    ]

    /// Every token the web's stylesheets define.
    public static var webCases: [QBankColorToken] {
        allCases.filter { !boardOnly.contains($0) }
    }

    /// The matching CSS custom property, for example `--text-on-tint`.
    public var cssName: String {
        var name = "--"
        var previous: Character?
        for character in rawValue {
            if character.isUppercase {
                name += "-" + character.lowercased()
            } else if character.isNumber, let previous, !previous.isNumber {
                name += "-" + String(character)
            } else {
                name.append(character)
            }
            previous = character
        }
        return name
    }

    /// The value for one palette and appearance, exactly as the web resolves it.
    public func value(palette: QBankPalette = .default, appearance: QBankAppearance) -> QBankRGBA {
        switch appearance {
        case .light: lightValue(palette)
        case .dark: darkValue(palette)
        }
    }

    private func lightValue(_ palette: QBankPalette) -> QBankRGBA {
        typealias C = QBankBaseColors
        let accent = palette.accent
        let guessRamp = palette.guess
        switch self {
        case .bg: return C.paper100
        case .bgSidebar: return C.paper200
        case .surface: return C.paper0
        case .surfaceRaised: return C.paper0
        case .surfaceSunken: return C.paper200
        case .surfacePressed: return C.paper300
        case .overlay: return QBankRGBA(red: 28, green: 27, blue: 24, alpha: 0.4)
        case .material: return QBankRGBA(red: 247, green: 244, blue: 238, alpha: 0.85)
        case .text1: return C.paper850
        case .text2: return QBankRGBA(0x5C5750)
        case .text3: return QBankRGBA(0x8A847A)
        case .text4: return QBankRGBA(0xB4AEA3)
        case .textOnTint: return QBankRGBA(0xFFFFFF)
        case .separator: return QBankRGBA(0xE4DFD5)
        case .separatorStrong: return C.paper400
        case .focusRing: return accent.shade500
        case .tint: return accent.shade600
        case .tintPressed: return accent.shade700
        case .tintSoft: return accent.shade50
        case .tintSoftBorder: return accent.shade100
        case .correct: return C.sage600
        case .correctSoft: return C.sage50
        case .correctBorder: return C.sage300
        case .partial: return C.amber600
        case .partialSoft: return C.amber50
        case .partialBorder: return C.amber300
        case .wrong: return C.brick600
        case .wrongSoft: return C.brick50
        case .wrongBorder: return C.brick300
        case .guess: return guessRamp.shade600
        case .guessSoft: return guessRamp.shade50
        case .guessBorder: return guessRamp.shade300
        case .highlight: return QBankRGBA(0xFBE9A6)
        case .highlightText: return C.paper850
        case .timerNormal: return QBankColorToken.text2.lightValue(palette)
        case .timerLow: return QBankColorToken.wrong.lightValue(palette)
        case .timerLowSoft: return QBankColorToken.wrongSoft.lightValue(palette)
        case .progressTrack: return C.paper300
        case .progressFill: return QBankColorToken.tint.lightValue(palette)
        case .highlightBlue: return QBankRGBA(0xB9DBFA)
        case .highlightPink: return QBankRGBA(0xFEBCCF)
        case .highlightBlueText, .highlightPinkText: return C.paper850
        case .exhibit: return QBankRGBA(0x08606F)
        case .exhibitSoft: return QBankRGBA(0xD5F1F7)
        case .correctText, .chartCorrect: return QBankRGBA(0x1F6B40)
        case .chartPartial: return QBankRGBA(0xBD8412)
        case .chartWrong: return C.brick600
        }
    }

    private func darkValue(_ palette: QBankPalette) -> QBankRGBA {
        typealias C = QBankBaseColors
        let accent = palette.accent
        let guessRamp = palette.guess
        switch self {
        case .bg: return C.paper950
        case .bgSidebar: return QBankRGBA(0x121110)
        case .surface: return C.paper900
        case .surfaceRaised: return C.paper850
        case .surfaceSunken: return QBankRGBA(0x232220)
        case .surfacePressed: return C.paper800
        case .overlay: return QBankRGBA(red: 0, green: 0, blue: 0, alpha: 0.6)
        case .material: return QBankRGBA(red: 12, green: 12, blue: 11, alpha: 0.8)
        case .text1: return QBankRGBA(0xF3EFE8)
        case .text2: return QBankRGBA(0xB8B2A8)
        case .text3: return QBankRGBA(0x8A847A)
        case .text4: return QBankRGBA(0x5C5750)
        case .textOnTint: return accent.onTintDark
        case .separator: return C.paper800
        case .separatorStrong: return QBankRGBA(0x3A3833)
        case .focusRing: return accent.shade400
        case .tint: return accent.tintDark
        case .tintPressed: return accent.pressedDark
        case .tintSoft: return accent.softDark
        case .tintSoftBorder: return accent.softBorderDark
        case .correct: return C.sage400
        case .correctSoft: return C.sage900
        case .correctBorder: return QBankRGBA(0x2F5A40)
        case .partial: return C.amber400
        case .partialSoft: return C.amber900
        case .partialBorder: return QBankRGBA(0x6B5320)
        case .wrong: return C.brick400
        case .wrongSoft: return C.brick900
        case .wrongBorder: return QBankRGBA(0x6E3028)
        case .guess: return guessRamp.shade400
        case .guessSoft: return guessRamp.shade900
        case .guessBorder: return guessRamp.borderDark
        case .highlight: return QBankRGBA(0x4A3E14)
        case .highlightText: return QBankRGBA(0xF7EBBE)
        case .timerNormal: return QBankColorToken.text2.darkValue(palette)
        case .timerLow: return QBankColorToken.wrong.darkValue(palette)
        case .timerLowSoft: return QBankColorToken.wrongSoft.darkValue(palette)
        case .progressTrack: return C.paper800
        case .progressFill: return QBankColorToken.tint.darkValue(palette)
        case .highlightBlue: return QBankRGBA(0x143A5C)
        case .highlightBlueText: return QBankRGBA(0xD5E9F8)
        case .highlightPink: return QBankRGBA(0x632344)
        case .highlightPinkText: return QBankRGBA(0xFBDCE8)
        case .exhibit: return QBankRGBA(0x74CDE2)
        case .exhibitSoft: return QBankRGBA(0x0D2E35)
        case .correctText: return C.sage400
        case .chartCorrect: return QBankRGBA(0x2F9463)
        case .chartPartial: return QBankRGBA(0xC49A2C)
        case .chartWrong: return QBankRGBA(0xD8563F)
        }
    }
}
