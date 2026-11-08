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

// MARK: Single, priority, select all

/// One full-width row per option, lettered A, B, C in the order she sees them, in round marks
/// for one answer and square ones for select-all, as the web letters them. While she answers, each row has a control to strike out a choice she has ruled out, and the
/// same control restores it; a long press offers the same.
private struct OptionList: View {
    let options: [QuestionOption]
    let order: [Int]
    let picked: [Int]
    let isMulti: Bool
    let revealed: Bool
    let isLocked: Bool
    let struck: Set<Int>
    let strike: ((Int) -> Void)?
    let pick: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(order.enumerated()), id: \.element) { position, original in
                let option = options[original]
                let selected = picked.contains(original)
                let isStruck = struck.contains(original)
                let state = revealed ? RevealState(selected: selected, correct: option.isCorrect) : nil
                Button {
                    // A struck choice cannot be picked until she restores it.
                    if !isStruck { pick(original) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: QBankSpacing.space4) {
                        ChoiceMark(shape: isMulti ? .square : .circle, letter: Self.letter(position), selected: selected, state: state, isStruck: isStruck)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                            StruckText(text: option.text, isStruck: isStruck)
                            if let tag = state?.tag {
                                ChoiceTag(text: tag, state: state)
                            }
                            if revealed, let why = option.why {
                                Reason(text: why)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, QBankSpacing.space4)
                    .padding(.leading, 14)
                    // Room for the strike control, which sits over the row's trailing edge.
                    .padding(.trailing, strike == nil ? 14 : StrikeButton.reserved)
                    .frame(minHeight: QBankSpacing.rowMin)
                    .choiceBox(selected: selected, state: state)
                    .animation(QBankMotion.select, value: isStruck)
                }
                .buttonStyle(ChoicePressStyle())
                .allowsHitTesting(!isLocked)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(isStruck ? "Struck out" : "")
                .accessibilityIdentifier("practice.option.\(original)")
                .contextMenu {
                    if let strike, !isLocked {
                        StrikeMenuItem(isStruck: isStruck) { strike(original) }
                    }
                }
                .overlay(alignment: .trailing) {
                    if let strike {
                        StrikeButton(option: original, letter: Self.letter(position), isStruck: isStruck) { strike(original) }
                            .padding(.trailing, QBankSpacing.space2)
                            .allowsHitTesting(!isLocked)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: struck)
    }

    /// "A", "B", ...: a choice's letter in the order she sees the choices.
    static func letter(_ position: Int) -> String {
        String(UnicodeScalar(UInt8(65 + position % 26)))
    }
}

/// A choice's text, crossed out and dimmed while she has it struck out.
private struct StruckText: View {
    let text: String
    let isStruck: Bool
    @Environment(\.self) private var environment

    var body: some View {
        Text(text)
            .qbankFont(.body)
            .strikethrough(isStruck, color: Color(QBankColor(.text3).resolve(in: environment)))
            .foregroundStyle(.qbank(isStruck ? .text3 : .text1))
    }
}

/// The control at the end of a choice that strikes it out, and restores it once struck: "Strike
/// out B", "Restore B". The mark is an X. A struck-through S read as an unknown mark.
private struct StrikeButton: View {
    /// The room it takes at the row's trailing edge, inset included.
    static let reserved: CGFloat = 52

    /// The choice's original index.
    let option: Int
    let letter: String
    let isStruck: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isStruck ? "arrow.counterclockwise" : "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.qbank(isStruck ? .tint : .text3))
                .frame(width: QBankSpacing.rowMin, height: QBankSpacing.rowMin)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStruck ? "Restore \(letter)" : "Strike out \(letter)")
        .accessibilityIdentifier("practice.strike.\(option)")
    }
}

/// "Strike out" or "Restore" in a choice's long-press menu.
private struct StrikeMenuItem: View {
    let isStruck: Bool
    let action: () -> Void

    var body: some View {
        if isStruck {
            Button("Restore", systemImage: "arrow.counterclockwise", action: action)
        } else {
            Button("Strike out", systemImage: "xmark", action: action)
        }
    }
}

