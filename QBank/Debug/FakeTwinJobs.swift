#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// Exam twins on the fake server, with the rules and words of the server's twin jobs
/// (`question-maker/twins.ts`, `views.ts`, `routes/question-maker.ts`): only the accounts that may
/// make questions, nothing without the Claude key, the daily limit shared with sets, a sentence
/// for each refusal, and a job that reads her questions, writes their twins, and files them as an
/// exam set beside each practice set. Nothing is written by a model: each read of a running job
/// moves it one step on, so a screen that polls sees it go.
nonisolated final class FakeTwinJobs: Sendable {
    static let maxTwins = 60
    /// Twins written between two reads of a job.
    static let twinsPerRead = 3

    private struct TwinSet {
        let setID: String
        let setTitle: String
        let folderID: String
        let folderName: String
        let questionIDs: [String]
    }

    private struct ScopeFolder {
        let id: String
        let name: String
        let questionCount: Int
        let twinCount: Int
        let alreadyTwinned: Int
    }

    private struct Filed {
        let setID: String
        let title: String
        let folderID: String
        let folderName: String
        let examPageID: String?
        let questionCount: Int
        let practiceSetID: String
        let practiceSetTitle: String
    }

    private struct Job {
        let id: String
        let owner: String
        let courseID: String
        let pool: ExamPool
        let folders: [ScopeFolder]
        let note: String
        let sets: [TwinSet]
        var status = "running"
        var step = "read"
        var progress: (done: Int, total: Int)?
        var filed: [Filed] = []
        let createdAt: Date
        var updatedAt: Date
        var finishedAt: Date?

        var twinCount: Int { sets.reduce(0) { $0 + $1.questionIDs.count } }
    }

    private struct State {
        var jobs: [Job] = []
        var made = 0
    }

    private let maker: FakeQuestionMaker
    private let study: FakeStudy
    private let state = Mutex(State())

    init(maker: FakeQuestionMaker, study: FakeStudy) {
        self.maker = maker
        self.study = study
    }

    typealias Reply = (Int, [String: Any])

    /// Whether exam twins of hers are still being written in the course, so it cannot be deleted yet.
    func isWorking(courseID: String, email: String) -> Bool {
        state.withLock { state in state.jobs.contains { $0.owner == email && $0.courseID == courseID && $0.status == "running" } }
    }

    /// The answer to a twin-job call, or nil for any other path.
    func answer(method: String, path: String, body: [String: Any], email: String, library: some FakeQuestionLibrary) -> Reply? {
        guard path == "/api/twin-jobs" || path.hasPrefix("/api/twin-jobs/") else { return nil }
        if let refusal = maker.refusal(for: email) { return refusal }
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
            return Self.failure(404, "not_found", "Those exam twins are not in QBank.")
        }
        switch (method, parts.dropFirst(3).joined(separator: "/")) {
        case ("GET", ""):
            return (200, json(tick(id, library: library), library: library))
        case ("POST", "cancel"):
            return cancel(id, library: library)
        default:
            return Self.failure(404, "not_found", "That is not in QBank.")
        }
    }

    // MARK: Starting

    private func start(_ body: [String: Any], email: String, library: some FakeQuestionLibrary) -> Reply {
        let courseID = body["courseId"] as? String ?? ""
        let folderIDs = body["folderIds"] as? [String] ?? []
        guard let pool = ExamPool(rawValue: body["pool"] as? String ?? "all") else {
            return Self.failure(400, "invalid_request", "Check the fields and try again.")
        }
        guard library.makerCourse(courseID) != nil else { return Self.failure(404, "not_found", "That course is not in QBank.") }
        guard !folderIDs.isEmpty else { return Self.failure(400, "invalid_request", "Tick at least one folder.") }
        guard let sources = study.twinSources(courseID: courseID, folderIDs: folderIDs, pool: pool) else {
            return Self.failure(400, "invalid_request", "That folder is not in this course.")
        }
        let busy = Set(state.withLock { state in
            state.jobs.filter { $0.courseID == courseID && $0.status == "running" }.flatMap { $0.folders.filter { $0.twinCount > 0 }.map(\.id) }
        })
        let clash = sources.map(\.folder).filter { busy.contains($0.id) }.map(\.name)
        if !clash.isEmpty {
            return Self.failure(400, "invalid_request", "QBank is still writing exam twins in \(FakeStudy.listText(clash)). Try again once they are filed.")
        }
        let scope: (folders: [ScopeFolder], note: String, sets: [TwinSet])
        switch Self.scope(sources, pool: pool, library: library) {
        case .success(let found): scope = found
        case .failure(let refusal): return Self.failure(400, "invalid_request", refusal.message)
        }
        if let refusal = maker.startTwins(email: email) { return refusal }
        let job = state.withLock { state -> Job in
            state.made += 1
            let job = Job(
                id: String(format: "a0b20000-0000-4000-8000-%012d", state.made), owner: email, courseID: courseID, pool: pool,
                folders: scope.folders, note: scope.note, sets: scope.sets, createdAt: .now, updatedAt: .now
            )
            state.jobs.insert(job, at: 0)
            return job
        }
        return (202, json(job, library: library))
    }

    private struct Refusal: Error {
        let message: String
    }

    /// What a twin job over these folders twins, and its note, or the sentence that refuses it:
    /// `twinScope` of the server's `twins.ts`.
    private static func scope(
        _ sources: [FakeStudy.TwinSource], pool: ExamPool, library: some FakeQuestionLibrary
    ) -> Result<(folders: [ScopeFolder], note: String, sets: [TwinSet]), Refusal> {
        var folders: [ScopeFolder] = []
        var sets: [TwinSet] = []
        var narrowed: [String] = []
        var unmatched: [String] = []
        for source in sources {
            let pooled = source.pooled
            let leftAsItIs = source.unmatched
            for set in source.sets where !leftAsItIs {
                let fresh = set.questionIDs.filter { !source.twinned.contains($0) }
                if !fresh.isEmpty {
                    sets.append(TwinSet(
                        setID: set.setID, setTitle: library.makerSetTitle(set.setID) ?? "Invented set", folderID: source.folder.id,
                        folderName: source.folder.name, questionIDs: fresh
                    ))
                }
            }
            let fresh = leftAsItIs ? 0 : pooled.count { !source.twinned.contains($0) }
            folders.append(ScopeFolder(
                id: source.folder.id, name: source.folder.name, questionCount: pooled.count, twinCount: fresh,
                alreadyTwinned: pooled.count { source.twinned.contains($0) }
            ))
            if leftAsItIs, !pooled.isEmpty { unmatched.append(source.folder.name) }
            let own = source.folder.sets.reduce(0) { $0 + (FakeStudy.setSizes[$1] ?? 0) }
            if source.folder.bank.isEmpty, fresh > 0, fresh < own { narrowed.append(source.folder.name) }
        }
        let which = pool == .wrong ? "wrong question" : "question"
        let empty = folders.filter { $0.questionCount == 0 }.map(\.name)
        let one = unmatched.count == 1
        let leftAlone = unmatched.isEmpty ? [] : [
            "\(FakeStudy.listText(unmatched)) already \(has(unmatched)) exam questions QBank can't match to \(one ? "its" : "their") practice questions, so QBank leaves \(one ? "it as it is" : "them as they are")."
        ]
        let total = sets.reduce(0) { $0 + $1.questionIDs.count }
        if total == 0 {
            let withQuestions = folders.filter { $0.questionCount > 0 }
            if withQuestions.isEmpty {
                return .failure(Refusal(message: pool == .wrong
                    ? "\(FakeStudy.listText(empty)) \(has(empty)) no wrong questions, so there is nothing to twin."
                    : "\(FakeStudy.listText(empty)) \(has(empty)) no practice questions to twin."))
            }
            let twinned = withQuestions.filter { folder in !unmatched.contains(folder.name) }.map(\.name)
            let sentences = (twinned.isEmpty ? [] : ["Every \(which) in \(FakeStudy.listText(twinned)) already has an exam twin."])
                + leftAlone + ["Start the exam\(pool == .wrong ? " with Wrong questions only" : "") to take them."]
            return .failure(Refusal(message: sentences.joined(separator: " ")))
        }
        if total > maxTwins {
            return .failure(Refusal(message: "That is \(total) questions to twin; QBank twins up to \(maxTwins) at a time. Tick fewer folders\(pool == .all ? ", or turn on Wrong questions only" : "")."))
        }
        let twinnedNames = folders.filter { $0.twinCount > 0 }.map(\.name)
        let kept = folders.reduce(0) { $0 + $1.alreadyTwinned }
        var note = ["QBank writes exam twins of \(total) \(which)\(total == 1 ? "" : "s") in \(FakeStudy.listText(twinnedNames))."]
        if kept > 0 {
            note.append("\(Wording.count(kept, "question")) already \(kept == 1 ? "has" : "have") one and \(kept == 1 ? "stays" : "stay") as \(kept == 1 ? "it is" : "they are").")
        }
        if !empty.isEmpty { note.append("\(FakeStudy.listText(empty)) \(has(empty)) no \(which)s.") }
        note += leftAlone
        if !narrowed.isEmpty {
            note.append("Once they are filed, exams over \(FakeStudy.listText(narrowed)) ask only \(narrowed.count == 1 ? "its" : "their") exam twins.")
        }
        return .success((folders, note.joined(separator: " "), sets))
    }

    private static func has(_ names: [String]) -> String {
        names.count == 1 ? "has" : "have"
    }

    // MARK: Moving on

    /// Moves a running job one step on, as if QBank had done that much work since it was last read.
    private func tick(_ id: String, library: some FakeQuestionLibrary) -> Job {
        let toFile = state.withLock { state -> Job? in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return nil }
            var job = state.jobs[index]
            guard job.status == "running" else { return nil }
            job.updatedAt = .now
            defer { state.jobs[index] = job }
            switch job.step {
            case "read":
                job.step = "twins"
                job.progress = (0, job.twinCount)
            case "twins":
                let done = min(job.twinCount, (job.progress?.done ?? 0) + Self.twinsPerRead)
                if done >= job.twinCount {
                    job.step = "file"
                    job.progress = (0, job.sets.count)
                } else {
                    job.progress = (done, job.twinCount)
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

    /// Files each practice set's twins as a new exam set beside it, in its folder's exam bank.
    private func file(_ job: Job, library: some FakeQuestionLibrary) {
        let filed = job.sets.map { set -> Filed in
            let filed = library.fileTwinSet(courseID: job.courseID, folderID: set.folderID, title: "\(set.setTitle) exam", questionCount: set.questionIDs.count)
            study.fileTwins(of: set.questionIDs, examSetID: filed.setID, in: set.folderID)
            return Filed(
                setID: filed.setID, title: "\(set.setTitle) exam", folderID: set.folderID, folderName: set.folderName,
                examPageID: filed.examPageID, questionCount: set.questionIDs.count, practiceSetID: set.setID, practiceSetTitle: set.setTitle
            )
        }
        state.withLock { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            state.jobs[index].filed = filed
            state.jobs[index].status = "done"
            state.jobs[index].step = "done"
            state.jobs[index].progress = nil
            state.jobs[index].finishedAt = .now
            state.jobs[index].updatedAt = .now
        }
    }

    private func cancel(_ id: String, library: some FakeQuestionLibrary) -> Reply {
        let cancelled = state.withLock { state -> Job? in
            let index = Self.index(of: id, in: state.jobs)
            guard state.jobs[index].status == "running" else { return nil }
            state.jobs[index].status = "cancelled"
            state.jobs[index].progress = nil
            state.jobs[index].finishedAt = .now
            state.jobs[index].updatedAt = .now
            return state.jobs[index]
        }
        guard let cancelled else { return Self.failure(409, "wrong_step", "These exam twins have already finished.") }
        return (200, json(cancelled, library: library))
    }

    // MARK: Shapes

    private static let steps = ["read", "twins", "file"]
    private static let labels = ["read": "Read your questions", "twins": "Exam twins", "file": "File the twins"]

    private func json(_ job: Job, library: some FakeQuestionLibrary) -> [String: Any] {
        let at = job.step == "done" ? Self.steps.count : (Self.steps.firstIndex(of: job.step) ?? 0)
        let steps: [[String: Any]] = Self.steps.enumerated().map { index, key in
            var state = index < at ? "done" : "todo"
            if index == at {
                state = switch job.status {
                case "failed": "failed"
                case "cancelled": "cancelled"
                default: "current"
                }
            }
            let progress = state == "current" ? job.progress : nil
            return [
                "key": key, "label": Self.label(key), "state": state,
                "done": progress.map { $0.done as Any } ?? NSNull(), "total": progress.map { $0.total as Any } ?? NSNull(),
            ]
        }
        let course = library.makerCourse(job.courseID)
        // The exam over the twins: the folders with questions in the pool, then any other a set was filed in.
        var examFolders = job.folders.filter { folder in folder.questionCount > 0 || job.filed.contains { $0.folderID == folder.id } }.map(\.id)
        for filed in job.filed where !examFolders.contains(filed.folderID) {
            examFolders.append(filed.folderID)
        }
        return [
            "id": job.id, "status": job.status, "step": job.step, "steps": steps,
            "course": ["id": job.courseID, "code": course?.code ?? "", "title": course?.title ?? ""],
            "level": "exam", "pool": job.pool.rawValue,
            "folders": job.folders.map { folder in
                ["id": folder.id, "name": folder.name, "questionCount": folder.questionCount, "twinCount": folder.twinCount, "alreadyTwinned": folder.alreadyTwinned]
            },
            "twinCount": job.twinCount, "note": job.note,
            "sets": job.filed.map { filed in
                [
                    "setId": filed.setID, "title": filed.title, "folderId": filed.folderID, "folderName": filed.folderName,
                    "examPageId": filed.examPageID.map { $0 as Any } ?? NSNull(), "questionCount": filed.questionCount, "termCount": 0,
                    "twinsOf": ["id": filed.practiceSetID, "title": filed.practiceSetTitle],
                ] as [String: Any]
            },
            "exam": job.status == "done" ? ["folderIds": examFolders, "pool": job.pool.rawValue] as [String: Any] : NSNull(),
            "createdAt": Self.postgresTime(job.createdAt), "updatedAt": Self.postgresTime(job.updatedAt),
            "finishedAt": job.finishedAt.map { Self.postgresTime($0) as Any } ?? NSNull(),
            "failure": NSNull(), "warnings": [String](),
            "usage": ["calls": 0, "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0],
        ]
    }

    /// A job's times as the server sends them: Postgres's own text, `2026-10-15 20:06:54.585+00`.
    private static func postgresTime(_ date: Date) -> String {
        QBankJSON.formatDate(date).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "+00")
    }

    private static func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }

    /// The route has already refused a missing job. Reaching here without it is a bug in the fake.
    private func requireJob(_ id: String) -> Job {
        state.withLock { state in
            guard let job = state.jobs.first(where: { $0.id == id }) else {
                preconditionFailure("Twin job \(id) is in the fake server.")
            }
            return job
        }
    }

    private static func index(of id: String, in jobs: [Job]) -> Int {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Twin job \(id) is in the fake server.")
        }
        return index
    }

    private static func label(_ key: String) -> String {
        guard let label = labels[key] else {
            preconditionFailure("Every twin-job step has a label.")
        }
        return label
    }
}
#endif
