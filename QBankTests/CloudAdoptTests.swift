import Foundation
import QBankKit
import Testing
@testable import QBank

/// Taking the bank QBank Cloud already holds, in the model (`docs/cloud.md`, the hand-over's second
/// row): on a second device, for a returning subscriber, and after a refused upload. Nothing is
/// uploaded or merged, nothing switches until the person taps, the bank file on this phone stays byte
/// for byte as it was, and its own sets go to QBank Cloud as new sets only on a tap. The bank is a real
/// file in a folder of the test's own, and the server a stub with the contract's shapes and words.
/// Invented data only.
@MainActor
struct CloudAdoptTests {
    private static let download = "GET /api/me/bank"
    private static let upload = "PUT /api/me/bank"
    private static let signIn = "POST /api/sign-in/apple"
    private static let imports = "POST /api/imports"
    private static let rivers = #"{"title":"Invented rivers","questions":[{"id":"R1","type":"single","ask":"Which river is longest?","options":[{"t":"The Sile","ok":true},{"t":"The Orne"}]}]}"#

    /// This phone's bank, with the sample set and a set of its own, for a person who signed out; QBank
    /// Cloud holds the sample set too, and a topic of its own.
    private func secondDevice(_ phone: CloudPhone, _ server: StubServer) async throws -> AppModel {
        let free = try await phone.free(server)
        _ = try await free.client.importSet(ImportRequest(source: Self.rivers, title: nil, course: .newTopic(title: "Geography"), folder: .unsorted, decision: .import))
        try phone.session.clear()
        server[Self.signIn] = .ok(Bodies.appleSignedIn(cloud: true))
        server[Self.download] = CloudPhone.reply(try await CloudPhone.cloudArchive(topics: ["Made in QBank Cloud"]))
        return phone.launch(server)
    }

    private func found(_ app: AppModel) async throws -> CloudAdoptModel.Found {
        try await waitUntil {
            if case .found = app.cloudAdopt.phase { return true }
            return false
        }
        guard case .found(let found) = app.cloudAdopt.phase else { throw CancellationError() }
        return found
    }

    // MARK: A second device

    @Test func aFirstLaunchOnASecondDeviceTakesQBankCloudsBankAndMakesNoBankHere() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        try phone.session.clear()
        let server = StubServer([Self.signIn: .ok(Bodies.appleSignedIn(cloud: true))])
        let app = phone.launch(server)

        await AppleSignInModel(app: app).signIn(over: nil)

