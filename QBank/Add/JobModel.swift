import Foundation
import Observation
import QBankKit

/// A set being made on the server, followed while its screen is open: reading her material,
/// writing samples, her check of them (Q-4) or of the questions copied from her photos (Q-2b),
/// writing the rest (Q-5), and the finished set (Q-6). The work goes on on the server when she
/// leaves; this only reads it and sends her answers.
@Observable
final class JobModel {
    /// Her word on a sample, kept on the phone: the server hears it as her notes.
    enum Verdict: Hashable {
        case notChecked
        case looksRight
        case change
    }

    let id: String
    private(set) var job: QuestionJob?
    /// While it waits for her check of the samples.
    private(set) var samples: QuestionSamples?
    /// While it waits for her check of the copies.
    private(set) var copies: QuestionCopies?
    /// Once filed.
    private(set) var result: QuestionResult?
    private(set) var problem: String?
    private(set) var isSending = false
    /// The set is not hers or not there anymore.
    private(set) var isGone = false

    private(set) var verdicts: [String: Verdict] = [:]
    /// What to change, by sample.
    var notes: [String: String] = [:]

    /// Copies she leaves out.
    private(set) var skipped: Set<String> = []
    /// Answers she set, by copy, as the choices picked.
    private(set) var answers: [String: Set<Int>] = [:]

    private let app: AppModel
    private let pollInterval: Duration

    /// `seed` is the set as last read elsewhere, shown until this model reads it.
    init(app: AppModel, id: String, seed: QuestionJob? = nil, pollInterval: Duration = .seconds(2)) {
        self.app = app
        self.id = id
        self.pollInterval = pollInterval
        job = seed
    }

    /// The server is working on it, so the screen keeps reading it.
    var isWorking: Bool {
        guard let job else { return !isGone }
        return job.status == .running
    }

    func load() async {
        do {
            let next = try await app.client.questionJob(id: id)
            try await loadDetails(of: next)
            job = next
            problem = nil
        } catch {
            if app.handle(error) { return }
            if case .server(let server) = error, server.status == 404 {
                isGone = true
            }
            problem = Wording.problem(error)
        }
    }

    /// Reads the job until it waits for her or has ended, every couple of seconds, for as long as
    /// the screen is open.
    func follow() async {
        await load()
        while isWorking, !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// What the step it is at shows: the samples or copies she checks, or the finished set.
    private func loadDetails(of next: QuestionJob) async throws(QBankError) {
        switch (next.status, next.waitingFor) {
        case (.waiting, .samples?):
            // A set that comes back to her samples after running again has new ones, even when
            // both of its updates fell in the same millisecond.
            if samples == nil || job?.waitingFor != .samples || job?.updatedAt != next.updatedAt {
                take(try await app.client.questionSamples(jobID: id))
            }
        case (.waiting, .copies?):
            if copies == nil {
                copies = try await app.client.questionCopies(jobID: id)
            }
        case (.done, _):
            if result == nil {
                result = try await app.client.questionResult(jobID: id)
            }
        default:
            break
        }
    }

    private func take(_ next: QuestionSamples) {
        // New samples, after her notes, start unchecked.
        if samples?.round != next.round {
            verdicts = [:]
            notes = [:]
        }
        samples = next
    }

    // MARK: Samples (Q-4)

    func verdict(_ question: Question) -> Verdict {
        verdicts[question.id] ?? .notChecked
    }

    func mark(_ question: Question, _ verdict: Verdict) {
        verdicts[question.id] = verdict
    }

    /// The samples she marked Change, in order, for their notes.
    var changing: [Question] {
        samples?.questions.filter { verdict($0) == .change } ?? []
    }

    /// Her notes on the samples she marked Change, without the empty ones.
    var changes: [SampleChange] {
        changing.compactMap { question in
            let note = notes[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note.isEmpty ? nil : SampleChange(questionID: question.id, note: note)
        }
    }

    /// How many questions the rest is: the count less the samples.
    var restCount: Int {
        max(0, (job?.count ?? 0) - (samples?.questions.count ?? 0))
    }

    /// The samples can be written again from her notes: she wrote one, and the server allows
    /// another round.
    var canRevise: Bool {
        samples?.canRevise == true && !changes.isEmpty
    }

    /// The samples look right: the rest is written the same way, following her notes.
    func acceptSamples() async {
        let words = changes.compactMap { change -> String? in
            guard let number = samples?.questions.firstIndex(where: { $0.id == change.questionID }) else { return nil }
            return "Sample \(number + 1): \(change.note)"
        }
        await send { () async throws(QBankError) in
            try await app.client.acceptSamples(jobID: id, words: words.isEmpty ? nil : words.joined(separator: "\n"))
        }
    }

    /// Writes the samples again from her notes.
    func reviseSamples() async {
        let changes = changes
        guard !changes.isEmpty else { return }
        await send { () async throws(QBankError) in try await app.client.reviseSamples(jobID: id, changes: changes) }
    }

    // MARK: Copies (Q-2b)

    func isSkipped(_ copy: QuestionCopies.Copy) -> Bool {
        skipped.contains(copy.id)
    }

    func setSkipped(_ copy: QuestionCopies.Copy, _ skip: Bool) {
        if skip { skipped.insert(copy.id) } else { skipped.remove(copy.id) }
    }

    /// The answer she set, or nil for the one copied.
    func answer(_ copy: QuestionCopies.Copy) -> Set<Int>? {
        answers[copy.id]
    }

    /// Sets her answer; the one already copied clears it.
    func setAnswer(_ copy: QuestionCopies.Copy, _ picks: Set<Int>) {
        answers[copy.id] = picks == MakeWording.key(copy.question) ? nil : picks
    }

    /// The copies she keeps.
    var keptCount: Int {
        copies?.questions.count { !isSkipped($0) } ?? 0
    }

    /// Adds the copies she kept, in order, each with her answer when she set one.
    func acceptCopies() async {
        guard let copies else { return }
        let keep = copies.questions.filter { !isSkipped($0) }.map { copy in
            KeptCopy(id: copy.id, question: answers[copy.id].map { Self.file(copy.file, answering: $0) })
        }
        await send { () async throws(QBankError) in try await app.client.acceptCopies(jobID: id, keep: keep) }
    }

    /// A copied question in the set file format with her answer: the picked choices marked
    /// `"ok": true` and the rest unmarked.
    static func file(_ file: JSONValue, answering picks: Set<Int>) -> JSONValue {
        guard case .object(var question) = file, case .array(let options)? = question["options"] else { return file }
        question["options"] = .array(
            options.enumerated().map { index, option in
                guard case .object(var choice) = option else { return option }
                if picks.contains(index) {
                    choice["ok"] = .bool(true)
                } else {
                    choice.removeValue(forKey: "ok")
                }
                return .object(choice)
            })
        return .object(question)
    }

    // MARK: Stopping

    /// Stops the set. Nothing is filed, and her material is deleted on the server.
    func cancel() async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            job = try await app.client.cancelQuestionJob(id: id)
            return true
        } catch {
            if app.handle(error) { return false }
            problem = Wording.problem(error)
            return false
        }
    }

    private func send(_ call: () async throws(QBankError) -> QuestionJob) async {
        problem = nil
        isSending = true
        defer { isSending = false }
        do {
            job = try await call()
        } catch {
            if app.handle(error) { return }
            problem = Wording.problem(error)
        }
    }
}
