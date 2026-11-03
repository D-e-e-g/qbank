import QBankDesign
import QBankKit
import SwiftUI

/// What the runner practices: a set from the Course screen, or the Review list.
struct PracticeRoute: Identifiable, Hashable {
    enum Source: Hashable {
        case set(id: String)
        /// The course's Review list under a filter, or only one of its questions.
        case review(filter: ReviewFilter, questionID: String?)
        /// A sample of a set being made, answered to check it. Her answer is not saved.
        case sample(jobID: String, sampleID: String)
    }

    let source: Source
    let courseID: String
    let title: String
    /// Whether the set is in a course or a topic, which the result's way back names.
    var kind: CourseKind = .course

    var id: String {
        switch source {
        case .set(let id): "set:\(id)"
        case .review(let filter, let questionID): "review:\(filter.rawValue):\(questionID ?? "")"
        case .sample(let jobID, let sampleID): "sample:\(jobID):\(sampleID)"
        }
    }
}

/// The practice runner, shown full screen over the tabs: one question at a time, Check answer,
/// the verdict with a reason on every choice, the rationale, then the set result. Swipe-down does
/// not close it, so a stray thumb never loses a half-answered question; ✕ closes. Answers waiting
/// on the phone to be sent show as a count at the top right, which opens Saved for offline.
struct PracticeView: View {
    @State private var model: PracticeModel
    @State private var showsWaiting = false
    @Environment(\.dismiss) private var dismiss
    /// Whether the set is in a course or a topic, which the result's way back names.
    private let kind: CourseKind

    init(app: AppModel, route: PracticeRoute) {
        _model = State(initialValue: PracticeModel(app: app, source: route.source, courseID: route.courseID, title: route.title))
        kind = route.kind
    }

    init(model: PracticeModel, kind: CourseKind = .course) {
        _model = State(initialValue: model)
        self.kind = kind
    }

