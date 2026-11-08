import Foundation
import QBankKit

/// Her answer to one question while she works on it, in the stored question's indexes, as the
/// web runner keeps it (`apps/web/src/practice/model.ts`). Nil parts are not filled in yet.
nonisolated enum AnswerDraft: Equatable, Sendable {
    case single(Int?)
    case priority(Int?)
    case sata([Int])
    case highlight([Int])
    /// `positions[i]` is the original item index she placed at position i, top first.
    case order([Int])
    case match([String?])
    case matrix([String?])
    /// Column names checked on each row. An empty list is a row with nothing checked yet.
    case matrixmulti([[String]])
    case cloze([Int?])
    /// A format this version of the app cannot show.
    case unsupported

    /// An empty answer. An ordering question starts in the order it opened.
    init(body: QuestionBody, layout: Layout) {
        switch body {
        case .single: self = .single(nil)
        case .priority: self = .priority(nil)
        case .sata: self = .sata([])
        case .highlight: self = .highlight([])
        case .order(let items):
            if case .order(let start) = layout {
                self = .order(start)
            } else {
                self = .order(Array(items.indices))
            }
        case .match(let pairs, _): self = .match(pairs.map { _ in nil })
        case .matrix(_, let rows): self = .matrix(rows.map { _ in nil })
        case .matrixmulti(_, let rows): self = .matrixmulti(rows.map { _ in [] })
        case .cloze(let cloze): self = .cloze(cloze.blanks.map { _ in nil })
        case .unsupported: self = .unsupported
        }
    }

    /// An answer she sent, to show again, as on an exam's result. Nil when it is not for this
    /// question's format.
    init?(response: AnswerResponse, body: QuestionBody) {
        switch (response, body) {
        case (.single(let choice), .single): self = .single(choice)
        case (.priority(let choice), .priority): self = .priority(choice)
        case (.sata(let picks), .sata): self = .sata(picks)
        case (.highlight(let picks), .highlight): self = .highlight(picks)
        case (.order(let positions), .order(let items)) where positions.sorted() == Array(items.indices): self = .order(positions)
        case (.match(let choices), .match(let pairs, _)) where choices.count == pairs.count: self = .match(choices)
        case (.matrix(let choices), .matrix(_, let rows)) where choices.count == rows.count: self = .matrix(choices)
        case (.matrixmulti(let choices), .matrixmulti(_, let rows)) where choices.count == rows.count: self = .matrixmulti(choices)
        case (.cloze(let choices), .cloze(let cloze)) where choices.count == cloze.blanks.count: self = .cloze(choices)
        default: return nil
        }
    }

    /// The answer to send, or nil while a required part is still empty. Ordering always counts.
    var response: AnswerResponse? {
        switch self {
        case .single(let choice): choice.map { .single(choice: $0) }
        case .priority(let choice): choice.map { .priority(choice: $0) }
        case .sata(let picks): picks.isEmpty ? nil : .sata(picks: picks)
        case .highlight(let picks): picks.isEmpty ? nil : .highlight(picks: picks)
        case .order(let positions): .order(positions: positions)
        case .match(let choices): choices.contains(nil) ? nil : .match(choices: choices)
        case .matrix(let choices): choices.contains(nil) ? nil : .matrix(choices: choices)
        case .matrixmulti(let choices): choices.contains(where: \.isEmpty) ? nil : .matrixmulti(choices: choices)
        case .cloze(let choices): choices.contains(nil) ? nil : .cloze(choices: choices)
        case .unsupported: nil
        }
    }

    /// The option or phrase indexes she has picked, for the formats that pick.
    var picked: [Int] {
        switch self {
        case .single(let choice), .priority(let choice): choice.map { [$0] } ?? []
        case .sata(let picks), .highlight(let picks): picks
        default: []
        }
    }

    /// Picks an option: replaces the choice of a single-answer question, toggles a select-all
    /// option or a highlight phrase.
    func picking(_ index: Int) -> AnswerDraft {
        switch self {
        case .single: .single(index)
        case .priority: .priority(index)
        case .sata(let picks): .sata(Self.toggle(picks, index))
        case .highlight(let picks): .highlight(Self.toggle(picks, index))
        default: self
        }
    }

    /// Whether she can strike out choices she has ruled out: the formats whose answer is a list
    /// of choices.
    var canStrike: Bool {
        switch self {
        case .single, .priority, .sata: true
        default: false
        }
    }

    /// Her answer with option `index` no longer picked, as when she strikes it out.
    func unpicking(_ index: Int) -> AnswerDraft {
        switch self {
        case .single(let choice) where choice == index: .single(nil)
        case .priority(let choice) where choice == index: .priority(nil)
        case .sata(let picks): .sata(picks.filter { $0 != index })
        default: self
        }
    }

    /// Strikes out option `index`, or restores it when it is struck already, in `struck`. A struck
    /// option she had picked is unpicked. Only her own aid while she answers: strikes are never
    /// sent, saved, or scored.
    func striking(_ index: Int, in struck: inout Set<Int>) -> AnswerDraft {
        guard canStrike else { return self }
        if struck.remove(index) != nil { return self }
        struck.insert(index)
        return unpicking(index)
    }

    /// Swaps the item at `position` with its neighbour above (-1) or below (+1).
    func moving(at position: Int, by step: Int) -> AnswerDraft {
        guard case .order(var positions) = self else { return self }
        let other = position + step
        guard positions.indices.contains(position), positions.indices.contains(other) else { return self }
        positions.swapAt(position, other)
        return .order(positions)
    }

    /// Lifts the item at `source` out and drops it at `destination`, shifting the rows between.
    func moving(from source: Int, to destination: Int) -> AnswerDraft {
        guard case .order(var positions) = self else { return self }
        guard positions.indices.contains(source), positions.indices.contains(destination), source != destination else { return self }
        let item = positions.remove(at: source)
        positions.insert(item, at: destination)
        return .order(positions)
    }

    /// Checks or clears one column on a matrixmulti row. The same column on a row counts once.
    func checking(_ column: String, at row: Int) -> AnswerDraft {
        guard case .matrixmulti(var choices) = self, choices.indices.contains(row) else { return self }
        if let index = choices[row].firstIndex(of: column) {
            choices[row].remove(at: index)
        } else {
            choices[row].append(column)
        }
        return .matrixmulti(choices)
    }

    /// Sets one row's match, one matrix row's column, or one blank's option.
    func choosing(_ value: String?, at row: Int) -> AnswerDraft {
        switch self {
        case .match(var choices) where choices.indices.contains(row):
            choices[row] = value
            return .match(choices)
        case .matrix(var choices) where choices.indices.contains(row):
            choices[row] = value
            return .matrix(choices)
        default:
            return self
        }
    }

    func choosing(option: Int?, forBlank blank: Int) -> AnswerDraft {
        guard case .cloze(var choices) = self, choices.indices.contains(blank) else { return self }
        choices[blank] = option
        return .cloze(choices)
    }

    private static func toggle(_ picks: [Int], _ index: Int) -> [Int] {
        picks.contains(index) ? picks.filter { $0 != index } : picks + [index]
    }
}

