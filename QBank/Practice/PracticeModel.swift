import Foundation
import Observation
import QBankKit

/// One run through a practice set or the course's Review list: the questions in order, her answer
/// to each, and its score. Works like the web runner (`apps/web/src/practice/PracticeScreen.tsx`):
/// every opening shuffles the choices, Check answer sends the answer and shows the server's score,
/// and after the last question the result. Without a connection a set comes from the phone, and
/// Check answer keeps the answer on the phone to send later and shows the score the phone gives
/// it, with the server's rules. The Review list is chosen by the server, so it needs a connection.
///
/// A set she left midway opens at the first question she has not answered, from its sitting on the
/// server and the answers still waiting on the phone, and the answers she already checked count in
/// the result. The server closes the sitting once every question has an answer, so a finished set
/// opens at question 1. Review and samples have no sitting.
@Observable
final class PracticeModel {
    /// Her work on one question during this run. A question she answered earlier in the sitting
    /// comes with her answer's id and verdict.
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

    /// Where a set she left midway picked up, for the line under the title.
    struct PickedUp: Equatable {
        /// 1-based, the question it opened at.
        let number: Int
        /// When she last answered in the set, or nil when the sitting says nothing of it.
        let lastAnsweredAt: Date?
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
    /// The questions she answered before this opening, which the run does not ask again.
    private(set) var answeredEarlier: Set<String> = []
    /// Set while she is still on the question a set picked up at.
    private(set) var pickedUp: PickedUp?
    /// True while Check answer is sending.
    private(set) var isChecking = false
    /// True while Start over is asking QBank.
    private(set) var isStartingOver = false
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
    var isLast: Bool { nextIndex == nil }

    /// The next question she has not answered, after the current one.
    private var nextIndex: Int? {
        questions.indices.first { $0 > index && !answeredEarlier.contains(questions[$0].id) }
    }

    /// Whether the current answer is checked and waits on the phone to be sent.
    var isWaitingToSend: Bool {
        guard let attempt, attempt.score != nil else { return false }
        return app.offline?.waiting.contains { $0.id == attempt.clientAttemptID } ?? false
    }

    /// Answers on the phone that QBank does not have yet, from this run and earlier ones.
    var waitingCount: Int { app.offline?.waiting.count ?? 0 }

    /// "3 of 17".
    var countText: String { "\(index + 1) of \(questions.count)" }

    /// Questions done, counting this one once it is checked and the ones she answered earlier.
    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(answeredCount) / Double(questions.count)
    }

    /// The questions with an answer in this sitting, this run's and the earlier ones.
    var answeredCount: Int {
        zip(questions, attempts).count { question, attempt in
            attempt.score != nil || answeredEarlier.contains(question.id)
        }
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
            // This opening's time would say little of a set she answered over several nights.
            elapsed: answeredEarlier.isEmpty ? (finishedAt ?? startedAt).timeIntervalSince(startedAt) : nil
        )
    }

    // MARK: Loading

    func load() async {
        guard app.account?.role == .student else {
            phase = .readOnly
            return
        }
        // Read before asking QBank: an answer may reach it after its reply was written.
        let waitingBefore = app.offline?.waiting ?? []
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
            begin(await countingWaiting(waitingBefore, in: loaded))
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

    /// A set with the answers waiting on the phone counted in its sitting. The copy saved on the phone
    /// keeps them, so her place holds once they are sent and the signal goes again.
    private func countingWaiting(_ waitingBefore: [PendingAttempt], in set: PracticeSet) async -> PracticeSet {
        guard case .set = source, let offline = app.offline else { return set }
        let later = offline.waiting.filter { attempt in !waitingBefore.contains { $0.id == attempt.id } }
        let counted = set.counting(waiting: waitingBefore + later)
        if counted != set {
            await offline.keep(counted)
        }
        return counted
    }

    private func begin(_ loaded: PracticeSet) {
        practiceSet = loaded
        questions = loaded.questions.sorted { $0.position < $1.position }
        let answered = Set(loaded.sitting?.answeredQuestionIDs ?? [])
        // Every question answered is a finished set, which opens fresh.
        let place = answered.isEmpty ? nil : questions.firstIndex { !answered.contains($0.id) }
        let answers = place == nil ? [:] : Dictionary((loaded.sitting?.answers ?? []).map { ($0.questionID, $0) }) { _, latest in latest }
        attempts = questions.map { question in
            let layout = makeLayout(question.body)
            let answer = answers[question.id]
            return Attempt(
                layout: layout,
                draft: AnswerDraft(body: question.body, layout: layout),
                guessed: answer?.guessed ?? false,
                clientAttemptID: answer?.clientAttemptID ?? newAttemptID(),
                feedback: answer.map(Feedback.init)
            )
        }
        if let place {
            answeredEarlier = answered
            index = place
            pickedUp = PickedUp(number: place + 1, lastAnsweredAt: answers.values.map(\.answeredAt).max())
        } else {
            practiceSet?.sitting = nil
            answeredEarlier = []
            index = 0
            pickedUp = nil
        }
        problem = nil
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
            shuffle: attempt.layout,
            fromReview: isReview
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
        await keepPlace(question: question, attempt: attempts[checking])
    }

    /// Keeps a checked answer in the set's copy on the phone, so the set opens past it even when QBank
    /// cannot be reached next time.
    private func keepPlace(question: Question, attempt: Attempt) async {
        guard case .set = source, let practiceSet, let feedback = attempt.feedback, let offline = app.offline else { return }
        let counted = practiceSet.counting(SittingAnswer(
            clientAttemptID: attempt.clientAttemptID, questionID: question.id, feedback: feedback,
            guessed: attempt.guessed, answeredAt: now()
        ))
        self.practiceSet = counted
        await offline.keep(counted)
    }

    /// Ends the sitting and opens the set again at question 1. Every answer stays saved and still
    /// counts. QBank must have what she answered first, or it would count in the new sitting, so this
    /// needs a connection. A failure leaves her where she was, and says why.
    func startOver() async {
        guard case .set(let id) = source, let practiceSet, !isChecking, !isStartingOver else { return }
        problem = nil
        isStartingOver = true
        defer { isStartingOver = false }
        do throws(QBankError) {
            if let offline = app.offline, !offline.waiting.isEmpty {
                let report = await offline.send()
                guard offline.waiting.isEmpty else {
                    throw report.stoppedBy ?? QBankError.transport(.notConnectedToInternet)
                }
            }
            try await app.client.startPracticeSetOver(id: id)
        } catch {
            if error == .cancelled || app.handle(error) { return }
            problem = "Could not start over. Check your connection and try again."
            return
        }
        var fresh = practiceSet
        fresh.sitting = nil
        await app.offline?.keep(fresh)
        begin(fresh)
    }

    /// The next question she has not answered, or the set result after the last one.
    func next() {
        guard isRevealed || attempt?.draft == .unsupported else { return }
        pickedUp = nil
        if let nextIndex {
            problem = nil
            index = nextIndex
        } else if phase == .answering {
            finishedAt = now()
            phase = .finished
        }
    }
}
