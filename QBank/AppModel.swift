import Observation
import QBankKit
import UIKit

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
///
/// A store account's bank moves to QBank Cloud once Cloud is on (`cloudMove`). Where it is, the
/// phone or QBank Cloud, is what the record beside the bank says (`BankHandover`), never the Cloud
/// state alone: a store account whose bank moved is `.store`, on the server, and the bank file on this
/// phone stays as it was, a safety copy that is not even opened. A move the app was closed during is
/// found at launch, with the bank's writes held, and finished before anything else.
///
/// When Cloud ends for a store account whose bank is in QBank Cloud, the bank comes back to this phone
/// (`cloudReturn`), into a fresh file the record then names, and the account is free again. On a
/// second device, or for a returning subscriber, QBank Cloud's bank is the authority: a first launch
/// with Cloud on makes no bank here, and a bank already here is replaced only on the person's word,
/// staying as it was, a safety copy whose own sets are offered to QBank Cloud as new sets
/// (`cloudAdopt`).
///
/// A store account, free or Cloud, is deleted with a fresh Sign in with Apple, in a fixed order: this
/// phone's copy is erased, then the account on the server, then the session (`deleteAccount(confirmedWith:nonce:)`).
/// A delete that stopped after the erase began opens as `finishingDeletion`, which offers to finish it
/// or to sign out, which keeps the account on QBank's server until it is deleted later from Settings.
@Observable
final class AppModel {
    enum Route: Equatable {
        /// No session on this phone: the sign-in screen.
        case signedOut
        /// The owner reset her password: she chooses a new one before anything else.
        case choosingPassword(Account)
        case signedIn(Account)
        /// A store account's delete that stopped once this phone's copy was erased, or while it was,
        /// before the server deleted the account: finishing the delete, or signing out, is offered.
        case finishingDeletion(Account)
    }

    private(set) var route: Route {
        didSet {
            routeChanges += 1
            openOffline()
            drafts.open(accountID: phoneKey)
            frozen.isOn = account?.role == .admin
            cloud.follow(account?.id)
        }
    }
    /// Counts the route's changes, so a screen the route left stays in front of the screens that
    /// came after it while it fades out.
    private(set) var routeChanges = 0
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
    /// Why the last try to delete a store account stopped after this phone's copy was erased, or while
    /// it was, for the screen that finishes it. Nil when none did. Kept past the sign-out that ends
    /// the delete, so the finishing screen says it until it is gone.
    private(set) var deletionProblem: String?
    /// True while a store account's delete runs, from the server's check to its last step, so every
    /// screen shows it under way and a second one never begins.
    private(set) var isDeletingAccount = false
    /// True once a delete to finish has erased this phone's copy of the account. Kept past the
    /// sign-out that ends the delete, so the finishing screen says it until it is gone.
    private(set) var phoneCopyErased = false
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
    /// Moving the bank on this phone to QBank Cloud, and the screen that shows the move.
    let cloudMove = CloudMoveModel()
    /// Bringing the bank back from QBank Cloud once Cloud has ended, and the screen that shows it.
    let cloudReturn = CloudReturnModel()
    /// Taking the bank QBank Cloud already holds, and offering this phone's own sets to it.
    let cloudAdopt = CloudAdoptModel()
    /// Saved courses and unsent answers for the account on this phone. Nil when signed out.
    private(set) var offline: OfflineStore?

    private let storage: PhoneStorage
    /// The bank on this phone, while a free account is signed in and only then.
    var bank: LocalBank? { kind.bankIsOnPhone ? phoneBank?.bank : nil }
    /// The bank opened last, kept open while it is the one in use.
    private var phoneBank: OpenBank?
    /// Apple's id of the person whose bank is in QBank Cloud, while their store account is signed in:
    /// the key of their safety copy on this phone, which names what this phone keeps for them.
    private var cloudBankKey: String?
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

