import Foundation
import QBankKit
import Testing
@testable import QBank

/// Moving a free account's bank to QBank Cloud in the model (`docs/cloud.md`, the hand-over): when it
/// starts, what the switch changes, and that every other ending leaves the bank on this phone the
/// authority with its file byte for byte as it was. The bank is a real file in a folder of the test's
/// own, opened as the app opens it, and the server a stub with the contract's shapes and words. A
/// relaunch is a second model over the same folder and session. Invented data only.
@MainActor
struct CloudMoveTests {
    nonisolated private static let upload = "PUT /api/me/bank"
    private static let on = CloudPhone.cloudOn

    /// A free model on `phone` whose server says Cloud is on, with the bank's sample set filed.
    private func free(on phone: Phone, _ server: StubServer) async throws -> AppModel {
        try await phone.free(server)
    }

    // MARK: Starting

    @Test func aPurchaseThatTurnsCloudOnMovesTheBankOnceThePlansSheetHasClosed() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer(["GET /api/me/cloud": .ok(#"{"active":false,"expiresAt":null,"storeToken":"00000000-0000-4000-8000-000000000001"}"#), "POST /api/me/cloud/transactions": Self.on])
        let app = phone.launch(server)
        server[Self.upload] = try phone.stored()

        app.cloudMove.plansOpened()
        await app.cloud.buy(DebugFakeStore.plans[0], in: nil)

        #expect(app.cloudMove.isDue, "the move waits for the plans sheet to close")
        #expect(!app.cloudMove.isShown)
        #expect(!server.calls.contains(Self.upload))
        await app.cloudMove.plansClosed()
        #expect(app.cloudMove.phase == .moved(try phone.summary()))
        #expect(app.kind == .store)
    }

    @Test func aPurchaseConfirmedAfterThePlansSheetClosedMovesTheBankAtOnce() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer(["GET /api/me/cloud": .ok(#"{"active":false,"expiresAt":null,"storeToken":"00000000-0000-4000-8000-000000000001"}"#), "POST /api/me/cloud/transactions": Self.on])
        let app = phone.launch(server)
        server[Self.upload] = try phone.stored()
        server.hold("POST /api/me/cloud/transactions")
        app.cloudMove.plansOpened()
        let buying = Task { await app.cloud.buy(DebugFakeStore.plans[0], in: nil) }
        try await waitUntil { server.calls.contains("POST /api/me/cloud/transactions") }

        // The person closes the sheet while the purchase is on its way to the server.
        await app.cloudMove.plansClosed()
        server.release("POST /api/me/cloud/transactions")
        await buying.value

        let summary = try phone.summary()
        try await waitUntil { app.cloudMove.phase == .moved(summary) }
        #expect(!app.cloudMove.isDue)
        #expect(app.kind == .store)
    }

    @Test func cloudThatIsOnOffersTheMoveAndOnlyWhileTheBankIsOnThisPhone() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        #expect(app.cloudMove.isOffered)
        server[Self.upload] = try phone.stored()
        await app.cloudMove.start()
        app.cloudMove.close()
        #expect(!app.cloudMove.isOffered, "the bank is in QBank Cloud now")
    }

    // MARK: The switch

    @Test func aMoveWhoseCountsMatchPutsTheAccountOnTheServerAndKeepsTheFileAsItWas() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        let before = try phone.bytes()
        let counts = try phone.counts()
        server[Self.upload] = try phone.stored()
        server["GET /api/semesters"] = .ok(Bodies.semesters([], topics: [Bodies.topic(id: "t1", title: SampleSet.topic)]))

        await app.cloudMove.start()

        #expect(app.cloudMove.phase == .moved(try phone.summary()))
        #expect(app.cloudMove.isShown, "the outcome waits to be read")
        #expect(app.kind == .store)
        #expect(app.bank == nil)
        #expect(app.offline != nil, "the account keeps saved copies and waiting answers, as any account on the server")
        #expect(app.phoneKey == TestApp.appleUser, "the same person keeps what this phone keeps for them")
        #expect(app.route == .signedIn(.store()))
        let archive = try #require(server.requests.first { $0.url?.path() == "/api/me/bank" }?.httpBody)
        let fresh = try LocalStore.inMemory()
        #expect(try BankArchive.read(archive, into: fresh) == counts, "the whole bank went up")
        #expect(try await app.client.catalog().topics.map(\.id) == ["t1"])
        #expect(server.calls.last == "GET /api/semesters", "the bank's requests go to the server")
        #expect(try phone.record.load().authority == .cloud)
        #expect(try phone.record.load().lease == nil)
        #expect(try phone.bytes() == before, "the safety copy is byte for byte the bank before the move")

        app.cloudMove.close()
        #expect(!app.cloudMove.isShown)
    }

    @Test func theNextLaunchOpensABankInCloudOnTheServerAndNeverOpensTheSafetyCopy() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        server[Self.upload] = try phone.stored()
        await app.cloudMove.start()
        let before = try phone.bytes()
        let changed = try FileManager.default.attributesOfItem(atPath: phone.file.path)[.modificationDate] as? Date

        server["GET /api/semesters"] = .ok(Bodies.semesters([], topics: [Bodies.topic(id: "t1", title: SampleSet.topic)]))
        let relaunched = phone.launch(server)

        #expect(relaunched.kind == .store)
        #expect(relaunched.route == .signedIn(.store()))
        #expect(!relaunched.cloudMove.isShown)
        #expect(try await relaunched.client.catalog().topics.map(\.id) == ["t1"])
        #expect(try phone.bytes() == before)
        #expect(try FileManager.default.attributesOfItem(atPath: phone.file.path)[.modificationDate] as? Date == changed)
    }

    @Test func aBankInCloudThatWasNeverOnThisPhoneMakesNoFileHere() throws {
        let phone = Phone()
        defer { phone.remove() }
        try phone.record.save(BankHandover(authority: .cloud, movedToCloudAt: .now))
        let app = phone.launch(StubServer())
        #expect(app.kind == .store)
        #expect(!FileManager.default.fileExists(atPath: phone.file.path))
    }

    // MARK: Every other ending

    /// Each upload that does not end in a confirmed, matching copy in QBank Cloud, with what the move's
    /// screen says, and whether it offers to try again. An account that already has a bank in QBank
    /// Cloud combines with it instead (`CloudCombineTests`). What it says is read on the main
    /// actor, since a sentence that names the device says "iPhone" or "iPad" as the device the tests
    /// run on does.
    fileprivate nonisolated static let failures: [(name: String, reply: Reply?, says: @MainActor @Sendable () -> String, canRetry: Bool)] = [
        ("no connection", .offline, { "No connection, so your bank was not sent. Check Wi-Fi or cellular data and try again." }, true),
        ("no Cloud", .error(403, "cloud_required", "This needs Cloud. Your question bank is on this device."), { "This needs Cloud. Your question bank is on this device." }, false),
        ("a server that fails", .error(503, "unavailable", "QBank is busy."), { "QBank Cloud could not take your bank right now. Try again in a moment." }, true),
        ("an answer that cannot be read", .ok("<html>proxy</html>"), { "QBank Cloud's answer could not be read, so it has not confirmed it holds your whole bank." }, true),
        (
            "counts that differ", nil,
            { "QBank Cloud does not hold the same number of answers as this \(Device.model), so QBank keeps using the bank on this \(Device.model)." }, false
        ),
    ]

    @Test(arguments: failures.map(\.name))
    func anUploadWithoutAMatchingCopyLeavesTheBankOnThisPhoneUnchanged(_ name: String) async throws {
        let failure = try #require(Self.failures.first { $0.name == name })
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        let before = try phone.bytes()
        server[Self.upload] = try failure.reply ?? phone.stored { $0["attempts", default: 0] += 1 }

        await app.cloudMove.start()

        #expect(app.cloudMove.phase == .failed(failure.says(), canRetry: failure.canRetry))
        #expect(app.cloudMove.isShown)
        #expect(app.kind == .free)
        #expect(app.bank != nil)
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.bytes() == before, "the bank file is byte for byte as it was")
        let made = try await app.client.createTopic(title: "Invented Botany")
        #expect(try await app.client.catalog().topics.map(\.id).contains(made.id), "the bank on this phone takes writes again")
        #expect(app.cloudMove.isOffered, "the person can try again")
        app.cloudMove.close()
        #expect(!app.cloudMove.isShown)
    }

