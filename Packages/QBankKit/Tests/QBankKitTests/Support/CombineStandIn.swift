import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// QBank Cloud for a combine up test: `GET /api/me/bank` answers the bank it holds with its stamp, and
/// `POST /api/me/bank/combine` stores a combined bank as the server does, only while its own bank still
/// has the stamp the combined one carries, answering the counts it then holds and a new stamp; or as the
/// test says. It keeps every request. Invented data only.
final class CombineStandIn: HTTPTransport {
    enum Combine: Sendable {
        /// Stores the combined bank when its stamp is the held bank's, as the server does.
        case stores
        /// Answers `bank_changed` this many times, each after another device changed the bank, then stores.
        case changesFirst(Int)
        /// Stores the combined bank, then answers counts with this change made to them.
        case storesThenMiscounts(table: String)
        /// Stores the combined bank, then runs `after` before it answers, as when the phone's folder
        /// stops taking writes.
        case storesThen(@Sendable () throws -> Void)
        /// Stores nothing and answers with this status and body.
        case answers(Int, String)
        /// Stores nothing; the request never gets an answer.
        case fails(URLError.Code)
    }

    private struct Held {
        var archive: Data
        var stamp: String
        var changesLeft: Int
        var stored: LocalStore?
    }

    private let download: DownloadStandIn.Behavior?
    private let combine: Combine
    private let held: Mutex<Held>
    private let seen = Mutex<[URLRequest]>([])

    /// QBank Cloud holding `archive`, whose stamp is `CombineWorld.stamp`. `download` answers the
    /// download in its place when given.
    init(holding archive: Data, download: DownloadStandIn.Behavior? = nil, combine: Combine = .stores) {
        self.download = download
        self.combine = combine
        var changes = 0
        if case .changesFirst(let count) = combine { changes = count }
        held = Mutex(Held(archive: archive, stamp: CombineWorld.stamp, changesLeft: changes))
    }

    var requests: [URLRequest] { seen.withLock { $0 } }
    var calls: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }

    /// The stamps the combined banks sent carried, in order.
    var sentStamps: [String?] {
        requests.filter { $0.httpMethod == "POST" }.map { request in
            (try? ArchiveWorld.parsed(request.httpBody ?? Data()))?["stamp"] as? String
        }
    }

    /// The bank QBank Cloud holds once a combined one was stored.
    var stored: LocalStore? { held.withLock { $0.stored } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        let url = try #require(request.url)
        let (status, body): (Int, Data)
        switch (request.httpMethod, url.path()) {
        case ("GET", "/api/me/bank"):
            if let download {
                switch download {
                case .sends(let data): (status, body) = (200, data)
                case .answers(let code, let text): (status, body) = (code, Data(text.utf8))
                case .fails(let code): throw URLError(code)
                }
            } else {
                (status, body) = (200, held.withLock { $0.archive })
            }
        case ("POST", "/api/me/bank/combine"):
            (status, body) = try answerCombine(try #require(request.httpBody))
        default:
            (status, body) = (404, Data(#"{"error":"not_found","message":"No such route."}"#.utf8))
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (body, response)
    }

    private func answerCombine(_ archive: Data) throws -> (Int, Data) {
        switch combine {
        case .answers(let status, let text):
            return (status, Data(text.utf8))
        case .fails(let code):
            throw URLError(code)
        case .stores, .changesFirst, .storesThenMiscounts, .storesThen:
            break
        }
        let sent = try ArchiveWorld.parsed(archive)["stamp"] as? String
        let changed = held.withLock { held -> Bool in
            if held.changesLeft > 0 {
                // Another device wrote to the bank meanwhile: it has a new stamp.
                held.changesLeft -= 1
                held.stamp += "+"
                held.archive = (try? Self.stamped(held.archive, held.stamp)) ?? held.archive
                return true
            }
            return sent != held.stamp
        }
        if changed {
            return (409, Data(#"{"error":"bank_changed","message":"Your bank in QBank Cloud changed while this one was combined. Nothing was changed."}"#.utf8))
        }
        let store = try LocalStore.inMemory()
        var counts = try BankArchive.read(archive, into: store).values
        held.withLock { $0.stored = store }
        switch combine {
        case .storesThenMiscounts(let table): counts[table, default: 0] += 1
        case .storesThen(let after): try after()
        default: break
        }
        let text = try CloudStandIn.text(try #require(BankCounts(counts)))
        return (200, Data(#"{"counts":\#(text),"stamp":"opaque/server=after"}"#.utf8))
    }

    /// `archive` with `stamp` in place of its own.
    static func stamped(_ archive: Data, _ stamp: String) throws -> Data {
        var document = try ArchiveWorld.parsed(archive)
        document["stamp"] = stamp
        return try ArchiveWorld.serialized(document)
    }
}

/// The steps a combine up reported, in order.
actor CombineUpSteps {
    private(set) var all: [BankCombineUp.Step] = []

    func add(_ step: BankCombineUp.Step) { all.append(step) }
}