        #expect(app.route == .signedIn(.store(cloud: true)))
        #expect(app.kind == .store)
        #expect(app.bank == nil)
        #expect(!FileManager.default.fileExists(atPath: phone.file.path), "no bank is made here, and so no sample set")
        #expect(try phone.record.load().authority == .cloud)
        #expect(!app.cloudAdopt.isShown, "there is nothing here to ask about")
        #expect(server.calls == [Self.signIn], "nothing is uploaded")
    }

    @Test func signingInWithCloudOnAsksBeforeTakingQBankCloudsBankAndChangesNothingUntilATap() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await secondDevice(phone, server)

        await AppleSignInModel(app: app).signIn(over: nil)

        #expect(app.kind == .free, "the bank on this phone opens first")
        let found = try await found(app)
        let before = try phone.bytes()
        #expect(found.onlyOnPhone.map(\.title) == ["Invented rivers"], "the sample set, filed from the same file, is in QBank Cloud already")
        #expect(found.onlyOnPhone.first?.place.title == "Geography")
        #expect(found.counts["courses"] == 2)
        #expect(try phone.record.load() == .onPhone)
        #expect(!server.calls.contains(Self.upload), "nothing is uploaded")
        #expect(app.bank?.holdsWrites == false, "the bank on this phone is still the one in use")

        app.cloudAdopt.use()

        #expect(app.kind == .store)
        #expect(app.bank == nil)
        let record = try phone.record.load()
        #expect(record.authority == .cloud)
        #expect(record.offeredSets == found.onlyOnPhone.map(\.id))
        #expect(app.cloudAdopt.phase == .offering(found.onlyOnPhone))
        #expect(try phone.bytes() == before, "the bank file is the safety copy, as it was")
        #expect(!server.calls.contains(Self.imports), "nothing is added before the person asks")
        #expect(!server.calls.contains(Self.upload))
    }

    @Test func addingWhatOnlyThisPhoneHasImportsItAsANewSetAndRemovesNothing() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await secondDevice(phone, server)
        await AppleSignInModel(app: app).signIn(over: nil)
        _ = try await found(app)
        app.cloudAdopt.use()
        let before = try phone.bytes()
        server["GET /api/semesters"] = .ok(Bodies.semesters([], topics: [Bodies.topic(id: "t-geo", title: "geography")]))
        server[Self.imports] = StubServer.Reply(status: 201, body: ImportModelTests.imported())

        await app.cloudAdopt.add()

        #expect(app.cloudAdopt.phase == .added(1))
        let sent = try #require(server.requests.last { $0.url?.path() == "/api/imports" })
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["courseId"] as? String == "t-geo", "into QBank Cloud's topic of the same name")
        #expect(body["decision"] as? String == "separate", "beside any set of the same name, never in its place")
        #expect(body["folderId"] == nil && body["folderName"] == nil, "into Unsorted, as on this phone")
        let source = try #require(body["source"] as? String)
        let file = try #require(try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        #expect(file["title"] as? String == "Invented rivers", "the set rebuilt as a question file")
        #expect((file["questions"] as? [[String: Any]])?.map { $0["id"] as? String } == ["R1"])
        #expect(server.calls.filter { $0 == Self.imports }.count == 1)
        #expect(!server.calls.contains { $0.hasPrefix("DELETE") || $0.hasPrefix("PATCH") }, "nothing is removed or renamed")
        #expect(try phone.record.load().offeredSets.isEmpty)
        #expect(try phone.bytes() == before)
        app.cloudAdopt.close()
        app.cloudAdopt.refreshOffer()
        #expect(!app.cloudAdopt.offersSets)
    }

    @Test func anAddThatFailsKeepsOfferingWhatDidNotGo() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await secondDevice(phone, server)
        await AppleSignInModel(app: app).signIn(over: nil)
        _ = try await found(app)
        app.cloudAdopt.use()
        let offered = try phone.record.load().offeredSets
        server["GET /api/semesters"] = .ok(Bodies.semesters([], topics: []))
        server[Self.imports] = .offline

        await app.cloudAdopt.add()

        #expect(app.cloudAdopt.phase == .failed("No connection. Check Wi-Fi or cellular data and try again.", retry: .add))
        #expect(try phone.record.load().offeredSets == offered, "the set that did not go is still offered")
        app.cloudAdopt.close()
        #expect(app.cloudAdopt.offersSets, "Settings offers it")
        #expect(app.cloudAdopt.offeredCount == 1)

        server[Self.imports] = StubServer.Reply(status: 201, body: ImportModelTests.imported())
        app.cloudAdopt.offerSets()
        await app.cloudAdopt.add()
        #expect(app.cloudAdopt.phase == .added(1))
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests.last { $0.url?.path() == "/api/imports" }?.httpBody ?? Data()) as? [String: Any])
        #expect((body["newTopic"] as? [String: Any])?["title"] as? String == "Geography", "a topic QBank Cloud lacks is made")
    }

    @Test func notNowKeepsTheBankOnThisPhoneAndSettingsOffersQBankCloudsBank() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await secondDevice(phone, server)
        await AppleSignInModel(app: app).signIn(over: nil)
        _ = try await found(app)

        app.cloudAdopt.close()

        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone)
        #expect(app.cloudAdopt.isOffered)
        #expect(!app.cloudMove.isOffered, "QBank Cloud would refuse the move")
        _ = try await app.client.createTopic(title: "Invented Botany")
    }

    @Test func nothingIsAskedWhenQBankCloudHoldsNoBankOrCannotBeRead() async throws {
        for reply in [CloudPhone.reply(try await CloudPhone.cloudArchive(sample: false)), .offline, .error(503, "unavailable", "QBank is busy.")] {
            let phone = CloudPhone()
            defer { phone.remove() }
            let server = StubServer()
            let app = try await secondDevice(phone, server)
            server[Self.download] = reply

            await AppleSignInModel(app: app).signIn(over: nil)
            try await waitUntil { server.calls.contains(Self.download) }
            await app.cloudAdopt.check()

            #expect(!app.cloudAdopt.isShown)
            #expect(app.cloudAdopt.found == nil)
            #expect(app.kind == .free)
            #expect(try phone.record.load() == .onPhone)
        }
    }

    // MARK: A refused upload

    @Test func aMoveRefusedBecauseQBankCloudHoldsABankAsksAboutThatBank() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await phone.free(server)
        let before = try phone.bytes()
        server[Self.upload] = .error(409, "bank_not_empty", "This account already has a question bank on the server, so the upload was refused. Nothing was changed.")
        server[Self.download] = CloudPhone.reply(try await CloudPhone.cloudArchive(sample: false, topics: ["From another device"]))

        await app.cloudMove.start()

        #expect(!app.cloudMove.isShown)
        #expect(app.cloudAdopt.isShown)
        #expect(app.cloudScreenIsShown, "one screen still covers the app")
        let found = try await found(app)
        #expect(found.onlyOnPhone.map(\.title) == ["General knowledge sampler"])
        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.bytes() == before)

        app.cloudAdopt.close()
        #expect(app.cloudAdopt.isOffered)
        #expect(!app.cloudMove.isOffered, "the same upload would be refused again")
        _ = try await app.client.createTopic(title: "Invented Botany")
    }

    @Test func anUploadWhoseAnswerWasLostFindsEverySetInQBankCloudAndOffersNone() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        let server = StubServer()
        let app = try await phone.free(server)
        // The bank reached QBank Cloud, but the answer was lost: the next try is refused.
        server[Self.upload] = .error(409, "bank_not_empty", "This account already has a question bank on the server, so the upload was refused. Nothing was changed.")
        server[Self.download] = CloudPhone.reply(try phone.archive())

        await app.cloudMove.start()
        _ = try await found(app)
        guard case .found(let found) = app.cloudAdopt.phase else { return }
        #expect(found.onlyOnPhone.isEmpty)
        app.cloudAdopt.use()

        #expect(app.cloudAdopt.phase == .adopted)
        #expect(app.kind == .store)
        #expect(try phone.record.load().offeredSets.isEmpty)
    }

    // MARK: Words

    @Test func whatOnlyThisPhoneHasIsSaidPlainly() {
        #expect(CloudAdoptWording.onlyHere(0) == "QBank Cloud has every set on this iPhone.")
        #expect(CloudAdoptWording.onlyHere(1) == "1 set only on this iPhone. Next, you can add it to QBank Cloud as a new set.")
        #expect(CloudAdoptWording.onlyHere(3) == "3 sets only on this iPhone. Next, you can add them to QBank Cloud as new sets.")
        #expect(CloudAdoptWording.offeringBody(1) == "QBank Cloud does not have this set. It goes in as a new set, in the course or topic and folder of the same name. Nothing in QBank Cloud is replaced, renamed or removed.")
        #expect(CloudAdoptWording.offeringBody(2).hasPrefix("QBank Cloud does not have these sets. Each one goes in as a new set,"))
        #expect(CloudAdoptWording.addedTitle(1) == "Your set is in QBank Cloud")
        #expect(CloudAdoptWording.addedTitle(2) == "Your sets are in QBank Cloud")
        #expect(CloudAdoptWording.addedBody(1) == "QBank added 1 set to QBank Cloud as a new set. The safety copy on this iPhone is as it was.")
        #expect(CloudAdoptWording.addedBody(2) == "QBank added 2 sets to QBank Cloud as new sets. The safety copy on this iPhone is as it was.")
        #expect(CloudAdoptWording.add(1) == "Add it to QBank Cloud")
        #expect(CloudAdoptWording.add(2) == "Add all 2 to QBank Cloud")
        #expect(CloudAdoptWording.place(.init(kind: .course, code: "NURS 101", title: "Invented Nursing", semesterNumber: 1, folder: "Week 1")) == "NURS 101 Invented Nursing · Week 1")
        #expect(CloudAdoptWording.place(.init(kind: .topic, code: "", title: "Geography", semesterNumber: nil, folder: nil)) == "Geography")
        #expect(CloudAdoptWording.someAdded(1, of: 3, problem: "No connection.") == "QBank added 1 of 3 sets. No connection.")
        #expect(!CloudAdoptWording.canRetry(.moving))
        #expect(CloudAdoptWording.canRetry(.notDownloaded(.transport(.timedOut))))
    }
}
