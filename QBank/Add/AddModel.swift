import Foundation
import Observation
import QBankKit

/// The Add tab's hub: whether this account may make questions now, as the server says, the choices
/// it offers, and her recent sets. Import is for everyone and needs nothing from here.
@Observable
final class AddModel {
    /// What `GET /api/question-maker` says: whether she may start a set now, why not in the
    /// server's words, and the choices. Nil until QBank answers.
    private(set) var status: QuestionMakerStatus?
    private(set) var jobs: [QuestionJob] = []

    private let app: AppModel
    private let now: () -> Date

    init(app: AppModel, now: @escaping () -> Date = Date.init) {
        self.app = app
        self.now = now
    }

    /// Make questions shows only when the server says she may start a set now.
    var canMake: Bool {
        status?.available == true
    }

    /// How many sets are left today, or why she cannot make questions now, in the server's words:
    /// not on this account, not set up yet, or the daily limit.
    var makeNote: String? {
        // The server tells the admin only that it makes nothing, in words of its own.
        if app.frozen.isOn { return app.frozen.note }
        guard let status else { return nil }
        if status.available { return MakeWording.allowance(started: status.startedToday, limit: status.dailyLimit) }
        return status.reason
    }

    /// The sets under In progress: those still going or waiting for her, those that stopped, and
    /// those finished in the last day, so she can open the finished set.
    var inProgress: [QuestionJob] {
        let since = now().addingTimeInterval(-86_400)
        return jobs.filter { job in
            switch job.status {
            case .running, .waiting, .failed: true
            case .done: (job.finishedAt ?? job.updatedAt) > since
            case .cancelled: false
            }
        }
    }

    func load() async {
        guard app.connection.isOnline else { return }
        do {
            status = try await app.client.questionMakerStatus()
        } catch {
            // Import works either way, so a failed check keeps what was known.
            app.handle(error)
            return
        }
        do {
            jobs = try await app.client.questionJobs()
        } catch {
            if app.handle(error) { return }
            // The job routes refuse an account the server does not allow, and every account
            // while it is not set up: then she has no sets to show.
            if error.serverCode == .notAllowed || error.serverCode == .notSetUp { jobs = [] }
        }
    }
}

