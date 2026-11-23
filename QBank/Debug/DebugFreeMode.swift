#if DEBUG
import Foundation
import QBankKit

/// The app's model for a free account on this iPhone, for a launch scenario: the account's own
/// requests go to a fake server, and the bank is a real `LocalBank` over a store in memory, so a
/// test proves the bank runs on the phone, with no network, by the same code the app will use.
/// Compiled only into Debug builds.
///
/// The scenario assembles the model itself, as `DebugLaunchScenario.assemble` does for the other
/// kinds, so the shared seam and the UI test helpers stay as they are. A launch that asks for no
/// network (`QB_UITEST_NETWORK=offline`) turns the fake server off; the bank still answers.
nonisolated enum DebugFreeMode {
    /// The listeners that follow the test's notifications, kept while the app runs.
    @MainActor private static var network: DebugNetwork?
    @MainActor private static var look: DebugLook?

    /// The fake server stands in for the network the account's requests would reach; the free
    /// account is the one it already knows, signed in from an earlier launch.
    @MainActor
    static func model(context: DebugScenarioContext, bank: LocalBank) -> AppModel {
        let server = FakeQBankServer(signedIn: true, answersFile: context.answersFile)
        let connection = Connection(isOnline: context.isOnline)
        let network = DebugNetwork(server: server, connection: connection, isOnline: context.isOnline)
        network.listen()
        self.network = network
        let lookStore = LookStore(defaults: context.defaults)
        let look = DebugLook(store: lookStore)
        look.listen()
        self.look = look
        DebugWindows.listen()
        let client = AppModel.client(
            for: .free,
            configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
            network: server,
            bank: bank,
            sessionStore: InMemorySessionStore(FakeQBankServer.storedStudentSession())
        )
        return AppModel(
            client: client,
            kind: .free,
            look: lookStore,
            lock: AppLock(defaults: context.defaults, owner: context.owner),
            highlighter: HighlighterStore(defaults: context.defaults),
            aiConsent: AIConsentStore(defaults: context.defaults),
            storage: context.storage,
            connection: connection
        )
    }
}
#endif
