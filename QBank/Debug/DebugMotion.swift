#if DEBUG
import UIKit

/// Turns the app's animations off for a UI-test launch. XCTest waits for the app
/// to settle after a tap or a launch, and an animation is most of that wait.
/// `DebugLaunchScenario` calls `turnOff` only when the app itself is launching a
/// scenario. A normal Debug launch never calls it, and Release does not compile
/// this file.
@MainActor
enum DebugMotion {
    private static var isOff = false
    private static let windows = WindowSpeed()

    /// True once `turnOff` has run in this process.
    static var animationsAreOff: Bool { isOff }

    /// UIKit animations stop, and each window runs its remaining Core Animation
    /// to the end at once. SwiftUI still needs the transaction in `RootView`.
    static func turnOff() {
        guard !isOff else { return }
        isOff = true
        UIView.setAnimationsEnabled(false)
        windows.start()
    }
}

/// Speeds up every window, including one that appears later, such as the lock
/// window. A fast layer finishes an animation before XCTest's idle wait notices it.
@MainActor
private final class WindowSpeed: NSObject {
    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameVisible(_:)), name: UIWindow.didBecomeVisibleNotification, object: nil
        )
        speedUpExisting()
    }

    @objc private func windowBecameVisible(_ notification: Notification) {
        (notification.object as? UIWindow)?.layer.speed = 100
    }

    private func speedUpExisting() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.layer.speed = 100
            }
        }
    }
}
#endif
