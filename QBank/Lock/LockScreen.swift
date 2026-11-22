import QBankDesign
import SwiftUI
import UIKit

/// What covers QBank while it is locked: the mark and one button that asks for Face ID. While
/// QBank only leaves the screen, it shows the mark alone, so the app switcher shows no question.
struct LockScreen: View {
    let lock: AppLock
    /// False while QBank is only covered on its way out: there is nothing to unlock yet.
    let asks: Bool

    var body: some View {
        VStack(spacing: QBankSpacing.space7) {
            VStack(spacing: 8) {
                QBankMark()
                    .padding(.bottom, QBankSpacing.space2)
                Text("QBank")
                    .qbankFont(.largeTitle)
                    .foregroundStyle(.qbank(.text1))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lock.title")
                Text(asks ? "Locked. \(unlockWords) to keep studying." : " ")
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(!asks)
            }
            if asks {
                unlockButton
            } else {
                // Its place, so the mark stays where it is; there is nothing to unlock yet.
                unlockButton.hidden()
            }
        }
        .padding(.horizontal, QBankSpacing.gutterPhone)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qbankScreenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lock")
    }

    private var unlockButton: some View {
        Button {
            Task { await lock.unlock() }
        } label: {
            Label(unlockWords, systemImage: lock.method?.systemImage ?? "lock")
        }
        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
        .disabled(lock.isChecking)
        .accessibilityIdentifier("lock.unlock")
    }

    /// "Unlock with Face ID", or "Unlock" on a device that lost its passcode, which unlocks for good.
    private var unlockWords: String {
        guard let method = lock.method else { return "Unlock" }
        return "Unlock with \(method.name)"
    }
}

/// Puts the lock screen in a window of its own above the app's, so it covers practice, exams and
/// sheets too and leaves them as they were underneath. Placed in the background of the app's
/// root view, it follows the window scene that view is in.
///
/// It also covers QBank, without asking, the moment the scene stops being active while the lock is
/// on, so the app switcher's snapshot shows no question even before QBank locks in the background.
/// Not while the device is asking for Face ID, which takes the scene out of active by itself.
struct LockWindow: UIViewRepresentable {
    let lock: AppLock
    let look: Look
    let palette: QBankPalette
    /// True when a signed-in account is on screen, so there is something to lock.
    let hasAccount: Bool
    /// True while the lock covers the account's screens. Passed in, rather than read from `lock`
    /// here, so SwiftUI updates this view each time it changes.
    let isLocked: Bool

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isUserInteractionEnabled = false
        host.isAccessibilityElement = false
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        host.lock = lock
        host.look = look
        host.palette = palette
        host.hasAccount = hasAccount
        host.isLocked = isLocked
        host.apply()
    }

    final class Host: UIView {
        var lock: AppLock?
        var look: Look = .matchDevice
        var palette: QBankPalette = .default
        var hasAccount = false
        var isLocked = false
        /// True from the moment the scene stops being active until it is active again.
        private var isCovered = false
        private var lockWindow: UIWindow?
        private var hosting: UIHostingController<AnyView>?
        private weak var observedScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observe(window?.windowScene)
            apply()
        }

        /// Shows, updates or hides the lock window to match the lock.
        func apply() {
            guard let lock, let scene = window?.windowScene else { return }
            guard isLocked || (hasAccount && isCovered) else {
                hide()
                return
            }
            let screen = AnyView(
                LockScreen(lock: lock, asks: isLocked)
                    .tint(QBankColor(.tint))
                    .qbankPalette(palette)
            )
            if let hosting, let lockWindow {
                hosting.rootView = screen
                lockWindow.overrideUserInterfaceStyle = look.userInterfaceStyle
                return
            }
            // A field being typed in keeps its keyboard above every window, so it goes first.
            window?.endEditing(true)
            let hosting = UIHostingController(rootView: screen)
            let lockWindow = UIWindow(windowScene: scene)
            lockWindow.windowLevel = .alert + 1
            lockWindow.overrideUserInterfaceStyle = look.userInterfaceStyle
            lockWindow.rootViewController = hosting
            lockWindow.accessibilityViewIsModal = true
            lockWindow.makeKeyAndVisible()
            self.hosting = hosting
            self.lockWindow = lockWindow
        }

        private func hide() {
            guard let lockWindow else { return }
            self.lockWindow = nil
            hosting = nil
            window?.makeKey()
            UIView.animate(
                withDuration: QBankMotion.standard,
                animations: {
                    lockWindow.alpha = 0
                },
                completion: { _ in
                    lockWindow.isHidden = true
                })
        }

        private func observe(_ scene: UIWindowScene?) {
            guard scene !== observedScene else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            observedScene = scene
            guard let scene else { return }
            center.addObserver(self, selector: #selector(sceneStopsBeingActive), name: UIScene.willDeactivateNotification, object: scene)
            center.addObserver(self, selector: #selector(sceneIsActive), name: UIScene.didActivateNotification, object: scene)
        }

        @objc private func sceneStopsBeingActive() {
            guard let lock, lock.isEnabled, !lock.isChecking else { return }
            isCovered = true
            apply()
        }

        @objc private func sceneIsActive() {
            isCovered = false
            apply()
        }
    }
}
