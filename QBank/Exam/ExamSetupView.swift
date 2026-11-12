import QBankDesign
import QBankKit
import SwiftUI

/// An exam to open full screen: one just started, her running one, or a past one's result.
struct ExamRoute: Identifiable, Hashable {
    let id: String
}

/// How she left an exam's full screen.
enum ExamExit {
    /// Done: back where she opened it.
    case done
    case backToCourse
    case openReview
}

/// Exam setup: Resume her running exam, Wrong questions only, the folders to tick by exam page,
/// the summary of what Start draws, Start exam, Write exam twins and her twin jobs for the account
/// that may make questions, and her past exams.
struct ExamSetupView: View {
    let app: AppModel
    @State private var model: ExamSetupModel
    @State private var running: ExamRoute?
    @State private var exit: ExamExit?
    /// The past exam she asked to delete, while its warning is open.
    @State private var deleting: DeleteRequest?
    /// The pick whose plan is taking a moment, so the last plan is dimmed rather than read as its.
    @State private var slowPick: ExamSetupModel.Pick?
    @Environment(HomeNavigator.self) private var navigator: HomeNavigator?

    init(app: AppModel, route: ExamSetupRoute) {
        self.app = app
        _model = State(initialValue: ExamSetupModel(app: app, route: route))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.gapSection) {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    Text(Wording.line(model.course))
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                    if model.needsConnection {
                        OfflineBanner.examsNeedConnection
                            .accessibilityIdentifier("exam.needsConnection")
                    }
                    if let problem = model.problem {
                        ProblemText(text: problem)
                    }
                    if let exam = model.running.exam {
                        runningExam(exam)
                    }
                }
                content
            }
            .screenColumn()
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Exam")
        .screenColumnTitle()
        .refreshable { await model.load() }
        .reloadsWithConnection(app) { await model.load() }
        .task { await model.load() }
        .onChange(of: app.deletions.revision) {
            // A past exam deleted here or brought back with Undo, or a folder deleted: the lists change.
            Task { await model.load() }
        }
        .deleteSheet(app: app, request: $deleting)
        .sensoryFeedback(.selection, trigger: model.ticked)
        .onChange(of: model.pick) {
            // Not cancelled by the next tick: a late answer is dropped by the model instead.
            Task { await model.readPlan() }
        }
        .task(id: model.pick) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { slowPick = model.pick }
        }
        .confirmSheet(
            isPresented: $model.asksToReplace,
            title: "Start a new exam?",
            message: "The exam in progress ends now. What you answered on it is scored, and the rest score 0.",
            confirm: "Start new exam",
            isDestructive: false,
            identifier: "exam.replaceSheet"
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

    @ViewBuilder
    private var content: some View {
        if let setup = model.setup {
            if setup.folders.isEmpty {
                EmptyCard(message: "This \(model.words.container) has no questions yet. An exam draws from the sets in the folders you tick.", systemImage: "timer")
            } else {
                wrongOnlySwitch
                folderPicker
                summary
            }
            if let jobs = model.twinJobs, !jobs.isEmpty {
                twinJobs(jobs)
            }
            if !setup.folders.isEmpty {
                pastExams(setup.exams)
            }
        } else if model.problem == nil, !model.needsConnection {
            Loading(title: "Loading the exam setup")
        }
    }

    private func runningExam(_ exam: ExamSummary) -> some View {
        QBankListGroup {
            Button {
                running = ExamRoute(id: exam.id)
            } label: {
                QBankListRow(
                    "Exam in progress",
                    detail: model.runningLine(exam),
                    systemImage: "timer",
                    showsChevron: true
                ) {
                    Text("Resume")
                        .qbankFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.qbank(.tint))
                }
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("exam.resume")
        }
    }

    private var wrongOnlySwitch: some View {
        QBankListGroup {
            Toggle(isOn: Binding(get: { model.wrongOnly }, set: { on in app.frozen.perform { model.wrongOnly = on } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wrong questions only")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                    Text("Last answer not fully right")
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                }
            }
            .tint(QBankColor(.tint))
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .frame(minHeight: QBankSpacing.rowMin)
            .accessibilityIdentifier("exam.wrongOnly")
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            QBankSectionHeader("Folders this exam covers")
                .padding(.horizontal, QBankSpacing.space5)
            if let line = model.preselectedLine {
                Text(line)
                    .qbankFont(.footnote, weight: .semibold)
                    .foregroundStyle(.qbank(.tint))
                    .padding(.horizontal, QBankSpacing.space5)
                    .padding(.bottom, QBankSpacing.space1)
                    .accessibilityIdentifier("exam.preselected")
            }
            ForEach(model.groups) { group in
                if let title = group.title {
                    Text(title)
                        .qbankFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.qbank(.text2))
                        .padding(.horizontal, QBankSpacing.space5)
                        .padding(.top, QBankSpacing.space3)
                        .accessibilityAddTraits(.isHeader)
                }
                QBankListGroup {
                    ForEach(group.folders) { folder in
                        FolderPickRow(
                            name: folder.name,
                            meta: model.meta(folder),
                            isTicked: model.isTicked(folder),
                            canTick: model.canTick(folder),
                            drawn: model.drawn(folder),
                            isUpdating: isPlanSlow
                        ) {
                            model.toggle(folder)
                        }
                        // With its page when another folder shares its name, so each row is found by one name.
                        .accessibilityIdentifier("exam.folder.\(model.name(folder))")
                    }
                }
            }
            Text(model.footer)
                .qbankFont(.footnote)
                .foregroundStyle(.qbank(.text3))
                .padding(.horizontal, QBankSpacing.space5)
        }
    }

    private var summary: some View {
        QBankCard {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                    if let count = model.summaryCount, let time = model.summaryTime {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(count)
                                .qbankFont(.title3, weight: .bold)
                                .foregroundStyle(.qbank(.text1))
                            Text(time)
                                .qbankFont(.body)
                                .foregroundStyle(.qbank(.text2))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("exam.summary.count")
                    }
                    Text(model.summarySplit)
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text1))
                        .accessibilityIdentifier("exam.summary.split")
                    if let fallback = model.fallbackLine {
                        Text(fallback)
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text1))
                            .accessibilityIdentifier("exam.summary.fallback")
                    }
                }
                .opacity(isPlanSlow ? 0.45 : 1)
                .animation(.default, value: isPlanSlow)
                Text("Feedback comes at the end. Leaving midway ends the exam and scores what you answered.")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                Button("Start exam") {
                    app.frozen.perform {
                        open { await model.start() }
                    }
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(!model.canStart)
                .answersWhenFrozen(app.frozen)
                .padding(.top, QBankSpacing.space1)
                .accessibilityIdentifier("exam.start")
                if model.canTwin {
                    twinOffer
                }
            }
        }
    }

    /// Write exam twins: instead of an exam on these questions, QBank writes their exam twins.
    @ViewBuilder
    private var twinOffer: some View {
        Text(Twins.offer(wrongOnly: model.wrongOnly))
            .qbankFont(.footnote)
            .foregroundStyle(.qbank(.text3))
            .padding(.top, QBankSpacing.space1)
            .accessibilityIdentifier("exam.twins.offer")
        if let problem = model.twinProblem {
            ProblemText(text: problem)
        }
        Button {
            Task {
                if let job = await model.writeTwins() {
                    navigator?.open(StudyRoute.twinJob(TwinJobRoute(course: model.course, jobID: job.id, seed: job)))
                }
            }
        } label: {
            ButtonLabel(text: "Write exam twins", isBusy: model.isTwinning)
        }
        .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
        .disabled(model.picked.isEmpty || model.isStarting || model.isTwinning || model.needsConnection)
        .accessibilityIdentifier("exam.twins.write")
    }

    /// Her exam twins over this course, newest first, so a job is found again after she leaves it.
    private func twinJobs(_ jobs: [TwinJob]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QBankSectionHeader("Exam twins")
                .padding(.horizontal, QBankSpacing.space5)
            QBankListGroup {
                ForEach(jobs) { job in
                    NavigationLink(value: StudyRoute.twinJob(TwinJobRoute(course: model.course, jobID: job.id, seed: job))) {
                        TwinJobRow(job: job)
                    }
                    .buttonStyle(.qbankRow)
                    .accessibilityIdentifier("exam.twins.\(job.id)")
                }
            }
        }
    }

    private func pastExams(_ exams: [ExamSummary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QBankSectionHeader("Past exams")
                .padding(.horizontal, QBankSpacing.space5)
            if exams.isEmpty {
                EmptyCard(
                    message: "Exams you finish show up here with their scores.",
                    systemImage: "timer"
                )
            } else {
                QBankListGroup(footer: !model.needsConnection ? "Touch and hold an exam to delete it." : nil) {
                    ForEach(exams) { exam in
                        Button {
                            running = ExamRoute(id: exam.id)
                        } label: {
                            PastExamRow(exam: exam)
                        }
                        .buttonStyle(.qbankRow)
                        .deletable("exam", isEnabled: !model.needsConnection) {
                            app.frozen.perform { deleting = DeleteRequest(target: .exam(id: exam.id)) }
                        }
                        .accessibilityIdentifier("exam.past.\(exam.id)")
                    }
                }
            }
        }
    }

    /// The plan on screen is the last one and the new one is taking a moment.
    private var isPlanSlow: Bool {
        model.isPlanUpdating && slowPick == model.pick
    }

    /// Opens the exam a start gave, full screen.
    private func open(_ start: @escaping () async -> Exam?) {
        Task {
            if let exam = await start() {
                running = ExamRoute(id: exam.id)
            }
        }
    }

    /// After the exam's full screen closed: her counts changed, and she may have asked for Review
    /// or the course.
    private func closed() {
        Task { await model.load() }
        switch exit {
        case .openReview:
            navigator?.open(StudyRoute.review(model.course))
        case .backToCourse:
            navigator?.back()
        case .done, nil:
            break
        }
        exit = nil
    }
}