    /// Where a store account's bank is, as the record beside it says.
    private enum StoreBank {
        /// On this phone, open. `moveLeftOpen` when the app was closed during a move of it, whose lease
        /// the record still holds: the bank's writes are held until that move ends.
        case onPhone(LocalBank, moveLeftOpen: Bool)
        /// In QBank Cloud. The bank file on this phone is a safety copy, and it is not opened.
        case inCloud
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
        var inCloud: String?
        var moveLeftOpen = false
        var reason: String?
        var start = Route.signedOut
        if let stored, let account = stored.account {
            if stored.deletion != nil {
                // A delete that stopped part way: this phone's copy may be erased already, so nothing
                // opens it again, and finishing the delete or signing out is offered.
                start = .finishingDeletion(account)
            } else if account.origin == .store {
                // A store account's bank is named by Apple's id of the person: on this phone, or in
                // QBank Cloud. One that cannot open is not replaced by an empty one: signing in again
                // finds it.
                switch stored.appleUser.flatMap({ try? Self.storeBank($0, from: banks, sampleSet: sampleSet) }) {
                case .onPhone(let bank, let leftOpen)?:
                    opened = stored.appleUser.map { OpenBank(key: $0, bank: bank) }
                    moveLeftOpen = leftOpen
                    start = .signedIn(account)
                case .inCloud? where stored.awaitsServer:
                    // A bank in QBank Cloud needs the server, which has not confirmed this sign-in.
                    reason = AppleSignInWording.bankInCloudNeedsServer
                case .inCloud?:
                    inCloud = stored.appleUser
                    start = .signedIn(account)
                case nil:
                    reason = AppleSignInWording.bankDidNotOpen
                }
            } else {
                start = Self.route(for: account)
            }
        }
        phoneBank = opened
        cloudBankKey = inCloud
        kind = opened != nil || stored?.deletion != nil ? .free : inCloud != nil ? .store : .invited
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
        phoneCopyErased = stored?.deletion == .phoneErased
        route = start
        openOffline()
        drafts.open(accountID: phoneKey)
        frozen.isOn = account?.role == .admin
        cloud.app = self
        cloud.follow(account?.id)
        cloudMove.app = self
        cloudReturn.app = self
        cloudAdopt.app = self
        if moveLeftOpen { cloudMove.foundLeftOpen() }
        network.onChange = { [weak self] isOnline in
            self?.offline?.connectionChanged(isOnline: isOnline)
            guard isOnline, self?.awaitsServer == true else { return }
            Task { await self?.sendAppleSignInAgain() }
        }
    }

    var account: Account? {
        switch route {
        case .signedOut: nil
        case .choosingPassword(let account), .signedIn(let account), .finishingDeletion(let account): account
        }
    }

    /// True while a store account's delete is to be finished: this phone's copy is erased, or being
    /// erased, and the server has not deleted the account yet.
    var isFinishingDeletion: Bool {
        if case .finishingDeletion = route { true } else { false }
    }

    /// Who is signed in, as this phone keeps their things apart, such as the sets they are writing: for
    /// a bank on this phone its key, Apple's id of the person, which stays the same when the server
    /// confirms a sign-in it had not; for any other account its id.
    var phoneKey: String? {
        guard let account else { return nil }
        if kind.bankIsOnPhone, let phoneBank { return phoneBank.key }
        // The same person, after their bank moved to QBank Cloud: their key stays, and so do their drafts.
        if kind == .store, let cloudBankKey { return cloudBankKey }
        return account.id
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
        // phone's bank opens as it is. A delete to finish checks it itself.
        guard account != nil, !kind.bankIsOnPhone, !isFinishingDeletion else { return }
        do {
            let session = try await client.session()
            route = Self.route(for: session.user)
            if session.user.cloud?.active == false { cloudReturn.cloudEnded() }
        } catch {
            handle(error)
        }
    }