/// The words of the make-questions screens.
nonisolated enum MakeWording {
    /// "2 of 3 sets left today".
    static func allowance(started: Int, limit: Int) -> String {
        "\(max(0, limit - started)) of \(Wording.count(limit, "set")) left today"
    }

    /// A set being made, as the In progress row says it: "NURS 406 · Week 4 · 9 of 15 written".
    /// A topic is named by its name.
    static func progress(_ job: QuestionJob) -> String {
        "\(course(job)) · \(job.folder.name) · \(state(job))"
    }

    /// The course's code, or the topic's name.
    static func course(_ job: QuestionJob) -> String {
        Wording.name(code: job.course.code, title: job.course.title)
    }

    /// Where a set being made is, in a few words.
    static func state(_ job: QuestionJob) -> String {
        switch job.status {
        case .waiting: return job.waitingFor == .copies ? "Questions to check" : "Samples to check"
        case .done: return "Ready"
        case .failed: return "Stopped"
        case .cancelled: return "Cancelled"
        case .running: break
        }
        let step = job.currentStep
        switch step?.key {
        case .read?:
            if job.materialKind == .questions { return "Copying the questions" }
            return job.photoCount > 0 ? "Reading your \(Wording.count(job.photoCount, "photo"))" : "Reading your material"
        case .samples?: return "Writing the samples"
        case .write?:
            if let done = step?.done, let total = step?.total { return "\(done) of \(total) written" }
            return "Writing the rest"
        case .check?: return "Blind check"
        case .twins?: return "Writing exam twins"
        case .file?: return "Filing the set"
        case .review?, .done?, nil: return "Working"
        }
    }

    /// The big line of the writing screen: "9 of 15 written", or the step it is on.
    static func headline(_ job: QuestionJob) -> String {
        if let step = job.currentStep, let done = step.done, let total = step.total {
            switch step.key {
            case .write: return "\(done) of \(total) written"
            case .twins: return "\(done) of \(total) exam twins written"
            default: break
            }
        }
        return state(job)
    }

    /// How far the step the headline counts has got, from 0 to 1: "9 of 15 written" is 60%. Nil
    /// while the step counts nothing.
    static func fraction(_ job: QuestionJob) -> Double? {
        guard let step = job.currentStep, let done = step.done, let total = step.total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// The set's name, or what it is while it has none yet.
    static func title(_ job: QuestionJob) -> String {
        if let title = job.title, !title.isEmpty { return title }
        if let set = job.sets.first { return set.title }
        return job.materialKind == .questions ? "Questions from your photos" : "Your new set"
    }

    /// "Schizophrenia and Antipsychotics · NURS 406 · Week 4".
    static func place(_ job: QuestionJob) -> String {
        "\(title(job)) · \(course(job)) · \(job.folder.name)"
    }

    /// The title of the screen that follows a running set.
    static func runningTitle(_ job: QuestionJob) -> String {
        switch job.currentStep?.key {
        case .read?: job.materialKind == .questions ? "Copying the questions" : job.photoCount > 0 ? "Reading your photos" : "Reading your material"
        case .samples?: "Writing 5 samples"
        default: job.materialKind == .questions ? "Adding your questions" : "Writing your set"
        }
    }

    /// Said without a promise of a notification, which the app does not send yet.
    static let leaveNote = "You can leave this screen. The set keeps going on QBank and shows under In progress on Add until it is ready."

    /// The level's line under the picker, from her recipe.
    static let levels = "Exam: short four-option questions like your class exam, tricky through the wrong answers. Course: NCLEX formats one step below the board. Board: hard NCLEX board items."

    static func level(_ level: QuestionLevel) -> String {
        switch level {
        case .exam: "Exam"
        case .course: "Course"
        case .board: "Board"
        }
    }

    /// "About 20 minutes to write", an estimate until real sets are measured.
    static func writingTime(count: Int) -> String {
        let minutes = max(5, Int((Double(count) * 4 / 3 / 5).rounded(.up)) * 5)
        return "About \(minutes) minutes to write"
    }

    /// The formats a level writes.
    static func kinds(_ level: QuestionLevel) -> (title: String, detail: String) {
        switch level {
        case .exam: ("Four-option single answer", "Exam level asks like your class exam. Board and Course mix all 8 NCLEX formats.")
        case .course, .board: ("All 8 NCLEX formats, mixed", "Board and Course. Exam level uses four-option single answer only.")
        }
    }

    /// "Single answer · 4 choices".
    static func shape(_ question: Question) -> String {
        let format = Wording.format(question.type)
        guard let options = options(question) else { return format }
        return "\(format) · \(options.count) choices"
    }

    /// The choices of a question whose answer she can set here: single, priority, select all.
    static func options(_ question: Question) -> [QuestionOption]? {
        switch question.body {
        case .single(let options), .priority(let options), .sata(let options): options
        default: nil
        }
    }

    /// The choices the question's key marks right.
    static func key(_ question: Question) -> Set<Int> {
        guard let options = options(question) else { return [] }
        return Set(options.indices.filter { options[$0].isCorrect })
    }

    /// "B", "A, C, D": the letters of the picked choices, in order.
    static func letters(_ picks: Set<Int>) -> String? {
        picks.isEmpty ? nil : picks.sorted().map(letter).joined(separator: ", ")
    }

    static func letter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index % 26)))
    }

    /// The answer line on a copied question: hers, from the photo, or QBank's suggestion to check.
    static func answer(_ copy: QuestionCopies.Copy, chosen: Set<Int>?) -> String? {
        if let chosen, let letters = letters(chosen) { return "Your answer: \(letters)" }
        guard let letters = letters(key(copy.question)) else { return nil }
        switch copy.answerFrom {
        case .suggested: return "No answer in the photo · QBank suggests \(letters), check it"
        case .photo: return "Answer from the photo: \(letters)"
        }
    }

    /// "From 2 photos · NURS 402 · Week 3. Tap a question to check its answer or leave it out."
    static func copiesNote(_ copies: QuestionCopies, _ job: QuestionJob) -> String {
        let from = copies.photoCount > 0 ? "From \(Wording.count(copies.photoCount, "photo"))" : "From your material"
        return "\(from) · \(course(job)) · \(job.folder.name). Tap a question to check its answer or leave it out."
    }

    /// "4 questions found".
    static func found(_ copies: QuestionCopies) -> String {
        "\(Wording.count(copies.questions.count, "question")) found"
    }

    static func verdict(_ verdict: JobModel.Verdict) -> String {
        switch verdict {
        case .looksRight: "Looks right"
        case .change: "Change"
        case .notChecked: "Not checked"
        }
    }

    /// The blind check's line on the finished set: "13 of 15 passed the blind check · 1 fixed, 1 removed".
    static func blindCheck(_ check: QuestionResult.BlindCheck) -> String {
        let total = check.passed + check.fixed + check.removed
        var line = "\(check.passed) of \(total) passed the blind check"
        var changes: [String] = []
        if check.fixed > 0 { changes.append("\(check.fixed) fixed") }
        if check.removed > 0 { changes.append("\(check.removed) removed") }
        if !changes.isEmpty { line += " · " + changes.joined(separator: ", ") }
        return line
    }

    /// "“Title” · 15 questions in NURS 406, Week 4."
    static func finished(_ result: QuestionResult, course: String) -> String {
        "“\(result.set.title)” · \(Wording.count(result.set.questionCount, "question")) in \(course), \(result.set.folderName)."
    }
}
