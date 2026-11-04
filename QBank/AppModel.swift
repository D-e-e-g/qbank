import Observation
import QBankKit

/// The app's top-level state: who is signed in, the client every screen talks through, and what
/// the phone keeps for her account to study without signal.
@Observable
final class AppModel {
    enum Route: Equatable {
        /// No session on this phone: the sign-in screen.
        case signedOut
        /// The owner reset her password: she chooses a new one before anything else.
        case choosingPassword(Account)
        case signedIn(Account)
    }

    private(set) var route: Route {
        didSet { openOffline() }
    }
    /// Said on the sign-in screen after the server ended the session.
    private(set) var signedOutReason: String?
    /// The password she just signed in with, offered on the choose-a-new-password screen.
    private(set) var temporaryPassword: String?
    /// True once Home has opened the course she used last, so it happens once per sign-in.
    var hasLanded = false
    /// Counts sign-ins on this phone, so each starts from fresh screens, even for the account that
    /// just signed out.
    private(set) var signIns = 0

    let client: QBankClient
    /// Light or dark, chosen in Settings and kept on this phone.
    let look: LookStore
    /// The color scheme she picked in Settings while it is on its way to the server, shown at once.
    private(set) var pickedPalette: Account.Palette?
    /// Said under Color in Settings when the server did not save her pick.
    private(set) var paletteProblem: String?
    /// Counts her picks, so only the latest decides what shows once the server answers.
    @ObservationIgnored private var palettePicks = 0
    /// The optional Face ID lock, turned on in Settings and kept on this phone.
    let lock: AppLock
    /// Whether the phone has a network path.
    let connection: Connection
    /// Her last delete, offered for Undo, and a count the screens follow after a delete or Undo.
    let deletions = Deletions()
    /// Saved courses and unsent answers for the account on this phone. Nil when signed out.
    private(set) var offline: OfflineStore?

    private let storage: PhoneStorage
    private let networkWatcher: NetworkWatcher?

    init(
        client: QBankClient,
        look: LookStore = LookStore(),
        lock: AppLock = AppLock(),
        storage: PhoneStorage,
        connection: Connection = Connection(),
        networkWatcher: NetworkWatcher? = nil
    ) {
        self.client = client
        self.look = look
        self.lock = lock
        self.storage = storage
        self.connection = connection
        self.networkWatcher = networkWatcher
        let stored = try? client.storedSession()
        route = stored?.account.map(Self.route(for:)) ?? .signedOut
        openOffline()
        connection.onChange = { [weak self] isOnline in
            self?.offline?.connectionChanged(isOnline: isOnline)
        }
    }

    var account: Account? {
        switch route {
        case .signedOut: nil
        case .choosingPassword(let account), .signedIn(let account): account
        }
    }

    /// The color scheme the screens are drawn in: her account's, which follows it to every device,
    /// or the one she just picked. Dusk when no one is signed in.
    var palette: Account.Palette {
        pickedPalette ?? account?.palette ?? .dusk
    }

    /// Saves the color scheme she picked in Settings to her account. It shows at once; when the
    /// server does not take it, the screens go back to her account's and Settings says why.
    func pickPalette(_ palette: Account.Palette) async {
        guard account != nil, palette != self.palette else { return }
        palettePicks += 1
        let pick = palettePicks
        pickedPalette = palette
        paletteProblem = nil
        do {
            let saved = try await client.setPalette(palette)
            guard pick == palettePicks else { return }
            pickedPalette = nil
            if account?.id == saved.id {
                route = Self.route(for: saved)
            }
        } catch {
            guard pick == palettePicks else { return }
            pickedPalette = nil
            guard !handle(error) else { return }
            paletteProblem = Wording.problem(error)
        }
    }

    /// Checks the stored session with the server. The phone stays signed in when the server
    /// cannot be reached; only a session the server has ended signs her out.
    func refreshSession() async {
        guard account != nil else { return }
        do {
            let session = try await client.session()
            route = Self.route(for: session.user)
        } catch {
            handle(error)
        }
    }

    /// QBank is on screen again: the lock asks for Face ID if it locked in the meantime.
    func becameActive() async {
        guard account != nil else { return }
        await lock.becameActive()
    }

    /// After a sign-in with her password.
    func signedIn(_ signedIn: SignedIn, password: String) {
        signIns += 1
        signedOutReason = nil
        hasLanded = false
        lock.signedIn()
        temporaryPassword = signedIn.user.mustChangePassword ? password : nil
        route = Self.route(for: signedIn.user)
    }

