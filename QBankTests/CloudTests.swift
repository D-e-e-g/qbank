import Foundation
import QBankKit
import Testing
import UIKit
@testable import QBank

/// QBank Cloud in the model: buying with the token the server gave the account, sending what the App
/// Store signed to the server, and finishing a transaction only once the server answers that Cloud is
/// active; the App Store's updates, Restore, and who is offered Cloud at all. The App Store is a
/// scripted stand-in and the server a stub with the contract's shapes and words. Invented data only.
@MainActor
struct CloudTests {
    /// Sells the fake store's two plans and answers a purchase as the test says, keeping what it was
    /// asked and which transactions the app finished.
    final class ScriptedStore: CloudStore {
        var answer: CloudPurchase?
        var failure: CloudStoreFailure?
        var plansOnSale = DebugFakeStore.plans
        var unfinishedTransactions: [CloudTransaction] = []
        var entitlements: [CloudTransaction] = []
        private(set) var purchases: [(plan: String, token: UUID)] = []
        private(set) var finished: [UInt64] = []
        private(set) var syncs = 0
        let updateStream = AsyncStream.makeStream(of: CloudTransaction.self)

        func transaction(_ id: UInt64, product: String = CloudProducts.monthly) -> CloudTransaction {
            CloudTransaction(id: id, productID: product, signed: "synthetic.signed.\(id)") { [weak self] in
                await self?.finish(id)
            }
        }

        private func finish(_ id: UInt64) {
            finished.append(id)
        }

        func plans() async throws(CloudStoreFailure) -> [CloudPlan] {
            if let failure { throw failure }
            return plansOnSale
        }

        func buy(_ planID: String, token: UUID, in scene: UIWindowScene?) async throws(CloudStoreFailure) -> CloudPurchase {
            purchases.append((planID, token))
            if let failure { throw failure }
            return answer ?? .purchased(transaction(1, product: planID))
        }

        func updates() -> AsyncStream<CloudTransaction> { updateStream.stream }
        func unfinished() async -> [CloudTransaction] { unfinishedTransactions }
        func currentEntitlements() async -> [CloudTransaction] { entitlements }

        func sync() async throws(CloudStoreFailure) {
            syncs += 1
            if let failure { throw failure }
        }

        func manageSubscriptions(in scene: UIWindowScene?) async throws(CloudStoreFailure) {}
    }

    private static let token = "00000000-0000-4000-8000-000000000001"
    private static let read = "GET /api/me/cloud"
    private static let record = "POST /api/me/cloud/transactions"

    private static func status(active: Bool, expiresAt: String? = nil, token: String? = CloudTests.token) -> Reply {
        let expires = expiresAt.map { #""\#($0)""# } ?? "null"
        let token = token.map { #""\#($0)""# } ?? "null"
        return .ok(#"{"active":\#(active),"expiresAt":\#(expires),"storeToken":\#(token)}"#)
    }

    private static let off = status(active: false)
    private static let on = status(active: true, expiresAt: "2027-12-03T00:00:00.000Z")

    /// A model signed in with a session as `account`, a free store account unless the test says,
    /// whose App Store is `store`.
    private func free(_ server: StubServer, store: ScriptedStore, account: Account = .store()) -> AppModel {
        let session = StoredSession(token: TestApp.token, account: account, appleUser: account.origin == .store ? TestApp.appleUser : nil)
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: InMemorySessionStore(session))
        let defaults = TestApp.freshDefaults()
        return AppModel(
            client: client, banks: .memory(), appleSignIn: DebugScriptedAppleSignIn(), store: store, look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), highlighter: HighlighterStore(defaults: defaults),
            aiConsent: AIConsentStore(defaults: defaults), drafts: WriteDraftStore(defaults: defaults), storage: .memory()
        )
    }

    private func sentTransactions(_ server: StubServer) throws -> [String] {
        try server.requests.filter { $0.url?.path() == "/api/me/cloud/transactions" }.map { request in
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
            return try #require(body["signedTransaction"])
        }
    }

    // MARK: Who is offered Cloud

    @Test func cloudIsOfferedToAStoreAccountWithASessionOnly() {
        let (free, _) = TestApp.free()
        #expect(CloudModel.isOffered(to: free))
        let (waiting, _) = TestApp.free(awaitsServer: true)
        #expect(!CloudModel.isOffered(to: waiting), "no session on the server yet to buy with")
        let (invited, _) = TestApp.make(StubServer(), account: .student())
        #expect(!CloudModel.isOffered(to: invited), "an invited account has Cloud without buying it")
        let (signedOut, _) = TestApp.make(StubServer())
        #expect(!CloudModel.isOffered(to: signedOut))
    }

    // MARK: Buying

    @Test func aPurchaseBuysWithTheServersTokenAndIsFinishedOnceTheServerSaysCloudIsOn() async throws {
        let server = StubServer([Self.read: Self.off, Self.record: Self.on])
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(store.purchases.map(\.plan) == [CloudProducts.monthly])
        #expect(store.purchases.map(\.token) == [UUID(uuidString: Self.token)])
        #expect(try sentTransactions(server) == ["synthetic.signed.1"])
        #expect(server.calls == [Self.read, Self.record], "the token comes first, then the purchase")
        #expect(store.finished == [1])
        #expect(app.cloud.status?.active == true)
        #expect(app.cloud.problem == nil)
        #expect(app.cloud.buying == nil)
    }

    @Test func aPurchaseTheServerSaysLeavesCloudOffIsNotFinished() async throws {
        let server = StubServer([Self.read: Self.off, Self.record: Self.status(active: false, expiresAt: "2026-01-01T00:00:00.000Z")])
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[1], in: nil)

        #expect(try sentTransactions(server) == ["synthetic.signed.1"])
        #expect(store.finished.isEmpty)
        #expect(app.cloud.status?.active == false)
        #expect(app.cloud.problem == CloudWording.notActive)
    }

