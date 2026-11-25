import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transport of a bank on the phone: the bank's requests go to the bank on the phone and every
/// other request, the account's, goes where the account lives, which is the network.
///
/// The bank's paths are the ones `docs/on-phone-bank.md` lists: the semesters, courses, topics,
/// pages, folders, sets, imports, answers, exams and deleted courses, with everything under them,
/// and the place she left off. A bank path the bank does not serve yet is the bank's own 404, never
/// a request to the network, so a bank on the phone never sends a request that names her study.
public struct BankRoutedTransport: HTTPTransport {
    private let bank: any HTTPTransport
    private let account: any HTTPTransport

    public init(bank: any HTTPTransport, account: any HTTPTransport) {
        self.bank = bank
        self.account = account
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let path = request.url?.path, Self.isBankPath(path) {
            return try await bank.send(request)
        }
        return try await account.send(request)
    }

    /// The first segment after `/api` of every bank route.
    private static let bankResources: Set<String> = [
        "semesters", "courses", "topics", "topic-order", "course-exams", "folders", "practice-sets", "imports", "attempts", "exams",
        "deleted-courses",
    ]

    /// Whether the path belongs to the bank. `/api/me/place` does and no other `/api/me` path does.
    static func isBankPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "api" else { return false }
        if parts[1] == "me" { return parts.count == 3 && parts[2] == "place" }
        return bankResources.contains(String(parts[1]))
    }
}

/// The account's side of a bank on the phone while the server has not answered a Sign in with Apple:
/// there is no session on the server to send, so every request of the account fails here, before the
/// network, as one that could not reach QBank. It never answers, so it never signs anyone out.
struct NoServerSession: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.userAuthenticationRequired)
    }
}
