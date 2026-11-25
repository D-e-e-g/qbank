#if DEBUG
import Foundation

nonisolated extension DebugScenario {
    /// As `freeNewBank`, with the first request to delete the account losing its connection before it
    /// reaches the server. By then the delete has erased this phone's copy, so it is left to finish;
    /// the next request goes through.
    static let freeDeleteDrops = DebugScenario("free-delete-drops") { context in
        DebugFreeMode.model(context: context, droppedAccountDeletes: 1)
    }
}
#endif
