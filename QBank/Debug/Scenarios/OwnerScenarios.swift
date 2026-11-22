#if DEBUG
import Foundation

nonisolated extension DebugScenario {
    /// `FakeQBankServer.owner` is signed in, on Home, in the frozen view of `FakeQBankServer.student`.
    static let owner = DebugScenario("owner") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, as: FakeQBankServer.owner, examInProgress: false),
            session: FakeQBankServer.storedOwnerSession()
        )
    }

    /// As `owner`, with the exam of `examInProgress` running on the account it looks at.
    static let ownerExamInProgress = DebugScenario("owner-exam-in-progress") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, as: FakeQBankServer.owner, examInProgress: true),
            session: FakeQBankServer.storedOwnerSession()
        )
    }
}
#endif