/// A folder to tick: its name, its question or wrong count, and how many the exam takes from it.
private struct FolderPickRow: View {
    let name: String
    let meta: String
    let isTicked: Bool
    let canTick: Bool
    let drawn: Int?
    /// The drawn count is the last plan's while the next one is on its way.
    let isUpdating: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: QBankSpacing.space4) {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(.qbank(isTicked ? .tint : .separatorStrong))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                    QBankDetailText(meta)
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let drawn {
                    Text("\(drawn) in exam")
                        .qbankFont(.footnote, weight: .semibold)
                        .foregroundStyle(.qbank(.text2))
                        .opacity(isUpdating ? 0.45 : 1)
                }
            }
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .frame(minHeight: QBankSpacing.rowMin)
            .contentShape(.rect)
            .opacity(canTick ? 1 : 0.45)
        }
        .buttonStyle(.qbankRow)
        .disabled(!canTick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTicked ? .isSelected : [])
    }
}

/// A twin job: its folders and date, its count and pool, and what it is doing or how it ended.
private struct TwinJobRow: View {
    let job: TwinJob

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Twins.rowTitle(job))
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                QBankDetailText(Twins.meta(job))
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let state = Twins.state(job) {
                Text(state)
                    .qbankFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.qbank(tone))
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.qbank(.text4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Set like an exam's score: in the tint, a failure in red, a cancelled job quiet.
    private var tone: QBankColorToken {
        switch job.status {
        case .failed: .wrong
        case .cancelled: .text3
        default: .tint
        }
    }
}

/// A past exam: its folders and date, its minutes and kind, and how many were fully right.
struct PastExamRow: View {
    let exam: ExamSummary

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exam.finishedAt == nil ? "\(Wording.folders(exam.weeks)) · In progress" : exam.pastTitle)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                Text(exam.finishedAt == nil ? "\(exam.answeredCount) of \(exam.questionCount) answered" : exam.pastLine)
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(exam.finishedAt == nil ? "Resume" : exam.scoreText)
                .qbankFont(.subheadline, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.qbank(exam.finishedAt == nil ? .tint : .text1))
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.qbank(.text4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
