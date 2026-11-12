import QBankDesign
import QBankKit
import SwiftUI

/// An exam, full screen over the tabs: End exam, the question count over the weeks, the timer,
/// one question at a time with Skip for now and Submit and continue, then the result. Swipe-down
/// does not close it, so only End exam ends it. An end the server has not confirmed leaves only
/// its one button, which asks again. The timer keeps counting from the server's clock while she is
/// away; coming back checks it with the server.
struct ExamView: View {
    @State private var model: ExamModel
    @State private var asksToEnd = false
    @Environment(\.scenePhase) private var scenePhase
    let close: (ExamExit) -> Void
    private let frozen: FrozenView
    /// Whether the exam is over a course or a topic, which its result's way back names.
    private let kind: CourseKind

    init(app: AppModel, examID: String, kind: CourseKind = .course, close: @escaping (ExamExit) -> Void) {
        _model = State(initialValue: ExamModel(app: app, examID: examID))
        frozen = app.frozen
        self.kind = kind
        self.close = close
    }

    var body: some View {
        Group {
            if model.isEnded, let exam = model.exam, let result = exam.result {
                ExamResultView(exam: exam, result: result, kind: kind, close: close)
                    .transition(.opacity)
            } else {
                runner
            }
        }
        .animation(QBankMotion.reveal, value: model.isRunning)
        .animation(QBankMotion.reveal, value: model.isEnded)
        .animation(QBankMotion.reveal, value: model.pendingEnd)
        .qbankScreenBackground()
        .interactiveDismissDisabled()
        .frozenRunnerNote(frozen, clearing: model.isRunning ? RunnerNote.footerClearance : 0)
        .task { await model.load() }
        .task { await model.runClock() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.resync() }
        }
        .onChange(of: model.canEnd) {
            // Time ran out or the exam ended elsewhere while she was asked: nothing is left to end.
            if !model.canEnd { asksToEnd = false }
        }
        .confirmSheet(
            isPresented: $asksToEnd,
            title: "End the exam now?",
            message: model.endMessage,
            confirm: "End exam",
            cancel: "Keep going",
            identifier: "exam.endSheet"
        ) {
            Task { await model.end(.left) }
        }
    }

    /// On a question: not loading, ended, or left with only an end to confirm.
    private var isOnQuestion: Bool {
        model.isRunning && model.pendingEnd == nil
    }

    private var runner: some View {
        RunnerShell(count: isOnQuestion ? model.countText : "", title: model.title, progress: model.progress) {
            if isOnQuestion {
                Button("End exam") {
                    // Only End exam leaves a running exam, so the frozen view's way out is here:
                    // back to the screen under it with the note, and the exam goes on as it was.
                    if frozen.refuses() {
                        close(.done)
                    } else {
                        asksToEnd = true
                    }
                }
                    .buttonStyle(.qbank(.plain, size: .small))
                    .disabled(!model.canEnd)
                    .accessibilityIdentifier("exam.end")
            } else {
                RunnerCloseButton { close(.done) }
            }
        } trailing: {
            if model.isRunning {
                QBankTimerPill(secondsRemaining: Int(model.secondsLeft.rounded(.up)), compact: true)
                    // Inset as far as End exam's label is on the other side: the small button's 12pt.
                    .padding(.trailing, QBankButtonStyle.Size.small.horizontalPadding)
                    .accessibilityIdentifier("exam.timer")
            } else {
                EmptyBarItem()
            }
        } content: {
            content
        } footer: {
            if let reason = model.pendingEnd {
                Button {
                    Task { await model.retryEnd() }
                } label: {
                    ButtonLabel(text: reason == .left ? "End exam" : "Finish exam", isBusy: model.isBusy)
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(model.isBusy)
                .answersWhenFrozen(frozen)
                .accessibilityIdentifier("exam.finishPending")
            } else if model.isRunning, model.item != nil {
                HStack(spacing: QBankSpacing.space3) {
                    Button("Skip for now") {
                        Task { await model.skip() }
                    }
                    .buttonStyle(.qbank(.quiet, size: .large, fullWidth: true))
                    .disabled(!model.isAnswering)
                    .accessibilityIdentifier("exam.skip")
                    Button(model.isLastPending ? "Finish exam" : "Submit and continue") {
                        Task { await model.submit() }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .disabled(!model.canSubmit)
                    .answersWhenFrozen(frozen)
                    .accessibilityIdentifier("exam.submit")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            RunnerNote(text: "Loading the exam.")
        case .failed(let problem):
            RunnerNote(text: problem)
        case .running(.endPending(let reason, let problem, _)):
            PendingEndPage(note: model.pendingEndNote(reason), problem: problem)
        case .running, .ended:
            if let question = model.question, let item = model.item {
                ExamQuestionPage(model: model, question: question, item: item)
                    .id(model.index)
            } else {
                RunnerNote(text: "This exam has no questions.")
            }
        }
    }
}

/// One exam question: the notices, format and topic, stem, exhibits, ask, her answer, and the
/// guess flag. No feedback until the end.
private struct ExamQuestionPage: View {
    let model: ExamModel
    let question: Question
    let item: ExamModel.Item
    @Environment(\.runnerScroll) private var scroll

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            if model.isWaiting {
                WaitingBanner()
            }
            if model.skippedLeft > 0 {
                SkippedNotice(
                    left: model.skippedLeft,
                    isFirst: model.wrappedTo == model.index,
                    isBusy: !model.isAnswering
                ) {
                    Task { await model.end(.finished) }
                }
            }
            QuestionMeta(question: question) {
                if item.skipped {
                    Text("Skipped earlier")
                        .foregroundStyle(.qbank(.guess))
                }
            }
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
            AnswerArea(
                question: question,
                layout: item.layout,
                draft: item.draft,
                revealed: false,
                isLocked: !model.isAnswering,
                struck: item.struck,
                onStrike: { model.toggleStrike($0) }
            ) { draft in
                model.update(draft)
            }
            if item.draft != .unsupported {
                GuessToggle(isOn: Binding(get: { item.guessed }, set: { model.setGuessed($0) }))
                    .disabled(!model.isAnswering)
            }
        }
        .onAppear {
            scroll.scroll(to: RunnerScroll.top, anchor: .top)
        }
    }
}

/// An end the server has not confirmed: why the last try failed, and what is left to do. The
/// footer's one button asks again.
private struct PendingEndPage: View {
    let note: String
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let problem {
                ProblemText(text: problem)
            }
            Text(note)
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("exam.pendingEnd")
        }
    }
}

/// "2 skipped questions left. This is the first one." with Finish exam beside it.
private struct SkippedNotice: View {
    let left: Int
    let isFirst: Bool
    let isBusy: Bool
    let finish: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: QBankSpacing.space3) {
            Label {
                Text("\(Wording.count(left, "skipped question")) left.\(isFirst ? " This is the first one." : "")")
                    .foregroundStyle(.qbank(.text1))
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.qbank(.tint))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Finish exam", action: finish)
                .buttonStyle(.qbank(.plain, size: .small))
                .disabled(isBusy)
                .accessibilityIdentifier("exam.finishSkipped")
        }
        .qbankFont(.subheadline)
        .padding(.vertical, QBankSpacing.space3)
        .padding(.horizontal, 14)
        .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exam.skippedNotice")
    }
}
