import QBankDesign
import QBankKit
import SwiftUI

/// A set being made, on whichever step it is: reading her material, her check of five samples
/// (Q-4) or of the questions copied from her photos (Q-2b), writing the rest (Q-5), and the
/// finished set (Q-6). The server does the work; this screen follows it while it is open.
struct JobView: View {
    let app: AppModel
    @State private var model: JobModel
    /// Back to the Add hub.
    let close: () -> Void
    /// The set was let go: back to Your material for new material.
    let startOver: () -> Void
    @State private var practicing: PracticeRoute?
    @State private var asksToStop = false
    @Environment(TabNavigator.self) private var tabs

    /// `seed` is the set as the screen that opens this one last read it, so the title and the
    /// step show from the first frame.
    /// "course", or "topic" for a set going into a topic.
    private var container: String {
        Wording.words(model.job.map { Wording.kind(code: $0.course.code) } ?? .course).container
    }

    init(app: AppModel, id: String, seed: QuestionJob?, close: @escaping () -> Void, startOver: @escaping () -> Void) {
        self.app = app
        self.close = close
        self.startOver = startOver
        _model = State(initialValue: JobModel(app: app, id: id, seed: seed))
    }

    var body: some View {
        // The step's large title is the top of its own content, under an inline bar that says
        // where she is. The navigation bar's large title would keep whatever state the step
        // before left it in, so after scrolling to her answer a new step would open without one.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let heading {
                    Text(heading)
                        .qbankFont(.largeTitle)
                        .foregroundStyle(.qbank(.text1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .screenColumn()
                        .accessibilityAddTraits(.isHeader)
                }
                content
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // As in the wireframes: the tab bar shows while QBank works, not on her checks or the finished set.
        .toolbar(showsTabBar ? .visible : .hidden, for: .tabBar)
        .qbankScreenBackground()
        // Follows the job again whenever it goes back to work, as after her check of the samples.
        .task(id: model.isWorking) { await model.follow() }
        .fullScreenCover(item: $practicing) { route in
            PracticeView(app: app, route: route)
        }
        .toolbar {
            if let step {
                ToolbarItem(placement: .principal) {
                    StepTitle(step)
                }
            }
            if let job = model.job, job.status == .running || job.status == .waiting {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Stop making this set", systemImage: "xmark.circle", role: .destructive) { asksToStop = true }
                            .accessibilityIdentifier("make.stop")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("make.more")
                }
            }
        }
        .confirmationDialog("Stop making this set?", isPresented: $asksToStop, titleVisibility: .visible) {
            Button("Stop and delete it", role: .destructive) {
                Task {
                    if await model.cancel() { close() }
                }
            }
            .accessibilityIdentifier("make.stop.confirm")
        } message: {
            Text("Nothing is added to your \(container), and your material is deleted.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let job = model.job {
            switch job.status {
            case .running:
                WorkingView(job: job, problem: model.problem)
            case .waiting:
                if job.waitingFor == .copies, let copies = model.copies {
                    CopiesView(model: model, job: job, copies: copies) {
                        Task {
                            if await model.cancel() { startOver() }
                        }
                    }
                } else if let samples = model.samples {
                    SamplesView(model: model, job: job, samples: samples) { question, number in
                        practicing = PracticeRoute(source: .sample(jobID: job.id, sampleID: question.id), courseID: job.course.id, title: "Sample \(number)", kind: Wording.kind(code: job.course.code))
                    }
                } else {
                    loading
                }
            case .done:
                if let result = model.result {
                    FinishedView(job: job, result: result, close: close) {
                        practicing = PracticeRoute(source: .set(id: result.set.setID), courseID: job.course.id, title: result.set.title, kind: Wording.kind(code: job.course.code))
                    } open: {
                        tabs.openFolder(courseID: job.course.id, name: Wording.name(code: job.course.code, title: job.course.title), folderID: result.set.folderID)
                    }
                } else {
                    loading
                }
            case .failed, .cancelled:
                StoppedView(job: job, problem: model.problem, close: close, startOver: startOver)
            }
        } else if let problem = model.problem {
            ContentUnavailableView {
                Label(model.isGone ? "This set is gone" : "Could not open this set", systemImage: "exclamationmark.circle")
            } description: {
                Text(problem)
            } actions: {
                if model.isGone {
                    Button("Back to Add", action: close)
                        .buttonStyle(.qbank(.secondary))
                } else {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.qbank(.secondary))
                }
            }
            .containerRelativeFrame(.vertical)
        } else {
            loading
        }
    }

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
    }

    /// The large title of the step the set is on; the finished set has none.
    private var title: String {
        guard let job = model.job else { return "" }
        switch job.status {
        case .running: return MakeWording.runningTitle(job)
        case .waiting:
            if job.waitingFor == .copies { return model.copies.map(MakeWording.found) ?? "Check the copies" }
            return "Check 5 samples"
        case .done: return ""
        case .cancelled: return "Set stopped"
        case .failed: return "This set stopped"
        }
    }

    /// The title over the step once it shows: none on the finished set, which has its own, or on
    /// a stopped set, whose title stays in the bar.
    private var heading: String? {
        guard let job = model.job else { return nil }
        switch job.status {
        case .running: return title
        case .waiting:
            if job.waitingFor == .copies { return model.copies.map(MakeWording.found) }
            return model.samples == nil ? nil : title
        case .done, .failed, .cancelled: return nil
        }
    }

    private var showsTabBar: Bool {
        switch model.job?.status {
        case .waiting?, .done?: false
        case .running?, .failed?, .cancelled?, nil: true
        }
    }

    /// Where she is in making the set, in the bar: "Step 3 of 4", or "Check the copies".
    private var step: String? {
        guard let job = model.job else { return nil }
        switch job.status {
        case .running:
            if job.materialKind == .questions { return StepTitle.text(step: 2, of: 2) }
            let early = job.currentStep.map { $0.key == .read || $0.key == .samples } == true
            return StepTitle.text(step: early ? 3 : 4, of: 4)
        case .waiting:
            return job.waitingFor == .copies ? "Check the copies" : StepTitle.text(step: 3, of: 4)
        case .done, .failed, .cancelled:
            return nil
        }
    }
}

