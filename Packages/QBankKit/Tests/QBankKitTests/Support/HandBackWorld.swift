import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// A store account's bank that moved to QBank Cloud, for a hand-back test: its folder on this phone,
/// with the safety copy (a real file holding `ArchiveWorld`'s rows) and the record saying QBank Cloud
/// holds the bank, and QBank Cloud's copy, which has gone on since with a topic the safety copy does
/// not have. Invented data only.
struct HandBackWorld {
    let root: URL
    let record: BankHandoverRecord
    /// The record as the move to QBank Cloud left it.
    let before: BankHandover
    /// QBank Cloud's bank, as `GET /api/me/bank` answers it.
    let cloudArchive: Data
    /// Every row of QBank Cloud's bank.
    let cloudRows: [String: [[StoreValue]]]
    let cloudCounts: BankCounts

    static let key = MoveWorld.key
    static let start = MoveWorld.start

    static func make() async throws -> HandBackWorld {
        let moved = try await MoveWorld.make()
        let harness = try await ArchiveWorld.make()
        #expect(try await harness.send("POST", "/api/topics", .object(["title": .string("Added in QBank Cloud")])).status == 201)
        let cloudArchive = try BankArchive.write(from: harness.store, at: ArchiveWorld.date)
        let before = BankHandover.onPhone.inCloud(since: start)
        try moved.record.save(before)
        // In Cloud mode the safety copy is not open.
        moved.store.close()
        return HandBackWorld(
            root: moved.root, record: moved.record, before: before, cloudArchive: cloudArchive, cloudRows: try ArchiveWorld.dump(harness.store),
            cloudCounts: try BankArchive.counts(of: harness.store))
    }

    var folder: URL { root.appendingPathComponent("Banks").appendingPathComponent(Self.key) }

    /// Every file in the bank's folder, by name, with its bytes.
    func files() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// The hand-back of this bank, downloading through a client of `cloud`, with a clock that starts at
    /// `start` and moves a second at each read, or stays at `start` when `fixedClock`.
    func handBack(
        from cloud: DownloadStandIn, fixedClock: Bool = false, keepWaitingAnswers: @escaping @Sendable (LocalStore) async throws -> Void = { _ in }
    ) -> BankHandBack {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
        let ticks = Mutex(0)
        let root = self.root
        return BankHandBack(
            record: record,
            clock: {
                guard !fixedClock else { return Self.start }
                return ticks.withLock { tick in
                    defer { tick += 1 }
                    return Self.start.addingTimeInterval(TimeInterval(tick))
                }
            },
            download: { () throws(QBankError) in try await client.downloadBank() },
            createFile: { file in try LocalStore.create(key: Self.key, in: root, file: file) },
            removeFile: { file in try? LocalStore.removeUnused(key: Self.key, in: root, file: file) },
            keepWaitingAnswers: keepWaitingAnswers)
    }
}

/// QBank Cloud for a hand-back test: `GET /api/me/bank` answered with a bank archive, or as the test
/// says. It keeps every request.
final class DownloadStandIn: HTTPTransport {
    enum Behavior: Sendable {
        /// Answers 200 with this body.
        case sends(Data)
        /// Answers with this status and body.
        case answers(Int, String)
        /// The request never gets an answer, or loses it on the way.
        case fails(URLError.Code)
    }

    private let behavior: Behavior
    private let seen = Mutex<[URLRequest]>([])

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var requests: [URLRequest] { seen.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        let url = try #require(request.url)
        let (status, body): (Int, Data)
        switch behavior {
        case .sends(let data): (status, body) = (200, data)
        case .answers(let code, let text): (status, body) = (code, Data(text.utf8))
        case .fails(let code): throw URLError(code)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (body, response)
    }
}

/// The steps a hand-back reported, in order.
actor HandBackSteps {
    private(set) var all: [BankHandBack.Step] = []

    func add(_ step: BankHandBack.Step) { all.append(step) }
}

/// A value a test shares with a closure the code under test may call from any task.
final class Box<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>

    init(_ value: Value) { stored = Mutex(value) }

    var value: Value { stored.withLock { $0 } }

    func set(_ value: Value) { stored.withLock { $0 = value } }
}
