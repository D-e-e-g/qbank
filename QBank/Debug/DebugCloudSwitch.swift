#if DEBUG
import Foundation

/// Ends the fake server's store account's Cloud while the app runs, as a subscription that lapses
/// does, when a UI test posts the Darwin notification `endNotification`. The app learns it the way it
/// learns it from QBank: the next time it reads the account's Cloud. Compiled only into Debug builds.
final class DebugCloudSwitch {
    nonisolated static let endNotification = "com.dimitrygallego.qbank.uitest.cloud.end"

    /// The switch of the app's scenario, kept while the app runs.
    private static var current: DebugCloudSwitch?

    private let server: FakeQBankServer

    private init(server: FakeQBankServer) {
        self.server = server
    }

    /// Follows the test's notification that ends `server`'s store account's Cloud.
    static func listen(_ server: FakeQBankServer) {
        let gate = DebugCloudSwitch(server: server)
        current = gate
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let gate = Unmanaged<DebugCloudSwitch>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                gate.server.endApplePersonCloud()
            }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(gate).toOpaque(), callback, endNotification as CFString, nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
#endif
