import Foundation
import Observation
import QBankKit

/// One exam, as the web runs it (`apps/web/src/exam/ExamScreen.tsx`): questions in the order
/// served, no feedback until the end, Skip for now and coming back to skipped ones, a timer
/// counted from the server's clock, and the result once it ends.
@Observable
final class ExamModel {
    /// Her work on one question.
    struct Item: Equatable {
        let layout: Layout
        var draft: AnswerDraft
        var guessed = false
        /// Original indexes of the choices she has struck out, for this sitting only.
        var struck: Set<Int> = []
        /// Made once per opening, so a retried send is never counted twice.
        let clientAttemptID: String
        var submitted: Bool
        var skipped = false
    }

    enum Phase: Equatable {
        case loading
        case failed(String)
        case running(Running)
        case ended
    }

    /// What the runner is doing while the exam runs: one value, so an answer on its way, an end
    /// asked for and an end not yet confirmed never mix.
    enum Running: Equatable {
        /// On a question. `problem` says why her last Submit did not go through.
        case answering(problem: String?)
        /// Her answer on its way; `retrying` after a dropped connection, under "No connection".
        case saving(retrying: Bool)
        /// The end asked of the server from a question, not answered yet.
        case ending(ExamEndReason)
        /// The end she asked for, or the one an exam with nothing left to answer needs, not
        /// confirmed by the server yet. Its one button asks again, and the clock does too, further
        /// apart each time. `isTrying` while a request is on its way; `problem` says why the last
        /// one failed.
        case endPending(ExamEndReason, problem: String?, isTrying: Bool)
    }

    let examID: String
    private(set) var phase: Phase = .loading
    private(set) var exam: Exam?
    private(set) var items: [Item] = []
    private(set) var index = 0
    /// Every question has been reached once: she is working back through the skipped ones.
    private(set) var isReturning = false
    /// The skipped question the runner wrapped back to, for "This is the first one."
    private(set) var wrappedTo: Int?
    /// Seconds left, from the server's clock.
    private(set) var secondsLeft: TimeInterval = 0

    private let app: AppModel
    private let clock: () -> ContinuousClock.Instant
    private let sleep: (Duration) async throws -> Void
    private let makeLayout: (QuestionBody) -> Layout
    private let newAttemptID: () -> String
    /// When the time runs out, on this phone's steady clock: the server's time left added to the
    /// moment its answer arrived, so a wrong phone clock does not change her time.
    private var deadline: ContinuousClock.Instant?
    private var sending: Task<Void, Never>?
    /// While an end is pending: when the clock asks again, and how long it waits after that.
    private var nextEndTry: ContinuousClock.Instant?
    private var endRetryDelay = ExamModel.firstRetryDelay

    init(
        app: AppModel,
        examID: String,
        clock: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        makeLayout: @escaping (QuestionBody) -> Layout = { Layout.make(for: $0) },
        newAttemptID: @escaping () -> String = { AttemptSubmission.newID() }
    ) {
        self.app = app
        self.examID = examID
        self.clock = clock
        self.sleep = sleep
        self.makeLayout = makeLayout
        self.newAttemptID = newAttemptID
    }

    var questions: [Question] {
        exam?.questions ?? []
    }

    var question: Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    var item: Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// "Exam · Weeks 1-2", or "Exam · First Pass, Second Pass".
    var title: String {
        exam.map { "Exam · \(Wording.folders($0.weeks))" } ?? "Exam"
    }

    /// "5 of 11".
    var countText: String {
        "\(index + 1) of \(questions.count)"
    }

    var submittedCount: Int {
        items.count(where: \.submitted)
    }

    var pendingCount: Int {
        items.count { !$0.submitted }
    }

    var progress: Double {
        questions.isEmpty ? 0 : Double(submittedCount) / Double(questions.count)
    }

    /// What the runner is doing, while the exam runs.
    var running: Running? {
        if case .running(let running) = phase { return running }
        return nil
    }

    var isRunning: Bool {
        running != nil
    }

    var isEnded: Bool {
        phase == .ended
    }

    /// On a question, with nothing on its way.
    var isAnswering: Bool {
        if case .answering = running { return true }
        return false
    }

    /// An answer or an end on its way: the question waits.
    var isBusy: Bool {
        switch running {
        case .saving, .ending: true
        case .endPending(_, _, let isTrying): isTrying
        case .answering, nil: false
        }
    }

