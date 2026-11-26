#if DEBUG
import Foundation
import QBankKit

/// The app's model for a free account on this iPhone, for a launch scenario: the store account
/// `FakeQBankServer.applePerson`, signed in with Apple from an earlier launch. Its own requests go to
/// a fake server, and its bank is a real `LocalBank` in the scenario's folder, opened by the model
/// from the session as the app opens it, so a test proves the bank runs on the phone, with no network,
/// by the same code the app uses. Compiled only into Debug builds.
///
/// The scenario assembles the model itself, as `DebugLaunchScenario.assemble` does for the other
/// kinds, so its bank starts empty or with the sample set, as the scenario says. A launch that asks
/// for no network (`QB_UITEST_NETWORK=offline`) turns the fake server off; the bank still answers.
nonisolated enum DebugFreeMode {
    /// The listeners that follow the test's notifications, kept while the app runs.
    @MainActor private static var network: DebugNetwork?
    @MainActor private static var look: DebugLook?

    /// The fake server stands in for the network the account's requests would reach; the free
    /// account is the one it already knows, signed in from an earlier launch. A new bank is given
    /// `sampleSet` when there is one. The first `droppedAccountDeletes` requests to delete the account
    /// lose the connection before they reach the server. `prepare` sets the fake server up before the
    /// app starts.
    @MainActor
    static func model(
        context: DebugScenarioContext, sampleSet: String? = nil, droppedAccountDeletes: Int = 0, prepare: (FakeQBankServer) -> Void = { _ in }
    ) -> AppModel {
        // Sign in with Apple made the account, so it has no password.
        let signedIn = FakeQBankServer.Credentials(email: FakeQBankServer.applePerson.email, password: "")
        let server = FakeQBankServer(signedIn: true, as: signedIn, droppedAccountDeletes: droppedAccountDeletes, answersFile: context.answersFile)
        prepare(server)
        let connection = Connection(isOnline: context.isOnline)
        let network = DebugNetwork(server: server, connection: connection, isOnline: context.isOnline)
        network.listen()
        self.network = network
        let lookStore = LookStore(defaults: context.defaults)
        let look = DebugLook(store: lookStore)
        look.listen()
        self.look = look
        DebugWindows.listen()
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
            transport: server,
            sessionStore: InMemorySessionStore(FakeQBankServer.storedApplePersonSession())
        )
        return AppModel(
            client: client,
            banks: context.banks,
            sampleSet: sampleSet,
            appleSignIn: context.appleSignIn,
            store: context.store,
            look: lookStore,
            lock: AppLock(defaults: context.defaults, owner: context.owner),
            highlighter: HighlighterStore(defaults: context.defaults),
            aiConsent: AIConsentStore(defaults: context.defaults),
            drafts: WriteDraftStore(defaults: context.defaults),
            storage: context.storage,
            connection: connection
        )
    }
}
#endif
