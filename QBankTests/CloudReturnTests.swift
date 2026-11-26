import Foundation
import QBankKit
import Testing
@testable import QBank

/// Bringing a store account's bank back from QBank Cloud once Cloud has ended, in the model
/// (`docs/cloud.md`, the hand-over's third row): what starts it, what the switch changes, and that
/// every other ending leaves QBank Cloud's bank the one in use with every file on this phone as it
/// was. The bank is a real file in a folder of the test's own, opened as the app opens it, and the
/// server a stub with the contract's shapes and words. Invented data only.
@MainActor
struct CloudReturnTests {
    private static let download = "GET /api/me/bank"
    private static let session = "GET /api/session"
    private static let cloudRequired = QBankError.server(ServerError(status: 403, code: .cloudRequired, message: "This needs Cloud. Your question bank is on this device."))

    /// A model whose bank is in QBank Cloud, whose server says Cloud has ended and sends `archive` as
    /// the bank, or the bank as it moved.
    private func ended(on phone: CloudPhone, _ server: StubServer, sending archive: Data? = nil) async throws -> AppModel {
        let app = try await phone.inCloud(server)
        server[Self.session] = .ok(Bodies.storeSession(cloud: false))
        server[Self.download] = CloudPhone.reply(try archive ?? phone.archive())
        return app
    }

    private func waitForOutcome(_ app: AppModel) async throws {
        try await waitUntil { app.cloudReturn.phase != .idle && !app.cloudReturn.isReturning }
    }

    // MARK: A hand-back that works

    @Test func aSessionThatSaysCloudEndedBringsTheWholeBankBackIntoAFreshFile() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let archive = try await CloudPhone.cloudArchive(topics: ["Added in QBank Cloud"])
        let app = try await ended(on: phone, server, sending: archive)
        let safetyCopy = try phone.bytes()
        let before = try phone.record.load()
        let sentStore = try LocalStore.inMemory()
        let sent = try BankArchive.read(archive, into: sentStore)
        let earlier = server.calls.count

        await app.refreshSession()

        #expect(app.cloudReturn.isShown, "the screen covers the app at once")
        try await waitForOutcome(app)
        #expect(app.cloudReturn.phase == .returned(try BankSummary.of(sentStore)))
        #expect(app.cloudReturn.phase == .returned(BankSummary(sets: 1, questions: 10, answers: 0)), "the sample set, counted as the person counts it")
        let record = try phone.record.load()
        #expect(record.authority == .phone)
        #expect(record.lease == nil)
        #expect(record.bankFile != LocalStore.firstFile)
        #expect(record.movedToCloudAt == before.movedToCloudAt)
        #expect(try phone.counts(of: record.bankFile) == sent, "the fresh file holds what QBank Cloud sent")
        #expect(try phone.bytes() == safetyCopy, "the safety copy is as it was")
        #expect(app.kind == .free)
        #expect(app.bank != nil)
        #expect(app.offline == nil, "the bank on this phone answers without a connection")
        #expect(try await app.client.catalog().topics.map(\.title).sorted() == ["Added in QBank Cloud", SampleSet.topic].sorted())
        let since = server.calls.dropFirst(earlier)
        #expect(since.filter { $0 == Self.download }.count == 1)
        #expect(!since.contains { $0.hasPrefix("DELETE") || $0.hasPrefix("PUT") || $0.hasPrefix("POST") }, "nothing is deleted or written in QBank Cloud")
        app.cloudReturn.close()
        #expect(!app.cloudReturn.isShown)
        #expect(!app.cloudReturn.isOffered)