    /// Whether a screen over the app shows the bank moving between this phone and QBank Cloud.
    var cloudScreenIsShown: Bool {
        cloudMove.isShown || cloudReturn.isShown || cloudAdopt.isShown
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
        cloudBankKey = nil
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
        let cloudIsOn = signedIn.user.cloud?.active == true
        var moveLeftOpen = false
        var bankIsHere = false
        if signedIn.user.origin == .store {
            // A first launch on a second device: with Cloud on, QBank Cloud's bank is the one in use,
            // and no bank is made on this phone, sample set and all.
            if cloudIsOn, phoneBank?.key != appleUser, !banks.exists(appleUser), let record = try? banks.handover(appleUser) {
                try? BankAdoption.adoptWithNoBankHere(record: record)
            }
            switch try? storeBank(appleUser) {
            case .onPhone(let bank, let leftOpen)?:
                kind = .free
                cloudBankKey = nil
                client = server.routingBank(to: bank)
                connection = Connection.onThisPhone()
                moveLeftOpen = leftOpen
                bankIsHere = true
            case .inCloud?:
                // The person's bank moved to QBank Cloud: it is the server's, as an invited account's is.
                kind = .store
                cloudBankKey = appleUser
                client = server
                connection = network
            case nil:
                // The server's session is of no use without the bank: end it, and say why.
                try? await server.signOut()
                return .refused(AppleSignInWording.bankDidNotOpen, emailDoor: nil)
            }
        } else {
            kind = .invited
            cloudBankKey = nil
            client = server
            connection = network
        }
        awaitsServer = false
        needsAppleSignInAgain = false
        serverSignInProblem = nil
        temporaryPassword = nil
        if !isConfirming { beginSignIn() }
        route = Self.route(for: signedIn.user)
        if moveLeftOpen {
            cloudMove.foundLeftOpen()
            Task { await cloudMove.finishLeftOpen() }
        } else if kind == .store, signedIn.user.cloud?.active == false {
            cloudReturn.cloudEnded()
        } else if bankIsHere, cloudIsOn {
            // QBank Cloud may hold a bank for the person already, from another device.
            Task { await cloudAdopt.check() }
        }
        return .signedIn
    }