    @Test func aPurchaseTheServerCannotConfirmStaysUnfinishedAndGoesAgainOnRefresh() async throws {
        let server = StubServer([Self.read: Self.off])
        server.script(Self.record, [.offline])
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(store.finished.isEmpty, "nothing is finished on the App Store's word alone")
        #expect(app.cloud.problem == CloudWording.notConfirmedYet)
        #expect(app.cloud.status?.active == false)

        // The App Store still holds it unfinished; the next refresh sends it again.
        store.unfinishedTransactions = [store.transaction(1)]
        server[Self.record] = Self.on
        server[Self.read] = Self.on
        await app.cloud.refresh()
        #expect(try sentTransactions(server) == ["synthetic.signed.1", "synthetic.signed.1"])
        #expect(store.finished == [1])
        #expect(app.cloud.status?.active == true)
    }

    @Test func aPurchaseBoughtForAnotherAccountIsRefusedInTheServersWordsAndNotFinished() async throws {
        let message = "This App Store subscription belongs to another QBank account. Nothing was recorded."
        let server = StubServer([Self.read: Self.off, Self.record: .error(409, "transaction_other_account", message)])
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(store.finished.isEmpty)
        #expect(app.cloud.problem == message)
        #expect(app.route == .signedIn(.store()), "a refusal signs nobody out")
    }

    @Test(arguments: [CloudPurchase.cancelled, .pending, .unverified])
    func aPurchaseThatPaidNothingYetSendsNothing(answer: CloudPurchase) async throws {
        let server = StubServer([Self.read: Self.off])
        let store = ScriptedStore()
        store.answer = answer
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(server.calls == [Self.read])
        #expect(store.finished.isEmpty)
        switch answer {
        case .pending:
            #expect(app.cloud.notice == .note(CloudWording.pending))
            #expect(app.cloud.problem == nil)
        case .unverified:
            #expect(app.cloud.problem == CloudWording.unverified)
        default:
            #expect(app.cloud.problem == nil)
            #expect(app.cloud.notice == nil)
        }
    }

    @Test func noTokenFromTheServerMeansNoPurchase() async {
        let server = StubServer()
        server.script(Self.read, [.offline])
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(store.purchases.isEmpty, "the App Store is not asked without the account's token")
        #expect(app.cloud.problem == "No connection. Check Wi-Fi or cellular data and try again.")
    }

    @Test func anAppStoreThatFailsSaysSoAndOneTheyCloseSaysNothing() async {
        let server = StubServer([Self.read: Self.off])
        let store = ScriptedStore()
        store.failure = .failed
        let app = free(server, store: store)
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)
        #expect(app.cloud.problem == CloudWording.appStoreProblem)

