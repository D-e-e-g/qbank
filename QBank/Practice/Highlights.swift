import Foundation
import Observation

/// The highlighter's colors. The user's own code: nothing in the app reads a meaning into them.
nonisolated enum HighlightColor: String, CaseIterable, Sendable {
    case yellow
    case blue
    case pink

    /// "Yellow", for the pen's menu and VoiceOver.
    var name: String {
        switch self {
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .pink: "Pink"
        }
    }
}

/// A piece of a question's text that can carry marks. Answer text is named by its stored index, not
/// the shuffled position, so a mark stays on its words whatever order the choices are shown in.
nonisolated enum MarkablePart: Hashable, Sendable {
    case stem
    case ask
    case tableCaption
    case tableHead(column: Int)
    case tableCell(row: Int, column: Int)
    /// A choice, or the label of a matching or matrix row.
    case answer(Int)
}

/// One mark: a run of a piece's text, in UTF-16 offsets as the text view counts them, and its color.
nonisolated struct Highlight: Equatable, Sendable {
    var range: Range<Int>
    var color: HighlightColor
}

/// The marks on one question. They live with the attempt on this device, as strikes do: never sent,
/// never saved, and gone when the set or exam closes.
nonisolated struct Highlights: Equatable, Sendable {
    private var marks: [MarkablePart: [Highlight]] = [:]

    var isEmpty: Bool { marks.isEmpty }

    /// The part's marks, in text order, none overlapping.
    subscript(part: MarkablePart) -> [Highlight] {
        marks[part] ?? []
    }

    /// The mark under a character, if any.
    func mark(at offset: Int, in part: MarkablePart) -> Highlight? {
        self[part].first { $0.range.contains(offset) }
    }

    /// Paints a run in a color. What it covers takes that color, and marks of one color that touch
    /// or overlap join into one.
    mutating func paint(_ range: Range<Int>, in part: MarkablePart, color: HighlightColor) {
        guard !range.isEmpty else { return }
        var kept: [Highlight] = []
        for mark in self[part] {
            if mark.range.lowerBound < range.lowerBound {
                kept.append(Highlight(range: mark.range.lowerBound..<min(mark.range.upperBound, range.lowerBound), color: mark.color))
            }
            if mark.range.upperBound > range.upperBound {
                kept.append(Highlight(range: max(mark.range.lowerBound, range.upperBound)..<mark.range.upperBound, color: mark.color))
            }
        }
        kept.append(Highlight(range: range, color: color))
        kept.sort { $0.range.lowerBound < $1.range.lowerBound }
        var joined: [Highlight] = []
        for mark in kept {
            if let last = joined.last, last.color == mark.color, last.range.upperBound >= mark.range.lowerBound {
                joined[joined.count - 1].range = last.range.lowerBound..<max(last.range.upperBound, mark.range.upperBound)
            } else {
                joined.append(mark)
            }
        }
        marks[part] = joined
    }

    /// Erases the mark under a character. False when there is none.
    @discardableResult
    mutating func erase(at offset: Int, in part: MarkablePart) -> Bool {
        guard let index = self[part].firstIndex(where: { $0.range.contains(offset) }) else { return false }
        marks[part]?.remove(at: index)
        if marks[part]?.isEmpty == true {
            marks[part] = nil
        }
        return true
    }

    mutating func clear() {
        marks = [:]
    }
}

/// Which words a press-and-drag covers.
nonisolated enum WordSpan {
    /// Sentence punctuation a word sheds at its ends. What stays is part of the reading: "93%",
    /// "86/48", "38.9", "°C".
    private static let trimmed = Set(".,;:!?\"'“”‘’()[]{}…")

    /// The words from the one under the press to the one under the finger now, in either direction,
    /// whole. A word runs between spaces, less sentence punctuation at its ends. Nil when the drag
    /// stays on spaces or punctuation. Offsets are UTF-16.
    static func covering(_ text: String, from anchor: Int, to current: Int) -> Range<Int>? {
        let low = max(0, min(anchor, current))
        let high = max(anchor, current) + 1
        var first: Int?
        var last: Int?
        let all = words(in: text)
        for word in all where word.upperBound > low && word.lowerBound < high {
            first = first ?? word.lowerBound
            last = word.upperBound
        }
        guard let first, let last else {
            // A hold on a quote or a comma right beside a word takes that word.
            let string = text as NSString
            guard anchor == current, anchor >= 0, anchor < string.length,
                  let held = Unicode.Scalar(string.character(at: anchor)), trimmed.contains(Character(held)) else { return nil }
            return all.first { $0.lowerBound == anchor + 1 || $0.upperBound == anchor }
        }
        return first..<last
    }

    /// Each word's run, in UTF-16 offsets.
    static func words(in text: String) -> [Range<Int>] {
        var words: [Range<Int>] = []
        var offset = 0
        var start: Int?
        var characters: [(Character, Int)] = []
        func close() {
            guard start != nil else { return }
            var lead = 0
            var tail = characters.count
            while lead < tail, trimmed.contains(characters[lead].0) { lead += 1 }
            while tail > lead, trimmed.contains(characters[tail - 1].0) { tail -= 1 }
            if lead < tail {
                let lower = characters[lead].1
                let upper = characters[tail - 1].1 + String(characters[tail - 1].0).utf16.count
                words.append(lower..<upper)
            }
            start = nil
            characters = []
        }
        for character in text {
            if character.isWhitespace {
                close()
            } else {
                start = start ?? offset
                characters.append((character, offset))
            }
            offset += String(character).utf16.count
        }
        close()
        return words
    }
}

/// The pen's color, kept on this device like the Look, and never sent.
@Observable
final class HighlighterStore {
    static let key = "qbank-highlighter"

    var color: HighlightColor {
        didSet { defaults.set(color.rawValue, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        color = defaults.string(forKey: Self.key).flatMap(HighlightColor.init(rawValue:)) ?? .yellow
    }
}
