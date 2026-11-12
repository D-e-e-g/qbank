import QBankDesign
import QBankKit
import SwiftUI

// MARK: Single, priority, select all

/// One full-width row per option, lettered A, B, C in the order she sees them, in round marks
/// for one answer and square ones for select-all, as the web letters them. While she answers, each
/// row has a control to strike out a choice she has ruled out, and the same control restores it.
/// Touch and hold on a choice's words marks them with the highlighter; a plain tap picks it.
struct OptionList: View {
    let options: [QuestionOption]
    let order: [Int]
    let picked: [Int]
    let isMulti: Bool
    let revealed: Bool
    let isLocked: Bool
    let struck: Set<Int>
    let strike: ((Int) -> Void)?
    let pick: (Int) -> Void
    @Environment(\.highlighting) private var highlighting
    /// The first line's height, so the letter sits on it at every text size.
    @ScaledMetric(relativeTo: .body) private var firstLine: CGFloat = QBankTextStyle.body.lineHeight

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(order.enumerated()), id: \.element) { position, original in
                let option = options[original]
                let selected = picked.contains(original)
                let isStruck = struck.contains(original)
                let state = revealed ? RevealState(selected: selected, correct: option.isCorrect) : nil
                Button {
                    // A struck choice cannot be picked until she restores it, and a checked one not at all.
                    if !isStruck, !isLocked { pick(original) }
                } label: {
                    HStack(alignment: .top, spacing: QBankSpacing.space4) {
                        ChoiceMark(shape: isMulti ? .square : .circle, letter: Self.letter(position), selected: selected, state: state, isStruck: isStruck)
                            .offset(y: firstLine / 2 - ChoiceMark.size / 2)
                        VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                            MarkableText(
                                text: option.text, part: .answer(original), isStruck: isStruck,
                                markInset: MarkableText.tightInset, isAccessibilityElement: false
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                .buttonStyle(ChoicePressStyle(isPressable: !isLocked))
                // A checked choice still takes a touch where its words can be marked.
                .allowsHitTesting(!isLocked || highlighting != nil)
                .accessibilityLabel([option.text, state?.tag, revealed ? option.why : nil].compactMap(\.self).joined(separator: ", "))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(Self.value(isStruck: isStruck, marks: MarkableText.spoken(option.text, highlighting?.highlights[.answer(original)] ?? [])))
                .accessibilityIdentifier("practice.option.\(original)")
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

    /// "Struck out", her marks on its words, or both.
    static func value(isStruck: Bool, marks: String) -> String {
        [isStruck ? "Struck out" : "", marks].filter { !$0.isEmpty }.joined(separator: ". ")
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

/// The round or square mark at the start of a choice, with its letter: empty, filled with the
/// tint when picked, and after checking, the pick turns right or wrong and a missed answer gets a
/// dashed outline. An open choice's letter takes the accent on its pale step; a struck choice's
/// letter is crossed out and its outline fades.
private struct ChoiceMark: View {
    enum Shape { case circle, square }

    static let size: CGFloat = 24

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
            } else if state == nil, !isStruck {
                base.fill(.qbank(.tintSoft))
                letterText(.tint)
            } else {
                base.fill(.qbank(.surface))
                base.stroke(.qbank(isStruck ? .separator : .separatorStrong), lineWidth: QBankBorder.emphasis)
                letterText(isStruck ? .text3 : .text2)
            }
        }
        .frame(width: Self.size, height: Self.size)
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

/// "YOUR ANSWER - CORRECT", "MISSED": the small uppercase tag under a checked choice. Correct is
/// the darker green, which small text needs in light.
struct ChoiceTag: View {
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
        case .correct, .missed: .correctText
        case .wrong: .wrong
        case .dim, nil: .text2
        }
    }
}

/// Why a choice is right or wrong.
struct Reason: View {
    let text: String

    var body: some View {
        Text(text)
            .qbankFont(.readingSmall)
            .foregroundStyle(.qbank(.text2))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Correct match: Fidelity" under a wrong pick.
struct CorrectAnswer: View {
    let label: String
    let text: String

    var body: some View {
        (Text("\(label): ").fontWeight(.semibold).foregroundStyle(.qbank(.correctText)) + Text(text).foregroundStyle(.qbank(.text2)))
            .qbankFont(.footnote, design: .default)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A choice gives a little under the finger, unless it can no longer change.
struct ChoicePressStyle: ButtonStyle {
    var isPressable = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isPressable ? 0.99 : 1)
            .animation(QBankMotion.press, value: configuration.isPressed)
    }
}

extension View {
    /// The card a choice sits in: plain, picked, or after checking right, wrong, a dashed
    /// missed answer, or faded.
    func choiceBox(selected: Bool, state: RevealState?, cornerRadius: CGFloat = QBankRadius.sm) -> some View {
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
