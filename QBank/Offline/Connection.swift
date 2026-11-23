import Network
import Observation

/// Whether the phone has a network path. It says nothing about the server: a phone on Wi-Fi can
/// still fail to reach QBank, so screens fall back to what is saved whenever a call fails for want
/// of a connection, not only when this is false.
@Observable
final class Connection {
    private(set) var isOnline: Bool
    /// Told about every change, after `isOnline` has changed.
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    /// True for a bank on this phone, which is always reachable: nothing the network does changes it.
    @ObservationIgnored let isFixed: Bool

    init(isOnline: Bool = true) {
        self.isOnline = isOnline
        isFixed = false
    }

    private init(fixedOnline: Void) {
        isOnline = true
        isFixed = true
    }

    /// What the screens read when the bank is on this phone: always online, whatever the network does.
    static func onThisPhone() -> Connection {
        Connection(fixedOnline: ())
    }

    func update(isOnline: Bool) {
        guard !isFixed, isOnline != self.isOnline else { return }
        self.isOnline = isOnline
        onChange?(isOnline)
    }
}

/// Keeps a `Connection` up to date with the phone's network path.
final class NetworkWatcher {
    private let monitor = NWPathMonitor()

    init(connection: Connection) {
        monitor.pathUpdateHandler = { path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in connection.update(isOnline: isOnline) }
        }
        monitor.start(queue: DispatchQueue(label: "com.dimitrygallego.qbank.network"))
    }

    deinit {
        monitor.cancel()
    }
}