/// QBank is reading her material, writing, checking, or filing (Q-5): how far it got, and each
/// step the server takes, in its words.
private struct WorkingView: View {
    let job: QuestionJob
    let problem: String?

    var body: some View {
        JobColumn {
            Text(MakeWording.place(job))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                Text(MakeWording.headline(job))
                    .qbankFont(.title3, weight: .bold)
                    .foregroundStyle(.qbank(.text1))
                    .accessibilityIdentifier("make.state")
                if let fraction = MakeWording.fraction(job) {
                    QBankProgressPill(value: fraction, accessibilityTitle: "Done")
                }
            }
            .padding(QBankSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .qbankCardBackground()
            QBankListGroup(footer: MakeWording.leaveNote) {
                ForEach(job.steps, id: \.key) { step in
                    StepRow(step: step)
                }
            }
            if let problem {
                ProblemText(text: problem)
            }
        }
    }
}

/// Check five samples (Q-4): open each one in the runner, mark it, and say what to change.
private struct SamplesView: View {
    let model: JobModel
    let job: QuestionJob
    let samples: QuestionSamples
    let open: (Question, Int) -> Void
    @FocusState private var noting: String?
    /// Her notes start new writing: the permission screen first when she has not allowed it, and
    /// what it sends once she does.
    @State private var asksAIPermission = false
    @State private var sendAfterPermission: (() -> Void)?

