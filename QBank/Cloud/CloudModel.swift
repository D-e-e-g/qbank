import Observation
import QBankKit
import UIKit

/// QBank Cloud for a store account: how it stands, the plans the App Store sells, buying one,
/// Restore, and Manage subscription (`docs/cloud.md`).
///
/// QBank's server is the authority on who has Cloud. Each transaction the App Store signs, whether
/// from a purchase here, from Restore, or from the App Store's updates, goes to the server with the
/// account's session, and is finished only once the server answers that Cloud is active. One the
/// server did not confirm stays unfinished: the App Store gives it to the app again at the next launch,
/// and `refresh()` sends it again. The app shows Cloud as on only when the server says so.
///
/// One model serves the whole app, as the App Store's updates do. It follows the account signed in
/// (`follow(_:)`), so what it says of one account is gone when another signs in.
@Observable
final class CloudModel {
    /// The plans the App Store sells, in `CloudProducts.all`'s order; nil until they are loaded.
    private(set) var plans: [CloudPlan]?
    /// Said in place of the plans when they could not be loaded.
    private(set) var plansProblem: String?
    private(set) var isLoadingPlans = false
    /// How the account stands with Cloud, as QBank's server last said; nil until it has said.
    private(set) var status: CloudStatus?
    /// The plan being bought, while its purchase runs.
    private(set) var buying: String?
    private(set) var isRestoring = false
    /// Why the last purchase, Restore or Manage subscription did not turn out as asked.
    private(set) var problem: String?
    /// What happened that needs nothing done: a restore that turned Cloud on, a purchase waiting for
    /// approval, or nothing to restore.
    private(set) var notice: CloudNotice?

    /// The app it serves: who is signed in, and the client to reach QBank's server with.
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: any CloudStore
    /// The account signed in, whose Cloud this is.
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(store: any CloudStore) {
        self.store = store
    }

    /// Whether Cloud is offered to the account signed in: a store account with a session on QBank's
    /// server. An invited account has Cloud without buying it, and a Sign in with Apple the server has
    /// not confirmed yet has no session to buy with.
    static func isOffered(to app: AppModel) -> Bool {
        app.account?.origin == .store && !app.awaitsServer
    }

    /// The account signed in now. When it changes, what was said of the one before goes with it.
    func follow(_ accountID: String?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        status = nil
        problem = nil
        notice = nil
    }

    /// Starts taking the App Store's updates, once, for as long as the app runs. The App Store gives
    /// each unfinished transaction again right after launch, so this starts with the app.
    func listen() {
        guard listener == nil else { return }
        let updates = store.updates()
        listener = Task { [weak self] in
            for await transaction in updates {
                await self?.receive(transaction)
            }
        }
    }

    /// Asks the server how the account stands, after sending it each transaction the App Store still
    /// holds unfinished, such as a purchase the server could not confirm when it was made.
    func refresh() async {
        guard case let (client, owner)? = reach() else { return }
        for transaction in await store.unfinished() {
            _ = try? await send(transaction, with: client)
        }
        do {
            let status = try await client.cloudStatus()
            guard owner == accountID else { return }
            self.status = status
        } catch {
            app?.handle(error)
        }
    }

    /// Loads the plans from the App Store, unless they are already here.
    func loadPlans() async {
        guard plans == nil, !isLoadingPlans else { return }
        isLoadingPlans = true
        plansProblem = nil
        defer { isLoadingPlans = false }
        do {
            let loaded = try await store.plans()
            let ordered = CloudProducts.all.compactMap { id in loaded.first { $0.id == id } }
            if ordered.isEmpty {
                plansProblem = CloudWording.plansUnavailable
            } else {
                plans = ordered
            }
        } catch {
            plansProblem = CloudWording.plansUnavailable
        }
    }

    /// Buys `plan` with the token the server gave the account, over `scene`, and sends what the App
    /// Store signed to the server, which turns Cloud on.
    func buy(_ plan: CloudPlan, in scene: UIWindowScene?) async {
        guard buying == nil, !isRestoring else { return }
        guard case let (client, owner)? = reach() else {
            problem = CloudWording.needsServer
            return
        }
        buying = plan.id
        problem = nil
        notice = nil
        defer { buying = nil }
        let token: UUID
        do {
            token = try await storeToken(client, for: owner)
        } catch {
            say(error, for: owner)
            return
        }
        let purchase: CloudPurchase
        do {
            purchase = try await store.buy(plan.id, token: token, in: scene)
        } catch {
            if owner == accountID, error != .cancelled { problem = CloudWording.appStoreProblem }
            return
        }
        switch purchase {
        case .purchased(let transaction):
            do {
                let status = try await send(transaction, with: client)
                guard owner == accountID else { return }
                self.status = status
                if !status.active { problem = CloudWording.notActive }
            } catch {
                say(error, for: owner, temporary: CloudWording.notConfirmedYet)
            }
        case .pending:
            if owner == accountID { notice = .note(CloudWording.pending) }
        case .cancelled:
            break
        case .unverified:
            if owner == accountID { problem = CloudWording.unverified }
        }
    }

