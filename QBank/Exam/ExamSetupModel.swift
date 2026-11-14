import Foundation
import Observation
import QBankKit

/// Exam setup, as the web's (`apps/web/src/exam/ExamSetupScreen.tsx`): the folders to tick, by
/// exam page, with their question or wrong counts, Wrong questions only, the summary of what Start
/// draws, Write exam twins for the account that may make questions, her running exam, her twin
/// jobs, and her past exams.
@Observable
final class ExamSetupModel {
    /// The folders of one exam page, or of none, as the picker groups them.
    struct Group: Identifiable, Equatable {
        /// The page's name, "On no page", or nil when the course's pages are not known.
        let title: String?
        let folders: [ExamSetup.Folder]

        var id: String { title ?? "" }
    }

    /// The ticked folders and the pool: what the summary shows the server's plan for, and what a
    /// twin job is asked for.
    struct Pick: Equatable {
        let folderIDs: Set<String>
        let pool: ExamPool
    }

    let route: ExamSetupRoute
    /// The setup as last read, with the server's plan (`preview`) for `setupPick`.
    private(set) var setup: ExamSetup?
    /// The course, for its exam pages and her order of their folders.
    private(set) var detail: CourseDetail?
    /// Her exam that has not ended, as last read. Starting an exam ends it, so Start waits until
    /// this is known and asks first while it is open.
    private(set) var running: RunningExam = .unknown
    /// "Start a new exam?" is open, about `running`'s exam.
    var asksToReplace = false
    /// The ticked folders, by id.
    private(set) var ticked: Set<String> = []
    var wrongOnly = false
    private(set) var isStarting = false
    private(set) var problem: String?
    /// Whether she may make questions now, which offers Write exam twins.
    private(set) var maker: QuestionMakerStatus?
    /// Her twin jobs over this course, newest first; nil while not read, or for an account that may
    /// not make questions.
    private(set) var twinJobs: [TwinJob]?
    private(set) var isTwinning = false
    /// A refusal of exam twins, with the folders and pool it was about: it shows only until she
    /// changes them.
    private var twinRefusal: (pick: Pick, message: String)?
    /// The folders and pool `setup` was read for.
    private var setupPick: Pick?
    /// The folders and pool of the newest read, done or on its way.
    private var requested: Pick?
    /// Counts reads, so an answer that comes back after a newer read started is dropped.
    private var reads = 0

    private let app: AppModel
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var hasTicked = false

    init(
        app: AppModel, route: ExamSetupRoute, now: @escaping () -> Date = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.app = app
        self.route = route
        self.now = now
        self.sleep = sleep
    }

    var course: CourseRef { route.course }

    /// Exams start and end on the server, so without a connection none can start.
    var needsConnection: Bool {
        !app.connection.isOnline
    }

    /// Only she starts exams and asks for twins; for the admin these answer with the frozen note.
    private var isStudent: Bool {
        app.account?.role == .student
    }

    var folders: [ExamSetup.Folder] {
        groups.flatMap(\.folders)
    }

    /// The words of the course's screens, or the topic's.
    var words: KindWords {
        Wording.words(detail?.kind ?? course.kind)
    }