/// The round or square mark at the start of a choice, with its letter: empty, filled with the
/// tint when picked, and after checking, the pick turns right or wrong and a missed answer gets a
/// dashed outline. A struck choice's letter is crossed out and its outline fades.
private struct ChoiceMark: View {
    enum Shape { case circle, square }

    let shape: Shape
    let letter: String
    let selected: Bool
    let state: RevealState?
    let isStruck: Bool
    @Environment(\.self) private var environment

    var body: some View {
        ZStack {
            if let fill {
                base.fill(.qbank(fill))
                if let state {
                    Image(systemName: state == .wrong ? "xmark" : "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.qbank(.textOnTint))
                } else {
                    letterText(.textOnTint)
                }
            } else if state == .missed {
                base.stroke(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [3, 2.5]))
                letterText(.correct)
            } else {
                base.fill(.qbank(.surface))
                base.stroke(.qbank(isStruck ? .separator : .separatorStrong), lineWidth: QBankBorder.emphasis)
                letterText(isStruck ? .text3 : .text2)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func letterText(_ color: QBankColorToken) -> some View {
        Text(letter)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .strikethrough(isStruck, color: Color(QBankColor(color).resolve(in: environment)))
            .foregroundStyle(.qbank(color))
    }

    private var base: AnyShape {
        shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var fill: QBankColorToken? {
        switch state {
        case nil: selected ? .tint : nil
        case .correct: .correct
        case .wrong: .wrong
        case .missed, .dim: nil
        }
    }
}

/// "YOUR ANSWER - CORRECT", "MISSED": the small uppercase tag under a checked choice.
private struct ChoiceTag: View {
    let text: String
    let state: RevealState?

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .qbankFont(.caption2, weight: .semibold, trackingEm: QBankTextStyle.capsTrackingEm)
            .foregroundStyle(.qbank(color))
    }

    private var color: QBankColorToken {
        switch state {
        case .correct, .missed: .correct
        case .wrong: .wrong
        case .dim, nil: .text2
        }
    }
}

/// Why a choice is right or wrong.
private struct Reason: View {
    let text: String

    var body: some View {
        Text(text)
            .qbankFont(.readingSmall)
            .foregroundStyle(.qbank(.text2))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Correct match: Fidelity" under a wrong pick.
private struct CorrectAnswer: View {
    let label: String
    let text: String

    var body: some View {
        (Text("\(label): ").fontWeight(.semibold).foregroundStyle(.qbank(.correct)) + Text(text).foregroundStyle(.qbank(.text2)))
            .qbankFont(.footnote, design: .default)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChoicePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(QBankMotion.press, value: configuration.isPressed)
    }
}

extension View {
    /// The card a choice sits in: plain, picked, or after checking right, wrong, a dashed
    /// missed answer, or faded.
    fileprivate func choiceBox(selected: Bool, state: RevealState?, cornerRadius: CGFloat = QBankRadius.sm) -> some View {
        modifier(ChoiceBox(selected: selected, state: state, cornerRadius: cornerRadius))
    }
}

private struct ChoiceBox: ViewModifier {
    let selected: Bool
    let state: RevealState?
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.qbank(fill), in: shape)
            .overlay {
                switch state {
                case .missed:
                    shape.strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
                case .correct:
                    shape.strokeBorder(.qbank(.correctBorder), lineWidth: QBankBorder.emphasis)
                case .wrong:
                    shape.strokeBorder(.qbank(.wrongBorder), lineWidth: QBankBorder.emphasis)
                case .dim, nil:
                    if selected && state == nil {
                        shape.strokeBorder(.qbank(.tint), lineWidth: QBankBorder.emphasis)
                    } else {
                        shape.strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.hairline)
                    }
                }
            }
            .opacity(state == .dim ? 0.72 : 1)
            .animation(QBankMotion.select, value: selected)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: selected ? .tintSoft : .surface
        case .correct, .missed: .correctSoft
        case .wrong: .wrongSoft
        case .dim: .surface
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
                AnswerCard(label: pair.left) {
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
private struct AnswerCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .qbankFont(.headline)
                .foregroundStyle(.qbank(.text1))
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

// MARK: Matrix

/// One card per row with a pill for each column, never a cramped table on a phone.
private struct MatrixList: View {
    let columns: [String]
    let rows: [MatrixRow]
    let selected: [String?]
    let revealed: Bool
    let isLocked: Bool
    let choose: (Int, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                let value = selected.indices.contains(row) ? selected[row] : nil
                AnswerCard(label: rows[row].text) {
                    FlowLayout(spacing: QBankSpacing.space3, lineSpacing: QBankSpacing.space3) {
                        ForEach(columns, id: \.self) { column in
                            let picked = value == column
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answer == column) : nil
                            Button {
                                choose(row, column)
                            } label: {
                                MatrixPill(text: column, picked: picked, state: state)
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrix.\(row).\(column)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
    }
}

private struct MatrixPill: View {
    let text: String
    let picked: Bool
    let state: RevealState?

    var body: some View {
        HStack(spacing: QBankSpacing.space3) {
            mark
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(text)
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(state == .dim ? .text3 : .text1))
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(.qbank(fill), in: .capsule)
        .overlay { border }
        .animation(QBankMotion.select, value: picked)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .correct, .missed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.correct))
        case .wrong:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.wrong))
        case .dim, nil:
            Circle()
                .fill(.qbank(.surface))
                .overlay {
                    if picked && state == nil {
                        Circle().strokeBorder(.qbank(.tint), lineWidth: 7)
                    } else {
                        Circle().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.emphasis)
                    }
                }
        }
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            Capsule().strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            Capsule().strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            Capsule().strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            Capsule().strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            Capsule().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

// MARK: Matrix, check all that fit

/// One card of check pills on iPhone. On iPad the same rows form a grid, because the runner's
/// column is wide enough for a header row.
private struct MatrixMultiList: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    var body: some View {
        if Device.isPad {
            MatrixMultiGrid(columns: columns, rows: rows, selected: selected, revealed: revealed, isLocked: isLocked, toggle: toggle)
        } else {
            MatrixMultiCards(columns: columns, rows: rows, selected: selected, revealed: revealed, isLocked: isLocked, toggle: toggle)
        }
    }
}

/// One card per row, with a check pill for each column.
private struct MatrixMultiCards: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                let picks = selected.indices.contains(row) ? selected[row] : []
                AnswerCard(label: rows[row].text) {
                    FlowLayout(spacing: QBankSpacing.space3, lineSpacing: QBankSpacing.space3) {
                        ForEach(columns.indices, id: \.self) { column in
                            let name = columns[column]
                            let picked = picks.contains(name)
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answers.contains(name)) : nil
                            Button {
                                toggle(row, name)
                            } label: {
                                MatrixMultiPill(text: name, picked: picked, state: state)
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrixmulti.\(row).\(name)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
    }
}

/// The wide table: column names wrap in a header, and each check cell stays 44 points unless the
/// row the runner proposes is too narrow for that, in which case the cells shrink so the row
/// stays on screen. The width comes from the layout proposal, so the cells exist on the first frame.
private struct MatrixMultiGrid: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MatrixColumnRow(columns: columns.count, pinsToBottom: true) {
                Color.clear.frame(height: 0).accessibilityHidden(true)
                ForEach(columns.indices, id: \.self) { column in
                    Text(columns[column])
                        .qbankFont(.subheadline, weight: .medium)
                        .foregroundStyle(.qbank(.text2))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("practice.matrixmulti.column.\(columns[column])")
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                let picks = selected.indices.contains(row) ? selected[row] : []
                VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                    MatrixColumnRow(columns: columns.count) {
                        Text(rows[row].text)
                            .qbankFont(.headline)
                            .foregroundStyle(.qbank(.text1))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns.indices, id: \.self) { column in
                            let name = columns[column]
                            let picked = picks.contains(name)
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answers.contains(name)) : nil
                            Button {
                                toggle(row, name)
                            } label: {
                                // A clear fill takes the column the layout proposes, so the check
                                // stays a 44-point square instead of shrinking to the mark.
                                Color.clear
                                    .frame(maxWidth: .infinity, minHeight: QBankSpacing.rowMin, maxHeight: QBankSpacing.rowMin)
                                    .overlay {
                                        MatrixMultiCell(picked: picked, state: state)
                                    }
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityLabel("\(rows[row].text), \(name)")
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrixmulti.\(row).\(name)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of the wide table. The first view is the row label and the rest are the columns, so a
/// header and the check cells share one width and line up. Extra room goes to the label. When the
/// row is tighter than a 44-point cell plus a short label, the cells shrink instead of scrolling.
private struct MatrixColumnRow: SwiftUI.Layout {
    var columns: Int
    var pinsToBottom = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? QBankLayout.contentMax
        let widths = columnWidths(available: available)
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: index == 0 ? widths.label : widths.cell, height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: available, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(available: bounds.width)
        var x = bounds.minX
        for index in subviews.indices {
            let slot = index == 0 ? widths.label : widths.cell
            let fitted = subviews[index].sizeThatFits(ProposedViewSize(width: slot, height: nil))
            let used = min(fitted.width, slot)
            // Columns are centered in the slot so a wrapping header lines up with its check cell.
            let inset = index == 0 ? 0 : (slot - used) / 2
            let y = pinsToBottom ? bounds.maxY - fitted.height : bounds.minY + (bounds.height - fitted.height) / 2
            subviews[index].place(
                at: CGPoint(x: x + inset, y: y),
                proposal: ProposedViewSize(width: used, height: fitted.height)
            )
            x += slot + QBankSpacing.space3
        }
    }

    /// Label width and check-cell width that add up to `available`, with one gap before each column.
    private func columnWidths(available: CGFloat) -> (label: CGFloat, cell: CGFloat) {
        guard columns > 0, available > 1 else { return (max(0, available), 0) }
        let gap = QBankSpacing.space3
        let room = max(0, available - CGFloat(columns) * gap)
        let cell = QBankSpacing.rowMin
        let cells = CGFloat(columns) * cell
        let minLabel: CGFloat = 96
        if room >= minLabel + cells { return (room - cells, cell) }
        let label = min(minLabel, room * 0.5)
        return (max(0, label), max(0, (room - label) / CGFloat(columns)))
    }
}

/// The phone's check pill: the matrix pill, with a square box in place of the radio dot.
private struct MatrixMultiPill: View {
    let text: String
    let picked: Bool
    let state: RevealState?

    var body: some View {
        HStack(spacing: QBankSpacing.space3) {
            MatrixMultiMark(picked: picked, state: state)
                .frame(width: 22, height: 22)
            Text(text)
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(state == .dim ? .text3 : .text1))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(.qbank(fill), in: .capsule)
        .overlay { border }
        .animation(QBankMotion.select, value: picked)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            Capsule().strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            Capsule().strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            Capsule().strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            Capsule().strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            Capsule().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

/// One grid cell: the same fill and border as a check pill, held to a square.
private struct MatrixMultiCell: View {
    let picked: Bool
    let state: RevealState?

    var body: some View {
        MatrixMultiMark(picked: picked, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.qbank(fill), in: .rect(cornerRadius: QBankRadius.xs, style: .continuous))
            .overlay { border }
            .animation(QBankMotion.select, value: picked)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

/// The square box. Checked is a filled box; after Check answer it takes the same correct, wrong,
/// missed, and neutral marks as the radio, drawn as squares.
private struct MatrixMultiMark: View {
    let picked: Bool
    let state: RevealState?

    var body: some View {
        mark
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .correct, .missed:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.correct))
        case .wrong:
            Image(systemName: "xmark.square.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.wrong))
        case .dim, nil:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.qbank(picked && state == nil ? .tint : .surface))
                .overlay {
                    if picked && state == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.qbank(.textOnTint))
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.emphasis)
                    }
                }
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
