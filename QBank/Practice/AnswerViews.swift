import QBankDesign
import QBankKit
import SwiftUI

/// Her answer to one question, in the control its format needs. Before Check answer she fills it
/// in; after, every choice shows whether it was hers and whether it was right, with its reason.
struct AnswerArea: View {
    let question: Question
    let layout: QBankKit.Layout
    let draft: AnswerDraft
    let revealed: Bool
    /// True after Check answer and while it is sending: nothing can change.
    let isLocked: Bool
    /// Original indexes of the choices she has struck out.
    var struck: Set<Int> = []
    /// Strikes out a choice or restores a struck one. Nil where choices cannot be struck, as on a result.
    var onStrike: ((Int) -> Void)?
    let onChange: (AnswerDraft) -> Void

    var body: some View {
        switch question.body {
        case .single(let options), .priority(let options), .sata(let options):
            OptionList(
                options: options,
                order: layout.optionOrder(count: options.count),
                picked: draft.picked,
                isMulti: question.type == .sata,
                revealed: revealed,
                isLocked: isLocked,
                // Once checked, every choice shows its verdict as it would without strikes.
                struck: revealed ? [] : struck,
                strike: revealed ? nil : onStrike
            ) { onChange(draft.picking($0)) }
        case .highlight(let segments):
            HighlightList(segments: segments, picked: draft.picked, revealed: revealed, isLocked: isLocked) {
                onChange(draft.picking($0))
            }
        case .order(let items):
            if case .order(let positions) = draft {
                OrderList(items: items, positions: positions, revealed: revealed, isLocked: isLocked) { source, destination in
                    onChange(draft.moving(from: source, to: destination))
                }
            }
        case .match(let pairs, let extra):
            if case .match(let choices) = draft {
                MatchList(
                    pairs: pairs,
                    choices: layout.matchChoices(pairs: pairs, extra: extra),
                    selected: choices,
                    revealed: revealed,
                    isLocked: isLocked
                ) { row, value in onChange(draft.choosing(value, at: row)) }
            }
        case .matrix(let columns, let rows):
            if case .matrix(let choices) = draft {
                MatrixList(columns: columns, rows: rows, selected: choices, revealed: revealed, isLocked: isLocked) { row, value in
                    onChange(draft.choosing(value, at: row))
                }
            }
        case .matrixmulti(let columns, let rows):
            if case .matrixmulti(let choices) = draft {
                MatrixMultiList(columns: columns, rows: rows, selected: choices, revealed: revealed, isLocked: isLocked) { row, column in
                    onChange(draft.checking(column, at: row))
                }
            }
        case .cloze(let cloze):
            if case .cloze(let choices) = draft {
                ClozePassage(
                    cloze: cloze,
                    orders: layout.clozeOrders(cloze),
                    selected: choices,
                    revealed: revealed,
                    isLocked: isLocked
                ) { blank, option in onChange(draft.choosing(option: option, forBlank: blank)) }
            }
        case .unsupported:
            Text("This question is in a format this version of the app cannot show yet. Update QBank to answer it, or answer it on the web.")
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.qbank(.surfaceSunken), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        }
    }
}

// MARK: Highlight

/// The passage as tappable phrases: tap to highlight, tap again to clear. After checking, each
/// phrase is marked and the notes under the passage give every phrase's reason.
private struct HighlightList: View {
    let segments: [QuestionOption]
    let picked: [Int]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                ForEach(segments.indices, id: \.self) { index in
                    let selected = picked.contains(index)
                    let state = revealed ? RevealState(selected: selected, correct: segments[index].isCorrect) : nil
                    Button {
                        toggle(index)
                    } label: {
                        Segment(text: segments[index].text, selected: selected, state: state)
                    }
                    .buttonStyle(ChoicePressStyle())
                    .allowsHitTesting(!isLocked)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(state?.tag ?? (selected ? "Highlighted" : ""))
                    .accessibilityIdentifier("practice.segment.\(index)")
                }
            }
            if revealed {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    ForEach(segments.indices, id: \.self) { index in
                        let state = RevealState(selected: picked.contains(index), correct: segments[index].isCorrect)
                        RevealNote(state: state) {
                            Text(segments[index].text)
                                .qbankFont(.body)
                                .foregroundStyle(.qbank(.text1))
                            if let tag = state.tag {
                                ChoiceTag(text: tag, state: state)
                            }
                            if let why = segments[index].why {
                                Reason(text: why)
                            }
                        }
                    }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) {
                    Rectangle().fill(.qbank(.separator)).frame(height: QBankBorder.hairline)
                }
                .padding(.top, QBankSpacing.space5)
            }
        }
        .padding(QBankSpacing.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
                .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
    }
}

