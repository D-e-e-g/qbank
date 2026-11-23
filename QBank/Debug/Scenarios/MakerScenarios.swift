#if DEBUG
import Foundation

nonisolated extension DebugScenario {
    /// `FakeQBankServer.maker` is signed in: the server lets her make questions, with one set
    /// being written and the questions copied from two photos waiting for her check.
    static let maker = DebugScenario("maker") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, as: FakeQBankServer.maker, makerIsSetUp: true),
            session: FakeQBankServer.storedMakerSession()
        )
    }

    /// `FakeQBankServer.maker` is signed in, but the server has no Claude key, so making
    /// questions is not set up yet.
    static let makerNotSetUp = DebugScenario("maker-not-set-up") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, as: FakeQBankServer.maker, makerIsSetUp: false),
            session: FakeQBankServer.storedMakerSession()
        )
    }
}
#endif
