import Foundation
import QBankKit
import Testing
@testable import QBank

/// The model's three kinds of account: which transport each uses, what the screens are told about the
/// connection, and which rows Settings offers. The invited kind is today's behavior. Invented data only.
@MainActor
struct AccountKindTests {
    /// A free account's model: a bank on this phone, in memory, and `network` for the account's
    /// own requests.
    private func freeApp(
        network: StubServer, connection: Connection = Connection(), bank: LocalBank? = nil
    ) throws -> (AppModel, InMemorySessionStore) {
        let bank = try bank ?? LocalBank(store: LocalStore.inMemory())
        let store = InMemorySessionStore(StoredSession(token: TestApp.token, account: .student()))
        let client = AppModel.client(
            for: .free, configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!),
            network: network, bank: bank, sessionStore: store
        )
        let defaults = TestApp.freshDefaults()
        let app = AppModel(
            client: client, kind: .free, look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), highlighter: HighlighterStore(defaults: defaults),
            aiConsent: AIConsentStore(defaults: defaults), storage: .memory(), connection: connection
        )
        return (app, store)
    }

    @Test func aModelIsInvitedUnlessItIsToldOtherwise() {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        #expect(app.kind == .invited)
        #expect(app.offersQuestionMaker)
    }

    // MARK: Transport

    @Test func aFreeAccountsBankAnswersOnThePhoneWithoutAskingTheNetwork() async throws {
        let network = StubServer()
        let (app, _) = try freeApp(network: network)
        let made = try await app.client.createTopic(title: "Pharmacology")
        let catalog = try await app.client.catalog()
        #expect(catalog.topics.map(\.id) == [made.id])
        #expect(catalog.topics.map(\.title) == ["Pharmacology"])
        #expect(network.requests.isEmpty, "nothing she studies reaches the network")
    }

    @Test func aFreeAccountsOwnRequestsStillGoToTheNetwork() async throws {
        let network = StubServer(["PUT /api/me/palette": .ok(Bodies.account(palette: "slate"))])
        let (app, _) = try freeApp(network: network)
        await app.pickPalette(.slate)
        #expect(network.calls == ["PUT /api/me/palette"])
    }

    @Test func anInvitedAccountsBankStaysOnTheServer() async throws {
        let server = StubServer(["GET /api/semesters": .ok(#"{"semesters":[],"topics":[]}"#)])
        let (app, _) = TestApp.make(server, account: .student())
        _ = try await app.client.catalog()
        #expect(server.calls == ["GET /api/semesters"])
        #expect(app.offline != nil, "its saved courses and waiting answers are kept as ever")
    }

    // MARK: What the phone keeps, and the connection

    @Test func aFreeAccountOpensNoOfflineStoreAndReadsThroughToItsBank() async throws {
        let (app, _) = try freeApp(network: StubServer())
        #expect(app.offline == nil)
        let loaded = try await app.load(.catalog) { () async throws(QBankError) in try await app.client.catalog() }
        #expect(loaded.savedAt == nil, "read live from the bank, never from a saved copy")
    }

    @Test func aFreeAccountsConnectionIsAlwaysUpWhateverThePhonesNetworkDoes() throws {
        let given = Connection(isOnline: false)
        let (app, _) = try freeApp(network: StubServer(), connection: given)
        #expect(app.connection.isOnline)
        app.connection.update(isOnline: false)
        #expect(app.connection.isOnline)
        #expect(!given.isOnline, "the phone's own network path is left as it was")
    }

    @Test func anInvitedAccountsConnectionFollowsTheNetwork() {
        let connection = Connection()
        let (app, _) = TestApp.make(StubServer(), account: .student(), connection: connection)
        connection.update(isOnline: false)
        #expect(!app.connection.isOnline)
    }

    // MARK: Session

    @Test func aFreeAccountStaysSignedInWhateverTheNetworkSaysOfItsSession() async throws {
        let network = StubServer(["GET /api/session": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, store) = try freeApp(network: network)
        await app.refreshSession()
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load() != nil)
        #expect(network.requests.isEmpty)
    }

    @Test func signingOutOfAFreeAccountLeavesItsBankAsItWas() async throws {
        let network = StubServer(["POST /api/sign-out": .offline])
        let bank = LocalBank(store: try LocalStore.inMemory())
        let (app, store) = try freeApp(network: network, bank: bank)
        let made = try await app.client.createTopic(title: "Pharmacology")
        await app.signOut()
        #expect(app.route == .signedOut)
        #expect(try store.load() == nil)
        // The same person signing in again finds the same bank: sign-out erases no study.
        let again = InMemorySessionStore(StoredSession(token: TestApp.token, account: .student()))
        let reopened = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!),
            transport: BankRoutedTransport(bank: bank, account: network), sessionStore: again
        )
        #expect(try await reopened.catalog().topics.map(\.id) == [made.id])
    }

    // MARK: What each kind is offered

    @Test func aFreeAccountIsNotOfferedTheQuestionMaker() async throws {
        let network = StubServer()
        let (app, _) = try freeApp(network: network)
        #expect(!app.offersQuestionMaker)
        let course = CourseModel(app: app, id: "c1")
        await course.loadMaker()
        #expect(course.maker == nil)
        #expect(network.requests.isEmpty)
    }

    @Test func accountDeletionByPasswordIsOfferedToAnInvitedStudentOnly() {
        #expect(DeleteAccountModel.isOffered(to: .student()))
        #expect(DeleteAccountModel.isOffered(to: .student(), kind: .invited))
        #expect(!DeleteAccountModel.isOffered(to: .student(), kind: .free))
        #expect(!DeleteAccountModel.isOffered(to: .student(), kind: .store))
        #expect(!DeleteAccountModel.isOffered(to: .admin, kind: .invited))
    }
}
