import Foundation
import QBankKit
import Testing
@testable import QBank

/// The phone of a test of a combine: the fake server's store account's bank in a folder of the test's
/// own, opened as the app opens it, with its record beside it, and the Debug fake server, whose
/// download carries a stamp and whose combine route keeps the real one's rules. A relaunch is a second
/// model over the same folder. Invented data only.
@MainActor
struct CombinePhone {
    static let key = FakeQBankServer.applePerson.user

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QBankCombinePhone-\(UUID().uuidString)", isDirectory: true)
    let defaults = TestApp.freshDefaults()
    /// The session the phone keeps, from an earlier launch until a launch at the first screen clears
    /// it, and the one a Sign in with Apple then keeps, which a relaunch finds.
    let session = InMemorySessionStore(FakeQBankServer.storedApplePersonSession())

    var banks: PhoneBanks { .files(root: root) }
    var folder: URL { root.appendingPathComponent("Banks/\(Self.key)") }
    var record: BankHandoverRecord { get throws { try banks.handover(Self.key) } }
    var receipts: [BankCombineReceipt] { get throws { try BankCombineReceipts(beside: try record).all() } }

    /// The bank file `name` as it is on disk now.
    func bytes(of name: String = LocalStore.firstFile) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// The names of the files in the bank's folder, in order.
    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A bank on this phone for the person, in its first file: the sample set, then `sets`.
    func fill(_ sets: [DebugBanks.Set]) async throws {
        try await DebugBanks.filled(try banks.open(Self.key), sample: Self.sample, with: sets)
    }

    /// The fake server, signed in as the store account of Sign in with Apple when `signedIn`.
    static func server(signedIn: Bool) -> FakeQBankServer {
        signedIn
            ? FakeQBankServer(signedIn: true, as: FakeQBankServer.Credentials(email: FakeQBankServer.applePerson.email, password: ""))
            : FakeQBankServer(signedIn: false)
    }

    /// QBank holds the person's bank, with the sample set and the invented capitals, and their Cloud
    /// is on when `cloud`, or ended yesterday.
    static func holdsABank(_ server: FakeQBankServer, cloud: Bool) async throws {
        try await giveACloudBank(server, sets: [DebugBanks.capitals])
        if cloud {
            server.giveApplePersonCloud()
        } else {
            server.endApplePersonCloud()
        }
    }

    /// QBank holds the person's bank, with the sample set and `sets`.
    static func giveACloudBank(_ server: FakeQBankServer, sets: [DebugBanks.Set]) async throws {
        let store = try LocalStore.inMemory()
        try await DebugBanks.filled(LocalBank(store: store), sample: sample, with: sets)
        server.giveApplePersonACloudBank(store)
    }

    static var sample: String {
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        return sample
    }

    /// The app as it launches on this phone over `server`: with the session the phone keeps, or at the
    /// first screen when not `signedIn`, where Sign in with Apple is the returning person's.
    func launch(_ server: FakeQBankServer, signedIn: Bool = true) -> AppModel {
        if !signedIn { try? session.clear() }
        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!), transport: server, sessionStore: session)
        return AppModel(
            client: client, banks: banks, sampleSet: Self.sample, appleSignIn: DebugScriptedAppleSignIn(script: .returningPerson),
            store: CloudTests.ScriptedStore(), look: LookStore(defaults: defaults), lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)),
            highlighter: HighlighterStore(defaults: defaults), aiConsent: AIConsentStore(defaults: defaults), drafts: WriteDraftStore(defaults: defaults),
            storage: .memory()
        )
    }

    /// Signs the returning person in with Apple, then waits for the combine that follows to end.
    func signIn(_ app: AppModel) async throws {
        await AppleSignInModel(app: app).signIn(over: nil)
        try await Self.waitForOutcome(app)
    }

    /// Waits until the combine on screen has an outcome.
    static func waitForOutcome(_ app: AppModel) async throws {
        try await waitUntil(timeout: .seconds(20)) {
            switch app.cloudCombine.phase {
            case .combined, .failed: true
            case .idle, .combining: false
            }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