    var body: some View {
        JobColumn {
            Text("Open each one and answer it like practice. Mark anything off; the other \(model.restCount) follow your notes.")
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
            if let note = samples.note {
                Text(note)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text1))
                    .padding(QBankSpacing.space4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
                    .accessibilityIdentifier("make.samples.note")
            }
            QBankListGroup {
                ForEach(Array(samples.questions.enumerated()), id: \.element.id) { index, question in
                    SampleRow(number: index + 1, question: question, verdict: model.verdict(question)) {
                        open(question, index + 1)
                    } mark: { verdict in
                        model.mark(question, verdict)
                        if verdict == .change { noting = question.id }
                    }
                }
            }
            ForEach(model.changing) { question in
                let number = (samples.questions.firstIndex(of: question) ?? 0) + 1
                VStack(alignment: .leading, spacing: 6) {
                    FieldTitle("What to change (sample \(number))")
                    TextField("What the rest should do differently", text: Binding(get: { model.notes[question.id] ?? "" }, set: { model.notes[question.id] = $0 }), axis: .vertical)
                        .lineLimit(3...8)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .focused($noting, equals: question.id)
                        .padding(.horizontal, QBankSpacing.space4)
                        .padding(.vertical, QBankSpacing.space3)
                        .frame(minHeight: 88, alignment: .topLeading)
                        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
                        }
                        .accessibilityLabel("What to change in sample \(number)")
                        .accessibilityIdentifier("make.sample.\(number).note")
                }
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            VStack(spacing: QBankSpacing.space2) {
                Button {
                    noting = nil
                    afterAIPermission { Task { await model.acceptSamples() } }
                } label: {
                    ButtonLabel(text: "Write the other \(model.restCount)", isBusy: model.isSending)
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("make.writeRest")
                if samples.canRevise {
                    Button("Redo the samples") {
                        noting = nil
                        afterAIPermission { Task { await model.reviseSamples() } }
                    }
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .disabled(!model.canRevise)
                    .accessibilityHint("Writes them again from what you said to change")
                    .accessibilityIdentifier("make.redo")
                }
            }
            .disabled(model.isSending)
        }
        .aiPermissionSheet(isPresented: $asksAIPermission, store: model.aiConsent) {
            sendAfterPermission?()
            sendAfterPermission = nil
        }
    }

    private func afterAIPermission(_ send: @escaping () -> Void) {
        if model.aiConsent.isAllowed {
            send()
        } else {
            sendAfterPermission = send
            asksAIPermission = true
        }
    }
}

/// A sample: its topic, format, and NCLEX step, which opens it in the runner, and her verdict.
private struct SampleRow: View {
    let number: Int
    let question: Question
    let verdict: JobModel.Verdict
    let open: () -> Void
    let mark: (JobModel.Verdict) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: QBankSpacing.space4) {
                    PositionMark(number: number)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.topic)
                            .qbankFont(.body)
                            .foregroundStyle(.qbank(.text1))
                        Text([Wording.format(question.type), question.clinicalJudgmentStep].compactMap(\.self).joined(separator: " · "))
                            .qbankFont(.footnote)
                            .foregroundStyle(.qbank(.text3))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, QBankSpacing.rowPaddingHorizontal)
                .padding(.vertical, 11)
                .frame(minHeight: QBankSpacing.rowMin)
                .contentShape(.rect)
            }
            .buttonStyle(.qbankRow)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens it to answer like practice")
            .accessibilityIdentifier("make.sample.\(number)")
            Menu {
                Picker("Your check", selection: Binding(get: { verdict }, set: { mark($0) })) {
                    Text("Looks right").tag(JobModel.Verdict.looksRight)
                    Text("Change").tag(JobModel.Verdict.change)
                    Text("Not checked").tag(JobModel.Verdict.notChecked)
                }
            } label: {
                VerdictPill(verdict: verdict)
                    .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
                    .frame(minHeight: QBankSpacing.rowMin)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Sample \(number): \(MakeWording.verdict(verdict))")
            .accessibilityHint("Changes your check")
            .accessibilityIdentifier("make.sample.\(number).verdict")
        }
    }
}

private struct VerdictPill: View {
    let verdict: JobModel.Verdict

    var body: some View {
        switch verdict {
        case .looksRight: QBankTintedLabel(MakeWording.verdict(verdict), tone: .correct, size: .small)
        case .change: QBankTintedLabel(MakeWording.verdict(verdict), tone: .partial, size: .small)
        case .notChecked: QBankTintedLabel(MakeWording.verdict(verdict), tone: .neutral, style: .dashed, size: .small)
        }
    }
}