/// One phrase of a highlight passage, as the web marks it: a dotted underline to tap, a soft
/// highlight when picked, and after checking a solid, struck-through, dashed or faded mark.
private struct Segment: View {
    let text: String
    let selected: Bool
    let state: RevealState?
    @Environment(\.self) private var environment

    var body: some View {
        Text(text)
            .qbankFont(.reading)
            .strikethrough(state == .wrong, color: Color(QBankColor(.wrong).resolve(in: environment)))
            .foregroundStyle(.qbank(state == .dim ? .text3 : .text1))
            .multilineTextAlignment(.leading)
            .padding(.vertical, QBankSpacing.space3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: QBankSpacing.rowMin, alignment: .leading)
            .background(.qbank(fill), in: .rect(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .bottom) { underline }
            .contentShape(.rect)
            .animation(QBankMotion.select, value: selected)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: selected ? .tintSoft : .surface
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surface
        }
    }

    @ViewBuilder
    private var underline: some View {
        switch state {
        case nil:
            if selected {
                Rectangle().fill(.qbank(.tint)).frame(height: QBankBorder.emphasis)
            } else {
                Line().stroke(.qbank(.text3), style: StrokeStyle(lineWidth: 1, dash: [1, 2.5])).frame(height: 1)
            }
        case .correct:
            Rectangle().fill(.qbank(.correct)).frame(height: 2)
        case .wrong:
            Rectangle().fill(.qbank(.wrong)).frame(height: 1)
        case .missed:
            Line().stroke(.qbank(.correct), style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(height: 2)
        case .dim:
            EmptyView()
        }
    }
}

/// A horizontal line across its frame, for dashed and dotted underlines.
private nonisolated struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// A note under a checked passage or drop-down: a colored bar at the leading edge (dashed for a
/// missed answer), then the text, its tag and its reason.
private struct RevealNote<Content: View>: View {
    let state: RevealState
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: QBankSpacing.space4) {
            bar
                .frame(width: 3)
            VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bar: some View {
        switch state {
        case .correct:
            Rectangle().fill(.qbank(.correct))
        case .wrong:
            Rectangle().fill(.qbank(.wrong))
        case .missed:
            VerticalLine().stroke(.qbank(.correct), style: StrokeStyle(lineWidth: 3, dash: [5, 3]))
        case .dim:
            Rectangle().fill(.qbank(.separatorStrong))
        }
    }
}

private nonisolated struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

// MARK: Ordering

/// The items in her order. Up and down buttons move a row one place; press and hold a row to
/// drag it. VoiceOver offers Move up and Move down on each row.
private struct OrderList: View {
    let items: [OrderItem]
    let positions: [Int]
    let revealed: Bool
    let isLocked: Bool
    let move: (_ source: Int, _ destination: Int) -> Void
    @State private var target: Int?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(positions.enumerated()), id: \.element) { position, original in
                row(position: position, original: original)
            }
        }
        .animation(QBankMotion.select, value: positions)
    }

    private func row(position: Int, original: Int) -> some View {
        let item = items[original]
        let right = original == position
        let state: RevealState? = revealed ? (right ? .correct : .wrong) : nil
        return HStack(spacing: QBankSpacing.space3) {
            if !revealed {
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.qbank(.text3))
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            NumberBadge(number: position + 1)
            VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                Text(item.text)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                if revealed {
                    ChoiceTag(text: right ? "Right position" : "Belongs in position \(original + 1)", state: state)
                    if let why = item.why {
                        Reason(text: why)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(position + 1). \(item.text)")
            .accessibilityAction(named: "Move up") { if position > 0 { move(position, position - 1) } }
            .accessibilityAction(named: "Move down") { if position < positions.count - 1 { move(position, position + 1) } }
            .accessibilityIdentifier("practice.order.item.\(original)")
            if !revealed {
                VStack(spacing: 0) {
                    MoveButton(systemImage: "chevron.up", label: "Move up", disabled: position == 0) {
                        move(position, position - 1)
                    }
                    .accessibilityIdentifier("practice.order.\(original).up")
                    MoveButton(systemImage: "chevron.down", label: "Move down", disabled: position == positions.count - 1) {
                        move(position, position + 1)
                    }
                    .accessibilityIdentifier("practice.order.\(original).down")
                }
            }
        }
        .padding(.vertical, revealed ? QBankSpacing.space4 : QBankSpacing.space1)
        .padding(.leading, QBankSpacing.space4)
        .padding(.trailing, revealed ? 14 : QBankSpacing.space1)
        .frame(minHeight: QBankSpacing.rowMin)
        .choiceBox(selected: target == position, state: state)
        .allowsHitTesting(!isLocked)
        .draggable(String(original)) {
            Text(item.text)
                .qbankFont(.body)
                .padding(QBankSpacing.space4)
                .frame(maxWidth: 300, alignment: .leading)
                .background(.qbank(.surfaceRaised), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard !isLocked, let value = dropped.first, let dragged = Int(value),
                  let source = positions.firstIndex(of: dragged) else { return false }
            move(source, position)
            return true
        } isTargeted: { over in
            if over {
                target = position
            } else if target == position {
                target = nil
            }
        }
    }
}

private struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .qbankFont(.footnote, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(.qbank(.text2))
            .frame(width: 24, height: 24)
            .background(.qbank(.surfaceSunken), in: .circle)
            .accessibilityHidden(true)
    }
}

private struct MoveButton: View {
    let systemImage: String
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        .foregroundStyle(.qbank(.text2))
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
    }
}