    /// A dropped connection is holding her answer: "No connection".
    var isWaiting: Bool {
        running == .saving(retrying: true)
    }

    /// Why her last Submit, or the last ask to end, did not go through.
    var problem: String? {
        switch running {
        case .answering(let problem): problem
        case .endPending(_, let problem, _): problem
        case .saving, .ending, nil: nil
        }
    }

    /// The end she asked for that the server has not confirmed yet: the runner offers only that.
    var pendingEnd: ExamEndReason? {
        if case .endPending(let reason, _, _) = running { return reason }
        return nil
    }

    /// End exam is offered while she is on a question, also with an answer on its way.
    var canEnd: Bool {
        switch running {
        case .answering, .saving: true
        case .ending, .endPending, nil: false
        }
    }

    /// The last question still open: its button finishes the exam.
    var isLastPending: Bool {
        pendingCount == 1 && item?.submitted == false
    }

    /// Her open answer can go: she is on a question not yet submitted, with an answer.
    var canSubmit: Bool {
        isAnswering && item?.submitted == false && item?.draft.response != nil
    }

    /// Skipped questions left once she is working back through them.
    var skippedLeft: Int {
        isReturning ? pendingCount : 0
    }

    /// The question in the end sheet, in the web's words.
    var endMessage: String {
        "The \(Wording.count(submittedCount, "question")) you answered will be scored. Skipped and unreached questions score 0 and stay out of Review."
    }

    /// What is left to do while an end is not confirmed: "3 of 3 questions answered. Finish the
    /// exam to see your result."
    func pendingEndNote(_ reason: ExamEndReason) -> String {
        switch reason {
        case .finished:
            "\(submittedCount) of \(Wording.count(questions.count, "question")) answered. Finish the exam to see your result."
        case .left:
            "You chose to end the exam. End it to see your result."
        case .timeout:
            "Time is up. Finish the exam to see your result."
        }
    }

    // MARK: Loading

    func load() async {
        do {
            show(try await app.client.exam(id: examID))
        } catch {
            if app.handle(error) { return }
            if let words = Wording.problem(error) {
                phase = .failed(words)
            }
        }
    }

    /// Reads the exam again when she comes back to the app: its time is checked with the server,
    /// and an exam whose time ran out, or whose end went through while she was away, arrives
    /// ended. Her open answers stay.
    func resync() async {
        switch running {
        case .answering, .saving, .endPending(_, _, isTrying: false): break
        case .ending, .endPending, nil: return
        }
        guard let fresh = try? await app.client.exam(id: examID) else { return }
        guard isRunning else { return }
        if fresh.isRunning {
            exam = fresh
            startClock(fresh)
        } else {
            show(fresh)
        }
    }

    private func show(_ loaded: Exam) {
        exam = loaded
        guard loaded.isRunning else {
            // An answer still being retried has nothing left to reach.
            sending?.cancel()
            phase = .ended
            return
        }
        guard items.isEmpty else {
            if !isRunning { phase = .running(.answering(problem: nil)) }
            startClock(loaded)
            return
        }
        let answered = Set(loaded.answeredQuestionIDs)
        items = loaded.questions.map { question in
            let layout = makeLayout(question.body)
            return Item(
                layout: layout,
                draft: AnswerDraft(body: question.body, layout: layout),
                clientAttemptID: newAttemptID(),
                submitted: answered.contains(question.id)
            )
        }
        if let stop = nextStop(from: -1) {
            index = stop.index
            phase = .running(.answering(problem: nil))
        } else {
            // Every answer is in, but the end never went through: finishing is all that is left,
            // and the clock asks for it at once.
            index = 0
            phase = .running(.endPending(.finished, problem: nil, isTrying: false))
            nextEndTry = clock()
        }
        startClock(loaded)
        if app.frozen.isOn { app.frozen.showNote() }
    }

    // MARK: The clock

    private func startClock(_ exam: Exam) {
        deadline = clock().advanced(by: .milliseconds(Int64((exam.secondsLeftAtServerNow * 1000).rounded())))
        tick()
    }