/// Check the copies (Q-2b): each question found in her photos, with its answer from the photo or
/// QBank's suggestion to check, the ones she leaves out, and those it could not read.
private struct CopiesView: View {
    let model: JobModel
    let job: QuestionJob
    let copies: QuestionCopies
    let retake: () -> Void
    @State private var checking: QuestionCopies.Copy?
    @State private var asksToRetake = false
    /// Her checked copies start new writing: the permission screen first when she has not allowed it.
    @State private var asksAIPermission = false

    var body: some View {
        JobColumn {
            Text(MakeWording.copiesNote(copies, job))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
            QBankListGroup {
                ForEach(Array(copies.questions.enumerated()), id: \.element.id) { index, copy in
                    Button {
                        checking = copy
                    } label: {
                        CopyRow(number: index + 1, copy: copy, isSkipped: model.isSkipped(copy), chosen: model.answer(copy))
                    }
                    .buttonStyle(.qbankRow)
                    .accessibilityIdentifier("make.copy.\(index + 1)")
                }
                ForEach(Array(copies.unreadable.enumerated()), id: \.offset) { index, unreadable in
                    UnreadableRow(number: copies.questions.count + index + 1, unreadable: unreadable)
                }
            }
            if job.examTwins {
                Text("QBank also writes an exam twin for each, so the exam asks it in new words.")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                    .padding(.horizontal, QBankSpacing.space5)
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            VStack(spacing: QBankSpacing.space2) {
                Button {
                    if model.aiConsent.isAllowed {
                        addCopies()
                    } else {
                        asksAIPermission = true
                    }
                } label: {
                    ButtonLabel(text: "Add \(Wording.count(model.keptCount, "question")) to \(job.folder.name)", isBusy: model.isSending)
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .disabled(model.keptCount == 0)
                .accessibilityIdentifier("make.addCopies")
                Button(retakeTitle) { asksToRetake = true }
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .accessibilityIdentifier("make.retake")
            }
            .disabled(model.isSending)
        }
        .sheet(item: $checking) { copy in
            CopySheet(model: model, copy: copy, number: (copies.questions.firstIndex(of: copy) ?? 0) + 1)
        }
        .aiPermissionSheet(isPresented: $asksAIPermission, store: model.aiConsent, onAllow: addCopies)
        .confirmationDialog(retakeTitle, isPresented: $asksToRetake, titleVisibility: .visible) {
            Button("Start over with new photos", role: .destructive, action: retake)
                .accessibilityIdentifier("make.retake.confirm")
        } message: {
            Text("The questions found in these photos are let go.")
        }
    }

    private func addCopies() {
        Task { await model.acceptCopies() }
    }

    /// "Retake photo 2" when a photo could not be read, else "Start over".
    private var retakeTitle: String {
        copies.unreadable.lazy.compactMap(\.photo).first.map { "Retake photo \($0)" } ?? "Start over"
    }
}

/// A copied question: its format, the start of its stem, and its answer.
private struct CopyRow: View {
    let number: Int
    let copy: QuestionCopies.Copy
    let isSkipped: Bool
    let chosen: Set<Int>?

    var body: some View {
        HStack(alignment: .top, spacing: QBankSpacing.space4) {
            PositionMark(number: number)
            VStack(alignment: .leading, spacing: 4) {
                Text(MakeWording.shape(copy.question))
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                Text(copy.question.stem)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .lineLimit(2)
                if isSkipped {
                    QBankTintedLabel("Left out", tone: .neutral, style: .dashed, size: .small)
                } else if let line = MakeWording.answer(copy, chosen: chosen) {
                    let suggested = copy.answerFrom == .suggested && chosen == nil
                    QBankTintedLabel(line, tone: suggested ? .partial : .tint, style: suggested ? .dashed : .soft, size: .small)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isSkipped ? 0.55 : 1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.qbank(.text4))
                .frame(minHeight: 22)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A question QBank could not copy in full, and why.
private struct UnreadableRow: View {
    let number: Int
    let unreadable: QuestionCopies.Unreadable

    var body: some View {
        HStack(alignment: .top, spacing: QBankSpacing.space4) {
            PositionMark(number: number)
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not read it")
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                Text(unreadable.reason)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("make.unreadable.\(number)")
    }
}

/// One copied question up close: its stem and choices, to set the right answer, or leave it out.
private struct CopySheet: View {
    let model: JobModel
    let copy: QuestionCopies.Copy
    let number: Int
    @State private var picks: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let question = copy.question
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    Text(MakeWording.shape(question))
                        .qbankFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.qbank(.text2))
                    Text(question.stem)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                    if !question.ask.isEmpty {
                        Text(question.ask)
                            .qbankFont(.body, weight: .semibold)
                            .foregroundStyle(.qbank(.text1))
                    }
                    if let options = MakeWording.options(question) {
                        if copy.answerFrom == .suggested {
                            Text("The photo marks no answer. QBank picked the one below; check it.")
                                .qbankFont(.subheadline)
                                .foregroundStyle(.qbank(.text3))
                        }
                        VStack(spacing: QBankSpacing.space2) {
                            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                                CopyChoiceRow(letter: MakeWording.letter(index), text: option.text, isMulti: question.type == .sata, isOn: picks.contains(index)) {
                                    toggle(index, multi: question.type == .sata)
                                }
                                .accessibilityIdentifier("make.copy.choice.\(MakeWording.letter(index))")
                            }
                        }
                        Button("Use this answer") {
                            model.setAnswer(copy, picks)
                            dismiss()
                        }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .disabled(picks.isEmpty)
                        .accessibilityIdentifier("make.copy.use")
                    } else {
                        Text("Its answer is kept as it was copied. Leave it out if it looks wrong.")
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text3))
                    }
                    if copy.explanationsFrom == .qbank {
                        Text("The photo has no explanations, so QBank wrote them.")
                            .qbankFont(.subheadline)
                            .foregroundStyle(.qbank(.text3))
                    }
                    Button(model.isSkipped(copy) ? "Put it back" : "Leave this one out") {
                        model.setSkipped(copy, !model.isSkipped(copy))
                        dismiss()
                    }
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("make.copy.skip")
                }
                .padding(.horizontal, QBankSpacing.gutterPhone)
                .padding(.vertical, QBankSpacing.space4)
            }
            .qbankScreenBackground()
            .navigationTitle("Question \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("make.copy.close")
                }
            }
        }
        .onAppear { picks = model.answer(copy) ?? MakeWording.key(question) }
    }

    private func toggle(_ index: Int, multi: Bool) {
        if multi {
            if picks.contains(index) { picks.remove(index) } else { picks.insert(index) }
        } else {
            picks = [index]
        }
    }
}

