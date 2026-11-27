import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The question bank on the phone, answering the server's contract from the phone's store.
///
/// It is an `HTTPTransport`, so a `QBankClient` talks to it exactly as it talks to the server:
/// the same paths, the same JSON, the same status codes, refusal codes and sentences. Each rule
/// family (`CatalogRules`, `FolderRules`, and the families later slices add) registers its routes
/// into one `BankRouter`; a request no route serves is a 404 in the contract's error shape.
///
/// The bank does not check the bearer token: a file on the phone is already the signed-in
/// person's (`docs/on-phone-bank.md`). It reads the time from the clock it was given and takes
/// every id from the generator it was given, so a test sets both. A free account's model uses it, behind `BankRoutedTransport`.
/// While its store holds writes, for a move to QBank Cloud, every write is refused as `bank_moving`.
public final class LocalBank: HTTPTransport {
    /// Where the bank reads the time.
    public typealias Clock = @Sendable () -> Date
    /// Where the bank gets an id: a lowercase UUID, `8-4-4-4-12`.
    public typealias IDGenerator = @Sendable () -> String
    /// Where the bank gets a random whole number below its argument, for the order of questions a runner is given.
    public typealias Randomness = @Sendable (Int) -> Int

    let store: LocalStore
    private let clock: Clock
    private let ids: IDGenerator
    private let random: Randomness
    let router: BankRouter

    public init(
        store: LocalStore, clock: @escaping Clock = { Date() }, ids: @escaping IDGenerator = LocalBank.randomID,
        random: @escaping Randomness = { Int.random(in: 0..<$0) }
    ) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.random = random
        var router = BankRouter()
        CatalogRules.register(in: &router)
        PageRules.register(in: &router)
        FolderRules.register(in: &router)
        ImportRules.register(in: &router)
        SetRules.register(in: &router)
        AnswerRules.register(in: &router)
        ReviewRules.register(in: &router)
        PlaceRules.register(in: &router)
        SetDeleteRules.register(in: &router)
        PageDeleteRules.register(in: &router)
        CourseDeleteRules.register(in: &router)
        RecentlyDeletedRules.register(in: &router)
        ExamRoutes.register(in: &router)
        self.router = router
    }

    /// Closes the bank's file, so it can be erased. Every later request fails.
    public func close() {
        store.close()
    }

    /// The whole bank as bank archive v1, written at the bank's clock. It reads one snapshot and
    /// changes nothing, so exporting leaves the bank as it was.
    public func exportArchive() throws -> Data {
        try BankArchive.write(from: store, at: clock())
    }

    /// Refuses every write from now on, as `bank_moving`, while the bank moves to QBank Cloud; reads
    /// go on (`LocalStore.holdWrites()`). A move holds it itself; the app holds it at launch too, when
    /// it finds a move the app was closed during, so nothing changes the bank before that move ends.
    public func holdWrites() {
        store.holdWrites()
    }

    /// Whether the bank refuses writes because it is moving.
    public var holdsWrites: Bool { store.holdsWrites }

    /// A random lowercase UUID. Swift's `uuidString` is uppercase.
    public static let randomID: IDGenerator = { UUID().uuidString.lowercased() }

    /// Whether a route of the bank answers this method and path. A path no family serves is a 404.
    func serves(_ method: String, path: String) -> Bool { router.find(method, path: path) != nil }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let answer: BankAnswer
        do {
            answer = try respond(method: method, url: url, body: request.httpBody)
        } catch let refusal as BankRefusal {
            answer = BankAnswer(status: refusal.status, body: refusal.body)
        } catch StoreError.writesHeld {
            answer = BankAnswer(status: BankRefusal.moving.status, body: BankRefusal.moving.body)
        } catch {
            answer = BankAnswer(status: BankRefusal.failed.status, body: BankRefusal.failed.body)
        }
        let data = try answer.body.map { try JSONEncoder().encode($0) } ?? Data()
        guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    func respond(method: String, url: URL, body: Data?) throws -> BankAnswer {
        guard let (route, params) = router.find(method, path: url.path) else { throw BankRefusal.notServed(method, url.path) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let lists = Dictionary(grouping: items, by: \.name).mapValues { $0.map { $0.value ?? "" } }
        let json = body.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let clock = clock
        let ids = ids
        let random = random
        let handler = route.handler
        let run: (StoreTransaction) throws -> BankAnswer = { tx in
            let call = BankCall(params: params, query: query, queryLists: lists, body: json, tx: tx, now: clock(), ids: ids, random: random)
            if route.writes { return try BankWriteTime.withTime(call.nowText, in: tx) { try handler(call) } }
            return try handler(call)
        }
        // A write that is refused after it began leaves nothing behind: the transaction undoes it.
        return route.writes ? try store.transaction(run) : try store.read(run)
    }
}
