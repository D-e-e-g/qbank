import Foundation
import Observation
import QBankKit

/// One run through a practice set or the course's Review list: the questions in order, her answer
/// to each, and its score. Works like the web runner (`apps/web/src/practice/PracticeScreen.tsx`):
/// every opening shuffles the choices, Check answer sends the answer and shows the server's score,
/// and after the last question the result. Without a connection a set comes from the phone, and
/// Check answer keeps the answer on the phone to send later and shows the score the phone gives
/// it, with the server's rules. The Review list is chosen by the server, so it needs a connection.
@Observable
final class PracticeModel {
    /// Her work on one question during this run.
    struct Attempt: Equatable {
        /// The order she sees the choices in, made once per opening and saved with the answer.
        let layout: Layout
        var draft: AnswerDraft
        var guessed = false
        /// Original indexes of the choices she has struck out, for this run only.
        var struck: Set<Int> = []
        /// Made once per opening, so a retried send is never counted twice.
        let clientAttemptID: String
        /// The verdict once she has checked: the server's score and words, or the phone's while
        /// the answer waits to be sent.
        var feedback: Feedback?

        var score: Score? { feedback?.score }
    }

    enum Phase: Equatable {
        case loading
        /// The set could not be opened, said in words for her.
        case failed(String)
        /// Someone other than the student: the owner can look at her progress but not answer.
        case readOnly
        case answering
        case finished
    }

    let source: PracticeRoute.Source
    let courseID: String
    /// The set's title from the Course screen, or "Review", shown while it loads.
    let initialTitle: String

    private(set) var phase: Phase = .loading
    private(set) var practiceSet: PracticeSet?
    /// The set's questions in the order she practices them.
    private(set) var questions: [Question] = []
    private(set) var attempts: [Attempt] = []
    private(set) var index = 0
    /// True while Check answer is sending.
    private(set) var isChecking = false
    /// Why the last Check answer did not go through.
    private(set) var problem: String?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    let app: AppModel
    private let now: () -> Date
    private let makeLayout: (QuestionBody) -> Layout
    private let newAttemptID: () -> String

    init(
        app: AppModel,
        source: PracticeRoute.Source,
        courseID: String,
        title: String,
        now: @escaping () -> Date = { .now },
        makeLayout: @escaping (QuestionBody) -> Layout = { Layout.make(for: $0) },
        newAttemptID: @escaping () -> String = { AttemptSubmission.newID() }
    ) {
        self.app = app
        self.source = source
        self.courseID = courseID
        self.initialTitle = title
        self.now = now
        self.makeLayout = makeLayout
        self.newAttemptID = newAttemptID
    }

    var title: String { practiceSet?.title ?? initialTitle }

    var isReview: Bool {
        if case .review = source { return true }
        return false
    }

    /// A sample of a set being made: scored on the phone and never sent.
    var isSample: Bool {
        if case .sample = source { return true }
        return false
    }

    var question: Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    var attempt: Attempt? {
        attempts.indices.contains(index) ? attempts[index] : nil
    }

    var isRevealed: Bool { attempt?.score != nil }
    var isLast: Bool { index == questions.count - 1 }

    /// Whether the current answer is checked and waits on the phone to be sent.
    var isWaitingToSend: Bool {
        guard let attempt, attempt.score != nil else { return false }
        return app.offline?.waiting.contains { $0.id == attempt.clientAttemptID } ?? false
    }

    /// Answers on the phone that QBank does not have yet, from this run and earlier ones.
    var waitingCount: Int { app.offline?.waiting.count ?? 0 }

    /// "3 of 17".
    var countText: String { "\(index + 1) of \(questions.count)" }