/// A choice of a copied question, picked to set the answer.
private struct CopyChoiceRow: View {
    let letter: String
    let text: String
    let isMulti: Bool
    let isOn: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: QBankSpacing.space3) {
                Image(systemName: isOn ? (isMulti ? "checkmark.square.fill" : "checkmark.circle.fill") : (isMulti ? "square" : "circle"))
                    .foregroundStyle(.qbank(isOn ? .tint : .text3))
                    .accessibilityHidden(true)
                Text("\(letter).")
                    .qbankFont(.body, weight: .semibold)
                    .foregroundStyle(.qbank(.text2))
                Text(text)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(QBankSpacing.space4)
            .background(.qbank(isOn ? .tintSoft : .surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                    .strokeBorder(.qbank(isOn ? .tintSoftBorder : .separatorStrong), lineWidth: isOn ? QBankBorder.emphasis : QBankBorder.regular)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// Your set is ready (Q-6): what the blind check did, the exam twins and terms, and where to go.
private struct FinishedView: View {
    let job: QuestionJob
    let result: QuestionResult
    let close: () -> Void
    let practice: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: QBankSpacing.space3) {
            DoneMark(systemImage: "checkmark")
            Text("Your set is ready")
                .qbankFont(.title2, weight: .bold)
                .foregroundStyle(.qbank(.text1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("make.done.title")
            Text(MakeWording.finished(result, course: Wording.name(code: job.course.code, title: job.course.title)))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("make.done.copy")
            QBankListGroup {
                if let check = result.blindCheck {
                    QBankListRow(MakeWording.blindCheck(check))
                } else {
                    QBankListRow("\(Wording.count(result.set.questionCount, "question")) checked by you")
                }
                if !result.suggestedAnswers.isEmpty {
                    QBankListRow("\(Wording.count(result.suggestedAnswers.count, "answer")) suggested by QBank", detail: "The photo marked none")
                }
                if let exam = result.examSet {
                    QBankListRow("\(Wording.count(exam.questionCount, "exam twin")) in the \(exam.folderName) exam bank")
                }
                if result.set.termCount > 0 {
                    QBankListRow(Wording.count(result.set.termCount, "term"), detail: "Added to Terms")
                }
            }
            .padding(.top, QBankSpacing.space4)
            .accessibilityIdentifier("make.done.rows")
            VStack(spacing: QBankSpacing.space2) {
                Button("Practice now", action: practice)
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("make.done.practice")
                Button("Open \(result.set.folderName)", action: open)
                    .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("make.done.open")
            }
            .padding(.top, QBankSpacing.space4)
        }
        .screenColumn()
        .padding(.top, QBankSpacing.space7)
        .padding(.bottom, QBankSpacing.space7)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
                    .accessibilityIdentifier("make.done.close")
            }
        }
    }
}

/// The set stopped on the server, or she stopped it: its words, and a way to start again.
private struct StoppedView: View {
    let job: QuestionJob
    let problem: String?
    let close: () -> Void
    let startOver: () -> Void

    var body: some View {
        JobColumn {
            let container = Wording.words(Wording.kind(code: job.course.code)).container
            Text(
                job.status == .cancelled
                    ? "You stopped this set. Nothing was added to your \(container)."
                    : job.failure ?? "QBank could not finish this set. Nothing was added to your \(container)."
            )
            .qbankFont(.body)
            .foregroundStyle(.qbank(.text1))
            .accessibilityIdentifier("make.stopped")
            QBankListGroup {
                ForEach(job.steps, id: \.key) { step in
                    StepRow(step: step)
                }
            }
            if let problem {
                ProblemText(text: problem)
            }
            VStack(spacing: QBankSpacing.space2) {
                Button("Start over", action: startOver)
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("make.startOver")
                Button("Back to Add", action: close)
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
            }
        }
    }
}

/// The column every step of a set being made uses, in JobView's scroll view.
private struct JobColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            content
        }
        .screenColumn()
        .padding(.top, QBankSpacing.space2)
        .padding(.bottom, QBankSpacing.space7)
    }
}