        // The next launch opens the fresh file the record names.
        let relaunched = phone.launch(server)
        #expect(relaunched.kind == .free)
        #expect(try await relaunched.client.catalog().topics.map(\.title).contains("Added in QBank Cloud"))
        #expect(try phone.bytes() == safetyCopy)
    }

    @Test func aRequestRefusedForWantOfCloudBringsTheBankBack() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)

        #expect(app.handle(Self.cloudRequired), "the screen that ran into it has nothing more to say")

        #expect(app.cloudReturn.isShown)
        try await waitForOutcome(app)
        guard case .returned = app.cloudReturn.phase else {
            Issue.record("not returned: \(app.cloudReturn.phase)")
            return
        }
        #expect(app.kind == .free)
    }

    @Test func cloudsStateSaysWhetherTheBankComesBack() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)
        server[Self.session] = .ok(Bodies.storeSession(cloud: true))

        await app.refreshSession()
        #expect(!app.cloudReturn.isShown, "Cloud is on, so the bank stays in QBank Cloud")

        server["GET /api/me/cloud"] = CloudPhone.cloudOff
        await app.cloud.refresh()
        #expect(app.cloudReturn.isShown)
        try await waitForOutcome(app)
        #expect(app.kind == .free)
    }

    @Test func theAnswersThatWaitedForQBankCloudAreKeptInTheBankThatComesBack() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)
        let reader = try LocalStore.readOnly(key: TestApp.appleUser, in: phone.root, file: LocalStore.firstFile)
        let question = try #require(try reader.read { try $0.rows("SELECT id FROM question ORDER BY position LIMIT 1") }.first?.text("id"))
        let course = try #require(try reader.read { try $0.rows("SELECT course_id FROM practice_set LIMIT 1") }.first?.text("course_id"))
        reader.close()
        let moved = try phone.counts()
        server["POST /api/attempts"] = .error(403, "cloud_required", "This needs Cloud. Your question bank is on this device.")

        let waited = "a1000000-0000-4000-8000-000000000001"
        let delivery = try await app.submit(AttemptSubmission(clientAttemptID: waited, questionID: question, response: .single(choice: 0)), courseID: course)
        #expect(delivery == .waiting(reason: Self.cloudRequired), "an answer refused for want of Cloud waits, never dropped")
        #expect(app.offline?.waiting.map(\.id) == [waited])

        app.cloudReturn.cloudEnded()
        try await waitForOutcome(app)

        let record = try phone.record.load()
        #expect(record.authority == .phone)
        #expect(try phone.counts(of: record.bankFile)["attempts"] == (moved["attempts"] ?? 0) + 1, "the answer is in the bank on this phone")
        #expect(app.offline == nil)
        #expect(try phone.storage.open(Account.store().id).pending.load().isEmpty, "the answers kept for the server are gone, kept in the bank")
    }

    // MARK: A hand-back that does not

    /// Each download that does not arrive whole, with what the screen says.
    fileprivate nonisolated static let failures: [(name: String, says: String)] = [
        ("no connection", "No connection, so your bank could not be downloaded. Check Wi-Fi or cellular data and try again."),
        ("a server that fails", "QBank Cloud could not send your bank right now. Try again in a moment."),
        ("a download cut off", "Your bank did not arrive whole, so this iPhone did not use it."),
        ("counts that do not match the rows", "Your bank did not arrive whole, so this iPhone did not use it."),
    ]

    private static func reply(for name: String, archive: Data) throws -> StubServer.Reply {
        switch name {
        case "no connection": return .offline
        case "a server that fails": return .error(503, "unavailable", "QBank is busy.")
        case "a download cut off": return CloudPhone.reply(archive.prefix(archive.count / 2))
        default:
            var document = try #require(try JSONSerialization.jsonObject(with: archive) as? [String: Any])
            var counts = try #require(document["counts"] as? [String: Int])
            counts["questions", default: 0] += 1
            document["counts"] = counts
            return CloudPhone.reply(try JSONSerialization.data(withJSONObject: document))
        }
    }

    @Test(arguments: failures.map(\.name))
    func aDownloadThatDoesNotArriveWholeChangesNothing(_ name: String) async throws {
        let failure = try #require(Self.failures.first { $0.name == name })
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)
        server[Self.download] = try Self.reply(for: name, archive: phone.archive())
        let files = try phone.files()
        let before = try phone.record.load()

        app.cloudReturn.cloudEnded()
        try await waitForOutcome(app)

        #expect(app.cloudReturn.phase == .failed(failure.says, canRetry: true))
        #expect(app.kind == .store, "QBank Cloud's bank is still the one in use")
        #expect(try phone.record.load() == before, "the record is as it was, with no lease")
        #expect(try phone.files() == files, "every file is as it was, and no fresh file is left")
        #expect(!app.cloudReturn.isOffered, "not while the screen says why")

        // Put off, it waits for the person: Settings offers it, and nothing starts it on its own.
        app.cloudReturn.close()
        #expect(app.cloudReturn.isOffered)
        #expect(!app.handle(Self.cloudRequired))
        #expect(!app.cloudReturn.isShown)
        #expect(Wording.problem(Self.cloudRequired) == "QBank Cloud has ended, and your bank is still in it. Bring it back to this iPhone from Settings.")

        // Asked again in Settings, with the whole bank sent this time, it comes back.
        server[Self.download] = CloudPhone.reply(try phone.archive())
        await app.cloudReturn.start()
        guard case .returned = app.cloudReturn.phase else {
            Issue.record("not returned: \(app.cloudReturn.phase)")
            return
        }
        #expect(app.kind == .free)
        #expect(try phone.files()[LocalStore.firstFile] == files[LocalStore.firstFile])
    }

    @Test func aSessionThatEndedDuringTheDownloadSignsOutAndChangesNothing() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)
        server[Self.download] = .error(401, "unauthenticated", "Sign in to continue.")
        let files = try phone.files()
        let before = try phone.record.load()

        app.cloudReturn.cloudEnded()
        try await waitUntil { app.route == .signedOut }

        #expect(!app.cloudReturn.isShown)
        #expect(try phone.record.load() == before)
        #expect(try phone.files() == files)
    }

    @Test func cloudThatIsOnAgainKeepsTheBankInCloud() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await ended(on: phone, server)
        server[Self.download] = .offline
        app.cloudReturn.cloudEnded()
        try await waitForOutcome(app)
        app.cloudReturn.close()
        #expect(app.cloudReturn.isOffered)

        server["GET /api/me/cloud"] = CloudPhone.cloudOn
        await app.cloud.refresh()

        #expect(!app.cloudReturn.isOffered, "the bank stays in QBank Cloud, which is on again")
        #expect(!app.cloudReturn.isShown)
        #expect(app.kind == .store)
    }

    @Test func aFreeAccountHasNoBankToBringBack() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let app = try await phone.free(StubServer())
        #expect(!app.cloudReturn.cloudEnded())
        #expect(!app.handle(Self.cloudRequired))
        #expect(!app.cloudReturn.isShown)
        #expect(app.bankHandBack() == nil)
    }

    // MARK: The fresh file

    @Test func aHandBackTheAppWasClosedDuringIsLetGoOfAtLaunch() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        _ = try await phone.inCloud(server)
        let files = try phone.files()
        let before = try phone.record.load()
        // The app was closed while a fresh file had part of the bank in it.
        let left = "bank-20270115T080000000Z.sqlite"
        let half = try LocalStore.create(key: TestApp.appleUser, in: phone.root, file: left)
        try half.run("INSERT INTO semester (id, number, name, created_at) VALUES ('d1000000-0000-4000-8000-000000000009', 1, 'Semester 1', '2027-01-15T08:00:00.000Z')")
        half.close()
        try phone.record.save(before.leased(.init(direction: .toPhone, startedAt: .now, file: left)))

        let app = phone.launch(server)

        #expect(app.kind == .store, "QBank Cloud's bank is still the one in use")
        #expect(try phone.record.load() == before)
        #expect(try phone.files() == files, "the file that never became the bank is gone, and only it")
    }

    // MARK: Words

    @Test func theStepsAndEndingsSayWhatHappenedInPlainWords() {
        let steps: [BankHandBack.Step] = [.downloading, .writing, .checking]
        #expect(steps.map(CloudReturnWording.step) == ["Downloading your bank from QBank Cloud", "Writing it to this iPhone", "Checking that everything arrived"])
        #expect(CloudReturnWording.problem(.countsDiffer([.init(table: "attempts", onPhone: 1, inCloud: 2)])) == "This iPhone did not get the same number of answers as QBank Cloud holds, so it did not switch.")
        #expect(CloudReturnWording.problem(.switchNotRecorded(.closed)) == "Your whole bank arrived, but this iPhone could not note the switch, so it keeps using QBank Cloud's bank.")
        #expect(CloudReturnWording.notDownloaded(.transport(.networkConnectionLost)) == "The connection dropped before your whole bank arrived.")
        #expect(CloudReturnWording.notDownloaded(.server(ServerError(status: 404, code: "not_found", message: "No bank here."))) == "No bank here.")
        #expect(CloudReturnWording.canRetry(.notDownloaded(.transport(.timedOut))))
        #expect(CloudReturnWording.canRetry(.countsDiffer([])))
        #expect(!CloudReturnWording.canRetry(.alreadyOnPhone))
    }
}
