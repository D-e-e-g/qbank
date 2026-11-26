import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// A bank on this phone to move to QBank Cloud, in a folder of its own as the app keeps one: a real
/// file with a row in every table, and its hand-over record beside it. Invented data only.
struct MoveWorld {
    static let key = "000111.movetest00000000000000000001.0001"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    let root: URL
    let store: LocalStore
    let record: BankHandoverRecord

    /// A bank holding `ArchiveWorld`'s rows, or an empty one.
    static func make(filled: Bool = true) async throws -> MoveWorld {
        let root = StoreFixtures.temporaryDirectory()
        let store = try LocalStore.open(key: key, in: root)
        if filled {
            let source = try await ArchiveWorld.make()
            try BankArchive.read(try BankArchive.write(from: source.store, at: ArchiveWorld.date), into: store)
        }
        return MoveWorld(root: root, store: store, record: try BankHandoverRecord.file(key: key, in: root))
    }

    /// The bank's file as it is on disk now.
    func bankBytes() throws -> Data {
        try Data(contentsOf: try #require(store.fileURL))
    }

    /// The same folder opened again, as the next launch opens it.
    func relaunched() throws -> MoveWorld {
        MoveWorld(root: root, store: try LocalStore.open(key: Self.key, in: root), record: try BankHandoverRecord.file(key: Self.key, in: root))
    }

    var folder: URL { root.appendingPathComponent("Banks").appendingPathComponent(Self.key) }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// The move of this bank, uploading through a client of `cloud`, with a clock that starts at
    /// `start` and moves a second at each read.
    func move(to cloud: CloudStandIn) -> BankMoveToCloud {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
        let ticks = Mutex(0)
        return BankMoveToCloud(
            store: store, record: record,
            clock: {
                ticks.withLock { tick in
                    defer { tick += 1 }
                    return Self.start.addingTimeInterval(TimeInterval(tick))
                }
            },
            upload: { archive throws(QBankError) in try await client.uploadBank(archive) })
    }

    /// A write through the bank's own routes: a new topic. Its status, 201 when the bank took it.
    func writeATopic() async throws -> Int {
        var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/topics")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"title":"Written during a move"}"#.utf8)
        return try await LocalBank(store: store).send(request).1.statusCode
    }
}

/// QBank Cloud for a move test: `PUT /api/me/bank` answered as the server answers it, storing the
/// archive into a fresh bank of its own whole or not at all and answering the counts it holds then,
/// or answered as the test says. It keeps every request.
final class CloudStandIn: HTTPTransport {
    enum Behavior: Sendable {
        /// Stores the archive and answers its counts, as the server does.
        case stores
        /// Stores the archive, then answers with this status and body in place of its counts.
        case storesThenAnswers(Int, @Sendable (BankCounts) -> String)
        /// Stores the archive, then loses the connection before the answer arrives.
        case storesThenFails(URLError.Code)
        /// Stores nothing and answers with this status and body.
        case answers(Int, String)
        /// Stores nothing; the request never gets an answer.
        case fails(URLError.Code)
        /// Waits for `finish(with:)`.
        case waits
    }

    private let behavior: Behavior
    private let seen = Mutex<[URLRequest]>([])
    private let stored = Mutex<LocalStore?>(nil)
    private let waiting = Mutex<CheckedContinuation<Behavior, Never>?>(nil)
    private let arrived = AsyncStream.makeStream(of: Void.self)

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var requests: [URLRequest] { seen.withLock { $0 } }

    /// The bank it holds once an upload was stored.
    var bank: LocalStore? { stored.withLock { $0 } }

    /// Waits until a request has arrived.
    func waitForRequest() async {
        for await _ in arrived.stream { return }
    }

    /// Answers the waiting request as `behavior` says.
    func finish(with behavior: Behavior) {
        waiting.withLock { continuation in
            continuation?.resume(returning: behavior)
            continuation = nil
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        let url = try #require(request.url)
        var behavior = self.behavior
        if case .waits = behavior {
            behavior = await withCheckedContinuation { continuation in
                waiting.withLock { $0 = continuation }
                arrived.continuation.yield()
            }
        }
        let (status, body) = try answer(behavior, to: request)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private func answer(_ behavior: Behavior, to request: URLRequest) throws -> (Int, String) {
        switch behavior {
        case .stores:
            return (200, #"{"counts":\#(try Self.text(store(request)))}"#)
        case .storesThenAnswers(let status, let body):
            return (status, body(try store(request)))
        case .storesThenFails(let code):
            _ = try store(request)
            throw URLError(code)
        case .answers(let status, let body):
            return (status, body)
        case .fails(let code):
            throw URLError(code)
        case .waits:
            return (500, "")
        }
    }

    private func store(_ request: URLRequest) throws -> BankCounts {
        let bank = try LocalStore.inMemory()
        let counts = try BankArchive.read(try #require(request.httpBody), into: bank)
        stored.withLock { $0 = bank }
        return counts
    }

    static func text(_ counts: BankCounts) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: counts.values, options: [.sortedKeys]), as: UTF8.self)
    }
}