    @Test func aSessionThatEndedDuringTheMoveSignsOutAndLeavesTheBankAsItWas() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        let before = try phone.bytes()
        server[Self.upload] = .error(401, "unauthenticated", "Sign in to continue.")

        await app.cloudMove.start()

        #expect(app.route == .signedOut)
        #expect(!app.cloudMove.isShown)
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.bytes() == before)
    }

    // MARK: The lease

    @Test func whileTheBankMovesItTakesNoWritesAndTheLeaseIsWhatANewLaunchFinds() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await free(on: phone, server)
        let before = try phone.bytes()
        server[Self.upload] = .offline
        server.hold(Self.upload)
        let moving = Task { await app.cloudMove.start() }
        try await waitUntil { server.calls.contains(Self.upload) }

        #expect(app.cloudMove.phase == .moving(.sending))
        await #expect(throws: QBankError.server(ServerError(status: 409, code: "bank_moving", message: "Your bank is moving to QBank Cloud, so it cannot change until the move ends. Nothing was changed."))) {
            _ = try await app.client.createTopic(title: "Written during the move")
        }
        #expect(try await app.client.catalog().topics.count == 1, "reads go on")
        let found = try phone.record.load()
        #expect(found.authority == .phone)
        #expect(found.lease?.direction == .toCloud)

        // The app is closed and opened again while the upload is out.
        let relaunched = phone.launch(server)
        #expect(relaunched.kind == .free)
        #expect(relaunched.cloudMove.isShown, "the move's screen comes first")
        #expect(relaunched.cloudMove.phase == .moving(.writing))
        await #expect(throws: QBankError.self) {
            _ = try await relaunched.client.createTopic(title: "Written before the move is finished")
        }

        server.release(Self.upload)
        await moving.value
        #expect(try phone.bytes() == before)
    }

    @Test func aMoveTheAppWasClosedDuringIsFinishedAtLaunchBeforeAnythingElse() async throws {
        let phone = Phone()
        defer { phone.remove() }
        _ = try await free(on: phone, StubServer())
        let before = try phone.bytes()
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        let server = StubServer([Self.upload: try phone.stored()])

        let app = phone.launch(server)

        #expect(app.cloudMove.isShown)
        #expect(app.cloudMove.isResumed)
        #expect(try await app.client.catalog().topics.map(\.title) == [SampleSet.topic], "the sample set is not filed again, nor anything else")
        await app.cloudMove.finishLeftOpen()
        #expect(app.cloudMove.phase == .moved(try phone.summary()))
        #expect(app.kind == .store)
        #expect(try phone.record.load().lease == nil)
        #expect(try phone.bytes() == before)
    }

    @Test func aMoveTheAppWasClosedDuringThatFailsAtLaunchGivesTheLeaseBack() async throws {
        let phone = Phone()
        defer { phone.remove() }
        _ = try await free(on: phone, StubServer())
        let before = try phone.bytes()
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        let app = phone.launch(StubServer([Self.upload: .offline]))

        await app.cloudMove.finishLeftOpen()

        #expect(app.cloudMove.phase == .failed("No connection, so your bank was not sent. Check Wi-Fi or cellular data and try again.", canRetry: true))
        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.bytes() == before)
        _ = try await app.client.createTopic(title: "Invented Botany")
    }

    // MARK: Signing in

    @Test func signingInWithAppleOpensABankInCloudOnTheServer() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try phone.record.save(BankHandover(authority: .cloud, movedToCloudAt: .now))
        try phone.session.clear()
        let server = StubServer(["POST /api/sign-in/apple": .ok(Bodies.appleSignedIn(cloud: true))])
        let app = phone.launch(server)
        #expect(app.route == .signedOut)

        await AppleSignInModel(app: app).signIn(over: nil)

        #expect(app.route == .signedIn(.store(cloud: true)))
        #expect(app.kind == .store)
        #expect(!app.cloudReturn.isShown, "Cloud is on, so the bank stays in QBank Cloud")
        #expect(app.phoneKey == TestApp.appleUser)
        #expect(!FileManager.default.fileExists(atPath: phone.file.path), "the safety copy, had there been one, is not opened")
    }

    @Test func aBankInCloudIsNotOpenedOnThisPhoneWhenTheServerCannotBeReached() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try phone.record.save(BankHandover(authority: .cloud, movedToCloudAt: .now))
        try phone.session.clear()
        let server = StubServer(["POST /api/sign-in/apple": .offline])
        let app = phone.launch(server)
        let model = AppleSignInModel(app: app)

        await model.signIn(over: nil)

        #expect(app.route == .signedOut)
        #expect(model.problem == AppleSignInWording.bankInCloudNeedsServer)
        #expect(!FileManager.default.fileExists(atPath: phone.file.path))
    }

    @Test func signingInWithAppleFinishesAMoveTheAppWasClosedDuring() async throws {
        let phone = Phone()
        defer { phone.remove() }
        _ = try await free(on: phone, StubServer())
        let before = try phone.bytes()
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        try phone.session.clear()
        let server = StubServer(["POST /api/sign-in/apple": .ok(Bodies.appleSignedIn()), Self.upload: try phone.stored()])
        let app = phone.launch(server)
        #expect(app.route == .signedOut)

        await AppleSignInModel(app: app).signIn(over: nil)

        let summary = try phone.summary()
        try await waitUntil { app.cloudMove.phase == .moved(summary) }
        #expect(server.calls.contains(Self.upload))
        #expect(app.kind == .store)
        #expect(try phone.record.load().lease == nil)
        #expect(try phone.bytes() == before)
        app.cloudMove.close()
        #expect(!app.cloudMove.isShown)
    }

    @Test func signingInWithAppleWhileTheServerCannotBeReachedGivesBackTheLeaseOfAMoveTheAppWasClosedDuring() async throws {
        let phone = Phone()
        defer { phone.remove() }
        _ = try await free(on: phone, StubServer())
        let before = try phone.bytes()
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        try phone.session.clear()
        let server = StubServer(["POST /api/sign-in/apple": .offline])
        let app = phone.launch(server)

        await AppleSignInModel(app: app).signIn(over: nil)

        #expect(app.awaitsServer)
        try await waitUntil { !app.cloudMove.isMoving && app.cloudMove.phase != .idle }
        guard case .failed = app.cloudMove.phase else {
            Issue.record("the move ends in a failure, not \(app.cloudMove.phase)")
            return
        }
        #expect(!server.calls.contains(Self.upload))
        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.bytes() == before)
        app.cloudMove.close()
        #expect(!app.cloudMove.isShown)
        _ = try await app.client.createTopic(title: "Invented Botany")
    }

    // MARK: Words

    @Test func theStepsSayWhatTheyDoWithoutSoundingLikeTheBankIsOverwritten() {
        let steps: [BankMoveToCloud.Step] = [.writing, .sending, .checking]
        #expect(
            steps.map(CloudMoveWording.step) == [
                "Preparing a copy of your bank", "Sending it to QBank Cloud", "Checking that everything arrived",
            ])
    }

    @Test func everyFailureIsSaidInPlainWords() {
        #expect(CloudMoveWording.notStored(.transport(.timedOut)) == "QBank Cloud did not answer in time, so it has not confirmed it holds your whole bank.")
        #expect(CloudMoveWording.notStored(.transport(.networkConnectionLost)) == "The connection to QBank Cloud dropped before it confirmed it holds your whole bank.")
        #expect(CloudMoveWording.notStored(.transport(.userAuthenticationRequired)) == "This \(Device.model) is not connected to the QBank service yet, so your bank was not sent.")
        let differences = [BankMoveToCloud.Difference(table: "questions", onPhone: 2, inCloud: 1), .init(table: "attempts", onPhone: 3, inCloud: 2), .init(table: "studyPlace", onPhone: 1, inCloud: 0)]
        #expect(
            CloudMoveWording.problem(.countsDiffer(differences))
                == "QBank Cloud does not hold the same number of questions, answers and places you left off as this \(Device.model), so QBank keeps using the bank on this \(Device.model).")
        #expect(CloudMoveWording.problem(.switchNotRecorded(.writesHeld)) == "Your bank reached QBank Cloud whole, but this \(Device.model) could not note the switch, so it keeps using the bank here.")
        #expect(CloudMoveWording.problem(.notStarted(.closed)) == "This \(Device.model) could not note that a move was starting, so it did not start.")
        #expect(CloudMoveWording.list(["a"]) == "a")
        #expect(CloudMoveWording.list(["a", "b"]) == "a and b")
        #expect(CloudMoveWording.name(of: "practiceSets") == "sets")
    }

    @Test func tryingAgainIsOfferedOnlyWhereItMayEndDifferently() {
        #expect(CloudMoveWording.canRetry(.notStored(.transport(.timedOut))))
        #expect(CloudMoveWording.canRetry(.notStored(.server(ServerError(status: 503, code: "unavailable", message: "QBank is busy.")))))
        #expect(CloudMoveWording.canRetry(.notStored(.unexpectedResponse(status: 200, detail: "html"))))
        #expect(CloudMoveWording.canRetry(.notStarted(.closed)))
        #expect(!CloudMoveWording.canRetry(.notStored(.server(ServerError(status: 409, code: "bank_not_empty", message: "Refused.")))))
        #expect(!CloudMoveWording.canRetry(.notStored(.server(ServerError(status: 413, code: "archive_too_large", message: "Too large.")))))
        #expect(!CloudMoveWording.canRetry(.countsDiffer([.init(table: "attempts", onPhone: 2, inCloud: 1)])))
        #expect(!CloudMoveWording.canRetry(.switchNotRecorded(.closed)))
        #expect(!CloudMoveWording.canRetry(.alreadyInCloud))
    }
}

private typealias Reply = StubServer.Reply
private typealias Phone = CloudPhone
