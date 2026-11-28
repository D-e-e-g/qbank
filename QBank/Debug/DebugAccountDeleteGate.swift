#if DEBUG
import Foundation

/// The fake server's answer to a delete of the account, held back until a UI test releases it, so
/// the test can look at the screen for as long as it likes while the delete is under way. The test
/// posts the Darwin notification `releaseNotification`. Compiled only into Debug builds.
final class DebugAccountDeleteGate {
    nonisolated static let releaseNotification = "com.dimitrygallego.qbank.uitest.accountDelete.release"

    /// The gate of the app's scenario, kept while the app runs.
    private static var current: DebugAccountDeleteGate?

    private let server: FakeQBankServer

    private init(server: FakeQBankServer) {
        self.server = server
    }

    /// Holds `server`'s answers to deletes, and follows the test's notification that releases them.
    static func hold(_ server: FakeQBankServer) {
        server.holdAccountDeleteReplies()
        let gate = DebugAccountDeleteGate(server: server)
        current = gate
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let gate = Unmanaged<DebugAccountDeleteGate>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                gate.server.releaseAccountDeleteReplies()
            }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(gate).toOpaque(), callback, releaseNotification as CFString, nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
#endif
