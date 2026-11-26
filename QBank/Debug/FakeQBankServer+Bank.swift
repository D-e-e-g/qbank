#if DEBUG
import Foundation
import QBankKit

/// The bank archive upload on the fake server, `PUT /api/me/bank`, with the real route's rules and
/// words: it needs Cloud, it writes only into an account that has no bank yet, and it stores the whole
/// archive or none of it, answering the counts it then holds. The bank it stores is a real `LocalBank`,
/// which answers the account's bank requests from then on, as the server's copy of a moved bank does,
/// and `GET /api/me/bank` downloads it again. An invited account always has a bank here: the fake's
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
        state.withLock { $0.cloudBanks[account.id] = LocalBank(store: store) }
        return (200, ["counts": counts.values])
    }

    /// The account's Cloud bank answers `request` when it is one of the bank's requests, or the
    /// download of the whole bank, from an account whose bank moved to Cloud.
    func cloudBank(answering request: URLRequest) -> (any HTTPTransport)? {
        guard let path = request.url?.path(),
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: ""),
            let account = account(for: token),
            let bank = state.withLock({ $0.cloudBanks[account.id] })
        else { return nil }
        if BankRoutedTransport.isBankPath(path) { return bank }
        if request.httpMethod == "GET", path == "/api/me/bank" { return Download(bank: bank) }
        return nil
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

    /// The whole Cloud bank as one archive, as `GET /api/me/bank` answers it.
    private struct Download: HTTPTransport {
        let bank: LocalBank

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
            else {
                throw URLError(.badServerResponse)
            }
            return (try bank.exportArchive(), response)
        }
    }
}
#endif
