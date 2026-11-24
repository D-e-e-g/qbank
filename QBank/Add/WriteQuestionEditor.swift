import QBankDesign
import SwiftUI

/// One question of the set she is writing: its kind, its text, its choices with the right one marked,
/// and an optional explanation. `number` counts from 1 and names its fields for VoiceOver and tests.
struct WriteQuestionEditor: View {
    let number: Int
    let question: QuestionDraft
    /// What the import check refused in this question, in her words.
    let problems: [String]
    let canRemove: Bool
    let edit: ((inout QuestionDraft) -> Void) -> Void
    let remove: () -> Void

    private var prefix: String { "write.q\(number)" }

    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            HStack {
                Text("Question \(number)")
                    .qbankFont(.headline)
                    .foregroundStyle(.qbank(.text1))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canRemove {
                    Button("Remove", action: remove)
                        .buttonStyle(.qbank(.quiet, size: .small))
                        .accessibilityLabel("Remove question \(number)")
                        .accessibilityIdentifier("\(prefix).remove")
                }
            }
            ForEach(problems, id: \.self) { problem in
                ProblemText(text: problem.prefix(1).uppercased() + problem.dropFirst())
                    .accessibilityIdentifier("\(prefix).problem")
            }
            QBankSegmentedControl(
                "Kind of question \(number)",
                selection: Binding(get: { question.kind }, set: { kind in edit { $0.kind = kind } }),
                options: QuestionDraft.Kind.allCases.map { .init($0, $0.label) }
            )
            .accessibilityIdentifier("\(prefix).kind")
            LabeledField(label: "Question") {
                TextField("What is asked", text: Binding(get: { question.ask }, set: { text in edit { $0.ask = text } }), axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.vertical, QBankSpacing.space2)
                    .accessibilityIdentifier("\(prefix).ask")
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldTitle("Choices")
                VStack(spacing: QBankSpacing.space2) {
                    if question.kind == .single {
                        ForEach(Array(question.choices.enumerated()), id: \.element.id) { position, choice in
                            choiceRow(position: position, choice: choice)
                        }
                    } else {
                        ForEach(Array(QuestionDraft.trueFalseChoices.enumerated()), id: \.offset) { position, text in
                            fixedRow(position: position, text: text)
                        }
                    }
                }
                if question.canAddChoice {
                    Button {
                        edit { $0.addChoice() }
                    } label: {
                        Label("Add a choice", systemImage: "plus")
                    }
                    .buttonStyle(.qbank(.plain, size: .medium))
                    .accessibilityIdentifier("\(prefix).addChoice")
                }
                FieldHint(question.kind == .single ? "Tap the circle beside the right choice. Empty choices are left out." : "Tap the circle beside the right answer.")
            }
            LabeledField(label: "Explanation (optional)", hint: "Shown after the answer.") {
                TextField("Why the right choice is right", text: Binding(get: { question.explanation }, set: { text in edit { $0.explanation = text } }), axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.vertical, QBankSpacing.space2)
                    .accessibilityIdentifier("\(prefix).explanation")
            }
        }
        .padding(QBankSpacing.space4)
        .background(.qbank(.surfaceRaised), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
                .strokeBorder(.qbank(problems.isEmpty ? .separator : .wrongBorder), lineWidth: problems.isEmpty ? QBankBorder.hairline : QBankBorder.regular)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(prefix)
    }

    private func mark(_ position: Int) -> some View {
        let isRight = question.right == position
        return Button {
            edit { $0.right = position }
        } label: {
            Image(systemName: isRight ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(.qbank(isRight ? .correct : .text3))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choice \(MakeWording.letter(position)) is the right one")
        .accessibilityAddTraits(isRight ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("\(prefix).right.\(position)")
    }

    private func choiceRow(position: Int, choice: QuestionDraft.Choice) -> some View {
        HStack(spacing: QBankSpacing.space1) {
            mark(position)
            TextField(
                "Choice \(MakeWording.letter(position))",
                text: Binding(
                    get: { choice.text },
                    set: { text in
                        edit { draft in
                            if draft.choices.indices.contains(position) { draft.choices[position].text = text }
                        }
                    }),
                axis: .vertical
            )
            .lineLimit(1...4)
            .qbankFont(.body)
            .foregroundStyle(.qbank(.text1))
            .accessibilityIdentifier("\(prefix).choice.\(position)")
            if question.canRemoveChoice {
                Button {
                    edit { $0.removeChoice(at: position) }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.title3)
                        .foregroundStyle(.qbank(.text3))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove choice \(MakeWording.letter(position))")
                .accessibilityIdentifier("\(prefix).removeChoice.\(position)")
            }
        }
        .padding(.leading, QBankSpacing.space1)
        .padding(.trailing, QBankSpacing.space1)
        .frame(minHeight: QBankButtonStyle.Size.large.minHeight)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous).strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular))
    }

    private func fixedRow(position: Int, text: String) -> some View {
        HStack(spacing: QBankSpacing.space1) {
            mark(position)
            Text(text)
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, QBankSpacing.space1)
        .frame(minHeight: QBankButtonStyle.Size.large.minHeight)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous).strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular))
    }
}
