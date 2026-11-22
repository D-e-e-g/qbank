#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// What the fake question maker needs from the rest of `FakeQBankServer`: the courses and folders,
/// and filing a finished set the way an import files one.
nonisolated protocol FakeQuestionLibrary: AnyObject {
    func makerCourse(_ id: String) -> (code: String, title: String)?
    func makerFolderName(courseID: String, folderID: String) -> String?
    func makerSetTitle(_ id: String) -> String?
    /// Files the practice set, and the exam twins as the folder's exam bank. Nil when the folder
    /// cannot be made.
    func fileMadeSet(courseID: String, folderID: String?, folderName: String, title: String, questionCount: Int, termCount: Int, examTwins: Int) -> FakeQuestionMaker.Filed?
    /// Files an exam set of twins in a folder, the way an import files one. Its questions go into
    /// the folder's bank through `FakeStudy.fileTwins`.
    func fileTwinSet(courseID: String, folderID: String, title: String, questionCount: Int) -> (setID: String, examPageID: String?)
}

/// Make questions on the fake server, with the rules and words of the server's question maker
/// (`routes/question-maker.ts`, `question-maker/jobs.ts`): only the accounts it allows, nothing
/// without its Claude key, a daily limit, five samples or the copies for her to check, then the
/// rest written, checked, and filed. Nothing is written by a model: each read of a running set
/// moves it one step on, so a screen that polls sees it go.
nonisolated final class FakeQuestionMaker: Sendable {
    static let notAllowed = "Making questions is not available on this account. Import works on every account."
    static let notSetUp = "Making questions is not set up yet."
    static let dailyLimit = 3
    static let sampleSize = 5
    static let maxSampleRounds = 5
    static let levelSizes: [String: (min: Int, max: Int, default: Int)] = [
        "exam": (10, 15, 15), "course": (12, 16, 15), "board": (12, 16, 15),
    ]

    /// A set filed by the library.
    struct Filed {
        let setID: String
        let folderID: String
        let folderName: String
        let examPageID: String?
        let examSetID: String?
    }

    private struct Copy {
        let id: String
        let photo: Int?
        let answerFrom: String
        let explanationsFrom: String
        let template: Int
    }

    private struct Job {
        let id: String
        let owner: String
        let materialKind: String
        var status: String
        var step: String
        var progress: (done: Int, total: Int)?
        let courseID: String
        let folderID: String?
        let folderName: String?
        let level: String
        let referenceID: String?
        let count: Int?
        let examTwins: Bool
        let title: String?
        let photoCount: Int
        let createdAt: Date
        var updatedAt: Date
        var finishedAt: Date?
        var failure: String?
        var round = 0
        var sampleNote: String?
        var copies: [Copy] = []
        var unreadable: [(photo: Int?, reason: String)] = []
        var kept: [String] = []
        var filed: Filed?
        var filedTitle: String?
        var questionCount = 0
    }

    private struct State {
        var jobs: [Job]
        var made = 0
        /// Twin jobs started, by owner, which count against the daily limit like a set.
        var twinStarts: [(owner: String, at: Date)] = []
    }

    /// The accounts that may make questions, by email.
    private let allowed: Set<String>
    /// False: the server has no Claude key.
    private let isSetUp: Bool
    private let state: Mutex<State>

    init(allowed: Set<String>, isSetUp: Bool, seededFor owner: String?, now: Date = .now) {
        self.allowed = allowed
        self.isSetUp = isSetUp
        var jobs: [Job] = []
        if let owner {
            jobs.append(
                Job(
                    id: "a0b10000-0000-4000-8000-000000000002", owner: owner, materialKind: "questions", status: "waiting", step: "review",
                    courseID: FakeQBankServer.mentalHealthID, folderID: nil, folderName: "Week 3", level: "exam", referenceID: nil, count: nil,
                    examTwins: true, title: nil, photoCount: 2, createdAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-300),
                    copies: Self.seededCopies, unreadable: [(2, "The bottom of photo 2 is blurry.")]
                ))
            jobs.append(
                Job(
                    id: "a0b10000-0000-4000-8000-000000000001", owner: owner, materialKind: "notes", status: "running", step: "write",
                    progress: (9, 15), courseID: FakeQBankServer.mentalHealthID, folderID: nil, folderName: "Week 4", level: "exam",
                    referenceID: nil, count: 15, examTwins: true, title: "Schizophrenia and Antipsychotics", photoCount: 4,
                    createdAt: now.addingTimeInterval(-1_200), updatedAt: now.addingTimeInterval(-60), round: 1
                ))
        }
        state = Mutex(State(jobs: jobs))
    }

    private static var seededCopies: [Copy] {
        [
            Copy(id: "P01", photo: 1, answerFrom: "photo", explanationsFrom: "photo", template: 0),
            Copy(id: "P02", photo: 1, answerFrom: "photo", explanationsFrom: "qbank", template: 2),
            Copy(id: "P03", photo: 2, answerFrom: "suggested", explanationsFrom: "qbank", template: 1),
        ]
    }

    typealias Reply = (Int, [String: Any])

    /// Whether a set of hers is still being made in the course, so the course cannot be deleted yet.
    func isWorking(courseID: String, email: String) -> Bool {
        state.withLock { state in
            state.jobs.contains { $0.owner == email && $0.courseID == courseID && ["running", "waiting"].contains($0.status) }
        }
    }

    /// Whether a set of hers is being written in the course right now, so her account cannot be
    /// deleted yet. One waiting for her check is idle, and would go with the account.
    func isRunning(courseID: String, email: String) -> Bool {
        state.withLock { state in
            state.jobs.contains { $0.owner == email && $0.courseID == courseID && $0.status == "running" }
        }
    }

    /// The answer to a make-questions call, or nil for any other path.
    func answer(method: String, path: String, body: [String: Any], email: String, library: some FakeQuestionLibrary) -> Reply? {
        if method == "GET", path == "/api/question-maker" {
            return (200, status(email: email))
        }
        guard path == "/api/question-jobs" || path.hasPrefix("/api/question-jobs/") else { return nil }
        if let refusal = refusal(for: email) { return refusal }
        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts.count) {
        case ("GET", 2):
            let jobs = state.withLock { $0.jobs.filter { $0.owner == email } }
            return (200, ["jobs": jobs.map { json($0, library: library) }])
        case ("POST", 2):
            return start(body, email: email, library: library)
        default:
            break
        }
        let id = parts[2]
        guard state.withLock({ $0.jobs.contains { $0.id == id && $0.owner == email } }) else {
            return Self.failure(404, "not_found", "That set is not in QBank.")
        }
        switch (method, parts.dropFirst(3).joined(separator: "/")) {
        case ("GET", ""):
            return (200, json(tick(id, library: library), library: library))
        case ("GET", "samples"):
            return samples(id)
        case ("POST", "samples/accept"):
            return acceptSamples(id, words: body["words"] as? String, library: library)
        case ("POST", "samples/revise"):
            return revise(id, body: body, library: library)
        case ("GET", "copies"):
            return copies(id)
        case ("POST", "copies/accept"):
            return acceptCopies(id, keep: body["keep"] as? [[String: Any]] ?? [], library: library)
        case ("GET", "result"):
            return result(id, library: library)
        case ("POST", "cancel"):
            return cancel(id, library: library)
        default:
            return Self.failure(404, "not_found", "That is not in QBank.")
        }
    }

    // MARK: Status

    private func status(email: String) -> [String: Any] {
        let started = startedToday(email)
        var reason: String?
        if !allowed.contains(email) {
            reason = Self.notAllowed
        } else if !isSetUp {
            reason = Self.notSetUp
        } else if started >= Self.dailyLimit {
            reason = "You have started \(started) sets in the last 24 hours, the most for one day."
        }
        return [
            "available": reason == nil, "reason": json(reason), "dailyLimit": Self.dailyLimit, "startedToday": started,
            "nextAvailableAt": started >= Self.dailyLimit ? QBankJSON.formatDate(.now.addingTimeInterval(3 * 3_600)) : NSNull(),
            "levels": ["exam", "course", "board"].map { level in
                guard let size = Self.levelSizes[level] else {
                    preconditionFailure("Every question-maker level has a size.")
                }
                return ["level": level, "minCount": size.min, "maxCount": size.max, "defaultCount": size.default]
            },
            "defaultLevel": "exam", "sampleSize": Self.sampleSize,
            "limits": ["photos": 20, "photoBytes": 3_750_000, "fileBytes": 20_000_000, "textCharacters": 400_000],
            "imageTypes": ["image/jpeg", "image/png", "image/gif", "image/webp"],
            "fileTypes": ["application/pdf", "text/plain", "text/markdown"],
        ]
    }

    private func startedToday(_ email: String) -> Int {
        let since = Date.now.addingTimeInterval(-86_400)
        return state.withLock { state in
            state.jobs.count { $0.owner == email && $0.createdAt > since } + state.twinStarts.count { $0.owner == email && $0.at > since }
        }
    }

    // MARK: For exam twins

    /// The refusal of an account the server does not allow, or of every account while it is not
    /// set up; nil when she may use the make-questions routes, exam twins' among them.
    func refusal(for email: String) -> Reply? {
        guard allowed.contains(email) else { return Self.failure(403, "not_allowed", Self.notAllowed) }
        guard isSetUp else { return Self.failure(503, "not_set_up", Self.notSetUp) }
        return nil
    }

    /// Counts a twin job against her daily limit, as the server counts one like a set, or refuses
    /// it past the limit.
    func startTwins(email: String) -> Reply? {
        if let refusal = dailyLimitRefusal(email) { return refusal }
        state.withLock { $0.twinStarts.append((email, .now)) }
        return nil
    }

    private func dailyLimitRefusal(_ email: String) -> Reply? {
        let started = startedToday(email)
        guard started >= Self.dailyLimit else { return nil }
        return (
            429,
            [
                "error": "daily_limit",
                "message": "You have started \(started) sets in the last 24 hours, the most for one day. You can start another in 3 hours.",
                "availableAt": QBankJSON.formatDate(.now.addingTimeInterval(3 * 3_600)),
            ]
        )
    }

    // MARK: Starting

    private func start(_ body: [String: Any], email: String, library: some FakeQuestionLibrary) -> Reply {
        let kind = body["materialKind"] as? String ?? ""
        guard kind == "notes" || kind == "questions" else { return Self.failure(400, "invalid_request", "Say what the material is: notes or questions.") }
        let level = body["level"] as? String ?? "exam"
        guard let size = Self.levelSizes[level] else { return Self.failure(400, "invalid_request", "A level is exam, course, or board.") }
        var count: Int?
        if kind == "notes" {
            let asked = body["count"] as? Int ?? size.default
            guard asked >= size.min, asked <= size.max else {
                return Self.failure(400, "invalid_request", "At \(level) level a set has \(size.min) to \(size.max) questions.")
            }
            count = asked
        } else if body["count"] != nil {
            return Self.failure(400, "invalid_request", "Copying questions from photos copies every question it finds, so it takes no count.")
        }
        let reference = body["referenceSetId"] as? String
        if reference != nil, level != "exam" { return Self.failure(400, "invalid_request", "A reference set is only for exam level.") }
        if reference != nil, kind == "questions" { return Self.failure(400, "invalid_request", "Copied questions are not measured against a reference set.") }
        if let reference, library.makerSetTitle(reference) == nil { return Self.failure(400, "invalid_request", "That reference set is not in QBank.") }
        let folderID = body["folderId"] as? String
        let folderName = (body["folderName"] as? String)?.trimmingCharacters(in: .whitespaces)
        if folderID != nil, folderName != nil { return Self.failure(400, "invalid_request", "Choose a folder or a folder name, not both.") }
        let material = body["material"] as? [String: Any] ?? [:]
        let text = (material["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let images = material["images"] as? [[String: Any]] ?? []
        let file = material["file"] as? [String: Any]
        if images.count > 20 { return Self.failure(400, "invalid_request", "Send up to 20 photos at a time.") }
        for (index, image) in images.enumerated() {
            guard let data = (image["data"] as? String).flatMap({ Data(base64Encoded: $0) }), !data.isEmpty else {
                return Self.failure(400, "invalid_request", "Photo \(index + 1) did not arrive as an image. Add it again.")
            }
        }
        if text.isEmpty, images.isEmpty, file == nil {
            return Self.failure(400, "invalid_request", "Add your material first: paste text, add photos, or choose a file.")
        }
        let courseID = body["courseId"] as? String ?? ""
        guard library.makerCourse(courseID) != nil else { return Self.failure(404, "not_found", "That course is not in QBank.") }
        if let folderID, library.makerFolderName(courseID: courseID, folderID: folderID) == nil {
            return Self.failure(400, "invalid_request", "That folder is not in this course.")
        }
        if let refusal = dailyLimitRefusal(email) { return refusal }
        let job = state.withLock { state -> Job in
            state.made += 1
            let job = Job(
                id: String(format: "a0b10000-0000-4000-8000-%012d", 100 + state.made), owner: email, materialKind: kind, status: "running",
                step: "read", courseID: courseID, folderID: folderID, folderName: folderID == nil ? (folderName ?? "Unsorted") : nil,
                level: level, referenceID: reference, count: count, examTwins: body["examTwins"] as? Bool ?? true,
                title: (body["title"] as? String)?.trimmingCharacters(in: .whitespaces), photoCount: images.count,
                createdAt: .now, updatedAt: .now
            )
            state.jobs.insert(job, at: 0)
            return job
        }
        return (202, json(job, library: library))
    }

    // MARK: Moving on

    /// Moves a running set one step on, as if QBank had done that much work since it was last read.
    private func tick(_ id: String, library: some FakeQuestionLibrary) -> Job {
        let toFile = state.withLock { state -> Job? in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return nil }
            var job = state.jobs[index]
            guard job.status == "running" else { return nil }
            job.updatedAt = .now
            defer { state.jobs[index] = job }
            switch job.step {
            case "read":
                if job.materialKind == "notes" {
                    job.step = "samples"
                } else {
                    job.step = "review"
                    job.status = "waiting"
                    job.copies = Self.seededCopies
                    if job.photoCount > 1 { job.unreadable = [(job.photoCount, "The bottom of photo \(job.photoCount) is blurry.")] }
                }
            case "samples":
                job.round += 1
                job.step = "review"
                job.status = "waiting"
                job.sampleNote = job.round > 1 ? "Wrote them again from your notes." : nil
            case "write":
                let total = job.count ?? 15
                let done = min(total, (job.progress?.done ?? Self.sampleSize) + 3)
                if done >= total {
                    job.step = "check"
                    job.progress = nil
                } else {
                    job.progress = (done, total)
                }
            case "check":
                job.step = job.examTwins ? "twins" : "file"
                job.progress = job.examTwins ? (0, job.count ?? 15) : nil
            case "twins":
                let total = job.progress?.total ?? job.kept.count
                let done = min(total, (job.progress?.done ?? 0) + 5)
                if done >= total {
                    job.step = "file"
                    job.progress = nil
                } else {
                    job.progress = (done, total)
                }
            case "file":
                return job
            default:
                break
            }
            return nil
        }
        if let toFile { file(toFile, library: library) }
        return requireJob(id)
    }

    /// Files a set at its last step: the practice set, and its exam twins as the folder's bank.
    private func file(_ job: Job, library: some FakeQuestionLibrary) {
        let questionCount = job.materialKind == "notes" ? (job.count ?? 15) : job.kept.count
        let title = job.title ?? (job.materialKind == "notes" ? "\(job.folderName ?? "Unsorted") Practice" : "Copied from photos")
        let folderName = job.folderID.flatMap { library.makerFolderName(courseID: job.courseID, folderID: $0) } ?? job.folderName ?? "Unsorted"
        let filed = library.fileMadeSet(
            courseID: job.courseID, folderID: job.folderID, folderName: folderName, title: title,
            questionCount: questionCount, termCount: job.materialKind == "notes" ? questionCount * 2 : 0,
            examTwins: job.examTwins ? questionCount : 0
        )
        state.withLock { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            if let filed {
                state.jobs[index].status = "done"
                state.jobs[index].step = "done"
                state.jobs[index].filed = filed
                state.jobs[index].filedTitle = title
                state.jobs[index].questionCount = questionCount
            } else {
                state.jobs[index].status = "failed"
                state.jobs[index].failure = "QBank could not file the set. Nothing was added to your course."
            }
            state.jobs[index].finishedAt = .now
            state.jobs[index].updatedAt = .now
        }
    }

    // MARK: Her checks

    private func samples(_ id: String) -> Reply {
        let job = requireJob(id)
        guard job.materialKind == "notes" else { return Self.failure(409, "wrong_step", "This set copies questions from photos; it has no samples.") }
        guard job.round > 0 else { return Self.failure(409, "wrong_step", "The samples are not written yet.") }
        let templates = [6, 1, 2, 0, 4]
        return (
            200,
            [
                "round": job.round, "note": json(job.sampleNote), "canRevise": job.round < Self.maxSampleRounds,
                "questions": templates.enumerated().map { index, template in Self.draft(template: template, id: String(format: "A%02d", index + 1)) },
            ]
        )
    }

    private func waitingProblem(_ job: Job, for kind: String) -> Reply? {
        guard job.materialKind == kind else {
            return Self.failure(409, "wrong_step", kind == "notes" ? "This set copies questions from photos; it has no samples." : "This set writes new questions; it has no copies to check.")
        }
        guard job.status == "waiting", job.step == "review" else { return Self.failure(409, "wrong_step", "This set is not waiting for you right now.") }
        return nil
    }

    private func acceptSamples(_ id: String, words: String?, library: some FakeQuestionLibrary) -> Reply {
        if let words, words.count > 500 { return Self.failure(400, "invalid_request", "What you said is longer than 500 characters.") }
        return resume(id, kind: "notes", library: library) { job in
            job.step = "write"
            job.progress = (Self.sampleSize, job.count ?? 15)
        }
    }

    private func revise(_ id: String, body: [String: Any], library: some FakeQuestionLibrary) -> Reply {
        let job = requireJob(id)
        if let problem = waitingProblem(job, for: "notes") { return problem }
        if job.round >= Self.maxSampleRounds {
            return Self.failure(409, "wrong_step", "The samples were written \(Self.maxSampleRounds) times. Accept them, or cancel and start again with other material.")
        }
        let changes = body["changes"] as? [[String: Any]] ?? []
        let ids = Set((1...Self.sampleSize).map { String(format: "A%02d", $0) })
        var notes = 0
        for change in changes {
            let questionID = change["questionId"] as? String ?? ""
            guard ids.contains(questionID) else { return Self.failure(400, "invalid_request", "\(questionID) is not one of the samples.") }
            if !(change["note"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty { notes += 1 }
        }
        if !(body["note"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty { notes += 1 }
        guard notes > 0 else { return Self.failure(400, "invalid_request", "Say what to change in at least one sample.") }
        return resume(id, kind: "notes", library: library) { job in
            job.step = "samples"
            job.progress = nil
        }
    }

    private func copies(_ id: String) -> Reply {
        let job = requireJob(id)
        guard job.materialKind == "questions" else { return Self.failure(409, "wrong_step", "This set writes new questions; it has no copies to check.") }
        guard !job.copies.isEmpty else { return Self.failure(409, "wrong_step", "The questions are not copied yet.") }
        return (
            200,
            [
                "title": "Copied from photos", "photoCount": job.photoCount,
                "questions": job.copies.map { copy in
                    [
                        "id": copy.id, "photo": copy.photo.map { $0 as Any } ?? NSNull(), "answerFrom": copy.answerFrom,
                        "explanationsFrom": copy.explanationsFrom, "question": Self.draft(template: copy.template, id: copy.id),
                        "file": Self.file(template: copy.template, id: copy.id),
                    ] as [String: Any]
                },
                "unreadable": job.unreadable.map { ["photo": $0.photo.map { $0 as Any } ?? NSNull(), "reason": $0.reason] },
            ]
        )
    }

    private func acceptCopies(_ id: String, keep: [[String: Any]], library: some FakeQuestionLibrary) -> Reply {
        let job = requireJob(id)
        if let problem = waitingProblem(job, for: "questions") { return problem }
        guard !keep.isEmpty else { return Self.failure(400, "invalid_request", "Keep at least one question, or cancel the set.") }
        var seen: Set<String> = []
        var questions: [[String: Any]] = []
        for choice in keep {
            let copyID = choice["id"] as? String ?? ""
            guard seen.insert(copyID).inserted else { return Self.failure(400, "invalid_request", "\(copyID) is listed twice.") }
            guard let copy = job.copies.first(where: { $0.id == copyID }) else { return Self.failure(400, "invalid_request", "\(copyID) is not one of the copies.") }
            var question = choice["question"] as? [String: Any] ?? Self.file(template: copy.template, id: copy.id)
            question["id"] = copy.id
            questions.append(question)
        }
        let source = (try? JSONSerialization.data(withJSONObject: ["title": "Copied from photos", "questions": questions])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let check = FakeImportCheck(source: source)
        guard check.ok else { return Self.failure(400, "invalid_request", check.errors.first ?? "These questions can't be added.") }
        let kept = questions.compactMap { $0["id"] as? String }
        return resume(id, kind: "questions", library: library) { job in
            job.kept = kept
            job.step = job.examTwins ? "twins" : "file"
            job.progress = job.examTwins ? (0, kept.count) : nil
        }
    }

    /// Moves a set that waits for her back to work, as her answer says.
    private func resume(_ id: String, kind: String, library: some FakeQuestionLibrary, _ change: (inout Job) -> Void) -> Reply {
        let job = requireJob(id)
        if let problem = waitingProblem(job, for: kind) { return problem }
        let resumed = state.withLock { state -> Job in
            let index = Self.index(of: id, in: state.jobs)
            state.jobs[index].status = "running"
            state.jobs[index].updatedAt = .now
            change(&state.jobs[index])
            return state.jobs[index]
        }
        return (202, json(resumed, library: library))
    }

    private func result(_ id: String, library: some FakeQuestionLibrary) -> Reply {
        let job = requireJob(id)
        guard job.status == "done", let filed = job.filed, let title = job.filedTitle else {
            return Self.failure(409, "wrong_step", "This set is not finished yet.")
        }
        let count = job.questionCount
        let set: [String: Any] = [
            "setId": filed.setID, "title": title, "folderId": filed.folderID, "folderName": filed.folderName,
            "examPageId": json(filed.examPageID), "questionCount": count, "termCount": job.materialKind == "notes" ? count * 2 : 0,
        ]
        var exam: Any = NSNull()
        if let examID = filed.examSetID {
            exam =
                [
                    "setId": examID, "title": "\(title) exam", "folderId": filed.folderID, "folderName": filed.folderName,
                    "examPageId": json(filed.examPageID), "questionCount": count, "termCount": 0,
                ] as [String: Any]
        }
        let blindCheck: Any = job.materialKind == "notes" ? Self.blindCheck(count) : NSNull()
        let examBlindCheck: Any = filed.examSetID != nil && job.materialKind == "notes" ? Self.blindCheck(count) : NSNull()
        return (
            200,
            [
                "set": set, "examSet": exam, "blindCheck": blindCheck, "examBlindCheck": examBlindCheck,
                "suggestedAnswers": job.copies.filter { $0.answerFrom == "suggested" && job.kept.contains($0.id) }.map(\.id),
                "warnings": [String](),
            ]
        )
    }

    private static func blindCheck(_ count: Int) -> [String: Any] {
        [
            "passed": count - 1, "fixed": 1, "removed": 0,
            "questions": (1...max(1, count)).map { index in
                ["id": String(format: "A%02d", index), "topic": "Question \(index)", "outcome": index == 3 ? "fixed" : "passed", "flags": index == 3 ? ["AMBIGUOUS"] : []]
            },
            "changeList": "A03: AMBIGUOUS. Rewrote choice C so only B is defensible.",
        ]
    }

    private func cancel(_ id: String, library: some FakeQuestionLibrary) -> Reply {
        let cancelled = state.withLock { state -> Job? in
            let index = Self.index(of: id, in: state.jobs)
            guard ["running", "waiting"].contains(state.jobs[index].status) else { return nil }
            state.jobs[index].status = "cancelled"
            state.jobs[index].finishedAt = .now
            state.jobs[index].updatedAt = .now
            state.jobs[index].progress = nil
            return state.jobs[index]
        }
        guard let cancelled else { return Self.failure(409, "wrong_step", "This set has already finished.") }
        return (200, json(cancelled, library: library))
    }

    // MARK: Shapes

    private static func steps(of job: Job) -> [String] {
        var steps = job.materialKind == "notes" ? ["read", "samples", "review", "write", "check"] : ["read", "review"]
        if job.examTwins { steps.append("twins") }
        steps.append("file")
        return steps
    }

    private static let labels = [
        "read": "Read your material", "samples": "Write 5 samples", "review": "Your check", "write": "Write the rest",
        "check": "Blind check", "twins": "Exam twins", "file": "File the set",
    ]

    private func json(_ job: Job, library: some FakeQuestionLibrary) -> [String: Any] {
        let keys = Self.steps(of: job)
        let at = job.step == "done" ? keys.count : (keys.firstIndex(of: job.step) ?? 0)
        let steps: [[String: Any]] = keys.enumerated().map { index, key in
            var state = index < at ? "done" : "todo"
            if index == at {
                state =
                    switch job.status {
                    case "waiting": "waiting"
                    case "failed": "failed"
                    case "cancelled": "cancelled"
                    default: "current"
                    }
            }
            let progress = state == "current" ? job.progress : nil
            return [
                "key": key, "label": job.materialKind == "questions" && key == "read" ? "Copy the questions" : Self.label(key), "state": state,
                "done": progress.map { $0.done as Any } ?? NSNull(), "total": progress.map { $0.total as Any } ?? NSNull(),
            ]
        }
        let course = library.makerCourse(job.courseID)
        let folder: [String: Any]
        if let filed = job.filed {
            folder = ["id": filed.folderID, "name": filed.folderName]
        } else if let folderID = job.folderID {
            folder = ["id": folderID, "name": library.makerFolderName(courseID: job.courseID, folderID: folderID) ?? "Unsorted"]
        } else {
            folder = ["id": NSNull(), "name": job.folderName ?? "Unsorted"]
        }
        var sets: [[String: Any]] = []
        if let filed = job.filed, let title = job.filedTitle {
            sets.append(["id": filed.setID, "title": title, "kind": "practice"])
            if let exam = filed.examSetID { sets.append(["id": exam, "title": "\(title) exam", "kind": "exam"]) }
        }
        return [
            "id": job.id, "status": job.status, "step": job.step,
            "waitingFor": job.status == "waiting" ? (job.materialKind == "notes" ? "samples" : "copies") : NSNull(),
            "steps": steps,
            "course": ["id": job.courseID, "code": course?.code ?? "", "title": course?.title ?? ""],
            "folder": folder, "materialKind": job.materialKind, "level": job.level,
            "reference": job.referenceID.map { ["id": $0, "title": library.makerSetTitle($0) ?? ""] as Any } ?? NSNull(),
            "count": job.count.map { $0 as Any } ?? NSNull(), "examTwins": job.examTwins, "title": json(job.title),
            "photoCount": job.photoCount, "sets": sets,
            "createdAt": Self.postgresTime(job.createdAt), "updatedAt": Self.postgresTime(job.updatedAt),
            "finishedAt": job.finishedAt.map { Self.postgresTime($0) as Any } ?? NSNull(),
            "failure": json(job.failure), "warnings": [String](),
            "usage": ["calls": 0, "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0],
        ]
    }

    /// A job's times as the server sends them: Postgres's own text, `2026-10-15 20:06:54.585+00`.
    private static func postgresTime(_ date: Date) -> String {
        QBankJSON.formatDate(date).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "+00")
    }

    /// A practice template as the server sends a sample or a copy: a question not in QBank yet.
    private static func draft(template index: Int, id: String) -> [String: Any] {
        let template = FakePracticeQuestions.templates[index]
        let body = template["body"] as? [String: Any] ?? [:]
        return [
            "id": id, "type": template["type"] ?? "single", "topic": template["topic"] ?? "", "cj": template["cj"] ?? NSNull(),
            "need": NSNull(), "difficulty": NSNull(), "stem": template["stem"] ?? "", "ask": template["ask"] ?? "",
            "rationale": template["rationale"] ?? "", "takeaway": template["takeaway"] ?? "", "body": body,
            "table": body["table"] ?? NSNull(), "images": body["images"] ?? [Any](), "terms": template["terms"] ?? [Any](),
            "source": NSNull(), "twinOf": NSNull(),
        ]
    }

    /// The same question in the set file format, which she changes to fix it.
    private static func file(template index: Int, id: String) -> [String: Any] {
        let template = FakePracticeQuestions.templates[index]
        var question: [String: Any] = [
            "id": id, "type": template["type"] ?? "single", "topic": template["topic"] ?? "", "cj": template["cj"] ?? "",
            "need": "Psychosocial integrity", "diff": 2, "src": "Photo", "stem": template["stem"] ?? "", "ask": template["ask"] ?? "",
            "rationale": template["rationale"] ?? "", "takeaway": template["takeaway"] ?? "",
        ]
        for (key, value) in template["body"] as? [String: Any] ?? [:] where key != "images" {
            question[key] = value
        }
        return question
    }

    private func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }

    /// The route has already refused a missing job. Reaching here without it is a bug in the fake.
    private func requireJob(_ id: String) -> Job {
        state.withLock { state in
            guard let job = state.jobs.first(where: { $0.id == id }) else {
                preconditionFailure("Question-maker job \(id) is in the fake server.")
            }
            return job
        }
    }

    private static func index(of id: String, in jobs: [Job]) -> Int {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Question-maker job \(id) is in the fake server.")
        }
        return index
    }

    private static func label(_ key: String) -> String {
        guard let label = labels[key] else {
            preconditionFailure("Every question-maker step has a label.")
        }
        return label
    }
}
#endif
