#if DEBUG
import Foundation

nonisolated extension DebugScenario {
    /// As `freeNewBank`, with the first request to delete the account losing its connection before it
    /// reaches the server. By then the delete has erased this phone's copy, so it is left to finish;
    /// the next request goes through.
    static let freeDeleteDrops = DebugScenario("free-delete-drops") { context in
        DebugFreeMode.model(context: context, droppedAccountDeletes: 1)
    }

    /// As `freeNewBank`, with the server's answer to the delete held back until the test releases it
    /// (`DebugAccountDeleteGate`), so it can look at the screen while the delete is under way.
    static let freeDeleteHeld = DebugScenario("free-delete-held") { context in
        DebugFreeMode.model(context: context) { DebugAccountDeleteGate.hold($0) }
    }

    /// As `signedIn`, an account that deletes with its password, with the server's answer to the
    /// delete held back until the test releases it, as in `freeDeleteHeld`.
    static let signedInDeleteHeld = DebugScenario("signed-in-delete-held") { context in
        let server = FakeQBankServer(signedIn: true, answersFile: context.answersFile)
        DebugAccountDeleteGate.hold(server)
        return context.model(server: server, session: FakeQBankServer.storedStudentSession())
    }
}
#endif
