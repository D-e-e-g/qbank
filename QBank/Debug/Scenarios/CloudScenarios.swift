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

    /// The same move left open, but the fake server already holds a bank for the account, moved from
    /// another device, with a set of its own and not the sample set. It refuses the upload with
    /// `bank_not_empty`, and the app asks whether to use that bank, the bank on this iPhone unchanged.
    static let cloudMoveRefused = DebugScenario("cloud-move-refused") { context in
        DebugCloudMove.model(context: context) { server in
            server.giveApplePersonACloudBank(sample: nil, sets: [DebugBanks.capitals])
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
    /// asks whether to use QBank Cloud's, and offers the set only this iPhone has.
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
        return context.model(server: server, session: nil)
    }
}

/// What the Cloud move scenarios share: the free account of `DebugFreeMode`, with Cloud on, whose bank
/// a move to QBank Cloud left open when the app was closed. Compiled only into Debug builds.
nonisolated enum DebugCloudMove {
    /// How long the fake server's answer to an upload takes in `cloud-move-left-open`.
    static let uploadReplyDelay = Duration.seconds(4)

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
