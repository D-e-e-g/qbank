import QBankDesign
import QBankKit
import SwiftUI

/// The set result: how many fully right, points and time, a bar split into fully right, partly
/// right and missed, the counts in tiles with the bar's colors, the score by clinical judgment step
/// with a meter each, and every question, which opens in place with its stem, rationale and
/// takeaway, without her marks.
struct PracticeResultView: View {
    let result: PracticeResult
    var kind: CourseKind = .course
    let done: () -> Void
    @State private var expanded: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space7) {
                head
                stats
                section("By clinical judgment step") {
                    QBankListGroup {
                        ForEach(result.steps, id: \.label) { step in
                            ResultStepRow(label: step.label, right: step.right, total: step.total)
                        }
                    }
                }
                section("Questions") {
                    QBankListGroup {
                        ForEach(result.rows, id: \.number) { row in
                            ResultQuestionRow(row: row, isExpanded: expanded.contains(row.number)) {
                                withAnimation(QBankMotion.reveal) {
                                    if expanded.contains(row.number) {
                                        expanded.remove(row.number)
                                    } else {
                                        expanded.insert(row.number)
                                    }
                                }
                            }
                        }
                    }
                }
                Button("Back to \(Wording.words(kind).container)", action: done)
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("result.back")
            }
            .frame(maxWidth: QBankLayout.contentMax, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Device.gutter)
            .padding(.bottom, QBankSpacing.space10)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.qbank(.plain))
                    .accessibilityIdentifier("result.done")
            }
            .padding(.horizontal, QBankSpacing.space3)
            .frame(minHeight: QBankLayout.navBarHeight)
            .background(.qbank(.bg))
        }
        .qbankScreenBackground()
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("\(result.isReview ? "Review finished" : "Set finished") · \(result.title)", color: .text2)
            Text("\(result.fullyRight) of \(result.questionCount) fully right")
                .qbankFont(.largeTitle)
                .foregroundStyle(.qbank(.text1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("result.title")
            Text(Wording.resultPoints(result))
                .qbankFont(.callout)
                .monospacedDigit()
                .foregroundStyle(.qbank(.text2))
                .accessibilityIdentifier("result.points")
            ResultSplitBar(segments: [
                .init(count: result.fullyRight, color: .chartCorrect),
                .init(count: result.partial, color: .chartPartial),
                .init(count: result.missed, color: .chartWrong),
            ])
            .padding(.top, QBankSpacing.space4)
        }
        .padding(.top, QBankSpacing.space3)
    }

    private var stats: some View {
        Grid(horizontalSpacing: QBankSpacing.space3, verticalSpacing: QBankSpacing.space3) {
            GridRow {
                stat(result.fullyRight, "Fully right", .chartCorrect)
                stat(result.partial, "Partly right", .chartPartial)
            }
            GridRow {
                stat(result.missed, "Missed", .chartWrong)
                stat(result.guessed, "Guessed", .guess)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Score summary")
    }

    private func stat(_ value: Int, _ label: String, _ dot: QBankColorToken) -> some View {
        ResultTile(value: value, label: label, dot: dot, identifier: "result.stat.\(label)")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            QBankSectionHeader(title)
                .padding(.horizontal, QBankSpacing.space1)
            content()
        }
    }
}

/// A question in the result list: its number, topic, format and points, and its mark. A tap
/// opens it in place.
private struct ResultQuestionRow: View {
    let row: PracticeResult.Row
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: QBankSpacing.space4) {
                    Text("\(row.number)")
                        .qbankFont(.footnote, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(.qbank(.text2))
                        .frame(width: 24, height: 24)
                        .background(.qbank(.surfaceSunken), in: .circle)
                    VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                        Text(row.title)
                            .qbankFont(.body)
                            .foregroundStyle(.qbank(.text1))
                            .multilineTextAlignment(.leading)
                        Text(row.detail)
                            .qbankFont(.footnote)
                            .foregroundStyle(.qbank(.text3))
                        QBankTintedLabel(row.mark, systemImage: icon, tone: tone, style: .soft, size: .small)
                            .padding(.top, QBankSpacing.space2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
                .padding(.vertical, QBankSpacing.rowPaddingVertical)
                .frame(minHeight: QBankSpacing.rowMin)
                .contentShape(.rect)
            }
            .buttonStyle(.qbankRow)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("result.question.\(row.number)")
            if isExpanded {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    Prose(row.question.stem)
                    StemExhibits(question: row.question)
                    Text(row.question.ask)
                        .qbankFont(.readingSmall, weight: .semibold)
                        .foregroundStyle(.qbank(.text1))
                    Prose(row.question.rationale)
                    RationaleImages(question: row.question)
                    Prose(row.question.takeaway)
                        .padding(.vertical, 14)
                        .padding(.horizontal, QBankSpacing.space5)
                        .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                }
                .padding(.leading, 52)
                .padding(.trailing, QBankSpacing.rowPaddingHorizontal)
                .padding(.bottom, QBankSpacing.space5)
                .transition(.opacity)
            }
        }
    }

    private var tone: QBankTintedLabel.Tone {
        guard let score = row.score else { return .neutral }
        if row.guessed { return .guess }
        switch score.status {
        case .correct: return .correct
        case .partial: return .partial
        case .incorrect: return .wrong
        }
    }

    private var icon: String {
        guard let score = row.score else { return QBankAnswerStatus.unanswered.systemImage }
        if row.guessed { return QBankAnswerStatus.guessed.systemImage }
        switch score.status {
        case .correct: return QBankAnswerStatus.correct.systemImage
        case .partial: return QBankAnswerStatus.partial.systemImage
        case .incorrect: return QBankAnswerStatus.wrong.systemImage
        }
    }
}
