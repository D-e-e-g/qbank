import Foundation
import Observation
import QBankKit

/// A twin job followed while its screen is open, as the web's twin job page
/// (`apps/web/src/exam/TwinJobScreen.tsx`): QBank reads her questions, writes their exam twins, and
/// files them; once done, the exam starts on the twins. The work goes on on the server when she
/// leaves; this only reads it, stops it, and starts the exam.
@Observable
final class TwinJobModel {
    let route: TwinJobRoute
    private(set) var job: TwinJob?
    /// Why the job could not be read, said in her words.
    private(set) var problem: String?
    /// Why Stop or Start exam on the twins did not go through.
    private(set) var actionProblem: String?
    /// The job is not hers or not there anymore.
    private(set) var isGone = false
    /// Her running exam, read once the twins are ready: starting the exam on them ends it, so
    /// Start waits until this is known, and asks first while one runs.
    private(set) var running: RunningExam = .unknown
    /// Why her running exam could not be read. It is read again until it is known.
    private(set) var runningProblem: String?
    /// "Start a new exam?" is open, about `running`'s exam.
    var asksToReplace = false
    private(set) var isStopping = false
    private(set) var isStarting = false

    private let app: AppModel
    private let pollInterval: Duration

    init(app: AppModel, route: TwinJobRoute, pollInterval: Duration = .seconds(2)) {
        self.app = app
        self.route = route
        self.pollInterval = pollInterval
        job = route.seed
    }

    var course: CourseRef { route.course }

    /// The twins are filed, and the exam on them can start.
    var isDone: Bool {
        job?.status == .done
    }

    /// The server is working on it, so the screen keeps reading it, as it does before the first
    /// read, until the job turns out to be gone.
    var isWorking: Bool {
        !isGone && job.map(Twins.isRunning) ?? true
    }

    /// Stop and Start reach the server, so without a connection they wait.
    var needsConnection: Bool {
        !app.connection.isOnline
    }

    /// The twins are ready and whether an exam of hers is running is not known yet.
    var needsRunningExam: Bool {
        isDone && !running.isKnown
    }

    /// Start exam on the twins: the job names the exam, and whether it ends a running one is known.
    var canStart: Bool {
        isDone && job?.exam != nil && running.isKnown && !isStarting && !needsConnection
    }

    func load() async {
        do {
            job = try await app.client.twinJob(id: route.jobID)
            problem = nil
        } catch {
            if app.handle(error) { return }
            // A refusal is the answer; a dropped connection or a server hiccup is tried again.
            if case .server(let server) = error, server.status < 500 {
                isGone = true
            }
            problem = Wording.problem(error) ?? "Could not load the exam twins. Trying again."
        }
    }

    /// Reads the job until it has ended, every couple of seconds, for as long as the screen is open.
    func follow() async {
        await load()
        while isWorking, !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// Reads whether an exam of hers is running, every couple of seconds until it is known, for as
    /// long as the screen is open, so Start exam on the twins asks first, as Exam setup does.
    func readRunningExam() async {
        while needsRunningExam, !Task.isCancelled {
            do {
                running = RunningExam(try await app.client.examSetup(courseID: route.course.id).inProgress)
                runningProblem = nil
                return
            } catch {
                if app.handle(error) { return }
                runningProblem = "Could not check for an exam in progress. Trying again."
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Stops the job. Nothing more is written or filed; sets already filed stay.
    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        actionProblem = nil
        defer { isStopping = false }
        do {
            job = try await app.client.cancelTwinJob(id: route.jobID)
        } catch {
            if app.handle(error) { return }
            actionProblem = Wording.problem(error) ?? "Could not stop the exam twins."
        }
    }

    /// Start exam on the twins: asks first while an exam of hers runs, otherwise starts it.
    /// Returns the exam to open, or nil.
    func start() async -> Exam? {
        guard canStart else { return nil }
        if running.exam != nil {
            asksToReplace = true
            return nil
        }
        return await startExam(replacing: nil)
    }

    /// Starts the exam once she agreed that her running exam ends.
    func startReplacing() async -> Exam? {
        guard canStart, let exam = running.exam else { return nil }
        return await startExam(replacing: exam.id)
    }

    /// Starts the exam the job names, sent as it is, the folders the twins are in and the pool she
    /// picked, with the running exam she agreed to end. An exam running that she was not asked
    /// about starts nothing and asks her now. Returns the exam to open, or nil after a refusal,
    /// said in her words.
    private func startExam(replacing: String?) async -> Exam? {
        guard let job, let exam = job.exam, !isStarting, !needsConnection else { return nil }
        isStarting = true
        actionProblem = nil
        defer { isStarting = false }
        do {
            switch try await app.client.startExam(courseID: job.course.id, on: exam, replaces: replacing) {
            case .started(let started):
                // The new exam runs now; it is read again for the next Start.
                running = .unknown
                return started
            case .examInProgress(let other):
                running = .running(other)
                asksToReplace = true
                return nil
            }
        } catch {
            if app.handle(error) { return nil }
            actionProblem = Wording.problem(error) ?? "Could not start the exam."
            return nil
        }
    }

    /// After the exam's full screen closed: an exam she left running asks again before the next one.
    func examClosed() {
        running = .unknown
    }
}
