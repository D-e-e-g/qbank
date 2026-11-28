import Foundation
import QBankKit
import Testing
@testable import QBank

/// Combining the bank on this phone with the one QBank holds, in the model (`docs/cloud.md`, Combining
/// two banks): up into QBank Cloud while Cloud is on, down into a fresh file while it is not. It starts
/// without asking, switches only once the checks hold, keeps the bank file on this phone byte for byte
/// as it was, keeps a receipt beside the bank, starts nothing while combining is paused, and runs again
/// when the app was closed during it. The bank is a real file in a folder of the test's own, and the
/// server the Debug fake, whose download carries a stamp and whose combine keeps the route's rules.
/// Invented data only.
@MainActor
struct CloudCombineTests {
    private typealias Phone = CombinePhone

    /// This phone holds the sample set and the invented rivers; QBank Cloud holds the sample set and
    /// the invented capitals, from another device; the person's Cloud is on.
    private func secondDevice(_ phone: Phone) async throws -> FakeQBankServer {
        try await phone.fill([DebugBanks.rivers])
        let server = Phone.server(signedIn: false)
        try await Phone.holdsABank(server, cloud: true)
        return server
    }

    private func combined(_ app: AppModel) throws -> CloudCombineModel.Combined {
        guard case .combined(let combined) = app.cloudCombine.phase else {
            Issue.record("not combined: \(app.cloudCombine.phase)")
            throw CancellationError()
        }
        return combined
    }

    private func topics(_ app: AppModel) async throws -> [String] {
        try await app.client.catalog().topics.map(\.title).sorted()
    }

    // MARK: A second device

    @Test func aFirstLaunchOnASecondDeviceTakesQBankCloudsBankAndMakesNoBankHere() async throws {
        let phone = CloudPhone()
        defer { phone.remove() }
        try phone.session.clear()
        let server = StubServer(["POST /api/sign-in/apple": .ok(Bodies.appleSignedIn(cloud: true))])
        let app = phone.launch(server)

        await AppleSignInModel(app: app).signIn(over: nil)

        #expect(app.route == .signedIn(.store(cloud: true)))
        #expect(app.kind == .store)
        #expect(app.bank == nil)
        #expect(!FileManager.default.fileExists(atPath: phone.file.path), "no bank is made here, and so no sample set")
        #expect(try phone.record.load().authority == .cloud)
        #expect(!app.cloudCombine.isShown, "there is nothing here to combine")
        #expect(server.calls == ["POST /api/sign-in/apple"], "nothing is uploaded")
    }

    @Test func aSecondDeviceCombinesUpWithoutAskingAndSwitchesOnlyOnceTheChecksHold() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = try await secondDevice(phone)
        let before = try phone.bytes()
        let app = phone.launch(server, signedIn: false)

        try await phone.signIn(app)