/// A step of the server's work: checked once done, a spinner while QBank is on it.
private struct StepRow: View {
    let step: QuestionJob.StepProgress

    var body: some View {
        HStack(spacing: QBankSpacing.space4) {
            mark
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(step.state == .todo ? .text2 : .text1))
                if let done = step.done, let total = step.total {
                    Text("\(done) of \(total)")
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 11)
        .frame(minHeight: QBankSpacing.rowMin)
        .accessibilityElement(children: .combine)
        .accessibilityValue(value)
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
        case .waiting:
            Image(systemName: "hand.raised.circle.fill")
                .font(.title3)
                .foregroundStyle(.qbank(.tint))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.qbank(.wrong))
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(.title3)
                .foregroundStyle(.qbank(.text3))
        case .todo:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.qbank(.separatorStrong))
        }
    }

    private var value: String {
        switch step.state {
        case .done: "Done"
        case .current: "Working"
        case .waiting: "Waiting for you"
        case .failed: "Stopped"
        case .cancelled: "Stopped"
        case .todo: "Not yet"
        }
    }
}

/// A row's number in a small round mark.
private struct PositionMark: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .qbankFont(.caption1, weight: .bold)
            .foregroundStyle(.qbank(.text2))
            .frame(width: 24, height: 24)
            .background(.qbank(.surfaceSunken), in: .circle)
            .accessibilityHidden(true)
    }
}
