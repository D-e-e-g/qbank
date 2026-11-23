#if DEBUG
import Foundation
import QBankKit

nonisolated extension DebugScenario {
    /// A free account on this iPhone with a new, empty bank: no semester, course or set. The bank is
    /// on the phone and answers every study request itself, so everything works with
    /// `QB_UITEST_NETWORK=offline`; only the account's own requests (its color, its sign-out) go to
    /// the fake server. Free mode has no screen to sign in to yet, so this is the one way in.
    static let freeNewBank = DebugScenario("free-new-bank") { context in
        guard let store = try? LocalStore.inMemory() else { fatalError("An in-memory bank always opens.") }
        return DebugFreeMode.model(context: context, bank: LocalBank(store: store))
    }

    /// A free account's first launch: a new, empty bank given the sample set the app ships with, as
    /// the app does for a new bank of a free account. Otherwise the same as `freeNewBank`.
    static let freeFirstLaunch = DebugScenario("free-first-launch") { context in
        guard let store = try? LocalStore.inMemory() else { fatalError("An in-memory bank always opens.") }
        guard let sample = SampleSet.bundledSource() else { fatalError("The app ships with its sample set.") }
        return DebugFreeMode.model(context: context, bank: LocalBank(store: store), sampleSet: sample)
    }
}
#endif