    /// Counts the time down. When it runs out the exam ends; an end not confirmed yet is asked
    /// again, further apart each time, and as a timeout once the time is out.
    func tick() {
        guard let running, let deadline else { return }
        let now = clock()
        let left = now.duration(to: deadline)
        secondsLeft = max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        // In the frozen view the exam is hers: it ends when her app next reads it.
        guard !app.frozen.isOn else { return }
        switch running {
        case .answering, .saving:
            if secondsLeft <= 0 { beginEnd(.timeout) }
        case .endPending(let reason, _, let isTrying):
            guard !isTrying, let nextEndTry, now >= nextEndTry else { return }
            beginEnd(secondsLeft <= 0 ? .timeout : reason)
        case .ending:
            break
        }
    }

    /// Ticks once a second while the exam runs.
    func runClock() async {
        while !Task.isCancelled, isRunning || phase == .loading {
            tick()
            do {
                try await sleep(.seconds(1))
            } catch {
                return
            }
        }
    }

    // MARK: Answering

    /// Whether her work on the question on screen can still change: she is on it, and it has not
    /// been sent.
    private var isEditable: Bool {
        isAnswering && items.indices.contains(index) && !items[index].submitted
    }

    /// Replaces her open answer. A struck choice cannot be picked until she restores it.
    func update(_ draft: AnswerDraft) {
        guard !app.frozen.refuses(), isEditable else { return }
        guard items[index].struck.isDisjoint(with: draft.picked) else { return }
        items[index].draft = draft
    }

    /// Strikes out a choice she has ruled out, or restores a struck one. Strikes stay with the
    /// question while she moves between questions, end with the exam, and are never sent.
    func toggleStrike(_ option: Int) {
        guard !app.frozen.refuses(), isEditable else { return }
        items[index].draft = items[index].draft.striking(option, in: &items[index].struck)
    }

    /// The guess flag goes with her answer, so it cannot change once the answer is sent.
    func setGuessed(_ guessed: Bool) {
        guard !app.frozen.refuses(), isEditable else { return }
        items[index].guessed = guessed
    }

    /// Sends the answer and moves on. An exam answer cannot wait on the phone like a practice one:
    /// a dropped connection is retried with the same answer id until the server answers, under the
    /// web's "No connection" line, while the timer keeps running. An answer the server already has
    /// counts as sent; an exam that ended meanwhile shows its result.
    func submit() async {
        guard !app.frozen.refuses(), canSubmit, let question, let item, let response = item.draft.response, let exam else { return }
        do {
            // Catches an answer the question cannot take before it leaves the phone.
            _ = try Scoring.score(question.body, response: response)
        } catch {
            phase = .running(.answering(problem: error.message))
            return
        }
        phase = .running(.saving(retrying: false))
        let at = index
        let submission = AttemptSubmission(
            clientAttemptID: item.clientAttemptID,
            questionID: question.id,
            response: response,
            guessed: item.guessed,
            shuffle: item.layout,
            studySessionID: exam.id
        )
        let task = Task { await send(submission, at: at) }
        sending = task
        await task.value
    }

    /// Sends one answer until the server has it, while the runner is saving it. An end asked for
    /// meanwhile drops it.
    private func send(_ submission: AttemptSubmission, at position: Int) async {
        var delay = Self.firstRetryDelay
        while true {
            do {
                _ = try await app.client.recordAttempt(submission)
                markSubmitted(position)
                return
            } catch where Self.isTransient(error) {
                guard isSaving else { return }
                phase = .running(.saving(retrying: true))
            } catch {
                guard isSaving, error != .cancelled else { return }
                if error.serverCode == .alreadyAnswered {
                    markSubmitted(position)
                } else if error.serverCode == .examFinished {
                    if let ended = try? await app.client.exam(id: examID) {
                        if isSaving { show(ended) }
                    } else if isSaving {
                        phase = .running(.answering(problem: Wording.problem(error)))
                    }
                } else if app.handle(error) {
                    phase = .running(.answering(problem: nil))
                } else {
                    phase = .running(.answering(problem: Wording.problem(error)))
                }
                return
            }
            do {
                try await sleep(delay)
            } catch {
                return
            }
            if Task.isCancelled || !isSaving { return }
            delay = min(delay * 2, Self.longestRetryDelay)
        }
    }

    private var isSaving: Bool {
        if case .saving = running { return true }
        return false
    }

