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

    /// The same move left open, but the fake server already holds a bank for the account, so it
    /// refuses the upload with `bank_not_empty` and the bank stays on this iPhone, unchanged.
    static let cloudMoveRefused = DebugScenario("cloud-move-refused") { context in
        DebugCloudMove.model(context: context) { server in
            server.giveApplePersonABank()
        }
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