        let combined = try combined(app)
        #expect(combined.direction == .up)
        #expect(combined.summary == BankSummary(sets: 3, questions: 15, answers: 0), "the sample set is one set, under QBank Cloud's id")
        #expect(combined.addedSets == 1, "only the invented rivers were only on this phone")
        #expect(combined.addedAnswers == 0)
        #expect(!combined.changedInBoth)
        #expect(app.kind == .store)
        let record = try phone.record.load()
        #expect(record.authority == .cloud)
        #expect(record.lease == nil)
        #expect(record.bankFile == LocalStore.firstFile, "the bank file stays the record's own, the safety copy")
        #expect(try phone.bytes() == before, "the bank file is only read")
        #expect(try phone.receipts.map(\.direction) == [.up], "a receipt is kept beside the bank")
        #expect(try await topics(app) == [DebugBanks.geography, SampleSet.topic].sorted())
        app.cloudCombine.close()
        #expect(!app.cloudCombine.isShown)
        #expect(!app.cloudCombine.isOffered, "nothing is left to combine")
    }

    @Test func aBankThatChangedMeanwhileIsCombinedAgainFromTheDownload() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = try await secondDevice(phone)
        server.refuseCombines(BankCombineUp.tries - 1)
        let app = phone.launch(server, signedIn: false)

        try await phone.signIn(app)

        #expect(try combined(app).summary == BankSummary(sets: 3, questions: 15, answers: 0))
        #expect(app.kind == .store)
    }

    // MARK: A combine that does not switch

    /// Each way a combine up ends without the switch, as the fake server makes it: the download loses
    /// the connection, and QBank Cloud's bank keeps changing under every try.
    fileprivate nonisolated static let failures: [(name: String, says: String)] = [
        ("a download that drops", "The connection dropped before your whole bank arrived."),
        ("a bank that keeps changing", FakeQBankServer.bankChanged),
    ]

    @Test(arguments: failures.map(\.name))
    func aFailureAtEachStepSwitchesNothingAndSettingsOffersTheCombine(_ name: String) async throws {
        let failure = try #require(Self.failures.first { $0.name == name })
        let phone = Phone()
        defer { phone.remove() }
        let server = try await secondDevice(phone)
        if name == "a download that drops" {
            server.slowBankDownloads(by: .zero, dropping: 1)
        } else {
            server.refuseCombines(BankCombineUp.tries)
        }
        let before = try phone.bytes()
        let app = phone.launch(server, signedIn: false)

        try await phone.signIn(app)

        #expect(app.cloudCombine.phase == .failed(failure.says, canRetry: true))
        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone, "the bank on this phone stays the one in use, with no lease")
        #expect(try phone.bytes() == before)
        #expect(app.bank?.holdsWrites == false, "the bank takes writes again")
        #expect(try phone.receipts.isEmpty)
        app.cloudCombine.close()
        #expect(app.cloudCombine.isOffered, "Settings offers the combine")
        #expect(app.cloudCombine.due == .up)
        #expect(!app.cloudMove.isOffered, "a move would be refused: QBank Cloud holds a bank")

        // Trying again from Settings combines.
        await app.cloudCombine.start()
        #expect(try combined(app).summary == BankSummary(sets: 3, questions: 15, answers: 0))
    }

    @Test func whileCombiningIsPausedNoneStartsAndSettingsSaysWhy() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = try await secondDevice(phone)
        server.pauseCombining()
        let app = phone.launch(server, signedIn: false)

        await AppleSignInModel(app: app).signIn(over: nil)
        try await waitUntil { app.cloud.bank != nil }

        #expect(!app.cloudCombine.isShown, "a paused combine starts on its own nowhere")
        #expect(app.cloudCombine.isOffered, "Settings still offers it")
        await app.cloudCombine.start()
        #expect(app.cloudCombine.phase == .failed(CloudCombineWording.paused, canRetry: false))
        #expect(app.kind == .free)
        #expect(try phone.record.load() == .onPhone)
    }

    // MARK: Cloud turning on

    @Test func cloudTurningOnWhenQBankCloudHoldsABankCombinesInsteadOfMoving() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([DebugBanks.rivers])
        let server = Phone.server(signedIn: true)
        try await Phone.holdsABank(server, cloud: true)
        let app = phone.launch(server, signedIn: true)
        await app.cloud.refresh()
        #expect(app.cloudCombine.due == .up)

        await app.cloudMove.start()

        #expect(!app.cloudMove.isShown)
        #expect(try combined(app).summary == BankSummary(sets: 3, questions: 15, answers: 0))
        #expect(app.kind == .store)
    }

    @Test func cloudTurningOnWhenQBankCloudHoldsNoBankStillMoves() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([])
        let server = Phone.server(signedIn: true)
        server.giveApplePersonCloud()
        let app = phone.launch(server, signedIn: true)

        await app.cloudMove.start()

        #expect(app.cloudMove.phase == .moved(BankSummary(sets: 1, questions: 10, answers: 0)))
        #expect(!app.cloudCombine.isShown)
        #expect(app.kind == .store)
    }

    /// A move the app was closed during runs again as a move, and QBank Cloud, which holds a bank from
    /// an upload whose answer was lost, refuses it: the two banks are combined instead.
    @Test func aMoveQBankCloudRefusesBecauseItHoldsABankBecomesACombine() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([DebugBanks.rivers])
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        let server = Phone.server(signedIn: true)
        try await Phone.holdsABank(server, cloud: true)
        let app = phone.launch(server, signedIn: true)
        #expect(app.cloudMove.isShown)

        await app.cloudMove.finishLeftOpen()

        #expect(!app.cloudMove.isShown)
        #expect(try combined(app).summary == BankSummary(sets: 3, questions: 15, answers: 0))
        #expect(app.kind == .store)
    }

    // MARK: A combine the app was closed during

    @Test func aCombineUpTheAppWasClosedDuringRunsAgainAtLaunch() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([DebugBanks.rivers])
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now, combines: true)))
        let server = Phone.server(signedIn: true)
        try await Phone.holdsABank(server, cloud: true)

        let app = phone.launch(server, signedIn: true)

        #expect(app.cloudCombine.isShown, "its screen comes first")
        #expect(app.bank?.holdsWrites == true, "nothing changes the bank before it runs again")
        await app.cloudCombine.finishLeftOpen()
        #expect(try combined(app).summary == BankSummary(sets: 3, questions: 15, answers: 0))
        #expect(app.kind == .store)
        #expect(try phone.record.load().lease == nil)
    }

    @Test func aCombineUpLeftOpenWhileCombiningIsPausedIsLetGoOf() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([DebugBanks.rivers])
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now, combines: true)))
        let server = Phone.server(signedIn: true)
        try await Phone.holdsABank(server, cloud: true)
        server.pauseCombining()
        let app = phone.launch(server, signedIn: true)

        await app.cloudCombine.finishLeftOpen()

        #expect(app.cloudCombine.phase == .failed(CloudCombineWording.paused, canRetry: false))
        #expect(try phone.record.load() == .onPhone)
        #expect(app.bank?.holdsWrites == false, "the bank takes writes again")
        #expect(app.kind == .free)
    }

    // MARK: Combining down

    @Test func aNewIPhoneForALapsedAccountCombinesDownIntoAFreshFile() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = Phone.server(signedIn: false)
        try await Phone.holdsABank(server, cloud: false)
        let app = phone.launch(server, signedIn: false)

        try await phone.signIn(app)

        let combined = try combined(app)
        #expect(combined.direction == .down)
        #expect(combined.summary == BankSummary(sets: 2, questions: 13, answers: 0), "the sample set this phone filed is QBank's, joined")
        #expect(app.kind == .free)
        let record = try phone.record.load()
        #expect(record.authority == .phone)
        #expect(record.bankFile != LocalStore.firstFile, "a fresh file")
        #expect(record.bankStamp != nil, "it names the bank it took in")
        #expect(try phone.fileNames().contains(LocalStore.firstFile), "the bank this phone made stays as it was")
        #expect(try phone.receipts.map(\.direction) == [.down])
        #expect(try await topics(app) == [DebugBanks.geography, SampleSet.topic].sorted())
        app.cloudCombine.close()
        #expect(!app.cloudCombine.isOffered, "the bank QBank holds is taken in")

        let relaunched = phone.launch(server)
        await relaunched.cloud.refresh()
        #expect(relaunched.cloudCombine.due == nil, "a relaunch does not combine the same bank again")
        #expect(try await topics(relaunched) == [DebugBanks.geography, SampleSet.topic].sorted())
    }

    @Test func aCombineDownThatFailsIsOfferedUntilItIsDoneAlsoAfterARelaunch() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = Phone.server(signedIn: false)
        try await Phone.holdsABank(server, cloud: false)
        server.slowBankDownloads(by: .zero, dropping: 1)
        let app = phone.launch(server, signedIn: false)

        try await phone.signIn(app)

        #expect(app.cloudCombine.phase == .failed("The connection dropped before your whole bank arrived.", canRetry: true))
        #expect(try phone.record.load() == .onPhone)
        #expect(try phone.fileNames().allSatisfy { !$0.hasPrefix("bank-") }, "the fresh file is taken away")
        app.cloudCombine.close()
        #expect(app.cloudCombine.isOffered)
        #expect(app.cloudCombine.due == .down)

        let relaunched = phone.launch(server)
        await relaunched.cloud.refresh()
        #expect(relaunched.cloudCombine.isOffered, "Settings offers it after QBank was closed and opened again")
        await relaunched.cloudCombine.start()
        #expect(try combined(relaunched).direction == .down)
        #expect(try await topics(relaunched) == [DebugBanks.geography, SampleSet.topic].sorted())
    }

    @Test func aCombineDownTheAppWasClosedDuringIsLetGoOfAndRunsAgain() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([])
        let left = "bank-20270115T080000000Z.sqlite"
        try phone.banks.create(Phone.key, file: left).close()
        try phone.record.save(BankHandover.onPhone.leased(.init(direction: .toPhone, startedAt: .now, file: left, combines: true)))
        let server = Phone.server(signedIn: true)
        try await Phone.holdsABank(server, cloud: false)

        let app = phone.launch(server, signedIn: true)

        #expect(app.cloudCombine.isShown)
        #expect(!(try phone.fileNames().contains(left)), "the file that never became the bank is gone")
        #expect(try phone.record.load() == .onPhone)
        await app.cloudCombine.finishLeftOpen()
        #expect(try combined(app).summary == BankSummary(sets: 2, questions: 13, answers: 0))
    }

    @Test func aBankHandedBackWhenCloudEndsLeavesNothingToCombineDown() async throws {
        let phone = Phone()
        defer { phone.remove() }
        let server = try await secondDevice(phone)
        let app = phone.launch(server, signedIn: false)
        try await phone.signIn(app)
        #expect(app.kind == .store)
        app.cloudCombine.close()
        server.endApplePersonCloud()

        await app.cloud.refresh()
        try await waitUntil(timeout: .seconds(20)) {
            if case .returned = app.cloudReturn.phase { true } else { false }
        }

        #expect(app.kind == .free)
        #expect(try phone.record.load().bankStamp != nil, "the record names the bank this phone took in")
        #expect(app.cloudCombine.due == nil, "the bank QBank holds is the one just taken in")
        #expect(!app.cloudCombine.isOffered)
    }

    @Test func aFreeAccountWhoseServerHoldsNoBankHasNothingToCombine() async throws {
        let phone = Phone()
        defer { phone.remove() }
        try await phone.fill([])
        let server = Phone.server(signedIn: true)
        let app = phone.launch(server, signedIn: true)

        await app.cloud.refresh()

        #expect(app.cloud.bank == CloudStatus.Bank(stamp: nil, combinePaused: false))
        #expect(app.cloudCombine.due == nil)
        #expect(!app.cloudCombine.isOffered)
    }

    // MARK: Words

    @Test func theScreensSayWhatWasCombinedInTheApprovedWords() {
        let device = Device.model
        #expect(CloudCombineWording.combiningTitle == "Combining your banks")
        #expect(
            [CloudCombineModel.Step.reading, .combining, .sending, .checking].map(CloudCombineWording.step) == [
                "Reading your bank in QBank Cloud", "Combining it with the bank on this \(device)", "Sending what QBank Cloud does not have",
                "Checking that everything is there",
            ])
        #expect(CloudCombineWording.keepOpen == "Keep QBank open. Your bank can't change until this ends.")
        #expect(CloudCombineWording.lead == "With QBank Cloud on, QBank keeps one bank for you. What is only on this \(device) is added to it. Nothing is removed.")
        #expect(CloudCombineWording.answersAdded == "Your answers from this \(device) are added too.")
        #expect(CloudCombineWording.safetyCopy == "The bank on this \(device) stays on it, unchanged, as a safety copy.")
        #expect(CloudCombineWording.combinedTitle == "Your banks are combined")
        #expect(CloudCombineWording.combinedUpBody == "QBank Cloud now holds everything from this \(device) and everything it already had. Nothing was removed.")
        #expect(CloudCombineWording.added(sets: 2, answers: 41) == "Added from this \(device): 2 sets, 41 answers")
        #expect(CloudCombineWording.added(sets: 1, answers: 2_104) == "Added from this \(device): 1 set, 2,104 answers")
        #expect(CloudCombineWording.newerKept == "Where something was changed in both places, the newer change was kept.")
        #expect(CloudCombineWording.failedTitle == "Your banks were not combined")
        #expect(CloudCombineWording.unchanged == "Nothing on this \(device) or in QBank Cloud was removed. You can keep using the bank on this \(device).")
        #expect(
            CloudCombineWording.combinedDownBody
                == "Everything QBank held for you is on this \(device), together with what was already here. Nothing in QBank was changed or deleted.")
        #expect(CloudCombineWording.combineUp == "Combine my bank with QBank Cloud")
        #expect(CloudCombineWording.combineUpDetail == "Your bank is still on this \(device).")
        #expect(CloudCombineWording.combineDown == "Bring my bank to this \(device)")
        #expect(CloudCombineWording.combineDownDetail == "QBank holds a bank for you that is not on this \(device) yet.")
        #expect(CloudCombineWording.canRetry(BankCombineUp.Failure.notStored(.server(ServerError(status: 409, code: .bankChanged, message: "Changed.")))))
        #expect(!CloudCombineWording.canRetry(BankCombineUp.Failure.countsDiffer([])))
    }
}
