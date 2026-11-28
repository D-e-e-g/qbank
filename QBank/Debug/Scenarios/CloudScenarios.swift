#if DEBUG
import Foundation
import QBankKit

nonisolated extension DebugScenario {
    /// A free account whose app was closed while its bank moved to QBank Cloud: the bank on this
    /// iPhone holds the sample set, the record beside it still holds the move's lease, and the fake
    /// server says Cloud is on and has no bank for the account. At launch the move runs again before
    /// anything else, and the bank switches to the server's copy once the counts match. The server's
    /// answer to the upload arrives a few seconds after it has the bank, so the move's screen can be
    /// seen while it runs.
    static let cloudMoveLeftOpen = DebugScenario("cloud-move-left-open") { context in
        DebugCloudMove.model(context: context) { server in
            server.delayUploadReplies(by: DebugCloudMove.uploadReplyDelay)
        }
    }

    /// A store account whose bank moved to QBank Cloud, signed in from an earlier launch, whose Cloud
    /// has ended. This iPhone holds the safety copy, with the sample set, and the record saying the bank
    /// is in QBank Cloud, where it holds the sample set and a set added there since. At launch the bank
    /// comes back to this iPhone. Each download takes a few seconds, so the screen can be seen while it
    /// runs, and the first loses the connection, so the first try fails and changes nothing.
    static let cloudEnded = DebugScenario("cloud-ended") { context in
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        let key = FakeQBankServer.applePerson.user
        do {
            DebugBanks.fill(try context.banks.open(key), sample: sample, with: [])
            try context.banks.handover(key).save(BankHandover.onPhone.inCloud(since: .now.addingTimeInterval(-30 * 86_400)))
        } catch {
            fatalError("The scenario's safety copy could not be made: \(error)")
        }
        return DebugFreeMode.model(context: context, sampleSet: sample) { server in
            server.giveApplePersonACloudBank(sample: sample, sets: [DebugBanks.capitals])
            server.endApplePersonCloud()
            server.slowBankDownloads(by: DebugCloudMove.uploadReplyDelay, dropping: 1)
        }
    }

    /// A second device: no one is signed in, and this iPhone holds a bank for the fake server's store
    /// account from before it had Cloud, with the sample set and a set of its own. The account has
    /// Cloud, and QBank Cloud holds its bank from another device, with the sample set and another set.
    /// Signing in with Apple (`QB_UITEST_APPLE=returning-person`) opens the bank on this iPhone, then
    /// combines it with QBank Cloud's without asking. The first combined bank arrives just after
    /// another device wrote to QBank Cloud's, so the server refuses it with `bank_changed` and the
    /// combine starts again from the download. Each download takes a moment, so the screen can be seen.
    /// A UI test can end the account's Cloud while the app runs (`DebugCloudSwitch`).
    static let cloudSecondDevice = DebugScenario("cloud-second-device") { context in
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        do {
            DebugBanks.fill(try context.banks.open(FakeQBankServer.applePerson.user), sample: sample, with: [DebugBanks.rivers])
        } catch {
            fatalError("The scenario's bank could not be made: \(error)")
        }
        let server = FakeQBankServer(signedIn: false)
        server.giveApplePersonCloud()
        server.giveApplePersonACloudBank(sample: sample, sets: [DebugBanks.capitals])
        server.refuseCombines(1)
        server.slowBankDownloads(by: DebugCloudMove.downloadDelay)
        DebugCloudSwitch.listen(server)
        return context.model(server: server, session: nil)
    }

    /// A returning subscriber, signed in from an earlier launch, whose Cloud has ended. QBank Cloud
    /// still holds their bank, with the sample set and a set added there; this iPhone holds the same
    /// bank, brought back when Cloud ended, under the same ids, in a dated file, and has renamed its
    /// topic since. Buying Cloud again combines the two: the newer name is kept.
    static let cloudReturningSubscriber = DebugScenario("cloud-returning-subscriber") { context in
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        return DebugFreeMode.model(context: context, sampleSet: sample) { server in
            server.giveApplePersonACloudBank(sample: sample, sets: [DebugBanks.capitals])
            server.endApplePersonCloud()
            server.slowBankDownloads(by: DebugCloudMove.downloadDelay)
            let key = FakeQBankServer.applePerson.user
            do {
                let (archive, stamp) = try server.applePersonsDownload()
                let file = "bank-20260101T000000000Z.sqlite"
                let store = try context.banks.create(key, file: file)
                try BankArchive.read(archive, into: store)
                try context.banks.handover(key).save(
                    BankHandover.onPhone.inCloud(since: .now.addingTimeInterval(-60 * 86_400)).onPhone(in: file, since: .now.addingTimeInterval(-30 * 86_400), stamp: stamp))
                DebugBanks.rename(topic: DebugBanks.geography, to: DebugBanks.renamedGeography, in: LocalBank(store: store))
                store.close()
            } catch {
                fatalError("The scenario's bank could not be made: \(error)")
            }
        }
    }

    /// A new iPhone for an account whose Cloud has ended: no one is signed in, this iPhone has no bank
    /// for the person, and QBank still holds their bank, with the sample set and a set added there.
    /// Signing in with Apple (`QB_UITEST_APPLE=returning-person`) makes a new bank with the sample set,
    /// then combines QBank's bank into it, without asking. Each download takes a moment, and the first
    /// loses the connection, so the first try fails and changes nothing.
    static let cloudLapsedNewIPhone = DebugScenario("cloud-lapsed-new-iphone") { context in
        let server = FakeQBankServer(signedIn: false)
        lapse(server)
        server.slowBankDownloads(by: DebugCloudMove.downloadDelay, dropping: 1)
        return context.model(server: server, session: nil)
    }

    /// The same account signed in from an earlier launch, with the bank this iPhone made, still not
    /// combined with QBank's: with `QB_UITEST_KEEP_PHONE_DATA=1` after `cloud-lapsed-new-iphone`, the
    /// one its first try left. Settings offers the combine.
    static let cloudLapsed = DebugScenario("cloud-lapsed") { context in
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        return DebugFreeMode.model(context: context, sampleSet: sample) { server in
            lapse(server)
            server.slowBankDownloads(by: DebugCloudMove.downloadDelay)
        }
    }

    /// QBank holds the bank of the fake server's store account, with the sample set and a set added
    /// there, and its Cloud ended yesterday.
    @MainActor
    private static func lapse(_ server: FakeQBankServer) {
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        server.giveApplePersonACloudBank(sample: sample, sets: [DebugBanks.capitals])
        server.endApplePersonCloud()
    }
}

