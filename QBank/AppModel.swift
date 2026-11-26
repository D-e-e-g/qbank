import Observation
import QBankKit

/// The app's top-level state: who is signed in, what kind of account it is, the client every screen
/// talks through, and what the phone keeps for her account to study without signal.
///
/// An invited or store account's bank is on the server, and the client talks to it. A free account's
/// bank is on this phone: its client answers the bank's requests on the phone, and the screens see a
/// connection that is always up. Which kind the account is, and so which rows Settings offers, is
/// `kind`, not the account's role. A password sign-in is always an invited account's, so it puts the
/// model back on the server, leaving a free bank on the phone as it was.
///
/// Sign in with Apple makes a store account with no Cloud, which is free: its bank is on this phone,
/// named by Apple's id of the person, so signing out leaves it and signing in again opens it. When
/// QBank's server cannot answer after Apple said yes, the bank opens all the same and the sign-in is
/// sent again later (`awaitsServer`). A session kept from before Sign in with Apple is an invited
/// account's and opens signed in, on the server, as it did.
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
        didSet {
            openOffline()
            drafts.open(accountID: phoneKey)
            frozen.isOn = account?.role == .admin
            cloud.follow(account?.id)
        }
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

    /// The client every screen talks through: the bank on this phone for a free account, else the server.
    private(set) var client: QBankClient
    /// What kind of account is signed in, which decides where its bank is and what it can do.
    private(set) var kind: AccountKind
    /// True while a Sign in with Apple that Apple confirmed waits for QBank's server, which could not
    /// answer it: the bank on this phone works all the same, and nothing of the account reaches the
    /// server until it answers. The sign-in is sent again at launch, when QBank is on screen again and
    /// when the network comes back (`sendAppleSignInAgain`).
    private(set) var awaitsServer = false
    /// True while `awaitsServer` once the server refused the kept Sign in with Apple, or the stored
    /// session keeps none: nothing is sent again on its own, and only a new Sign in with Apple connects
    /// this phone to the server.
    private(set) var needsAppleSignInAgain = false
    /// What the server answered, or why it could not, the last time it was sent a Sign in with Apple
    /// it has not confirmed. Nil when nothing was heard yet.
    private(set) var serverSignInProblem: String?
    /// Who asks Apple to sign the person in.
    let appleSignIn: any AppleSignInProvider
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
    /// The highlighter pen's color, kept on this phone.
    let highlighter: HighlighterStore
    /// Whether she allowed her material to go to Anthropic, kept on this phone.
    let aiConsent: AIConsentStore
    /// The sets the account signed in has begun writing by hand and not saved, kept on this phone.
    let drafts: WriteDraftStore
    /// Whether the phone has a network path. Always up when the bank is on this phone.
    private(set) var connection: Connection
    /// Her last delete, offered for Undo, and a count the screens follow after a delete or Undo.
    let deletions = Deletions()
    /// The admin's look at a user account: each control answers with one note and changes nothing.
    let frozen = FrozenView()
    /// QBank Cloud for a store account: whether it is on, as QBank's server says, and buying it.
    let cloud: CloudModel
    /// Saved courses and unsent answers for the account on this phone. Nil when signed out.
    private(set) var offline: OfflineStore?

    private let storage: PhoneStorage
    /// The bank on this phone, while a free account is signed in and only then.
    var bank: LocalBank? { kind.bankIsOnPhone ? phoneBank?.bank : nil }
    /// The bank opened last, kept open while it is the one in use.
    private var phoneBank: OpenBank?
    private let banks: PhoneBanks
    private let sampleSet: String?
    /// The client that talks to the server, and the phone's network path it follows.
    private let server: QBankClient
    private let network: Connection
    private let networkWatcher: NetworkWatcher?
    /// True while a kept Sign in with Apple is on its way to the server again, so it goes once at a time.
    @ObservationIgnored private var isSendingAppleSignIn = false

    private struct OpenBank {
        let key: String
        let bank: LocalBank
    }

    /// `client` talks to the server. The session it keeps decides where the bank is: a store account
    /// is free, and its bank is opened from `banks` under Apple's id of the person, which the session
    /// keeps too; any other account's bank is on the server. A free account's bank that is new, with
    /// nothing ever in it, is given `sampleSet`, a question file, as the first set of a topic made for
    /// it; a bank that is not new is left as it is, and an account whose bank is on the server has no
    /// bank here to give it to. `store` is the App Store that sells Cloud.
    init(
        client: QBankClient,
        banks: PhoneBanks = .memory(),
        sampleSet: String? = nil,
        appleSignIn: any AppleSignInProvider = SystemAppleSignIn(),
        store: any CloudStore = StoreKitCloudStore(),
        look: LookStore = LookStore(),
        lock: AppLock = AppLock(),
        highlighter: HighlighterStore = HighlighterStore(),
        aiConsent: AIConsentStore = AIConsentStore(),
        drafts: WriteDraftStore = WriteDraftStore(),
        storage: PhoneStorage,
        connection: Connection = Connection(),
        networkWatcher: NetworkWatcher? = nil
    ) {
        self.look = look
        self.lock = lock
        self.highlighter = highlighter
        self.aiConsent = aiConsent
        self.drafts = drafts
        self.storage = storage
        self.banks = banks
        self.sampleSet = sampleSet
        self.appleSignIn = appleSignIn
        cloud = CloudModel(store: store)
        server = client
        network = connection
        self.networkWatcher = networkWatcher
        let stored = try? client.storedSession()
        var opened: OpenBank?
        var reason: String?
        var start = Route.signedOut
        if let stored, let account = stored.account {
            if account.origin == .store {
                // A store account's bank is on this phone, named by Apple's id of the person. One that
                // cannot open is not replaced by an empty one: signing in again finds it.
                if let key = stored.appleUser, let bank = try? Self.openBank(key, from: banks, sampleSet: sampleSet) {
                    opened = OpenBank(key: key, bank: bank)
                    start = .signedIn(account)
                } else {
                    reason = AppleSignInWording.bankDidNotOpen
                }
            } else {
                start = Self.route(for: account)
            }
        }
        phoneBank = opened
        kind = opened == nil ? .invited : .free
        let waiting = opened != nil && stored?.awaitsServer == true
        awaitsServer = waiting
        needsAppleSignInAgain = waiting && stored?.unsent == nil
        if let opened {
            self.client = waiting ? client.routingBankWithoutServer(to: opened.bank) : client.routingBank(to: opened.bank)
        } else {
            self.client = client
        }
        // A bank on this phone is always reachable, so no network path is followed for it.
        self.connection = opened == nil ? connection : Connection.onThisPhone()
        signedOutReason = reason
        route = start
        openOffline()
        drafts.open(accountID: phoneKey)
        frozen.isOn = account?.role == .admin
        cloud.app = self
        cloud.follow(account?.id)
        network.onChange = { [weak self] isOnline in
            self?.offline?.connectionChanged(isOnline: isOnline)
            guard isOnline, self?.awaitsServer == true else { return }
            Task { await self?.sendAppleSignInAgain() }
        }
    }

    var account: Account? {
        switch route {
        case .signedOut: nil
        case .choosingPassword(let account), .signedIn(let account): account
        }
    }

    /// Who is signed in, as this phone keeps their things apart, such as the sets they are writing: for
    /// a bank on this phone its key, Apple's id of the person, which stays the same when the server
    /// confirms a sign-in it had not; for any other account its id.
    var phoneKey: String? {
        guard let account else { return nil }
        guard kind.bankIsOnPhone, let phoneBank else { return account.id }
        return phoneBank.key
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
        // The color is the account's, saved on the server, which has no session for her yet.
        if awaitsServer {
            await sendAppleSignInAgain()
            guard !awaitsServer else {
                paletteProblem = needsAppleSignInAgain ? AppleSignInWording.paletteNeedsAppleSignInAgain : AppleSignInWording.paletteAwaitsServer
                return
            }
        }
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
        // A Sign in with Apple the server has not answered is sent again instead.
        if awaitsServer {
            await sendAppleSignInAgain()
            return
        }
        // A free account's session is checked with the server when it signs in; until then the
        // phone's bank opens as it is.
        guard account != nil, !kind.bankIsOnPhone else { return }
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
        await sendAppleSignInAgain()
    }

    /// After a sign-in with her password, which only an invited account has: its bank is on the server.
    func signedIn(_ signedIn: SignedIn, password: String) {
        kind = .invited
        client = server
        connection = network
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

    /// Links to her account, checked with its current password, the Apple identity of a Sign in with
    /// Apple she just did in Settings, so Sign in with Apple opens this account from then on. The
    /// account comes back with Apple among its ways in and is otherwise as it was: its bank stays on
    /// the server and she stays signed in. A refusal links nothing and is thrown for the screen to say.
    func linkApple(_ credential: AppleCredential, nonce: AppleSignInNonce, password: String) async throws(QBankError) {
        let request = AppleLinkRequest(identityToken: credential.identityToken, nonce: nonce.value, password: password)
        let linked = try await client.linkApple(request)
        guard account?.id == linked.id else { return }
        route = Self.route(for: linked)
    }

    // MARK: Sign in with Apple

    /// Where a Sign in with Apple that Apple confirmed ended.
    enum AppleSignInOutcome: Equatable {
        /// Signed in, with the account's bank open: on this phone for a store account, on the server
        /// for an account the owner set up that linked Apple.
        case signedIn
        /// Signed in on this phone: QBank's server could not answer, so the bank on this phone is open
        /// and the sign-in is sent again later (`awaitsServer`).
        case awaitingServer
        /// Not signed in, for the reason said. `emailDoor` is set when the person's account signs in
        /// with email and password: the email Apple shared, to put in that door, or empty.
        case refused(String, emailDoor: String?)
    }

    /// Sends the server what Apple said, with the nonce Apple was asked with, and opens the account's
    /// bank. When the server cannot answer, the bank on this phone opens all the same; a refusal leaves
    /// whoever was signed in as they were.
    func signInWithApple(_ credential: AppleCredential, nonce: AppleSignInNonce) async -> AppleSignInOutcome {
        let request = AppleSignInRequest(identityToken: credential.identityToken, nonce: nonce.value)
        do {
            let signedIn = try await server.signInWithApple(request, appleUser: credential.user)
            return await appleSignedIn(signedIn, appleUser: credential.user)
        } catch {
            if AppleSignInWording.serverCannotAnswer(error) {
                return awaitServer(request, credential: credential, problem: AppleSignInWording.problem(error))
            }
            let emailDoor = error.serverCode == "password_account" || error.serverCode == "email_in_use" ? credential.email ?? "" : nil
            return .refused(AppleSignInWording.problem(error), emailDoor: emailDoor)
        }
    }

    /// Sends the server again a Sign in with Apple it could not answer, when one is kept. Once it
    /// answers, the account is the server's, and the screens stay as they are when it is the same
    /// person. Until the server can answer, the sign-in waits for the next time. A refusal is kept for
    /// Settings to say, and the same sign-in is not sent again, but after a lock, which ends.
    func sendAppleSignInAgain() async {
        guard awaitsServer, !isSendingAppleSignIn, let kept = try? server.storedSession(), kept.awaitsServer, kept.unsent != nil,
            let appleUser = kept.appleUser
        else { return }
        isSendingAppleSignIn = true
        defer { isSendingAppleSignIn = false }
        do {
            guard let signedIn = try await server.sendAppleSignInAgain(kept) else { return }
            _ = await appleSignedIn(signedIn, appleUser: appleUser)
        } catch {
            guard awaitsServer, phoneBank?.key == appleUser else { return }
            serverSignInProblem = AppleSignInWording.problem(error)
            if !AppleSignInWording.serverCannotAnswer(error), error.serverCode != .tooManyAttempts {
                try? server.forgetUnsentAppleSignIn(kept)
                needsAppleSignInAgain = (try? server.storedSession())?.unsent == nil
            }
        }
    }

    /// After the server answered a Sign in with Apple. A store account's bank is on this phone, under
    /// Apple's id of the person; an account the owner set up, which linked Apple, has its bank on the
    /// server, as with its password. The server confirming the person already signed in here on this
    /// phone keeps the screens as they are.
    private func appleSignedIn(_ signedIn: SignedIn, appleUser: String) async -> AppleSignInOutcome {
        let isConfirming = awaitsServer && phoneKey == appleUser && signedIn.user.origin == .store
        if signedIn.user.origin == .store {
            guard let bank = try? openBank(appleUser) else {
                // The server's session is of no use without the bank: end it, and say why.
                try? await server.signOut()
                return .refused(AppleSignInWording.bankDidNotOpen, emailDoor: nil)
            }
            kind = .free
            client = server.routingBank(to: bank)
            connection = Connection.onThisPhone()
        } else {
            kind = .invited
            client = server
            connection = network
        }
        awaitsServer = false
        needsAppleSignInAgain = false
        serverSignInProblem = nil
        temporaryPassword = nil
        if !isConfirming { beginSignIn() }
        route = Self.route(for: signedIn.user)
        return .signedIn
    }

    /// Apple said yes and the server could not answer: the bank on this phone opens under Apple's id of
    /// the person, with the account as Apple described it, and the sign-in is kept to send again. The
    /// same person asking again while waiting keeps the screens as they are.
    private func awaitServer(_ request: AppleSignInRequest, credential: AppleCredential, problem: String) -> AppleSignInOutcome {
        let samePerson = awaitsServer && phoneKey == credential.user ? account : nil
        let account =
            samePerson ?? Account(id: credential.user, email: credential.email ?? "", name: "", role: .student, mustChangePassword: false, origin: .store)
        guard let bank = try? openBank(credential.user) else {
            return .refused(AppleSignInWording.bankDidNotOpen, emailDoor: nil)
        }
        do {
            try server.keepAppleSignInForServer(request, account: account, appleUser: credential.user)
        } catch {
            return .refused(Wording.problem(error) ?? AppleSignInWording.appleDidNotFinish, emailDoor: nil)
        }
        kind = .free
        client = server.routingBankWithoutServer(to: bank)
        connection = Connection.onThisPhone()
        awaitsServer = true
        needsAppleSignInAgain = false
        serverSignInProblem = problem
        temporaryPassword = nil
        if samePerson == nil { beginSignIn() }
        route = .signedIn(account)
        return .awaitingServer
    }

    /// A new person signed in on this phone: fresh screens, the lock as at a sign-in, and no word left
    /// from the last sign-out.
    private func beginSignIn() {
        signIns += 1
        signedOutReason = nil
        hasLanded = false
        lock.signedIn()
    }

    /// The bank of `key`, opened once and kept open while it is the one in use.
    private func openBank(_ key: String) throws -> LocalBank {
        if let phoneBank, phoneBank.key == key { return phoneBank.bank }
        let bank = try Self.openBank(key, from: banks, sampleSet: sampleSet)
        phoneBank = OpenBank(key: key, bank: bank)
        return bank
    }

    /// A bank that has never held anything is given the sample set. The sample is a nicety: a bank
    /// that refuses it simply starts empty.
    private static func openBank(_ key: String, from banks: PhoneBanks, sampleSet: String?) throws -> LocalBank {
        let bank = try banks.open(key)
        if let sampleSet {
            _ = try? bank.fileSampleSet(sampleSet, inTopic: SampleSet.topic)
        }
        return bank
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
        // With no session on the server yet, this phone's is the only one.
        guard !awaitsServer else {
            await signOut()
            return
        }
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
    /// waiting, and deletes the sets she was writing. A refusal deletes nothing, keeps her signed in,
    /// and is thrown for the screen to say.
    func deleteAccount(password: String) async throws(QBankError) {
        try await client.deleteAccount(password: password)
        if let account { drafts.erase(accountID: account.id) }
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
        // The server's backstop: a control let a write through, so the answer is the same note.
        if error.isAdminReadOnly, frozen.isOn {
            frozen.showNote()
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
        awaitsServer = false
        needsAppleSignInAgain = false
        serverSignInProblem = nil
        kind = .invited
        client = server
        connection = network
        route = .signedOut
    }

    private static func route(for account: Account) -> Route {
        account.mustChangePassword ? .choosingPassword(account) : .signedIn(account)
    }

    /// Opens the phone's store for the account signed in, keeping it while the account stays. An
    /// ended session closes it but leaves its files, so waiting answers go once she signs in again.
    private func openOffline() {
        guard kind.savesForOffline, let account else {
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

    /// The model the app starts with, taking the App Store's Cloud updates from launch on. Debug builds
    /// let UI tests choose a scenario through `DebugLaunchScenario`; Release builds always talk to the
    /// live server and the App Store.
    static func launch() -> AppModel {
        let model = launchModel()
        model.cloud.listen()
        return model
    }

    private static func launchModel() -> AppModel {
        #if DEBUG
        if let model = DebugLaunchScenario.makeModel() {
            return model
        }
        #endif
        let connection = Connection()
        return AppModel(
            client: QBankClient(sessionStore: KeychainSessionStore()),
            banks: .standard(),
            sampleSet: SampleSet.bundledSource(),
            appleSignIn: SystemAppleSignIn(),
            store: StoreKitCloudStore(),
            storage: .standard(),
            connection: connection,
            networkWatcher: NetworkWatcher(connection: connection)
        )
    }
}