        store.failure = .cancelled
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)
        #expect(app.cloud.problem == nil)
        #expect(!server.calls.contains(Self.record))
    }

    // MARK: The App Store's updates

    @Test func anUpdateIsSentAndFinishedOnceTheServerSaysCloudIsOn() async throws {
        let server = StubServer([Self.record: Self.on])
        let store = ScriptedStore()
        let app = free(server, store: store)
        app.cloud.listen()
        store.updateStream.continuation.yield(store.transaction(7))

        try await waitUntil { store.finished == [7] }
        #expect(try sentTransactions(server) == ["synthetic.signed.7"])
        #expect(app.cloud.status?.active == true)
    }

    @Test func anUpdateWithNoStoreAccountSignedInStaysUnfinished() async throws {
        let server = StubServer([Self.record: Self.on])
        let store = ScriptedStore()
        let invited = free(server, store: store, account: .student())
        invited.cloud.listen()
        store.updateStream.continuation.yield(store.transaction(8))
        // Give the listener its turn: it hears the update and sends nothing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!server.calls.contains(Self.record))
        #expect(store.finished.isEmpty)
    }

    // MARK: Restore

    @Test func restoreSyncsThenSendsEachSubscriptionTheAppleAccountHas() async throws {
        let server = StubServer([Self.record: Self.on])
        let store = ScriptedStore()
        store.entitlements = [store.transaction(3, product: CloudProducts.yearly)]
        let app = free(server, store: store)
        await app.cloud.restore()

        #expect(store.syncs == 1)
        #expect(try sentTransactions(server) == ["synthetic.signed.3"])
        #expect(store.finished == [3])
        #expect(app.cloud.status?.active == true)
        #expect(app.cloud.notice == .done(CloudWording.restored))
    }

    @Test func restoreWithNothingToRestoreSaysSo() async {
        let server = StubServer()
        let store = ScriptedStore()
        let app = free(server, store: store)
        await app.cloud.restore()

        #expect(server.calls.isEmpty)
        #expect(app.cloud.notice == .note(CloudWording.nothingToRestore))
        #expect(app.cloud.problem == nil)
    }

    // MARK: Plans and the account

    @Test func thePlansAreMonthlyThenYearlyAndAStoreThatSellsNoneSaysSo() async {
        let store = ScriptedStore()
        store.plansOnSale = DebugFakeStore.plans.reversed()
        let app = free(StubServer(), store: store)
        await app.cloud.loadPlans()
        #expect(app.cloud.plans?.map(\.id) == CloudProducts.all)

        let empty = ScriptedStore()
        empty.plansOnSale = []
        let other = free(StubServer(), store: empty)
        await other.cloud.loadPlans()
        #expect(other.cloud.plans == nil)
        #expect(other.cloud.plansProblem == CloudWording.plansUnavailable)
    }

    @Test func signingOutForgetsTheAccountsCloud() async {
        let server = StubServer([Self.read: Self.on, "POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let app = free(server, store: ScriptedStore())
        await app.cloud.refresh()
        #expect(app.cloud.status?.active == true)

        await app.signOut()
        #expect(app.cloud.status == nil)
        await app.cloud.refresh()
        #expect(server.calls.filter { $0 == Self.read }.count == 1, "no one is signed in to ask for")
    }

    // MARK: Words

    @Test func settingsSaysWhetherCloudIsOnAndUntilWhen() throws {
        let date = try #require(QBankJSON.parseDate("2027-12-03T12:00:00.000Z"))
        let on = CloudStatus(active: true, expiresAt: date, storeToken: nil)
        let ended = CloudStatus(active: false, expiresAt: date, storeToken: nil)
        let never = CloudStatus(active: false, expiresAt: nil, storeToken: nil)
        #expect(CloudWording.settingsValue(nil) == nil)
        #expect(CloudWording.settingsValue(on) == "On")
        #expect(CloudWording.settingsValue(never) == "Off")
        #expect(CloudWording.settingsDetail(on) == "Paid until \(CloudWording.day(date))")
        #expect(CloudWording.settingsDetail(ended) == "Ended \(CloudWording.day(date))")
        #expect(CloudWording.settingsDetail(never) == CloudWording.offer)
        #expect(CloudWording.settingsDetail(nil) == CloudWording.offer)
    }

    @Test func aPeriodIsSaidInWords() {
        #expect(CloudPeriod(value: 1, unit: .month).text == "1 month")
        #expect(CloudPeriod(value: 1, unit: .year).text == "1 year")
        #expect(CloudPeriod(value: 3, unit: .month).text == "3 months")
        #expect(CloudWording.periodLine(CloudPeriod(value: 1, unit: .year)) == "1 year, renews automatically")
    }

    @Test func eachPlansControlsAreNamedByItsProductId() {
        #expect(DebugFakeStore.plans.map(CloudPlansView.key) == ["monthly", "yearly"])
    }
}

private typealias Reply = StubServer.Reply