    /// Restore purchases: brings the App Store's record of the Apple Account up to date, which may ask
    /// for its password, and sends the server each Cloud subscription it has now.
    func restore() async {
        guard !isRestoring, buying == nil else { return }
        guard case let (client, owner)? = reach() else {
            problem = CloudWording.needsServer
            return
        }
        isRestoring = true
        problem = nil
        notice = nil
        defer { isRestoring = false }
        do {
            try await store.sync()
        } catch {
            if owner == accountID, error != .cancelled { problem = CloudWording.appStoreProblem }
            return
        }
        let transactions = await store.currentEntitlements()
        guard !transactions.isEmpty else {
            if owner == accountID { notice = .note(CloudWording.nothingToRestore) }
            return
        }
        // Each answer is the account's whole Cloud state, so the last one received is how it stands.
        var latest: CloudStatus?
        var failure: QBankError?
        for transaction in transactions {
            do {
                latest = try await send(transaction, with: client)
            } catch {
                failure = error
            }
        }
        guard owner == accountID else { return }
        if let latest { status = latest }
        if latest?.active == true {
            notice = .done(CloudWording.restored)
        } else if let failure {
            say(failure, for: owner, temporary: CloudWording.notConfirmedYet)
        } else {
            problem = CloudWording.notActive
        }
    }

    /// Apple's Manage subscription sheet; once it is closed, the server is asked how the account stands.
    func manage(in scene: UIWindowScene?) async {
        problem = nil
        notice = nil
        do {
            try await store.manageSubscriptions(in: scene)
        } catch {
            if error != .cancelled { problem = CloudWording.manageUnavailable }
        }
        await refresh()
    }

    /// A transaction from the App Store's updates. With no store account signed in to send it for, or
    /// with no answer from the server, it stays unfinished, and the App Store gives it again.
    private func receive(_ transaction: CloudTransaction) async {
        guard case let (client, owner)? = reach(), let status = try? await send(transaction, with: client), owner == accountID else { return }
        self.status = status
    }

    /// Sends a transaction to QBank's server, and finishes it once the server answers that Cloud is
    /// active: never on the App Store's word alone, and never after a refusal or no answer.
    private func send(_ transaction: CloudTransaction, with client: QBankClient) async throws(QBankError) -> CloudStatus {
        let status = try await client.recordCloudTransaction(transaction.signed)
        if status.active {
            await transaction.finish()
        }
        return status
    }

    /// The token the account buys with, which the server issues at its first read and keeps.
    private func storeToken(_ client: QBankClient, for owner: String) async throws(QBankError) -> UUID {
        if let token = status?.storeToken { return token }
        let status = try await client.cloudStatus()
        if owner == accountID { self.status = status }
        guard let token = status.storeToken else {
            throw .unexpectedResponse(status: 200, detail: "The server gave this store account no storeToken")
        }
        return token
    }

    /// The client to reach QBank's server with, and the account it speaks for, while Cloud is offered.
    private func reach() -> (QBankClient, String)? {
        guard let app, Self.isOffered(to: app), let id = app.account?.id, id == accountID else { return nil }
        return (app.client, id)
    }

    /// Says why the server did not answer as asked, unless the account is no longer the one signed in
    /// or the failure ended the session. `temporary` is said of a failure that may pass by itself.
    private func say(_ error: QBankError, for owner: String, temporary: String? = nil) {
        guard owner == accountID, app?.handle(error) != true else { return }
        if let temporary, error.isTemporary {
            problem = temporary
        } else {
            problem = Wording.problem(error)
        }
    }
}

/// What happened on the plans sheet that needs nothing done.
nonisolated enum CloudNotice: Equatable, Sendable {
    /// Good news: Restore found the subscription and Cloud is on.
    case done(String)
    /// A plain fact: a purchase waiting for approval, or nothing to restore.
    case note(String)
}