    /// The folders by exam page, in her order, then those on no exam page. Without the course's
    /// pages, the folders as the setup lists them.
    var groups: [Group] {
        guard let setup else { return [] }
        guard let detail else { return [Group(title: nil, folders: setup.folders)] }
        let layout = CourseLayout(course: detail, sittings: [])
        let byID = Dictionary(setup.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var groups: [Group] = []
        let loose = "On no page"
        for (title, folders) in layout.pages.map({ ($0.exam.name, $0.folders) }) + [(loose, layout.looseFolders)] {
            let pools = folders.compactMap { byID[$0.id] }
            placed.formUnion(pools.map(\.id))
            if !pools.isEmpty { groups.append(Group(title: title, folders: pools)) }
        }
        // A folder the course read does not have yet still shows, at the end.
        let rest = setup.folders.filter { !placed.contains($0.id) }
        if !rest.isEmpty {
            if let last = groups.last, last.title == loose {
                groups[groups.count - 1] = Group(title: last.title, folders: last.folders + rest)
            } else {
                groups.append(Group(title: loose, folders: rest))
            }
        }
        return groups
    }

    /// A folder's name, with its exam page when another folder shares the name: "First Pass (Exam 3)".
    func name(_ folder: ExamSetup.Folder) -> String {
        let all = setup?.folders ?? []
        guard all.contains(where: { $0.id != folder.id && $0.name.lowercased() == folder.name.lowercased() }) else { return folder.name }
        let page = detail?.exams.first { $0.id == folder.examPageID }?.name ?? "no page"
        return "\(folder.name) (\(page))"
    }

    /// The questions a folder gives: all of them, or with Wrong questions only her wrong ones.
    func poolSize(_ folder: ExamSetup.Folder) -> Int {
        wrongOnly ? folder.wrongCount : folder.questionCount
    }

    /// A folder with nothing to draw cannot be ticked. Its tick comes back when the switch is off.
    func canTick(_ folder: ExamSetup.Folder) -> Bool {
        poolSize(folder) > 0
    }

    func isTicked(_ folder: ExamSetup.Folder) -> Bool {
        canTick(folder) && ticked.contains(folder.id)
    }

    func toggle(_ folder: ExamSetup.Folder) {
        guard canTick(folder), !app.frozen.refuses() else { return }
        if ticked.contains(folder.id) {
            ticked.remove(folder.id)
        } else {
            ticked.insert(folder.id)
        }
    }

    /// The ticked folders that give questions, in the picker's order.
    var picked: [ExamSetup.Folder] {
        folders.filter(isTicked)
    }

    var pick: Pick {
        Pick(folderIDs: Set(picked.map(\.id)), pool: wrongOnly ? .wrong : .all)
    }

    /// The server's plan the summary shows. After a tick, the plan for the folders ticked before
    /// stays until the new one arrives (`isPlanUpdating`), as on the web. Without a connection no
    /// new plan can arrive, so then only a plan for the folders ticked now shows.
    var plan: ExamPreview? {
        guard !picked.isEmpty, let preview = setup?.preview else { return nil }
        return setupPick == pick || !needsConnection ? preview : nil
    }

    /// Whether the plan on screen is still the one for the folders ticked before.
    var isPlanUpdating: Bool {
        plan != nil && setupPick != pick
    }

    /// "4 in exam" beside a ticked folder.
    func drawn(_ folder: ExamSetup.Folder) -> Int? {
        guard isTicked(folder) else { return nil }
        return plan?.folders.first { $0.id == folder.id }?.drawn
    }

    /// A folder of the plan by the name its row shows.
    private func name(_ folder: ExamPreview.Folder) -> String {
        setup?.folders.first { $0.id == folder.id }.map(name) ?? folder.name
    }

    /// "27 questions", or "7 wrong of 20" with Wrong questions only on, and "· exam bank" when the
    /// folder has one.
    func meta(_ folder: ExamSetup.Folder) -> String {
        let count = wrongOnly
            ? "\(folder.wrongCount) wrong of \(folder.questionCount)"
            : Wording.count(folder.questionCount, "question")
        return folder.source == .exam ? "\(count) · exam bank" : count
    }

    /// The summary's first line: "11 questions", with its time beside it. Nil without a plan.
    var summaryCount: String? {
        plan.map { Wording.count($0.questionCount, "question") }
    }

    var summaryTime: String? {
        plan.map { "in \(Wording.minutes(seconds: $0.timeLimitSeconds))" }
    }

    /// "4 from Week 1 · 7 from Week 2 · Fewer than 40, so it’s all of them at 1.5 minutes each.",
    /// with the numbers of the server's plan and rules, or what to tick.
    var summarySplit: String {
        if picked.isEmpty {
            if !wrongOnly { return "Tick at least one folder." }
            return folders.allSatisfy { $0.wrongCount == 0 }
                ? "No wrong questions in this \(words.container) right now."
                : "Tick at least one folder with wrong questions."
        }
        guard let plan, let rules = setup?.rules else {
            return needsConnection ? "What the exam draws shows once you’re back online." : "Working out what the exam draws."
        }
        let split = plan.folders.map { "\($0.drawn) from \(name($0))" }.joined(separator: " · ")
        guard plan.questionCount < rules.maxQuestions else { return split }
        return "\(split) · Fewer than \(rules.maxQuestions), so it’s all of them at \(Wording.minutes(seconds: rules.secondsPerQuestion)) each."
    }

    /// The planned folders without an exam bank, named only once the course has one, as the server does.
    var fallbackLine: String? {
        guard let plan, plan.practiceWeeks != nil else { return nil }
        let practice = plan.folders.filter { $0.source == .practice }.map(name)
        return practice.isEmpty ? nil : Wording.practiceFolders(practice, before: true)
    }

    var footer: String {
        wrongOnly
            ? "Questions are drawn only from the wrong ones in the folders you tick, in proportion to how many each folder has."
            : "Questions are drawn only from the folders you tick, in proportion to each folder’s size."
    }

    /// "Exam 2 · 5 folders ticked for you", when she came from an exam page's Start exam.
    var preselectedLine: String? {
        guard let name = route.examName, !route.folderIDs.isEmpty else { return nil }
        let known = Set(setup?.folders.map(\.id) ?? [])
        let count = route.folderIDs.filter(known.contains).count
        guard count > 0 else { return nil }
        return "\(name) · \(Wording.count(count, "folder")) ticked for you"
    }

    /// "Weeks 1-2 · Wrong questions only · 3 of 11 answered · 12 min left" at `date`. Once its
    /// time has run out, 0 min left.
    func runningLine(_ exam: ExamSummary, at date: Date) -> String {
        let secondsLeft = exam.status(at: date) == .running ? exam.endsAt.timeIntervalSince(date) : 0
        let minutesLeft = max(0, Int((secondsLeft / 60).rounded(.up)))
        var parts = [Wording.folders(exam.weeks)]
        if exam.pool == .wrong { parts.append("Wrong questions only") }
        parts.append("\(exam.answeredCount) of \(exam.questionCount) answered")
        parts.append("\(minutesLeft) min left")
        return parts.joined(separator: " · ")
    }

    // MARK: Loading and starting

    /// Loads the setup with the server's plan for the ticked folders, the course for its exam
    /// pages, and whether she may write exam twins. The first load asks for the plan over the
    /// folders an exam page ticked. A course that cannot be read leaves the folders ungrouped.
    func load() async {
        async let reading = courseDetail()
        async let twins: Void = loadTwins()
        await read(hasTicked ? pick : Pick(folderIDs: Set(route.folderIDs), pool: pick.pool))
        if let read = await reading {
            detail = read
        }
        await twins
    }

    /// Reads the setup again after she changed the folders or the pool, for the server's plan over
    /// them. Nothing to do when the setup on screen, or the read on its way, is already for them.
    func readPlan() async {
        guard hasTicked, pick != requested else { return }
        await read(pick)
    }

    private func read(_ pick: Pick) async {
        reads += 1
        let read = reads
        requested = pick
        do {
            let loaded = try await app.client.examSetup(courseID: course.id, folderIDs: pick.folderIDs.sorted(), pool: pick.pool)
            guard read == reads else { return }
            setup = loaded
            setupPick = pick
            running = RunningExam(loaded.inProgress)
            problem = nil
            if !hasTicked {
                hasTicked = true
                let ids = Set(loaded.folders.map(\.id))
                ticked = Set(route.folderIDs.filter(ids.contains))
                // The server left out the folders it does not have, so its plan is for the rest.
                setupPick = Pick(folderIDs: pick.folderIDs.intersection(ids), pool: pick.pool)
                requested = setupPick
            }
        } catch {
            guard read == reads else { return }
            report(error)
        }
    }

    /// The Twin option and her twin jobs, for the one account that may make questions. Every other
    /// account hears no from the status and is never sent to the twin-job routes.
    private func loadTwins() async {
        guard isStudent, let status = try? await app.client.questionMakerStatus() else { return }
        maker = status
        guard Twins.listsJobs(status) else {
            twinJobs = nil
            return
        }
        if let jobs = try? await app.client.twinJobs() {
            twinJobs = Twins.jobs(jobs, courseID: course.id)
        }
    }

    private func courseDetail() async -> CourseDetail? {
        let id = course.id
        return try? await app.load(.course(id)) { () async throws(QBankError) in try await app.client.course(id: id) }.value
    }

    /// Start exam: the folders are ticked and whether it ends a running exam is known.
    var canStart: Bool {
        !picked.isEmpty && running.isKnown && !isStarting && !isTwinning && !needsConnection
    }

    /// Start exam: asks first while an exam of hers is open, as the server does, otherwise starts
    /// it. One whose time is up since the setup was read has ended, so it is not asked about.
    /// Returns the new exam to open, or nil.
    func start() async -> Exam? {
        guard isStudent, canStart else { return nil }
        if running.exam(at: now()) != nil {
            asksToReplace = true
            return nil
        }
        return await start(replacing: nil)
    }

    /// Starts the exam once she agreed that her running exam ends.
    func startReplacing() async -> Exam? {
        guard isStudent, canStart, let exam = running.exam else { return nil }
        return await start(replacing: exam.id)
    }

    /// Starts the exam over the ticked folders, with the running exam she agreed to end. One
    /// running that she was not asked about, such as one started on another device since the last
    /// read, starts nothing and asks her now. Returns the new exam to open, or nil after a refusal,
    /// said in her words.
    private func start(replacing: String?) async -> Exam? {
        isStarting = true
        defer { isStarting = false }
        problem = nil
        do {
            switch try await app.client.startExam(courseID: course.id, folderIDs: picked.map(\.id), pool: wrongOnly ? .wrong : .all, replaces: replacing) {
            case .started(let exam):
                // The new exam runs now; the setup is read again once its screen closes.
                running = .unknown
                return exam
            case .examInProgress(let other):
                running = .running(other)
                asksToReplace = true
                return nil
            }
        } catch {
            report(error)
            return nil
        }
    }

    /// While the screen is open with her exam that has not ended: once its time is up, the setup is
    /// read again, so it shows among her past exams with its score. A read that still finds it open,
    /// as when this phone's clock runs ahead of the server's, or that fails, is tried again.
    func followRunningExam() async {
        var retry = Duration.zero
        while let exam = running.exam, !Task.isCancelled {
            let untilTimeUp = ExamStatus.timeUp(endsAt: exam.endsAt).timeIntervalSince(now())
            do {
                try await sleep(max(.milliseconds(Int64(max(0, untilTimeUp) * 1000)), retry) + .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, running.exam?.id == exam.id else { return }
            await read(requested ?? pick)
            retry = .seconds(5)
        }
    }

    // MARK: Exam twins

    /// Write exam twins shows while the server says she may make questions now.
    var canTwin: Bool {
        isStudent && Twins.canTwin(maker)
    }

    /// Why the server would not twin the folders and pool ticked now, in its words.
    var twinProblem: String? {
        guard let twinRefusal, twinRefusal.pick == pick else { return nil }
        return twinRefusal.message
    }

    /// Instead of an exam on the ticked folders' questions, QBank writes exam twins of them. Returns
    /// the job to follow, or nil after a refusal, said in her words until she changes the folders or
    /// the pool.
    func writeTwins() async -> TwinJob? {
        guard canTwin, !picked.isEmpty, !isStarting, !isTwinning, !needsConnection else { return nil }
        let pick = pick
        let folderIDs = picked.map(\.id)
        isTwinning = true
        twinRefusal = nil
        defer { isTwinning = false }
        do {
            let job = try await app.client.startTwinJob(NewTwinJob(courseID: course.id, folderIDs: folderIDs, pool: pick.pool))
            twinJobs = [job] + (twinJobs ?? []).filter { $0.id != job.id }
            return job
        } catch {
            if app.handle(error) { return nil }
            twinRefusal = (pick, Wording.problem(error) ?? "Could not start the exam twins.")
            return nil
        }
    }

    private func report(_ error: QBankError) {
        guard !app.handle(error) else { return }
        // Without a connection the screen says exams need one; the transport error adds nothing.
        if case .transport = error, needsConnection {
            problem = nil
            return
        }
        problem = Wording.problem(error)
    }
}

extension ExamSummary {
    /// A past exam's second line: "52 min · Wrong questions only · Time ran out".
    nonisolated var pastLine: String {
        var line = "\(minutesUsed ?? 0) min"
        if pool == .wrong { line += " · Wrong questions only" }
        switch endReason {
        case .timeout: line += " · Time ran out"
        case .left: line += " · Ended early"
        case .finished, nil: break
        }
        return line
    }

    /// "Weeks 1-2 · Oct 9".
    nonisolated var pastTitle: String {
        "\(Wording.folders(weeks)) · \(Wording.when(finishedAt ?? startedAt))"
    }

    /// "31 of 40".
    nonisolated var scoreText: String {
        "\(fullyRight ?? 0) of \(questionCount)"
    }
}