nonisolated extension Layout {
    /// Original option indexes in the order she sees them, or the stored order when the saved
    /// shuffle does not fit the question.
    func optionOrder(count: Int) -> [Int] {
        if case .options(let order) = self, order.sorted() == Array(0..<count) { return order }
        return Array(0..<count)
    }

    /// Every right-hand text, distractors included, in the order the menus list them.
    func matchChoices(pairs: [MatchPair], extra: [MatchExtra]) -> [String] {
        let stored = pairs.map(\.right) + extra.map(\.right)
        if case .match(let choices) = self, choices.sorted() == stored.sorted() { return choices }
        return stored
    }

    /// For each blank, original option indexes in the order its menu lists them.
    func clozeOrders(_ cloze: Cloze) -> [[Int]] {
        let saved: [[Int]] = if case .cloze(let blanks) = self { blanks } else { [] }
        return cloze.blanks.enumerated().map { index, blank in
            let natural = Array(blank.options.indices)
            guard saved.indices.contains(index), saved[index].sorted() == natural else { return natural }
            return saved[index]
        }
    }
}

/// A piece of a drop-down sentence: text, a blank by index, or a line break.
nonisolated enum ClozePart: Equatable, Sendable {
    case text(String)
    case blank(Int)
    case lineBreak

    /// Splits `{0}`, `{1}`, ... placeholders out of the sentence, as the web does, and keeps the
    /// line breaks the question file wrote.
    static func parse(_ text: String) -> [ClozePart] {
        var parts: [ClozePart] = []
        var rest = Substring(text)
        func addText(_ piece: Substring) {
            let lines = piece.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if index > 0 { parts.append(.lineBreak) }
                if !line.isEmpty { parts.append(.text(String(line))) }
            }
        }
        while let match = rest.firstMatch(of: /\{(\d+)\}/) {
            addText(rest[..<match.range.lowerBound])
            if let blank = Int(match.output.1) {
                parts.append(.blank(blank))
            }
            rest = rest[match.range.upperBound...]
        }
        addText(rest)
        return parts
    }
}

/// How one choice reads after she checks: her pick and whether it was right.
nonisolated enum RevealState: Equatable, Sendable {
    /// She picked it and it is right.
    case correct
    /// She picked it and it is wrong.
    case wrong
    /// A right answer she did not pick.
    case missed
    /// Neither picked nor right.
    case dim

    init(selected: Bool, correct: Bool) {
        if selected && correct {
            self = .correct
        } else if selected {
            self = .wrong
        } else if correct {
            self = .missed
        } else {
            self = .dim
        }
    }

    /// The tag under the choice, in the web's words. Nil for a choice that was neither.
    var tag: String? {
        switch self {
        case .correct: "Your answer - Correct"
        case .wrong: "Your answer - Not correct"
        case .missed: "Missed"
        case .dim: nil
        }
    }
}
