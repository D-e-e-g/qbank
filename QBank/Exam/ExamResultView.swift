import QBankDesign
import QBankKit
import SwiftUI

/// An ended exam, as the web shows it (`apps/web/src/exam/ExamResult.tsx`): how many fully right,
/// points and minutes, partly right / missed / guessed / not answered, Open Review for the
/// practice questions it sent there, the score by folder and by clinical judgment step, and every
/// question with her answer and its explanation.
struct ExamResultView: View {
    let exam: Exam
    let result: ExamResult
    var kind: CourseKind = .course
    let close: (ExamExit) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space7) {
                head
                stats
                review
                if let byFolder = result.byFolder {
                    breakdown("By folder", rows: byFolder, detail: source)
                } else {
                    // An exam from before folders.
                    breakdown("By week", rows: result.byWeek, detail: source)
                }
                breakdown("By clinical judgment step", rows: result.byStep) { _ in nil }
                questions
                Button("Back to \(Wording.words(kind).container)") { close(.backToCourse) }
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("examResult.back")
            }
            .frame(maxWidth: QBankLayout.contentMax, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Device.gutter)
            .padding(.bottom, QBankSpacing.space10)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { close(.done) }
                    .buttonStyle(.qbank(.plain))
                    .accessibilityIdentifier("examResult.done")
            }
            .padding(.horizontal, QBankSpacing.space3)
            .frame(minHeight: QBankLayout.navBarHeight)
            .background(.qbank(.bg))
        }
        .qbankScreenBackground()
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("Exam result · \(Wording.folders(exam.weeks))\(exam.pool == .wrong ? " · Wrong questions only" : "")")
            Text("\(result.fullyRight) of \(result.questionCount) fully right")
                .qbankFont(.largeTitle)
                .foregroundStyle(.qbank(.text1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("examResult.title")
            Text(subtitle)
                .qbankFont(.callout)
                .monospacedDigit()
                .foregroundStyle(.qbank(.text2))
                .accessibilityIdentifier("examResult.points")
            if let practiceWeeks = exam.practiceWeeks, !practiceWeeks.isEmpty {
                Text(Wording.practiceFolders(practiceWeeks, before: false))
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .padding(.top, QBankSpacing.space2)
            }
        }
        .padding(.top, QBankSpacing.space3)
    }

    /// "9 of 13 points · 15 min", and how it ended when not by her finishing.
    private var subtitle: String {
        var line = "\(result.points) of \(result.maxPoints) points · \(result.minutesUsed) min"
        switch exam.endReason {
        case .timeout: line += " · Time ran out"
        case .left: line += " · Ended early"
        case .finished, nil: break
        }
        return line
    }

    private var stats: some View {
        HStack(spacing: QBankSpacing.space2) {
            stat(result.partial, "Partly right")
            stat(result.missed, "Missed")
            stat(result.guessed, "Guessed")
            stat(result.unanswered, "Not answered")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Score summary")
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .qbankFont(.title3, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.qbank(.text1))
            Text(label)
                .qbankFont(.caption1)
                .foregroundStyle(.qbank(.text3))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, QBankSpacing.space3)
        .padding(.horizontal, QBankSpacing.space1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("examResult.stat.\(label)")
    }

    @ViewBuilder
    private var review: some View {
        let bankWrong = result.examBankWrong
        if result.reviewCount > 0 || bankWrong > 0 {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                if result.reviewCount > 0 {
                    Button {
                        close(.openReview)
                    } label: {
                        Label("Open Review · \(result.reviewCount) from this exam", systemImage: "tray")
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("examResult.openReview")
                }
                if bankWrong > 0 {
                    Text(Self.bankWrongText(bankWrong))
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                        .accessibilityIdentifier("examResult.bankWrong")
                }
            }
        }
    }

    /// Exam-bank questions stay out of Review, so the result says where the wrong ones went.
    nonisolated static func bankWrongText(_ count: Int) -> String {
        let one = count == 1
        let lead = "\(count) exam-bank \(one ? "question" : "questions") you got wrong \(one ? "stays" : "stay") out of Review."
        return "\(lead) Turn on Wrong questions only to take \(one ? "it" : "them") again."
    }

    /// Under a folder in By folder: where its questions came from, once the course has an exam bank.
    private func source(_ label: String) -> String? {
        guard let practiceWeeks = exam.practiceWeeks else { return nil }
        return practiceWeeks.contains(label) ? "practice questions" : "exam bank"
    }

    @ViewBuilder
    private func breakdown(_ title: String, rows: [ExamResult.Breakdown], detail: @escaping (String) -> String?) -> some View {
        if !rows.isEmpty {
            section(title) {
                QBankListGroup {
                    ForEach(rows) { row in
                        HStack(spacing: QBankSpacing.space4) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                    .qbankFont(.subheadline, weight: .medium)
                                    .foregroundStyle(.qbank(.text1))
                                if let detail = detail(row.label) {
                                    Text(detail)
                                        .qbankFont(.footnote)
                                        .foregroundStyle(.qbank(.text3))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(row.right) of \(row.total)")
                                .qbankFont(.subheadline, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(.qbank(.text2))
                        }
                        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
                        .padding(.vertical, QBankSpacing.rowPaddingVertical)
                        .frame(minHeight: QBankSpacing.rowMin)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var questions: some View {
        let items = Dictionary(result.items.map { ($0.questionID, $0) }, uniquingKeysWith: { first, _ in first })
        return section("Questions") {
            QBankListGroup {
                ForEach(Array(exam.questions.enumerated()), id: \.element.id) { offset, question in
                    if let item = items[question.id] {
                        ExamResultQuestion(
                            number: offset + 1,
                            question: question,
                            item: item,
                            isExpanded: expanded.contains(question.id)
                        ) {
                            withAnimation(QBankMotion.reveal) {
                                if expanded.contains(question.id) {
                                    expanded.remove(question.id)
                                } else {
                                    expanded.insert(question.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            QBankSectionHeader(title)
                .padding(.horizontal, QBankSpacing.space1)
            content()
        }
    }
}

/// A question of the result: its number, topic, format and points, and its mark. A tap opens it
/// in place with her answer marked against the right one, the rationale and the takeaway.
private struct ExamResultQuestion: View {
    let number: Int
    let question: Question
    let item: ExamResult.Item
    let isExpanded: Bool
    let toggle: () -> Void

    private var answered: Bool { item.status != .unanswered }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: QBankSpacing.space4) {
                    Text("\(number)")
                        .qbankFont(.footnote, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(.qbank(.text2))
                        .frame(width: 24, height: 24)
                        .background(.qbank(.surfaceSunken), in: .circle)
                    VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                        Text(question.topic.isEmpty ? question.publicID : question.topic)
                            .qbankFont(.body)
                            .foregroundStyle(.qbank(.text1))
                            .multilineTextAlignment(.leading)
                        Text("\(Wording.format(question.type)) · \(item.points) of \(item.maxPoints)")
                            .qbankFont(.footnote)
                            .foregroundStyle(.qbank(.text3))
                        QBankStatusMark(mark.status, label: mark.label, variant: .pill, size: .small)
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
            .accessibilityIdentifier("examResult.question.\(number)")
            if isExpanded {
                detail
                    .padding(.leading, 52)
                    .padding(.trailing, QBankSpacing.rowPaddingHorizontal)
                    .padding(.bottom, QBankSpacing.space5)
                    .transition(.opacity)
            }
        }
    }

    private var detail: some View {
        let layout = item.shuffle ?? .plain
        let draft = item.response.flatMap { AnswerDraft(response: $0, body: question.body) } ?? AnswerDraft(body: question.body, layout: layout)
        return VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            Prose(question.stem)
            StemExhibits(question: question)
            Text(question.ask)
                .qbankFont(.readingSmall, weight: .semibold)
                .foregroundStyle(.qbank(.text1))
            if !answered {
                Text("Not answered. The right answer is marked below.")
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
            }
            AnswerArea(question: question, layout: layout, draft: draft, revealed: true, isLocked: true) { _ in }
            Prose(question.rationale)
            RationaleImages(question: question)
            Prose(question.takeaway)
                .padding(.vertical, 14)
                .padding(.horizontal, QBankSpacing.space5)
                .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        }
    }

    /// The server's word, "Correct" or "Not answered", and "Guessed - Partly correct" for a guess,
    /// as the web marks exam questions.
    private var mark: (status: QBankAnswerStatus, label: String) {
        let status: QBankAnswerStatus
        switch item.status {
        case .unanswered: return (.unanswered, item.label)
        case .correct: status = .correct
        case .partial: status = .partial
        case .incorrect: status = .wrong
        }
        return item.guessed ? (.guessed, "Guessed - \(item.label)") : (status, item.label)
    }
}
