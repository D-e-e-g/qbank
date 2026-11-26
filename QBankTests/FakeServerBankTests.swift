import Foundation
import QBankKit
import Testing
@testable import QBank

/// The Debug fake server's bank archive upload, `PUT /api/me/bank`, called as raw requests: it needs
/// Cloud, writes only into an account with no bank, stores a whole archive or nothing, and then
/// answers the account's bank requests and the download from what it stored. The UI tests of the move
/// to QBank Cloud stand on these answers. Invented data only.
@MainActor
struct FakeServerBankTests {
    private typealias Calls = FakeServerRoutesTests.Calls

    /// The fake server signed in as the store account of Sign in with Apple.
    private static func applePerson() -> FakeQBankServer {
        FakeQBankServer(signedIn: true, as: FakeQBankServer.Credentials(email: FakeQBankServer.applePerson.email, password: ""))
    }

    /// A bank holding the app's sample set, as an archive, with its counts.
    private static func sampleArchive() throws -> (archive: Data, counts: BankCounts) {
        let store = try LocalStore.inMemory()
        let bank = LocalBank(store: store)
        _ = try bank.fileSampleSet(try #require(SampleSet.bundledSource()), inTopic: SampleSet.topic)
        return (try bank.exportArchive(), try BankArchive.counts(of: store))
    }

    @Test func anUploadNeedsCloud() async throws {
        let calls = Calls(Self.applePerson())
        let answer = try await calls.call("PUT", "/api/me/bank", raw: try Self.sampleArchive().archive)
        #expect(answer.status == 403)
        #expect(answer.error == "cloud_required")
        #expect(answer.message == "This needs Cloud. Your question bank is on this device.")
    }

    @Test func anAccountWithCloudStoresTheWholeBankAndAnswersFromIt() async throws {
        let server = Self.applePerson()
        server.giveApplePersonCloud()
        let calls = Calls(server)
        let (archive, counts) = try Self.sampleArchive()
        #expect(try await calls.catalog().topics.isEmpty, "the server holds no bank for the account yet")

        let stored = try await calls.call("PUT", "/api/me/bank", raw: archive)
        #expect(stored.status == 200)
        #expect(stored["counts"] as? [String: Int] == counts.values)
        #expect(try await calls.catalog().topics.compactMap { $0["title"] as? String } == [SampleSet.topic])
        let download = try await calls.call("GET", "/api/me/bank")
        #expect(download.status == 200)
        #expect(try BankArchive.read(download.data, into: try LocalStore.inMemory()) == counts)

        let again = try await calls.call("PUT", "/api/me/bank", raw: archive)
        #expect(again.status == 409)
        #expect(again.error == "bank_not_empty")
        #expect(again.message == "This account already has a question bank on the server, so the upload was refused. Nothing was changed.")
    }

    @Test func aFileThatIsNotABankArchiveIsRefusedAndStoresNothing() async throws {
        let server = Self.applePerson()
        server.giveApplePersonCloud()
        let calls = Calls(server)
        let refused = try await calls.call("PUT", "/api/me/bank", raw: Data(#"{"format":"something else"}"#.utf8))
        #expect(refused.status == 400)
        #expect(refused.error == "invalid_archive")
        #expect(try await calls.call("PUT", "/api/me/bank", raw: try Self.sampleArchive().archive).status == 200, "nothing was stored")
    }

    @Test func anAccountThatAlreadyHasABankIsRefused() async throws {
        let server = Self.applePerson()
        server.giveApplePersonCloud()
        server.giveApplePersonABank()
        let answer = try await Calls(server).call("PUT", "/api/me/bank", raw: try Self.sampleArchive().archive)
        #expect(answer.status == 409)
        #expect(answer.error == "bank_not_empty")
    }

    @Test func anInvitedAccountAlwaysHasABank() async throws {
        let answer = try await Calls().call("PUT", "/api/me/bank", raw: try Self.sampleArchive().archive)
        #expect(answer.status == 409)
        #expect(answer.error == "bank_not_empty")
        let catalog = try await Calls().catalog()
        #expect(!catalog.semesters.isEmpty, "the invited account's courses are as they were")
    }
}
