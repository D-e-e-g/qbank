#if DEBUG
import Foundation

/// The fake server's network, which a UI test turns off and on while the app runs, so it can see
/// the app lose its connection and find it again. Off, every call fails as it does on a phone
/// without signal, and the app's `Connection` says so, as the phone's network path would.
///
/// The test posts the Darwin notifications named in `DebugLaunchScenario`; they cross from the
/// test runner to the app on the same simulator, and reach the app a moment later. The app posts
/// one back once the network has changed, which the test waits for. Compiled only into Debug
/// builds.
final class DebugNetwork {
    let server: FakeQBankServer
    let connection: Connection

    init(server: FakeQBankServer, connection: Connection, isOnline: Bool) {
        self.server = server
        self.connection = connection
        set(isOnline: isOnline)
    }

    func set(isOnline: Bool) {
        server.isOffline = !isOnline
        connection.update(isOnline: isOnline)
    }

    /// Starts following the test's notifications, until this network is released.
    func listen() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let network = Unmanaged<DebugNetwork>.fromOpaque(observer).takeUnretainedValue()
            let isOnline = name.rawValue as String == DebugLaunchScenario.networkOnlineNotification
            Task { @MainActor in
                network.set(isOnline: isOnline)
                let applied = DebugLaunchScenario.networkAppliedNotification(isOnline: isOnline)
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(applied as CFString), nil, nil, true)
            }
        }
        for name in [DebugLaunchScenario.networkOfflineNotification, DebugLaunchScenario.networkOnlineNotification] {
            CFNotificationCenterAddObserver(center, observer, callback, name as CFString, nil, .deliverImmediately)
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
#endif
