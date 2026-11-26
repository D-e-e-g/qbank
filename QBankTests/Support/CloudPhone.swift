import Foundation
import QBankKit
import Testing
@testable import QBank

/// The phone of a test of the bank moving between this phone and QBank Cloud: a free person's bank in
/// a folder of the test's own, opened as the app opens it, with its record beside it, and a session
/// kept from an earlier launch. A relaunch is a second model over the same folder and session.
/// Invented data only.
@MainActor
struct CloudPhone {
    static let cloudOn = StubServer.Reply.ok(#"{"active":true,"expiresAt":"2027-12-03T00:00:00.000Z","storeToken":"00000000-0000-4000-8000-000000000001"}"#)
    static let cloudOff = StubServer.Reply.ok(#"{"active":false,"expiresAt":"2027-01-03T00:00:00.000Z","storeToken":"00000000-0000-4000-8000-000000000001"}"#)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QBankCloudPhone-\(UUID().uuidString)", isDirectory: true)
    let defaults = TestApp.freshDefaults()
    let session = InMemorySessionStore(StoredSession(token: TestApp.token, account: .store(), appleUser: TestApp.appleUser))
    /// What the phone keeps for an account on the server: saved courses and waiting answers.
    let storage = PhoneStorage.memory()

    var banks: PhoneBanks { .files(root: root) }
    var folder: URL { root.appendingPathComponent("Banks/\(TestApp.appleUser)") }
    var file: URL { folder.appendingPathComponent("bank.sqlite") }
    var record: BankHandoverRecord { get throws { try banks.handover(TestApp.appleUser) } }

    func bytes() throws -> Data { try Data(contentsOf: file) }

    /// Every file in the bank's folder, by name, with its bytes.
    func files() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    /// The counts of the bank file `name`, read by a store of the test's own that writes nothing.
    func counts(of name: String = LocalStore.firstFile) throws -> BankCounts {
        let store = try LocalStore.readOnly(key: TestApp.appleUser, in: root, file: name)
        defer { store.close() }
        return try BankArchive.counts(of: store)
    }

    /// The bank file `name` as the person counts it, read by a store of the test's own that writes nothing.
    func summary(of name: String = LocalStore.firstFile) throws -> BankSummary {
        let store = try LocalStore.readOnly(key: TestApp.appleUser, in: root, file: name)
        defer { store.close() }
        return try BankSummary.of(store)
    }

    /// The bank file `name` as a bank archive, as QBank Cloud would send it.
    func archive(of name: String = LocalStore.firstFile) throws -> Data {
        let store = try LocalStore.readOnly(key: TestApp.appleUser, in: root, file: name)
        defer { store.close() }
        return try BankArchive.write(from: store, at: .now)
    }

    /// The answer QBank Cloud gives an upload of this bank, with `change` made to its counts.
    func stored(_ change: (inout [String: Int]) -> Void = { _ in }) throws -> StubServer.Reply {
        var values = try counts().values
        change(&values)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
        return .ok(#"{"counts":\#(text)}"#)
    }

    /// The app as it launches on this phone, its server `server` and its App Store `store`.
    func launch(
        _ server: StubServer, store: CloudTests.ScriptedStore = CloudTests.ScriptedStore(), apple: any AppleSignInProvider = AppleSignInTests.Apple()
    ) -> AppModel {
        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: session)
        return AppModel(
            client: client, banks: banks, sampleSet: SampleSet.bundledSource(), appleSignIn: apple, store: store,
            look: LookStore(defaults: defaults), lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)),
            highlighter: HighlighterStore(defaults: defaults), aiConsent: AIConsentStore(defaults: defaults), drafts: WriteDraftStore(defaults: defaults),
            storage: storage
        )
    }

    /// A free model on this phone whose server says Cloud is on, with the bank's sample set filed.
    func free(_ server: StubServer) async throws -> AppModel {
        server["GET /api/me/cloud"] = Self.cloudOn
        let app = launch(server)
        #expect(app.kind == .free)
        #expect(try await app.client.catalog().topics.map(\.title) == [SampleSet.topic], "the bank holds the sample set")
        await app.cloud.refresh()
        return app
    }

    /// A model whose bank moved to QBank Cloud: the free model, moved, then launched again. QBank Cloud
    /// holds what the bank held; this phone keeps it, the safety copy.
    func inCloud(_ server: StubServer) async throws -> AppModel {
        let free = try await free(server)
        server["PUT /api/me/bank"] = try stored()
        await free.cloudMove.start()
        #expect(free.kind == .store)
        free.cloudMove.close()
        let app = launch(server)
        #expect(app.kind == .store)
        return app
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A bank QBank Cloud holds, made as the app makes one: the sample set, when `sample`, then a topic
    /// for each of `topics`. As a bank archive, the way `GET /api/me/bank` sends it.
    static func cloudArchive(sample: Bool = true, topics: [String] = []) async throws -> Data {
        let store = try LocalStore.inMemory()
        let bank = LocalBank(store: store)
        if sample, let source = SampleSet.bundledSource() {
            _ = try bank.fileSampleSet(source, inTopic: SampleSet.topic)
        }
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: bank,
            sessionStore: InMemorySessionStore(StoredSession(token: TestApp.token)))
        for topic in topics {
            _ = try await client.createTopic(title: topic)
        }
        return try BankArchive.write(from: store, at: .now)
    }

    /// `data` as a stub's reply.
    static func reply(_ data: Data) -> StubServer.Reply {
        .ok(String(decoding: data, as: UTF8.self))
    }
}
