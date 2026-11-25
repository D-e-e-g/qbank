#if DEBUG
import Foundation
import QBankKit

/// One launch scenario of the Debug launch seam: a name a UI test puts in `QB_UITEST_SCENARIO`, and
/// how to build the app's model for it. Each scenario lives in its own file under
/// `QBank/Debug/Scenarios/` as a static member of this type, and joins the seam with one line in
/// `DebugScenarioCatalog`. Compiled only into Debug builds.
nonisolated struct DebugScenario: Hashable, Sendable {
    /// The value of `QB_UITEST_SCENARIO` that starts this scenario.
    let name: String
    /// Builds the model for a launch. A scenario composes a fake server and a session through
    /// `DebugScenarioContext.model(server:session:)`, never a real account or the live server.
    let make: @MainActor @Sendable (DebugScenarioContext) -> AppModel

    init(_ name: String, make: @escaping @MainActor @Sendable (DebugScenarioContext) -> AppModel) {
        self.name = name
        self.make = make
    }

    static func == (left: DebugScenario, right: DebugScenario) -> Bool {
        left.name == right.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// What a launch gives every scenario: the phone's own settings, storage, banks and answers file, the
/// network and the device owner the launch asked for, the scripted Sign in with Apple the launch
/// environment picks, and the fake store, which is empty until the pull request that needs it fills
/// it in.
struct DebugScenarioContext {
    let defaults: UserDefaults
    let storage: PhoneStorage
    /// Free accounts' banks, in the scenario's own folder, emptied with it.
    let banks: PhoneBanks
    /// The file the fake server keeps her answers in, for a scenario whose server keeps them.
    let answersFile: URL
    let isOnline: Bool
    let owner: DeviceOwner
    let appleSignIn: DebugScriptedAppleSignIn
    let store: DebugFakeStore

    /// The app's model on `server`, signed in with `session` or signed out for nil, wired to the
    /// launch's network, Look, lock and phone storage.
    func model(server: FakeQBankServer, session: StoredSession?) -> AppModel {
        DebugLaunchScenario.assemble(server: server, session: session, context: self)
    }
}
#endif