    /// Apple said yes and the server could not answer: the bank on this phone opens under Apple's id of
    /// the person, with the account as Apple described it, and the sign-in is kept to send again. The
    /// same person asking again while waiting keeps the screens as they are.
    private func awaitServer(_ request: AppleSignInRequest, credential: AppleCredential, problem: String) -> AppleSignInOutcome {
        let samePerson = awaitsServer && phoneKey == credential.user ? account : nil
        let account =
            samePerson ?? Account(id: credential.user, email: credential.email ?? "", name: "", role: .student, mustChangePassword: false, origin: .store)
        let bank: LocalBank
        let moveLeftOpen: Bool
        switch try? storeBank(credential.user) {
        case .onPhone(let opened, let leftOpen)?:
            bank = opened
            moveLeftOpen = leftOpen
        case .inCloud?:
            // The person's bank is in QBank Cloud, which this phone cannot reach yet; the safety copy
            // on this phone is never opened in its place.
            return .refused(AppleSignInWording.bankInCloudNeedsServer, emailDoor: nil)
        case nil:
            return .refused(AppleSignInWording.bankDidNotOpen, emailDoor: nil)
        }
        do {
            try server.keepAppleSignInForServer(request, account: account, appleUser: credential.user)
        } catch {
            return .refused(Wording.problem(error) ?? AppleSignInWording.appleDidNotFinish, emailDoor: nil)
        }
        kind = .free
        cloudBankKey = nil
        client = server.routingBankWithoutServer(to: bank)
        connection = Connection.onThisPhone()
        awaitsServer = true
        needsAppleSignInAgain = false
        serverSignInProblem = problem
        temporaryPassword = nil
        if samePerson == nil { beginSignIn() }
        route = .signedIn(account)
        if moveLeftOpen {
            cloudMove.foundLeftOpen()
            Task { await cloudMove.finishLeftOpen() }
        }
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

    /// Where the bank of `key` is. One on this phone is opened once and kept open while it is the one
    /// in use.
    private func storeBank(_ key: String) throws -> StoreBank {
        if let phoneBank, phoneBank.key == key { return .onPhone(phoneBank.bank, moveLeftOpen: phoneBank.bank.holdsWrites) }
        let place = try Self.storeBank(key, from: banks, sampleSet: sampleSet)
        if case .onPhone(let bank, _) = place {
            phoneBank = OpenBank(key: key, bank: bank)
        }
        return place
    }

    /// Where the bank of `key` is, as the record beside it says, without opening a bank that is in
    /// QBank Cloud. A bank on this phone opens from the file the record names. A first file that has
    /// never held anything is given the sample set; the sample is a nicety, and a bank that refuses it
    /// simply starts empty. A bank a move left open is not given it, nor anything else: its writes are
    /// held at once, until that move ends. A hand-back the app was closed during is let go of first:
    /// the fresh file it was writing never became the bank, and QBank Cloud's bank is still the one in use.
    private static func storeBank(_ key: String, from banks: PhoneBanks, sampleSet: String?) throws -> StoreBank {
        let record = try banks.handover(key)
        try BankHandBack.letGoLeftOpen(record: record) { file in banks.removeUnused(key, file: file) }
        let handover = try record.load()
        if handover.authority == .cloud { return .inCloud }
        let bank = try banks.open(key, file: handover.bankFile)
        if handover.lease != nil {
            bank.holdWrites()
            return .onPhone(bank, moveLeftOpen: true)
        }
        if let sampleSet, handover.bankFile == LocalStore.firstFile {
            _ = try? bank.fileSampleSet(sampleSet, inTopic: SampleSet.topic)
        }
        return .onPhone(bank, moveLeftOpen: false)
    }

    // MARK: Moving the bank to QBank Cloud

    /// The move of the bank on this phone to QBank Cloud, for a free account, with the bank's key; nil
    /// for any other, and while the account is being deleted, whose erase the move would undo by
    /// writing the bank's record again. The archive goes up the way the account's own requests go, so
    /// a phone whose Sign in with Apple the server has not confirmed yet sends nothing, and that move
    /// fails at once with nothing changed.
    func bankMove() -> (move: BankMoveToCloud, key: String)? {
        guard kind == .free, !isDeletingAccount, let phoneBank, let record = try? banks.handover(phoneBank.key) else { return nil }
        let client = self.client
        let move = BankMoveToCloud(bank: phoneBank.bank, record: record) { archive throws(QBankError) in
            try await client.uploadBank(archive)
        }
        return (move, phoneBank.key)
    }

    /// The bank on this phone as the person counts it, or nil when there is none or it cannot be read.
    func phoneBankSummary() -> BankSummary? {
        phoneBank.flatMap { try? BankSummary.of($0.bank) }
    }

    /// After a move whose counts matched recorded that the bank is QBank Cloud's: the account is on the
    /// server from now on, with saved copies and waiting answers as any account there has, and the
    /// bank file on this phone is left as it was, its writes held. The same person stays signed in, and
    /// keeps their key, so what this phone keeps for them, such as the sets they are writing, stays.
    /// Changes nothing when the bank of `key` is no longer the one open, as after a sign-out during
    /// the move: the record beside it already says where it is for the next sign-in.
    func bankMovedToCloud(_ key: String) {
        guard kind == .free, let phoneBank, phoneBank.key == key else { return }
        cloudBankKey = key
        self.phoneBank = nil
        kind = .store
        client = server
        connection = network
        openOffline()
    }

    // MARK: Taking QBank Cloud's bank

    /// The adoption of QBank Cloud's bank in place of the bank on this phone, for a free account, with
    /// the bank's key; nil for any other, and while the account is being deleted, as for a move. QBank
    /// Cloud's bank is downloaded the way the account's own requests go, so a phone whose Sign in with
    /// Apple the server has not confirmed reads nothing.
    func bankAdoption() -> (adoption: BankAdoption, key: String)? {
        guard kind == .free, !awaitsServer, !isDeletingAccount, let phoneBank, let record = try? banks.handover(phoneBank.key) else { return nil }
        let client = self.client
        let adoption = BankAdoption(bank: phoneBank.bank, record: record) { () throws(QBankError) in
            try await client.downloadBank()
        }
        return (adoption, phoneBank.key)
    }

    /// After the person chose QBank Cloud's bank and the record says so: the account is on the server
    /// from then on, as after a move, and the bank file on this phone is left as it was, its writes
    /// held, a safety copy.
    func bankAdopted(_ key: String) {
        bankMovedToCloud(key)
    }

    /// This phone's sets offered to QBank Cloud, from the safety copy of a bank in QBank Cloud, opened
    /// only to read, with the record that names them. Nil when there are none to offer, or for any
    /// account but a store account whose bank is in QBank Cloud.
    func phoneOffer() -> PhoneOffer? {
        guard kind == .store, let key = cloudBankKey, let record = try? banks.handover(key), let handover = try? record.load(),
            handover.authority == .cloud, handover.lease == nil, !handover.offeredSets.isEmpty,
            let store = try? banks.readOnly(key, file: handover.bankFile), let sets = try? BankOffer.sets(handover.offeredSets, in: store)
        else { return nil }
        return PhoneOffer(sets: sets, ids: handover.offeredSets, store: store, record: record)
    }

    // MARK: Bringing the bank back from QBank Cloud

    /// The hand-back of the bank in QBank Cloud to this phone, for a store account whose bank is there,
    /// with the bank's key; nil for any other, and while the account is being deleted, whose erase the
    /// hand-back would undo by writing a fresh file and the bank's record. The answers waiting to be
    /// sent are kept in the bank that comes back.
    func bankHandBack() -> (handBack: BankHandBack, key: String)? {
        guard kind == .store, !isDeletingAccount, let key = cloudBankKey, let record = try? banks.handover(key) else { return nil }
        let client = self.client
        let server = self.server
        let banks = self.banks
        let waiting = offline?.waiting ?? []
        let handBack = BankHandBack(
            record: record,
            download: { () throws(QBankError) in try await client.downloadBank() },
            createFile: { file in try banks.create(key, file: file) },
            removeFile: { file in banks.removeUnused(key, file: file) },
            keepWaitingAnswers: { store in try await HandBackAnswers.keep(waiting, in: store, through: server) })
        return (handBack, key)
    }

    /// After a hand-back recorded that the bank is this phone's again, in `store`: the account is free
    /// once more, its bank on this phone, which answers without a connection. The answers that waited
    /// are in the bank already; any that came while it came down are kept in it too, and only then is
    /// what the phone kept for the account on the server erased. The same person stays signed in and
    /// keeps their key. When they signed out meanwhile, the record already says where the bank is for
    /// the next sign-in.
    func bankReturnedToPhone(_ key: String, store: LocalStore) async {
        guard kind == .store, cloudBankKey == key, let account else { return }
        let bank = LocalBank(store: store)
        let kept = offline
        offline = nil
        phoneBank = OpenBank(key: key, bank: bank)
        cloudBankKey = nil
        kind = .free
        client = server.routingBank(to: bank)
        connection = Connection.onThisPhone()
        guard let kept else { return }
        await kept.close()
        if (try? await HandBackAnswers.keep(kept.waiting, in: store, through: server)) != nil {
            storage.erase(account.id)
        }
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

    // MARK: Deleting a store account

    /// Why deleting a store account stopped: the words to show, or nil when there is nothing more to
    /// say, such as when the person closed Apple's sheet or the screen gave way to sign-in. Whether
    /// this phone's copy is erased already is the route: `finishingDeletion` once it is.
    struct DeletionStop: Error, Equatable {
        let reason: String?
    }

    /// Deletes the store account signed in: checks QBank's server, asks Apple over `window` for a fresh
    /// Sign in with Apple, then deletes (`deleteAccount(confirmedWith:nonce:)`). Closing Apple's sheet
    /// says nothing and deletes nothing. A delete already under way is not begun again.
    func deleteAccountWithApple(over window: UIWindow?) async throws(DeletionStop) {
        guard !isDeletingAccount, account != nil else { return }
        isDeletingAccount = true
        deletionProblem = nil
        defer { isDeletingAccount = false }
        do throws(DeletionStop) {
            try await checkBeforeDeletingAccount()
            let nonce = AppleSignInNonce()
            let credential: AppleCredential
            do {
                credential = try await appleSignIn.signIn(hashedNonce: nonce.hashed, over: window)
            } catch {
                throw DeletionStop(reason: error == .canceled ? nil : AppleSignInWording.appleDidNotFinish)
            }
            try await deleteAccount(confirmedWith: credential, nonce: nonce)
        } catch {
            if isFinishingDeletion { deletionProblem = error.reason }
            throw error
        }
    }

    /// Checks, before Apple is asked, that QBank's server can take the delete: a Sign in with Apple it
    /// has not confirmed is sent again first, and the session must still be the server's. Nothing is
    /// erased here. A session the server ended signs the person out, as any ended session does; the
    /// delete then never began, or, when this phone's copy is erased already, ends here.
    func checkBeforeDeletingAccount() async throws(DeletionStop) {
        if awaitsServer {
            await sendAppleSignInAgain()
            guard !awaitsServer else {
                throw DeletionStop(reason: needsAppleSignInAgain ? AccountDeletionWording.needsAppleSignInAgain : AccountDeletionWording.awaitsServer)
            }
        }
        do {
            _ = try await server.session()
        } catch {
            guard error.needsSignIn else { throw DeletionStop(reason: Wording.problem(error) ?? AccountDeletionWording.tryAgain) }
            try await sessionEndedWhileDeleting()
        }
    }

    /// Deletes the store account signed in, free or Cloud, for good, once a fresh Sign in with Apple
    /// confirmed it, in this order: this phone's copy is erased, then the server deletes the account
    /// and revokes Apple's tokens, then the session is forgotten from the keychain. The person must be
    /// the one signed in, or nothing is erased.
    ///
    /// Each step done is kept with the session before the next begins, so a delete that stops is
    /// finished from where it stopped, even after a relaunch, and never deletes twice: the erase runs
    /// until it is done once, and the server deletes only the account this phone's session is
    /// signed in to, whose session goes with it. Once the erase began, a failure leaves
    /// `finishingDeletion`, where trying again finishes the delete and signing out leaves it.
    func deleteAccount(confirmedWith credential: AppleCredential, nonce: AppleSignInNonce) async throws(DeletionStop) {
        guard let account, !kind.deletesWithPassword, !awaitsServer, let kept = try? server.storedSession(), let appleUser = kept.appleUser
        else { throw DeletionStop(reason: AccountDeletionWording.tryAgain) }
        // Another Apple Account's yes deletes nothing: the server would refuse it after the erase.
        guard credential.user == appleUser else {
            throw DeletionStop(reason: kept.deletion == nil ? AccountDeletionWording.otherAppleAccount : AccountDeletionWording.appleDidNotConfirm)
        }
        guard let code = credential.authorizationCode, !code.isEmpty else { throw DeletionStop(reason: AppleSignInWording.appleDidNotFinish) }
        if kept.deletion == nil {
            // Kept before anything is erased, so from here on the delete is finished, never begun again.
            do {
                try server.recordAccountDeletion(.erasingPhone)
            } catch {
                throw DeletionStop(reason: AccountDeletionWording.notBegun)
            }
        }
        if kept.deletion != .phoneErased {
            try await erasePhoneCopy(of: account, appleUser: appleUser)
        }
        let request = AppleAccountDeletionRequest(identityToken: credential.identityToken, nonce: nonce.value, authorizationCode: code)
        do {
            try await server.deleteAccount(confirmedWithApple: request)
        } catch {
            guard error.needsSignIn else {
                let words = error.serverCode == "invalid_apple_token" ? AccountDeletionWording.appleDidNotConfirm : Wording.problem(error)
                throw DeletionStop(reason: words ?? AccountDeletionWording.tryAgain)
            }
            // The server has no session for this phone: an earlier try deleted the account and its
            // answer never came, or the session ended another way. Either way nothing more can be
            // deleted from here.
            try await sessionEndedWhileDeleting()
            return
        }
        // Signed out with nothing more to say, as a password account's delete ends.
        forgetDeletedAccount(reason: nil)
    }

    /// Erases what this phone keeps of the account: its bank and anything kept beside it, the saved
    /// courses and waiting answers of an account whose bank is on the server, and the sets it was
    /// writing. Nothing reaches the bank again: from here finishing the delete or signing out is on screen, and a
    /// failure leaves it still at the erase, so trying again erases again.
    private func erasePhoneCopy(of account: Account, appleUser: String) async throws(DeletionStop) {
        let saved = offline
        phoneBank?.bank.close()
        phoneBank = nil
        client = server
        connection = network
        phoneCopyErased = false
        route = .finishingDeletion(account)
        await saved?.close()
        do {
            try banks.erase(appleUser)
        } catch {
            throw DeletionStop(reason: AccountDeletionWording.phoneNotErased)
        }
        storage.erase(account.id)
        drafts.erase(accountID: appleUser)
        drafts.erase(accountID: account.id)
        phoneCopyErased = true
        // Not kept, the erase simply runs again next time, and erases nothing more.
        try? server.recordAccountDeletion(.phoneErased)
    }

    /// The server ended this phone's session while a delete was to be done. Before anything was
    /// erased, the person is signed out with their bank kept, as from any ended session, and told
    /// to sign in and delete again. After, this phone finishes erasing its copy and forgets the
    /// session: the account is deleted already, or the person can sign in and delete it again.
    private func sessionEndedWhileDeleting() async throws(DeletionStop) {
        guard let account, let kept = try? server.storedSession(), let step = kept.deletion, let appleUser = kept.appleUser else {
            try? server.sessionStore.clear()
            forgetSession(reason: AccountDeletionWording.sessionEndedBeforeErasing)
            throw DeletionStop(reason: nil)
        }
        if step != .phoneErased {
            try await erasePhoneCopy(of: account, appleUser: appleUser)
        }
        forgetDeletedAccount(reason: AccountDeletionWording.sessionEndedAfterErasing)
        throw DeletionStop(reason: nil)
    }

    /// The delete's last step: the session, and with it the record of the delete, leaves the
    /// keychain. One that will not leave is finished at the next launch, which finds the account gone.
    private func forgetDeletedAccount(reason: String?) {
        try? server.sessionStore.clear()
        forgetSession(reason: reason)
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
        // A store account whose bank is in QBank Cloud lost Cloud: the bank comes back to this phone.
        if error.serverCode == .cloudRequired, cloudReturn.cloudEnded() {
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
        cloudBankKey = nil
        client = server
        connection = network
        cloudMove.reset()
        cloudReturn.reset()
        cloudAdopt.reset()
        route = .signedOut
    }

    private static func route(for account: Account) -> Route {
        account.mustChangePassword ? .choosingPassword(account) : .signedIn(account)
    }

    /// Opens the phone's store for the account signed in, keeping it while the account stays. An
    /// ended session closes it but leaves its files, so waiting answers go once she signs in again.
    private func openOffline() {
        guard kind.savesForOffline, let account, !isFinishingDeletion else {
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