    private func markSubmitted(_ position: Int) {
        guard isSaving, items.indices.contains(position) else { return }
        items[position].submitted = true
        items[position].skipped = false
        go(from: position)
    }

    /// Leaves the question open for later and moves on.
    func skip() async {
        guard !app.frozen.refuses(), isAnswering, items.indices.contains(index) else { return }
        items[index].skipped = true
        go(from: index)
    }

    /// Moves to the next question still open, or, with none left, finishes the exam.
    private func go(from position: Int) {
        guard let stop = nextStop(from: position) else {
            beginEnd(.finished)
            return
        }
        if stop.wrapped { isReturning = true }
        wrappedTo = stop.wrapped ? stop.index : nil
        index = stop.index
        phase = .running(.answering(problem: nil))
    }

    /// The next question not yet submitted, wrapping back to skipped ones.
    private func nextStop(from position: Int) -> (index: Int, wrapped: Bool)? {
        if let next = items.indices.first(where: { $0 > position && !items[$0].submitted }) {
            return (next, false)
        }
        if let next = items.indices.first(where: { $0 <= position && !items[$0].submitted }) {
            return (next, true)
        }
        return nil
    }

    static let firstRetryDelay = Duration.seconds(1)
    static let longestRetryDelay = Duration.seconds(15)

    /// A failed connection, or a proxy or a restarting server in front of the API: worth sending
    /// again with the same id while the exam runs. A refusal from the API itself is final.
    nonisolated static func isTransient(_ error: QBankError) -> Bool {
        switch error {
        case .transport:
            return true
        case .server(let server):
            return server.status == 502 || server.status == 504
        case .unexpectedResponse(let status, _):
            return status == 502 || status == 503 || status == 504
        case .cancelled, .notSignedIn, .storage, .invalidRequest:
            return false
        }
    }

    // MARK: Ending

    /// Ends the exam and shows the result: End exam, Finish exam beside the skipped questions, or
    /// the one button of an end not confirmed yet. Her open answer, if one is still sending, is
    /// dropped, as on the web: the end scores what the server has.
    func end(_ reason: ExamEndReason) async {
        guard !app.frozen.refuses() else { return }
        switch running {
        case .answering, .saving, .endPending(_, _, isTrying: false):
            await beginEnd(reason).value
        case .ending, .endPending, nil:
            return
        }
    }

    /// Asks the end of the server once more, at once: the button of an end not confirmed yet.
    func retryEnd() async {
        guard let pendingEnd else { return }
        await end(secondsLeft <= 0 ? .timeout : pendingEnd)
    }

    /// Moves the runner to the end on its way and asks the server for it. The request runs apart
    /// from the answer it may cancel.
    @discardableResult
    private func beginEnd(_ reason: ExamEndReason) -> Task<Void, Never> {
        if case .endPending(_, let problem, _) = running {
            phase = .running(.endPending(reason, problem: problem, isTrying: true))
        } else {
            phase = .running(.ending(reason))
        }
        sending?.cancel()
        return Task { await finish(reason) }
    }

    private func finish(_ reason: ExamEndReason) async {
        do {
            let ended = try await app.client.finishExam(id: examID, reason: reason)
            endRetryDelay = Self.firstRetryDelay
            nextEndTry = nil
            show(ended)
        } catch {
            guard isRunning else { return }
            if app.handle(error) {
                pend(reason, problem: nil, retry: false)
            } else if Self.isTransient(error) {
                pend(reason, problem: "Could not end the exam. Check the connection; QBank keeps trying.", retry: true)
            } else if case .server(let server) = error {
                // The server's own refusal says what happened, and asking again on a timer would not change it.
                pend(reason, problem: server.message, retry: false)
            } else {
                pend(reason, problem: "Could not end the exam. Check the connection and try again.", retry: false)
            }
        }
    }

    /// The end is not confirmed: the runner offers only it, and with `retry` the clock asks again
    /// after the current wait, which doubles up to the longest.
    private func pend(_ reason: ExamEndReason, problem: String?, retry: Bool) {
        phase = .running(.endPending(reason, problem: problem, isTrying: false))
        if retry {
            nextEndTry = clock().advanced(by: endRetryDelay)
            endRetryDelay = min(endRetryDelay * 2, Self.longestRetryDelay)
        } else {
            nextEndTry = nil
        }
    }
}