// MARK: Matching

/// One card per left-hand item with a menu of every right-hand text, distractors included.
private struct MatchList: View {
    let pairs: [MatchPair]
    let choices: [String]
    let selected: [String?]
    let revealed: Bool
    let isLocked: Bool
    let choose: (Int, String?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(pairs.indices, id: \.self) { row in
                let pair = pairs[row]
                let value = selected.indices.contains(row) ? selected[row] : nil
                let state: PickerState? = revealed ? (value == pair.right ? .correct : .wrong) : nil
                AnswerCard(label: pair.left, part: .answer(row)) {
                    AnswerMenu(
                        label: "Match for \(pair.left)",
                        placeholder: "Choose a match",
                        options: choices.map { ($0, $0) },
                        value: value,
                        state: state,
                        isInline: false
                    ) { choose(row, $0) }
                    .allowsHitTesting(!isLocked)
                    .accessibilityIdentifier("practice.match.\(row)")
                    if state == .wrong {
                        CorrectAnswer(label: "Correct match", text: pair.right)
                    }
                    if revealed, let why = pair.why {
                        Reason(text: why)
                    }
                }
            }
        }
    }
}

/// A card with a bold prompt and its answer controls under it.
struct AnswerCard<Content: View>: View {
    let label: String
    /// Which answer text the prompt is, so its words can be marked.
    let part: MarkablePart
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkableText(text: label, part: part, style: .headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .padding(14)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.hairline)
        }
    }
}

private enum PickerState {
    case correct
    case wrong
}

/// A menu that opens at the field, as iOS pop-up buttons do. Empty, filled, then right or wrong
/// after checking, when the chevron becomes a mark.
private struct AnswerMenu: View {
    let label: String
    let placeholder: String
    /// (value, text) pairs in the order the menu lists them.
    let options: [(String, String)]
    let value: String?
    let state: PickerState?
    let isInline: Bool
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            Picker(label, selection: Binding(get: { value }, set: { choose($0) })) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.1).tag(Optional(option.0))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: QBankSpacing.space3) {
                Text(text)
                    .qbankFont(isInline ? .callout : .body, weight: isInline ? .medium : nil)
                    .foregroundStyle(.qbank(value == nil ? .text3 : .text1))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: isInline ? nil : .infinity, alignment: .leading)
                Image(systemName: icon)
                    .font(.system(size: isInline ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.qbank(iconColor))
                    .accessibilityHidden(true)
            }
            .padding(.leading, isInline ? 10 : 14)
            .padding(.trailing, isInline ? QBankSpacing.space3 : QBankSpacing.space4)
            .padding(.vertical, isInline ? QBankSpacing.space2 : QBankSpacing.space3)
            .frame(minHeight: isInline ? 36 : QBankSpacing.rowMin)
            .background(.qbank(fill), in: .rect(cornerRadius: QBankRadius.xs, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                    .strokeBorder(.qbank(border), lineWidth: QBankBorder.emphasis)
            }
            .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var text: String {
        guard let value else { return placeholder }
        return options.first { $0.0 == value }?.1 ?? value
    }

    private var icon: String {
        switch state {
        case .correct: "checkmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        case nil: "chevron.down"
        }
    }

    private var iconColor: QBankColorToken {
        switch state {
        case .correct: .correct
        case .wrong: .wrong
        case nil: value == nil ? .text3 : .tint
        }
    }

    private var fill: QBankColorToken {
        switch state {
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case nil: value == nil ? .surfaceRaised : .tintSoft
        }
    }

    private var border: QBankColorToken {
        switch state {
        case .correct: .correct
        case .wrong: .wrong
        case nil: value == nil ? .separatorStrong : .tint
        }
    }

    private var accessibilityValue: String {
        let chosen = value == nil ? "Not chosen" : text
        switch state {
        case .correct: return "\(chosen), correct"
        case .wrong: return "\(chosen), not correct"
        case nil: return chosen
        }
    }
}

