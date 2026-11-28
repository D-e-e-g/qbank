import Foundation
import QBankKit
import Testing
@testable import QBank

/// The Debug fake server's bank archive upload, `PUT /api/me/bank`, and its combine,
/// `POST /api/me/bank/combine`, called as raw requests: the upload needs Cloud, writes only into an
/// account with no bank, stores a whole archive or nothing, and then answers the account's bank
/// requests and the download from what it stored; the download and `GET /api/me/cloud` carry the
/// bank's stamp, and the combine stores only a bank built on that stamp that holds every row. The UI
/// tests of the move to QBank Cloud and of the combine stand on these answers. Invented data only.
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

    // MARK: The stamp and the combine

    @Test func cloudsStatusSaysTheStampOfTheBankAndWhetherCombiningIsPaused() async throws {
        let server = Self.applePerson()
        let calls = Calls(server)
        let none = try await calls.call("GET", "/api/me/cloud")
        #expect(none["bankStamp"] is NSNull, "the server holds no bank for the account")
        #expect(none["combinePaused"] as? Bool == false)

        try await CombinePhone.giveACloudBank(server, sets: [])
        let held = try #require(try await calls.call("GET", "/api/me/cloud")["bankStamp"] as? String)
        let download = try await calls.call("GET", "/api/me/bank")
        #expect(download["stamp"] as? String == held, "the download carries the stamp the status says")
        #expect(download["writtenBy"] as? String == "server")
        #expect(try await calls.call("GET", "/api/me/cloud")["bankStamp"] as? String == held, "reading the bank changes nothing")

        server.pauseCombining()
        #expect(try await calls.call("GET", "/api/me/cloud")["combinePaused"] as? Bool == true)
    }

    @Test func aCombineIsStoredOnlyOnTheStampOfTheBankItWasBuiltOnAndWithEveryRow() async throws {
        let server = Self.applePerson()
        server.giveApplePersonCloud()
        try await CombinePhone.giveACloudBank(server, sets: [DebugBanks.capitals])
        let calls = Calls(server)
        let download = try await calls.call("GET", "/api/me/bank").data
        let phone = try LocalStore.inMemory()
        try await DebugBanks.filled(LocalBank(store: phone), sample: CombinePhone.sample, with: [DebugBanks.rivers])
        let combined = try BankCombine.combine(phone: try BankArchive.write(from: phone, at: .now), server: download, at: .now)
        let before = try #require(try await calls.call("GET", "/api/me/cloud")["bankStamp"] as? String)

        server.refuseCombines(1)
        let overtaken = try await calls.call("POST", "/api/me/bank/combine", raw: combined.archive)
        #expect(overtaken.status == 409)
        #expect(overtaken.error == "bank_changed", "another device wrote to the bank just before")
        let stale = try await calls.call("POST", "/api/me/bank/combine", raw: combined.archive)
        #expect(stale.error == "bank_changed", "the bank no longer has the stamp the combine was built on")

        let again = try BankCombine.combine(
            phone: try BankArchive.write(from: phone, at: .now), server: try await calls.call("GET", "/api/me/bank").data, at: .now)
        let stored = try await calls.call("POST", "/api/me/bank/combine", raw: again.archive)
        #expect(stored.status == 200)
        #expect(stored["counts"] as? [String: Int] == again.counts.values)
        let after = try #require(stored["stamp"] as? String)
        #expect(after != before)
        #expect(try await calls.call("GET", "/api/me/cloud")["bankStamp"] as? String == after)
        #expect(Set(try await calls.catalog().topics.compactMap { $0["title"] as? String }) == [SampleSet.topic, DebugBanks.geography])

        // A bank that leaves out a row the server holds is refused.
        let partial = try LocalStore.inMemory()
        _ = try LocalBank(store: partial).fileSampleSet(try #require(SampleSet.bundledSource()), inTopic: SampleSet.topic)
        var document = try #require(try JSONSerialization.jsonObject(with: BankArchive.write(from: partial, at: .now)) as? [String: Any])
        document["stamp"] = after
        let missing = try await calls.call("POST", "/api/me/bank/combine", raw: try JSONSerialization.data(withJSONObject: document))
        #expect(missing.status == 409)
        #expect(missing.error == "bank_rows_missing")
    }

    @Test func aCombineNeedsAStoreAccountWithCloud() async throws {
        let invited = try await Calls().call("POST", "/api/me/bank/combine", raw: try Self.sampleArchive().archive)
        #expect(invited.status == 403)
        #expect(invited.error == "not_store_account")
        let lapsed = try await Calls(Self.applePerson()).call("POST", "/api/me/bank/combine", raw: try Self.sampleArchive().archive)
        #expect(lapsed.status == 403)
        #expect(lapsed.error == "cloud_required")
    }

    @Test func anInvitedAccountAlwaysHasABank() async throws {
        let answer = try await Calls().call("PUT", "/api/me/bank", raw: try Self.sampleArchive().archive)
        #expect(answer.status == 409)
        #expect(answer.error == "bank_not_empty")
        let catalog = try await Calls().catalog()
        #expect(!catalog.semesters.isEmpty, "the invited account's courses are as they were")
    }
}
