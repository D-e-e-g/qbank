#if DEBUG
import Foundation

nonisolated extension DebugScenario {
    /// No session on the phone: the first screen. Sign in with Apple answers as
    /// `QB_UITEST_APPLE` says (`DebugScriptedAppleSignIn`), and a new person's bank on
    /// the phone is given the sample set. Behind "Use an existing QBank account",
    /// `FakeQBankServer.student` signs in normally and `FakeQBankServer.resetStudent`
    /// must choose a new password.
    static let signedOut = DebugScenario("signed-out") { context in
        context.model(server: FakeQBankServer(signedIn: false), session: nil)
    }

    /// `FakeQBankServer.student` is signed in from an earlier launch and last
    /// used the Mental Health course. The server does not let her make questions.
    static let signedIn = DebugScenario("signed-in") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, answersFile: context.answersFile),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// As `signedIn`, with an exam over Mental Health's Weeks 1-2 left in progress, so deleting
    /// what it asks is refused for now.
    static let examInProgress = DebugScenario("exam-in-progress") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, examInProgress: true, answersFile: context.answersFile),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// As `examInProgress`, with every question of the exam but its last answered, and the
    /// connection lost for the first six requests to end it: her last answer lands, and the
    /// finish after it does not, for a while.
    static let examFinishDrops = DebugScenario("exam-finish-drops") { context in
        context.model(
            server: FakeQBankServer(
                signedIn: true, examInProgress: true, examLastQuestionOpen: true, droppedFinishes: 6, answersFile: context.answersFile
            ),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// As `examInProgress`, with that exam's time running out a minute after launch.
    static let examTimeRunningOut = DebugScenario("exam-time-running-out") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, examInProgress: true, examEndsIn: 60, answersFile: context.answersFile),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// As `signedIn`, on a slow connection: the reply to each practice answer and to Start over
    /// takes `DebugLaunchScenario.slowSaveReplyDelay` to arrive, so a test can act while one is on its way.
    static let slowSaves = DebugScenario("slow-saves") { context in
        context.model(
            server: FakeQBankServer(
                signedIn: true, saveReplyDelay: DebugLaunchScenario.slowSaveReplyDelay, answersFile: context.answersFile
            ),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// Signed in, with Weeks 1-3 holding one matrixmulti question instead of the mixed set.
    static let matrixMulti = DebugScenario("matrix-multi") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, matrixMultiSet: true, answersFile: context.answersFile),
            session: FakeQBankServer.storedStudentSession()
        )
    }

    /// Signed in, with Weeks 1-3 holding one select-all question whose every option is correct.
    static let sataAllCorrect = DebugScenario("sata-all-correct") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, sataAllCorrectSet: true, answersFile: context.answersFile),
            session: FakeQBankServer.storedStudentSession()
        )
    }
}
#endif