    var body: some View {
        Group {
            if let result = model.result {
                PracticeResultView(result: result, kind: kind) { dismiss() }
                    .transition(.opacity)
            } else {
                runner
            }
        }
        .animation(QBankMotion.reveal, value: model.phase)
        .qbankScreenBackground()
        .task { await model.load() }
        .sheet(isPresented: $showsWaiting) {
            NavigationStack {
                SavedForOfflineView(app: model.app)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsWaiting = false }
                                .accessibilityIdentifier("savedForOffline.done")
                        }
                    }
            }
        }
    }

    private var runner: some View {
        RunnerShell(count: model.phase == .answering ? model.countText : "", title: model.title, progress: model.progress) {
            RunnerCloseButton { dismiss() }
        } trailing: {
            if model.waitingCount > 0 {
                Button { showsWaiting = true } label: {
                    QBankTintedLabel("\(model.waitingCount) waiting", systemImage: "arrow.up.circle", tone: .tint, size: .small)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Wording.waitingToSend(model.waitingCount))
                .accessibilityIdentifier("practice.waiting")
            } else {
                EmptyBarItem()
            }
        } content: {
            content
        } footer: {
            if model.phase == .answering {
                footer
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            RunnerNote(text: model.isReview ? "Loading Review." : "Loading the set.")
        case .failed(let problem):
            RunnerNote(text: problem)
        case .readOnly:
            RunnerNote(text: "Only she can answer questions. Her progress is read-only here.")
        case .answering, .finished:
            if let question = model.question, let attempt = model.attempt {
                QuestionPage(model: model, question: question, attempt: attempt)
                    .id(model.index)
            } else {
                RunnerNote(text: model.isReview ? "Nothing to review here right now." : "This set has no questions.")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isRevealed || model.attempt?.draft == .unsupported {
            Button(model.isLast ? "See results" : "Next question") {
                model.next()
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .accessibilityIdentifier("practice.next")
        } else if model.attempt != nil {
            Button("Check answer") {
                Task { await model.check() }
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(!model.canCheck)
            .accessibilityIdentifier("practice.check")
        }
    }
}

/// One question: format and topic, stem, exhibits, ask, then her answer. After Check answer, the
/// verdict sits right under the ask, every choice carries its reason, and the rationale, key
/// takeaway and terms follow.
private struct QuestionPage: View {
    let model: PracticeModel
    let question: Question
    let attempt: PracticeModel.Attempt
    @Environment(\.runnerScroll) private var scroll

    private var revealed: Bool { attempt.score != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            QuestionMeta(question: question)
            Text(question.stem)
                .qbankFont(.stem)
                .foregroundStyle(.qbank(.text1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("practice.stem")
            StemExhibits(question: question)
            Text(question.ask)
                .qbankFont(.headline)
                .foregroundStyle(.qbank(.text1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let feedback = attempt.feedback {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    if model.isWaitingToSend {
                        Group {
                            if model.app.offline?.keepsAnswers == false {
                                OfflineBanner.answerNotKept
                            } else {
                                OfflineBanner.answerSaved
                            }
                        }
                        .accessibilityIdentifier("practice.savedOnPhone")
                    }
                    FeedbackBox(feedback: feedback, guessed: attempt.guessed)
                }
                .id(RunnerScroll.feedback)
            }
            AnswerArea(
                question: question,
                layout: attempt.layout,
                draft: attempt.draft,
                revealed: revealed,
                isLocked: revealed || model.isChecking,
                struck: attempt.struck,
                onStrike: { model.toggleStrike($0) }
            ) { draft in
                model.update(draft)
            }
            if !revealed, attempt.draft != .unsupported {
                GuessToggle(isOn: Binding(get: { attempt.guessed }, set: { model.setGuessed($0) }))
                    .disabled(model.isChecking)
            }
            if revealed {
                RationaleSections(question: question)
                    .padding(.top, QBankSpacing.space2)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: revealed) { _, now in now }
        .onAppear {
            scroll.scroll(to: RunnerScroll.top, anchor: .top)
        }
        .onChange(of: revealed) { _, now in
            guard now else { return }
            withAnimation(QBankMotion.reveal) {
                scroll.scroll(to: RunnerScroll.feedback)
            }
            AccessibilityNotification.Announcement(attempt.feedback?.label ?? "").post()
        }
    }
}

/// The verdict under the question: Correct, Partly correct or Not correct, the points of a
/// multi-part answer, the scoring rule, and whether it was a guess.
private struct FeedbackBox: View {
    let feedback: Feedback
    let guessed: Bool

    private var score: Score { feedback.score }

    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space2) {
            Label {
                Text(feedback.label)
            } icon: {
                Image(systemName: icon)
                    .fontWeight(.semibold)
            }
            .qbankFont(.headline)
            .foregroundStyle(.qbank(tone))
            Group {
                if let points = feedback.pointsText {
                    Text(points)
                }
                if let rule = feedback.ruleText {
                    Text(rule)
                }
                if guessed {
                    Text("Flagged as a guess")
                }
            }
            .qbankFont(.subheadline)
            .foregroundStyle(.qbank(.text1))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, QBankSpacing.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(soft), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                .strokeBorder(.qbank(border), lineWidth: QBankBorder.regular)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("practice.feedback")
    }

    private var icon: String {
        switch score.status {
        case .correct: "checkmark.circle"
        case .partial: "minus.circle"
        case .incorrect: "xmark.circle"
        }
    }

    private var tone: QBankColorToken {
        switch score.status {
        case .correct: .correct
        case .partial: .partial
        case .incorrect: .wrong
        }
    }

    private var soft: QBankColorToken {
        switch score.status {
        case .correct: .correctSoft
        case .partial: .partialSoft
        case .incorrect: .wrongSoft
        }
    }

    private var border: QBankColorToken {
        switch score.status {
        case .correct: .correctBorder
        case .partial: .partialBorder
        case .incorrect: .wrongBorder
        }
    }
}

/// After Check answer: the rationale with its images, the key takeaway, and the question's terms.
private struct RationaleSections: View {
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                Kicker("Rationale")
                Prose(question.rationale)
                    .accessibilityIdentifier("practice.rationale")
                RationaleImages(question: question)
                    .padding(.top, QBankSpacing.space4)
            }
            VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                Kicker("Key takeaway")
                Prose(question.takeaway)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, QBankSpacing.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
            if !question.terms.isEmpty {
                VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                    Kicker("Terms in this question")
                    ForEach(Array(question.terms.enumerated()), id: \.offset) { offset, term in
                        VStack(alignment: .leading, spacing: QBankSpacing.space1) {
                            Text(term.term)
                                .qbankFont(.headline)
                                .foregroundStyle(.qbank(.text1))
                            Text(term.meaning)
                                .qbankFont(.subheadline)
                                .foregroundStyle(.qbank(.text2))
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            if offset > 0 {
                                Rectangle()
                                    .fill(.qbank(.separator))
                                    .frame(height: QBankBorder.hairline)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// A small uppercase label over a section: "RATIONALE", "KEY TAKEAWAY".
struct Kicker: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .qbankFont(.footnote, weight: .semibold, trackingEm: QBankTextStyle.capsTrackingEm)
            .foregroundStyle(.qbank(.text3))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rationale and takeaway text, in the smaller reading size.
struct Prose: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .qbankFont(.readingSmall)
            .foregroundStyle(.qbank(.text1))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
