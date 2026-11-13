#if DEBUG
import QBankKit

/// Answers to the invented questions, made from each question's own key: the right one, a wrong
/// one, and a partly right one where the format allows it.
nonisolated enum FakeAnswers {
    static func right(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .single(let options): options.firstIndex(where: \.isCorrect).map { .single(choice: $0) }
        case .priority(let options): options.firstIndex(where: \.isCorrect).map { .priority(choice: $0) }
        case .sata(let options): .sata(picks: options.indices.filter { options[$0].isCorrect })
        case .highlight(let segments): .highlight(picks: segments.indices.filter { segments[$0].isCorrect })
        case .order(let items): .order(positions: Array(items.indices))
        case .match(let pairs, _): .match(choices: pairs.map(\.right))
        case .matrix(_, let rows): .matrix(choices: rows.map(\.answer))
        case .matrixmulti(_, let rows): .matrixmulti(choices: rows.map(\.answers))
        case .cloze(let cloze): .cloze(choices: cloze.blanks.map(\.answer))
        case .unsupported: nil
        }
    }

    static func wrong(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .single(let options): options.firstIndex { !$0.isCorrect }.map { .single(choice: $0) }
        case .priority(let options): options.firstIndex { !$0.isCorrect }.map { .priority(choice: $0) }
        case .sata(let options): options.firstIndex { !$0.isCorrect }.map { .sata(picks: [$0]) }
        case .highlight(let segments): segments.firstIndex { !$0.isCorrect }.map { .highlight(picks: [$0]) }
        case .order(let items): .order(positions: Array(items.indices.reversed()))
        case .match(let pairs, _): .match(choices: pairs.indices.map { pairs[(($0 + 1) % pairs.count)].right })
        case .matrix(let columns, let rows): .matrix(choices: rows.map { row in columns.first { $0 != row.answer } ?? row.answer })
        case .matrixmulti(let columns, let rows):
            .matrixmulti(choices: rows.map { row in columns.first { !row.answers.contains($0) }.map { [$0] } ?? [] })
        case .cloze(let cloze): .cloze(choices: cloze.blanks.map { ($0.answer + 1) % max(1, $0.options.count) })
        case .unsupported: nil
        }
    }

    /// Partly right where the format gives points per part; a wrong answer otherwise.
    static func partly(_ body: QuestionBody) -> AnswerResponse? {
        switch body {
        case .sata(let options):
            let right = options.indices.filter { options[$0].isCorrect }
            return .sata(picks: Array(right.dropLast()))
        case .matrix(let columns, let rows):
            return .matrix(choices: rows.enumerated().map { index, row in index == 0 ? (columns.first { $0 != row.answer } ?? row.answer) : row.answer })
        default:
            return wrong(body)
        }
    }
}
#endif