    /// After she chose a new password: in place of the owner's temporary one, or in Settings.
    func passwordChosen(_ signedIn: SignedIn) {
        temporaryPassword = nil
        route = Self.route(for: signedIn.user)
    }

    /// Ends the session on the server and on this phone. The phone forgets it even without signal,
    /// with the courses it saved and any answers still waiting to be sent.
    func signOut() async {
        try? await client.signOut()
        await eraseAccount()
    }

    /// Ends every session of her account on the server, on every device, this one included, then
    /// forgets it here as a sign-out does, with the courses it saved and any answers still waiting.
    /// Unlike a sign-out it needs QBank's answer: without one the other devices may still be signed
    /// in, so she stays signed in here, keeps everything, and the failure is thrown for Settings to
    /// say. A session that had already ended goes back to sign-in, as any ended session does.
    func signOutEverywhere() async throws(QBankError) {
        do {
            try await client.signOutEverywhere()
        } catch {
            guard !handle(error) else { return }
            throw error
        }
        await eraseAccount()
    }

    /// Deletes her user account on the server, for good, checked with her password. Once it is
    /// gone the phone forgets it as a sign-out does, with the courses it saved and any answers still
    /// waiting. A refusal deletes nothing, keeps her signed in, and is thrown for the screen to say.
    func deleteAccount(password: String) async throws(QBankError) {
        try await client.deleteAccount(password: password)
        await eraseAccount()
    }

    /// Forgets the account signed in, and everything the phone kept for it.
    private func eraseAccount() async {
        if let account {
            await offline?.close()
            offline = nil
            storage.erase(account.id)
        }
        forgetSession(reason: nil)
    }

    /// Reads from the server and keeps a copy on the phone; without a connection, the copy saved last.
    func load<Value: Codable & Sendable>(
        _ key: CacheKey<Value>,
        from fetch: () async throws(QBankError) -> Value
    ) async throws(QBankError) -> Loaded<Value> {
        guard let offline else { return Loaded(value: try await fetch(), savedAt: nil) }
        return try await offline.load(key, from: fetch)
    }

    /// Sends a practice answer, or keeps it on the phone to send when QBank can be reached.
    func submit(_ submission: AttemptSubmission, courseID: String) async throws(QBankError) -> Delivery {
        guard let offline else { return .sent(try await client.recordAttempt(submission)) }
        return try await offline.submit(submission, courseID: courseID)
    }

    /// Reacts to a failure any screen ran into. Returns true when it changed the route, so the
    /// screen has nothing more to say.
    @discardableResult
    func handle(_ error: QBankError) -> Bool {
        if error.needsSignIn {
            try? client.sessionStore.clear()
            forgetSession(reason: "Your session ended. Sign in again.")
            return true
        }
        if error.serverCode == .mustChangePassword, let account {
            route = .choosingPassword(account)
            return true
        }
        return false
    }

    private func forgetSession(reason: String?) {
        signedOutReason = reason
        pickedPalette = nil
        paletteProblem = nil
        temporaryPassword = nil
        hasLanded = false
        route = .signedOut
    }

    private static func route(for account: Account) -> Route {
        account.mustChangePassword ? .choosingPassword(account) : .signedIn(account)
    }

    /// Opens the phone's store for the account signed in, keeping it while the account stays. An
    /// ended session closes it but leaves its files, so waiting answers go once she signs in again.
    private func openOffline() {
        guard let account else {
            offline?.stop()
            offline = nil
            return
        }
        guard offline?.accountID != account.id else { return }
        offline?.stop()
        let store = OfflineStore(accountID: account.id, client: client, connection: connection, storage: storage.open(account.id))
        offline = store
        store.sendIfWaiting()
    }

    /// The model the app starts with. Debug builds let UI tests choose a scenario through
    /// `DebugLaunchScenario`; Release builds always talk to the live server.
    static func launch() -> AppModel {
        #if DEBUG
        if let model = DebugLaunchScenario.makeModel() {
            return model
        }
        #endif
        let connection = Connection()
        return AppModel(
            client: QBankClient(sessionStore: KeychainSessionStore()),
            storage: .standard(),
            connection: connection,
            networkWatcher: NetworkWatcher(connection: connection)
        )
    }
}