// MARK: Drop-down

/// The sentence with a small menu in each blank. Long options wrap onto their own line.
private struct ClozePassage: View {
    let cloze: Cloze
    let orders: [[Int]]
    let selected: [Int?]
    let revealed: Bool
    let isLocked: Bool
    let choose: (Int, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 0, lineSpacing: QBankSpacing.space3) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .word(let text, let spoken):
                        Text(text)
                            .qbankFont(.reading)
                            .foregroundStyle(.qbank(.text1))
                            .accessibilityLabel(spoken ?? "")
                            .accessibilityHidden(spoken == nil)
                    case .blank(let index, let trailing):
                        // Punctuation right after a blank stays on its line.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            blank(index)
                                .padding(.horizontal, 2)
                            if let trailing {
                                Text(trailing)
                                    .qbankFont(.reading)
                                    .foregroundStyle(.qbank(.text1))
                            }
                        }
                    case .lineBreak:
                        Color.clear.frame(width: 0, height: 0).flowLineBreak()
                    }
                }
            }
            .accessibilityElement(children: .contain)
            if revealed, cloze.blanks.contains(where: { $0.why != nil }) {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    ForEach(cloze.blanks.indices, id: \.self) { index in
                        if let why = cloze.blanks[index].why {
                            let right = selected.indices.contains(index) && selected[index] == cloze.blanks[index].answer
                            RevealNote(state: right ? .correct : .wrong) {
                                ChoiceTag(text: "Blank \(index + 1) - \(right ? "Correct" : "Not correct")", state: right ? .correct : .wrong)
                                Reason(text: why)
                            }
                        }
                    }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) {
                    Rectangle().fill(.qbank(.separator)).frame(height: QBankBorder.hairline)
                }
                .padding(.top, QBankSpacing.space5)
            }
        }
        .padding(QBankSpacing.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
                .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
    }

    private func blank(_ index: Int) -> some View {
        let blank = cloze.blanks.indices.contains(index) ? cloze.blanks[index] : nil
        let value = selected.indices.contains(index) ? selected[index] : nil
        let state: PickerState? = revealed ? (value == blank?.answer ? .correct : .wrong) : nil
        let order = orders.indices.contains(index) ? orders[index] : []
        return VStack(alignment: .leading, spacing: QBankSpacing.space1) {
            AnswerMenu(
                label: "Blank \(index + 1)",
                placeholder: "Select",
                options: order.compactMap { original in
                    guard let blank, blank.options.indices.contains(original) else { return nil }
                    return (String(original), blank.options[original])
                },
                value: value.map(String.init),
                state: state,
                isInline: true
            ) { choose(index, $0.flatMap(Int.init)) }
            .allowsHitTesting(!isLocked)
            .accessibilityIdentifier("practice.blank.\(index)")
            if state == .wrong, let blank, blank.options.indices.contains(blank.answer) {
                CorrectAnswer(label: "Correct", text: blank.options[blank.answer])
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sentence cut into words, so it wraps around the menus like text. VoiceOver reads each
    /// run of words between two blanks as one sentence, on its first word.
    private enum Piece {
        case word(String, spoken: String?)
        /// A blank and the word that follows it with no space, such as a period.
        case blank(Int, trailing: String?)
        case lineBreak
    }

    private var pieces: [Piece] {
        var pieces: [Piece] = []
        for part in ClozePart.parse(cloze.text) {
            switch part {
            case .blank(let index):
                pieces.append(.blank(index, trailing: nil))
            case .lineBreak:
                pieces.append(.lineBreak)
            case .text(let run):
                var words = run.split(separator: " ", omittingEmptySubsequences: true)
                let spoken = run.trimmingCharacters(in: .whitespaces)
                if run.first != " ", let first = words.first, case .blank(let index, nil) = pieces.last {
                    pieces[pieces.count - 1] = .blank(index, trailing: words.count > 1 || run.last == " " ? first + " " : String(first))
                    words.removeFirst()
                }
                for (offset, word) in words.enumerated() {
                    var text = String(word)
                    if offset == 0, run.first == " " { text = " " + text }
                    if offset < words.count - 1 || run.last == " " { text += " " }
                    pieces.append(.word(text, spoken: offset == 0 ? spoken : nil))
                }
            }
        }
        return pieces
    }
}
