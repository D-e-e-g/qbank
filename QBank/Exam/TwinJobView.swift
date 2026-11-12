import QBankDesign
import QBankKit
import SwiftUI

/// A twin job, opened from Exam setup's Write exam twins or its Exam twins list.
struct TwinJobRoute: Hashable {
    let course: CourseRef
    let jobID: String
    /// The job as the screen that opens this one last read it, shown until this one reads it.
    var seed: TwinJob?
}

/// Exam twins, as the web's twin job page: what the job does, its three steps as they go, Stop
/// while it runs, the failure or the sets it filed, and once done, Start exam on the twins.
struct TwinJobView: View {
    let app: AppModel
    @State private var model: TwinJobModel
    @State private var running: ExamRoute?
    @State private var exit: ExamExit?
    @State private var asksToStop = false
    @Environment(HomeNavigator.self) private var navigator: HomeNavigator?

    init(app: AppModel, route: TwinJobRoute) {
        self.app = app
        _model = State(initialValue: TwinJobModel(app: app, route: route))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.gapSection) {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    Text(Wording.line(model.course))
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                    if let problem = model.problem {
                        ProblemText(text: problem)
                    }
                    if let job = model.job {
                        summary(job)
                    }
                }
                if let job = model.job {
                    steps(job)
                    // Warnings show even when nothing was filed: every twin can be left out once its question has one.
                    if !job.sets.isEmpty || !job.warnings.isEmpty {
                        filed(job)
                    }
                } else if model.problem == nil {
                    Loading(title: "Loading the exam twins")
                }
            }
            .screenColumn()
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Exam twins")
        .screenColumnTitle()
        // Follows the job again whenever it goes back to work, and once it has ended, reads it once more.
        .task(id: model.isWorking) { await model.follow() }
        // Once the twins are ready, and again after an exam: whether an exam of hers is running.
        .task(id: model.needsRunningExam) { await model.readRunningExam() }
        .refreshable { await model.load() }
        .confirmSheet(
            isPresented: $asksToStop,
            title: "Stop the exam twins?",
            message: "QBank stops writing them. Your questions, sets and folders stay as they are.",
            confirm: "Stop",
            cancel: "Keep going",
            identifier: "twins.stopSheet"
        ) {
            Task { await model.stop() }
        }
        .confirmSheet(
            isPresented: $model.asksToReplace,
            title: "Start a new exam?",
            message: "The exam in progress ends now. What you answered on it is scored, and the rest score 0.",
            confirm: "Start new exam",
            isDestructive: false,
            identifier: "twins.replaceSheet"
        ) {
            open { await model.startReplacing() }
        }
        .fullScreenCover(item: $running, onDismiss: closed) { route in
            ExamView(app: app, examID: route.id, kind: model.course.kind) { how in
                exit = how
                running = nil
            }
        }
    }

    /// The count and folders, the job's note, how it ended, and its one action.
    private func summary(_ job: TwinJob) -> some View {
        QBankCard {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Twins.count(job))
                        .qbankFont(.title3, weight: .bold)
                        .foregroundStyle(.qbank(.text1))
                    QBankDetailText(Twins.scope(job))
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("twins.count")
                Text(job.note)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text1))
                    .accessibilityIdentifier("twins.note")
                if let failure = job.failure {
                    ProblemText(text: failure)
                } else if job.status == .cancelled {
                    Text(Twins.stopped)
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                        .accessibilityIdentifier("twins.stopped")
                }
                if let problem = model.actionProblem ?? model.runningProblem {
                    ProblemText(text: problem)
                }
                if model.isDone {
                    Button {
                        open { await model.start() }
                    } label: {
                        ButtonLabel(text: "Start exam on the twins", isBusy: model.isStarting)
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .disabled(!model.canStart)
                    .padding(.top, QBankSpacing.space1)
                    .accessibilityIdentifier("twins.start")
                } else if Twins.isRunning(job) {
                    Button {
                        asksToStop = true
                    } label: {
                        ButtonLabel(text: "Stop", isBusy: model.isStopping)
                    }
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .disabled(model.isStopping || model.needsConnection)
                    .padding(.top, QBankSpacing.space1)
                    .accessibilityIdentifier("twins.stop")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Read your questions, Exam twins, File the twins: each with its mark and how far it is.
    private func steps(_ job: TwinJob) -> some View {
        QBankListGroup(header: "Steps", footer: Twins.isRunning(job) ? "You can leave this screen. QBank keeps writing them, and they show under Exam twins on Exam setup." : nil) {
            ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in
                TwinStepRow(step: step)
                    .accessibilityIdentifier("twins.step.\(step.key)")
            }
        }
    }

    /// The exam sets filed so far, and the job's warnings.
    private func filed(_ job: TwinJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QBankSectionHeader("Filed")
                .padding(.horizontal, QBankSpacing.space5)
            if job.sets.isEmpty {
                EmptyCard(message: Twins.nothingFiled, systemImage: "tray")
                    .accessibilityIdentifier("twins.nothingFiled")
            } else {
                QBankListGroup {
                    ForEach(job.sets) { set in
                        QBankListRow(set.title, detail: Twins.filed(set))
                            .accessibilityIdentifier("twins.filed.\(set.setID)")
                    }
                }
            }
            ForEach(Array(job.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                    .padding(.horizontal, QBankSpacing.space5)
                    .accessibilityIdentifier("twins.warning")
            }
        }
    }

    /// Opens the exam a start gave, full screen.
    private func open(_ start: @escaping () async -> Exam?) {
        Task {
            if let exam = await start() {
                running = ExamRoute(id: exam.id)
            }
        }
    }

    /// After the exam's full screen closed: she may have asked for Review or the course.
    private func closed() {
        model.examClosed()
        switch exit {
        case .openReview:
            navigator?.open(StudyRoute.review(model.course))
        case .backToCourse:
            // Past Exam setup, which opened this screen.
            navigator?.back(2)
        case .done, nil:
            break
        }
        exit = nil
    }
}

/// A step of the job: its mark, its label, and how far it is, as the web words it.
private struct TwinStepRow: View {
    let step: TwinJob.Step

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            mark
                .frame(width: 24)
            Text(step.label)
                .qbankFont(.body)
                .foregroundStyle(.qbank(step.state == .todo ? .text3 : .text1))
                .frame(maxWidth: .infinity, alignment: .leading)
            let progress = Twins.progress(step)
            if !progress.isEmpty {
                Text(progress)
                    .qbankFont(.subheadline, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.qbank(tone))
            }
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var mark: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.qbank(.correct))
        case .current:
            ProgressView()
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.qbank(.wrong))
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(.title3)
                .foregroundStyle(.qbank(.text4))
        default:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.qbank(.separatorStrong))
        }
    }

    /// Done in green, a failure in red, a stopped step quiet, the one running in the tint.
    private var tone: QBankColorToken {
        switch step.state {
        case .done: .correct
        case .failed: .wrong
        case .cancelled: .text3
        default: .tint
        }
    }
}