/// What the Cloud move scenarios share: the free account of `DebugFreeMode`, with Cloud on, whose bank
/// a move to QBank Cloud left open when the app was closed. Compiled only into Debug builds.
nonisolated enum DebugCloudMove {
    /// How long the fake server's answer to an upload takes in `cloud-move-left-open`.
    static let uploadReplyDelay = Duration.seconds(4)
    /// How long each download of QBank's bank takes in the combine scenarios.
    static let downloadDelay = Duration.seconds(2)

    /// Files the sample set into the account's new bank and records the lease of a move to QBank
    /// Cloud beside it, as the app does before it reads the bank, then makes the model, as a launch
    /// after the app was closed does. `prepare` sets the fake server up after Cloud is given.
    @MainActor
    static func model(context: DebugScenarioContext, prepare: @escaping (FakeQBankServer) -> Void) -> AppModel {
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        let key = FakeQBankServer.applePerson.user
        do {
            try context.banks.open(key).fileSampleSet(sample, inTopic: SampleSet.topic)
            try context.banks.handover(key).save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: .now)))
        } catch {
            fatalError("The scenario's bank could not be made: \(error)")
        }
        return DebugFreeMode.model(context: context, sampleSet: sample) { server in
            server.giveApplePersonCloud()
            prepare(server)
        }
    }
}
#endif