    /// Questions done, counting this one once it is checked.
    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(index + (isRevealed ? 1 : 0)) / Double(questions.count)
    }

    /// Whether Check answer can be pressed: every required part is filled in and nothing is sending.
    var canCheck: Bool {
        guard let attempt, attempt.score == nil, !isChecking else { return false }
        return attempt.draft.response != nil
    }

    var result: PracticeResult? {
        guard phase == .finished, let startedAt else { return nil }
        return PracticeResult(
            title: title,
            isReview: isReview,
            questions: questions,
            attempts: attempts,
            elapsed: (finishedAt ?? startedAt).timeIntervalSince(startedAt)
        )
    }

    // MARK: Loading

    func load() async {
        guard app.account?.role == .student else {
            phase = .readOnly
            return
        }
        do {
            let loaded = switch source {
            case .set(let id):
                try await app.load(.practiceSet(id)) { () async throws(QBankError) in try await app.client.practiceSet(id: id) }.value
            case .review(let filter, let questionID):
                try await app.client.reviewPractice(courseID: courseID, filter: filter, questionID: questionID)
            case .sample(let jobID, let sampleID):
                try await sample(jobID: jobID, sampleID: sampleID)
            }
            if loaded.kind == .exam {
                phase = .failed("This set’s questions are asked only on exams.")
                return
            }
            guard loaded.courseID == courseID else {
                phase = .failed("That set is not in this course.")
                return
            }
            begin(loaded)
        } catch {
            if app.handle(error) { return }
            if case .transport = error, !isReview, !isSample {
                phase = .failed("No connection, and this set is not saved on this \(Device.noun) yet. Open it once with a connection to practice it offline.")
            } else if let words = Wording.problem(error) {
                phase = .failed(words)
            }
        }
    }

    /// One sample of a set being made, as a set of one question.
    private func sample(jobID: String, sampleID: String) async throws(QBankError) -> PracticeSet {
        let samples = try await app.client.questionSamples(jobID: jobID)
        guard let index = samples.questions.firstIndex(where: { $0.id == sampleID }) else {
            throw .server(ServerError(status: 404, code: .requestRefused, message: "That sample is not in this set anymore."))
        }
        return PracticeSet(id: jobID, courseID: courseID, title: "Sample \(index + 1)", questions: [samples.questions[index]])
    }

    private func begin(_ loaded: PracticeSet) {
        practiceSet = loaded
        questions = loaded.questions.sorted { $0.position < $1.position }
        attempts = questions.map { question in
            let layout = makeLayout(question.body)
            return Attempt(layout: layout, draft: AnswerDraft(body: question.body, layout: layout), clientAttemptID: newAttemptID())
        }
        index = 0
        startedAt = now()
        finishedAt = nil
        phase = .answering
    }

    // MARK: Answering

    /// Replaces her answer to the current question while it is still open. A struck choice
    /// cannot be picked until she restores it.
    func update(_ draft: AnswerDraft) {
        guard attempts.indices.contains(index), attempts[index].score == nil, !isChecking else { return }
        guard attempts[index].struck.isDisjoint(with: draft.picked) else { return }
        attempts[index].draft = draft
    }

    /// Strikes out a choice of the current question she has ruled out, or restores a struck one,
    /// while it is still open. Strikes stay with the question until the run ends and are never sent.
    func toggleStrike(_ option: Int) {
        guard attempts.indices.contains(index), attempts[index].score == nil, !isChecking else { return }
        attempts[index].draft = attempts[index].draft.striking(option, in: &attempts[index].struck)
    }

    func setGuessed(_ guessed: Bool) {
        guard attempts.indices.contains(index), attempts[index].score == nil, !isChecking else { return }
        attempts[index].guessed = guessed
    }

    /// Sends the answer and shows the score and words the server gave it. Without a connection, or
    /// when QBank cannot be reached, the answer is kept on the phone and sent later with the same id,
    /// so it is never counted twice; she sees the phone's score and words, which follow the server's
    /// rules. A refusal is said in her words.
    func check() async {
        guard canCheck, let question, let attempt, let response = attempt.draft.response else { return }
        problem = nil
        let phoneScore: Score
        do {
            // Also catches an answer the question cannot take before it leaves the phone.
            phoneScore = try Scoring.score(question.body, response: response)
        } catch {
            problem = error.message
            return
        }
        let phoneFeedback = Feedback(phone: phoneScore, type: question.type)
        if isSample {
            attempts[index].feedback = phoneFeedback
            return
        }
        let checking = index
        isChecking = true
        defer { isChecking = false }
        let submission = AttemptSubmission(
            clientAttemptID: attempt.clientAttemptID,
            questionID: question.id,
            response: response,
            guessed: attempt.guessed,
            shuffle: attempt.layout
        )
        let feedback: Feedback
        do {
            switch try await app.submit(submission, courseID: courseID) {
            case .sent(let saved):
                feedback = Feedback(saved)
            case .waiting(let reason):
                // A session that ended goes to sign-in; the answer waits for her on the phone.
                if app.handle(reason) { return }
                feedback = phoneFeedback
            case .accepted:
                feedback = phoneFeedback
            }
        } catch {
            if error == .cancelled || app.handle(error) { return }
            if case .storage = error {
                problem = "This \(Device.model) could not save your answer. Try again."
            } else {
                problem = Wording.problem(error)
            }
            return
        }
        guard attempts.indices.contains(checking), attempts[checking].score == nil else { return }
        attempts[checking].feedback = feedback
    }

    /// The next question, or the set result after the last one.
    func next() {
        guard isRevealed else { return }
        if index < questions.count - 1 {
            problem = nil
            index += 1
        } else if phase == .answering {
            finishedAt = now()
            phase = .finished
        }
    }
}
