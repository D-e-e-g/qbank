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
        case running
        case ended
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
    private(set) var isSaving = false
    private(set) var isWaiting = false
    private(set) var isEnding = false
    private(set) var problem: String?
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

    var isBusy: Bool {
        isSaving || isEnding
    }

    /// The last question still open: its button finishes the exam.
    var isLastPending: Bool {
        pendingCount == 1 && item?.submitted == false
    }

    var canSubmit: Bool {
        !isBusy && item?.draft.response != nil
    }

    /// Skipped questions left once she is working back through them.
    var skippedLeft: Int {
        isReturning ? pendingCount : 0
    }

    /// The question in the end sheet, in the web's words.
    var endMessage: String {
        "The \(Wording.count(submittedCount, "question")) you answered will be scored. Skipped and unreached questions score 0 and stay out of Review."
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
    /// and an exam whose time ran out while she was away arrives ended. Her open answers stay.
    func resync() async {
        guard phase == .running, !isEnding else { return }
        guard let fresh = try? await app.client.exam(id: examID) else { return }
        guard phase == .running else { return }
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
            phase = .running
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
        index = nextStop(from: -1)?.index ?? 0
        phase = .running
        startClock(loaded)
        if app.frozen.isOn { app.frozen.showNote() }
    }

    // MARK: The clock

    private func startClock(_ exam: Exam) {
        deadline = clock().advanced(by: .milliseconds(Int64((exam.secondsLeftAtServerNow * 1000).rounded())))
        tick()
    }

    /// Counts the time down and ends the exam when it runs out. A failed end is tried again on
    /// the next tick.
    func tick() {
        guard phase == .running, let deadline else { return }
        let left = clock().duration(to: deadline)
        secondsLeft = max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        // In the frozen view the exam is hers: it ends when her app next reads it.
        if secondsLeft <= 0, !isEnding, !app.frozen.isOn {
            Task { await end(.timeout) }
        }
    }

    /// Ticks once a second while the exam runs.
    func runClock() async {
        while !Task.isCancelled, phase == .running || phase == .loading {
            tick()
            do {
                try await sleep(.seconds(1))
            } catch {
                return
            }
        }
    }

    // MARK: Answering

    /// Replaces her open answer. A struck choice cannot be picked until she restores it.
    func update(_ draft: AnswerDraft) {
        guard !app.frozen.refuses(), !isBusy, items.indices.contains(index), !items[index].submitted else { return }
        guard items[index].struck.isDisjoint(with: draft.picked) else { return }
        items[index].draft = draft
    }

    /// Strikes out a choice she has ruled out, or restores a struck one. Strikes stay with the
    /// question while she moves between questions, end with the exam, and are never sent.
    func toggleStrike(_ option: Int) {
        guard !app.frozen.refuses(), !isBusy, items.indices.contains(index), !items[index].submitted else { return }
        items[index].draft = items[index].draft.striking(option, in: &items[index].struck)
    }

    func setGuessed(_ guessed: Bool) {
        guard !app.frozen.refuses(), !isBusy, items.indices.contains(index) else { return }
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
            problem = error.message
            return
        }
        problem = nil
        isSaving = true
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

    private func send(_ submission: AttemptSubmission, at position: Int) async {
        defer {
            isSaving = false
            isWaiting = false
        }
        var delay = Self.firstRetryDelay
        while true {
            do {
                _ = try await app.client.recordAttempt(submission)
                markSubmitted(position)
                return
            } catch where Self.isTransient(error) {
                isWaiting = true
            } catch {
                if error == .cancelled || isEnding { return }
                if error.serverCode == .alreadyAnswered {
                    markSubmitted(position)
                } else if error.serverCode == .examFinished {
                    if let ended = try? await app.client.exam(id: examID) {
                        show(ended)
                    } else {
                        problem = Wording.problem(error)
                    }
                } else if !app.handle(error) {
                    problem = Wording.problem(error)
                }
                return
            }
            do {
                try await sleep(delay)
            } catch {
                return
            }
            if Task.isCancelled || isEnding || phase != .running { return }
            delay = min(delay * 2, Self.longestRetryDelay)
        }
    }

    private func markSubmitted(_ position: Int) {
        guard items.indices.contains(position), phase == .running else { return }
        items[position].submitted = true
        items[position].skipped = false
        go(from: position)
    }

    /// Leaves the question open for later and moves on.
    func skip() async {
        guard !app.frozen.refuses(), !isBusy, items.indices.contains(index) else { return }
        problem = nil
        items[index].skipped = true
        go(from: index)
    }

    private func go(from position: Int) {
        guard let stop = nextStop(from: position) else {
            Task { await end(.finished) }
            return
        }
        if stop.wrapped { isReturning = true }
        wrappedTo = stop.wrapped ? stop.index : nil
        index = stop.index
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

    /// Ends the exam and shows the result. Her open answer, if one is still sending, is dropped,
    /// as on the web: the end scores what the server has.
    func end(_ reason: ExamEndReason) async {
        guard !app.frozen.refuses(), phase == .running, !isEnding else { return }
        isEnding = true
        sending?.cancel()
        problem = nil
        do {
            let ended = try await app.client.finishExam(id: examID, reason: reason)
            isEnding = false
            show(ended)
        } catch {
            isEnding = false
            if app.handle(error) { return }
            // The server's own refusal says what happened; anything else is the connection, as on the web.
            if case .server(let server) = error {
                problem = server.message
            } else {
                problem = "Could not end the exam. Check the connection and try again."
            }
        }
    }
}
