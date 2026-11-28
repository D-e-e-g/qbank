#if DEBUG
import Foundation
import QBankKit

/// The bank archive upload on the fake server, `PUT /api/me/bank`, with the real route's rules and
/// words: it needs Cloud, it writes only into an account that has no bank yet, and it stores the whole
/// archive or none of it, answering the counts it then holds. The bank it stores is a real `LocalBank`,
/// which answers the account's bank requests from then on, as the server's copy of a moved bank does,
/// and `GET /api/me/bank` downloads it again, with its stamp, as the server writes it. A store account
/// without Cloud is refused on the bank's routes with `cloud_required`, but may still download its
/// bank, so it can come back to the phone. An invited account always has a bank here: the fake's
/// courses. Compiled only into Debug builds.
nonisolated extension FakeQBankServer {
    static let notEmpty = "This account already has a question bank on the server, so the upload was refused. Nothing was changed."
    static let notABank = "This is not a bank archive QBank can store. Nothing was changed."
    static let cloudRequired = "This needs Cloud. Your question bank is on this device."

    /// `PUT /api/me/bank`: stores `archive` as the account's bank.
    func storeBank(_ archive: Data?, for account: Account) -> Reply {
        guard account.origin == "invited" || account.cloudUntil.map({ $0 > .now }) == true else {
            return failure(403, "cloud_required", Self.cloudRequired)
        }
        let holds = state.withLock { $0.cloudBanks[account.id] != nil || $0.bankHolders.contains(account.id) }
        guard account.origin == "store", !holds else { return failure(409, "bank_not_empty", Self.notEmpty) }
        let store: LocalStore
        let counts: BankCounts
        do {
            store = try LocalStore.inMemory()
            counts = try BankArchive.read(archive ?? Data(), into: store)
        } catch {
            return (400, ["error": "invalid_archive", "message": Self.notABank, "problems": [String(describing: error)]])
        }
        state.withLock { $0.cloudBanks[account.id] = FakeCloudBank(store: store) }
        return (200, ["counts": counts.values])
    }

    /// The account's Cloud bank answers `request` when it is one of the bank's requests, or the
    /// download of the whole bank, from an account whose bank moved to Cloud.
    func cloudBank(answering request: URLRequest) -> (any HTTPTransport)? {
        guard let path = request.url?.path(), let account = requester(of: request), let held = state.withLock({ $0.cloudBanks[account.id] }) else {
            return nil
        }
        if BankRoutedTransport.isBankPath(path) { return held.bank }
        guard request.httpMethod == "GET", path == "/api/me/bank" else { return nil }
        let (delay, drops) = state.withLock { state in
            defer { state.downloadsToDrop = max(0, state.downloadsToDrop - 1) }
            return (state.downloadDelay, state.downloadsToDrop > 0)
        }
        return Download(held: held, stamp: bankStamp(of: account), delay: delay, drops: drops)
    }

    /// Whether `request` is one of the bank's, from a store account without Cloud, which the server
    /// refuses with `cloud_required`. The download of the whole bank is not one of them.
    func refusesWithoutCloud(_ request: URLRequest) -> Bool {
        guard let path = request.url?.path(), BankRoutedTransport.isBankPath(path), let account = requester(of: request) else { return false }
        return account.origin == "store" && account.cloud["active"] as? Bool != true
    }

    /// The account whose session sent `request`.
    func requester(of request: URLRequest) -> Account? {
        guard let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") else { return nil }
        return account(for: token)
    }

    /// `reply` as the server sends it.
    func reply(_ reply: Reply, to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.data(withJSONObject: reply.1), response)
    }

    /// The store account `applePerson` has a bank in Cloud already, as if moved from another device:
    /// the sample set when `sample` is given, then `sets`. It answers the account's bank requests while
    /// the account has Cloud, and its download at any time.
    func giveApplePersonACloudBank(sample: String?, sets: [DebugBanks.Set]) {
        guard let store = try? LocalStore.inMemory() else { fatalError("The fake server's Cloud bank could not be made.") }
        DebugBanks.fill(LocalBank(store: store), sample: sample, with: sets)
        giveApplePersonACloudBank(store)
    }

    /// The store account `applePerson` has the bank in `store` in Cloud already, as a test made it.
    func giveApplePersonACloudBank(_ store: LocalStore) {
        state.withLock { $0.cloudBanks["fake-apple-person"] = FakeCloudBank(store: store) }
    }

    /// The store account `applePerson`'s Cloud ended yesterday, as when a subscription lapses.
    func endApplePersonCloud() {
        state.withLock { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == "fake-apple-person" }) else { return }
            state.accounts[index].storeToken = state.accounts[index].storeToken ?? UUID().uuidString.lowercased()
            state.accounts[index].cloudUntil = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: .now)
        }
    }

    /// Makes each download of a Cloud bank take `delay`, and the first `dropped` of them lose the
    /// connection then, before the bank arrives.
    func slowBankDownloads(by delay: Duration, dropping dropped: Int = 0) {
        state.withLock { state in
            state.downloadDelay = delay
            state.downloadsToDrop = dropped
        }
    }

    /// The store account `applePerson` already has a bank on the server: an upload into it is refused.
    func giveApplePersonABank() {
        state.withLock { _ = $0.bankHolders.insert("fake-apple-person") }
    }

    /// The store account `applePerson` has Cloud for a month from now, as if bought from this phone.
    func giveApplePersonCloud() {
        state.withLock { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == "fake-apple-person" }) else { return }
            state.accounts[index].storeToken = UUID().uuidString.lowercased()
            state.accounts[index].cloudUntil = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: .now)
        }
    }

    /// Makes the answer to an upload arrive `delay` after the server has it.
    func delayUploadReplies(by delay: Duration) {
        state.withLock { $0.uploadReplyDelay = delay }
    }

    /// The whole Cloud bank as one archive, as `GET /api/me/bank` answers it, after `delay`, or the
    /// connection lost then when it `drops`: written by the server, with the bank's stamp.
    private struct Download: HTTPTransport {
        let held: FakeCloudBank
        let stamp: String?
        let delay: Duration
        let drops: Bool

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if delay > .zero { try await Task.sleep(for: delay) }
            if drops { throw URLError(.networkConnectionLost) }
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
            else {
                throw URLError(.badServerResponse)
            }
            return (try held.archive(stamp: stamp), response)
        }
    }
}
#endif
