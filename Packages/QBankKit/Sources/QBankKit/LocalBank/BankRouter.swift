import Foundation

/// What a route handler works with: the request's parts, the open transaction of the bank, and the
/// two things a test must be able to set, the time and the ids.
struct BankCall {
    /// The path's `:name` parts.
    let params: [String: String]
    let query: [String: String]
    /// The JSON body, or nil when the request sent none.
    let body: JSONValue?
    let tx: StoreTransaction
    let now: Date
    private let ids: @Sendable () -> String

    init(params: [String: String], query: [String: String], body: JSONValue?, tx: StoreTransaction, now: Date, ids: @escaping @Sendable () -> String) {
        self.params = params
        self.query = query
        self.body = body
        self.tx = tx
        self.now = now
        self.ids = ids
    }

    /// The time as the API writes it.
    var nowText: String { QBankJSON.formatDate(now) }

    /// A new id: a lowercase UUID from the generator the bank was given.
    func newID() -> String { ids() }
}

/// One route of the bank: a method and a path pattern whose `:name` parts are parameters.
struct BankRoute: Sendable {
    typealias Handler = @Sendable (BankCall) throws -> BankAnswer

    enum Segment: Sendable, Equatable {
        case literal(String)
        case parameter(String)
    }

    let method: String
    let segments: [Segment]
    /// Whether the handler changes the bank, so it runs in a transaction that commits or undoes all of it.
    let writes: Bool
    let handler: Handler

    func match(_ method: String, _ parts: [String]) -> [String: String]? {
        guard method == self.method, parts.count == segments.count else { return nil }
        var params: [String: String] = [:]
        for (segment, part) in zip(segments, parts) {
            switch segment {
            case .literal(let text): if text != part { return nil }
            case .parameter(let name): params[name] = part
            }
        }
        return params
    }
}

/// The table every rule family registers its routes into. A family adds its routes once, when the
/// bank is made; the bank finds the one that matches a request's method and path.
struct BankRouter: Sendable {
    private(set) var routes: [BankRoute] = []

    mutating func get(_ pattern: String, _ handler: @escaping BankRoute.Handler) { add("GET", pattern, writes: false, handler) }
    mutating func post(_ pattern: String, _ handler: @escaping BankRoute.Handler) { add("POST", pattern, writes: true, handler) }
    mutating func put(_ pattern: String, _ handler: @escaping BankRoute.Handler) { add("PUT", pattern, writes: true, handler) }
    mutating func patch(_ pattern: String, _ handler: @escaping BankRoute.Handler) { add("PATCH", pattern, writes: true, handler) }
    mutating func delete(_ pattern: String, _ handler: @escaping BankRoute.Handler) { add("DELETE", pattern, writes: true, handler) }

    private mutating func add(_ method: String, _ pattern: String, writes: Bool, _ handler: @escaping BankRoute.Handler) {
        let segments = pattern.split(separator: "/").map { part -> BankRoute.Segment in
            part.hasPrefix(":") ? .parameter(String(part.dropFirst())) : .literal(String(part))
        }
        precondition(!routes.contains { $0.method == method && $0.segments == segments }, "\(method) \(pattern) is registered twice")
        routes.append(BankRoute(method: method, segments: segments, writes: writes, handler: handler))
    }

    /// The route that serves the request, with its path parameters, or nil.
    func find(_ method: String, path: String) -> (route: BankRoute, params: [String: String])? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for route in routes {
            if let params = route.match(method, parts) { return (route, params) }
        }
        return nil
    }
}
