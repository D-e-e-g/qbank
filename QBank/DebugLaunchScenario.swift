#if DEBUG
import Foundation
import ObjectiveC
import QBankKit
import UIKit

/// Launch-environment seam for UI tests and local simulator review. Compiled
/// only into Debug builds; Release binaries contain none of it. Every scenario
/// composes synthetic data and in-process fakes, never a real account or the
/// production server: the app talks to `FakeQBankServer` and keeps its session
/// in memory, so the Keychain is never touched. Settings kept on the phone, such
/// as Look and the lock, live in their own defaults suite, and saved courses and
/// unsent answers in their own folder, `Application Support/QBankUITest`; both
/// are emptied at launch.
///
/// Supported environment variables:
/// - `QB_UITEST_SCENARIO`: the scenario to start in, the name of one `DebugScenarioCatalog`
///   lists. Absent means a normal launch.
/// - `QB_UITEST_KEEP_PHONE_SETTINGS`: `1` keeps the suite from the previous
///   launch, to check that a setting survives a relaunch.
/// - `QB_UITEST_AI_CONSENT`: `allowed` starts with her permission to share her material with
///   Anthropic already given, so a test of Make questions or exam twins need not answer the
///   permission screen first. Absent, she has not been asked.
/// - `QB_UITEST_KEEP_PHONE_DATA`: `1` keeps the courses saved and the answers
///   left waiting by the previous launch, to check that they survive a relaunch.
///   The fake server starts afresh either way, unless:
/// - `QB_UITEST_KEEP_SERVER_ANSWERS`: `1` keeps the answers and sittings the fake
///   server saved in the previous launch, to check that a set still opens where
///   she left it after the app is killed.
/// - `QB_UITEST_NETWORK`: `offline` starts without a network; absent or
///   `online` starts with one.
/// - `QB_UITEST_DEVICE_OWNER`: how the device answers the Face ID lock, one of
///   `DebugDeviceOwner.Kind`'s raw values, such as `face-id`. Absent means the
///   simulator's own Face ID or passcode, for a look by hand.
/// - `QB_UITEST_APPLE`: who answers Sign in with Apple, read by `DebugScriptedAppleSignIn`.
///
/// A scenario, the scripted Sign in with Apple and the fake store are not written here: each is a
/// file under `QBank/Debug/` (see `DebugScenario`, `DebugScriptedAppleSignIn` and `DebugFakeStore`),
/// so a pull request that adds one leaves this file and the UI test helpers alone. A free account's
/// bank is a real file, in `Banks/` under the scenario's folder, emptied with it.
///
/// While the app runs, a test turns the network off and on by posting the
/// Darwin notifications `networkOfflineNotification` and
/// `networkOnlineNotification` (see `DebugNetwork`), which the app answers
/// with `networkAppliedNotification(isOnline:)` once its network has changed,
/// sets the app's Look by posting `lookNotification(_:)` (see `DebugLook`),
/// and makes the device confirm or refuse her with `ownerConfirmsNotification`
/// and `ownerRefusesNotification` (see `DebugDeviceOwner`). On iPad, it opens
/// another window with `newWindowNotification` (see `DebugWindows`).
nonisolated enum DebugLaunchScenario {
    static let scenarioKey = "QB_UITEST_SCENARIO"
    static let keepPhoneSettingsKey = "QB_UITEST_KEEP_PHONE_SETTINGS"
    static let keepPhoneDataKey = "QB_UITEST_KEEP_PHONE_DATA"
    static let aiConsentKey = "QB_UITEST_AI_CONSENT"
    static let keepServerAnswersKey = "QB_UITEST_KEEP_SERVER_ANSWERS"
    static let networkKey = "QB_UITEST_NETWORK"
    static let deviceOwnerKey = "QB_UITEST_DEVICE_OWNER"
    static let defaultsSuite = "com.dimitrygallego.qbank.uitest"
    static let networkOfflineNotification = "com.dimitrygallego.qbank.uitest.network.offline"
    static let networkOnlineNotification = "com.dimitrygallego.qbank.uitest.network.online"
    static let ownerConfirmsNotification = "com.dimitrygallego.qbank.uitest.owner.confirms"
    static let ownerRefusesNotification = "com.dimitrygallego.qbank.uitest.owner.refuses"
    static let newWindowNotification = "com.dimitrygallego.qbank.uitest.window.new"

    /// What the app posts once the fake server and the app's connection are offline or online, so
    /// a test that turned the network off acts only after it is off.
    static func networkAppliedNotification(isOnline: Bool) -> String {
        (isOnline ? networkOnlineNotification : networkOfflineNotification) + ".applied"
    }

    /// The notification that sets the app's Look: `com.dimitrygallego.qbank.uitest.look.dark`,
    /// `.light`, or `.auto` for Match device.
    static func lookNotification(_ look: Look) -> String {
        "com.dimitrygallego.qbank.uitest.look.\(look.rawValue)"
    }

    /// UI tests play the window's animations quickly. On a busy Mac an animation that never
    /// finishes, such as the iPad software keyboard's edit menu, makes XCTest wait a minute
    /// before every later action in that test. A fast animation still ends on the final layout,
    /// and XCTest gets the finished notification. A launch with no scenario, and every Release
    /// build, keeps normal speed.
    @MainActor
    static func prepareForUITest() {
        guard ProcessInfo.processInfo.environment[scenarioKey] != nil else { return }
        speedUpWindows()
        guard windowObserver == nil else { return }
        keepScrollViewsAtNormalSpeed()
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { speedUpWindows() }
        }
    }

    @MainActor
    private static func speedUpWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.layer.speed = uiTestAnimationSpeed
                restoreScrollViewSpeeds(in: window)
            }
        }
    }

    /// A layer's speed multiplies by its ancestors', so a scroll view under a sped-up window would
    /// settle its deceleration and bounce 100 times too fast and rest off where a drag left it.
    /// Each scroll view takes the inverse of its ancestors' product, which also leaves a scroll view
    /// nested in a corrected one at 1.
    @MainActor
    private static func restoreScrollViewSpeeds(in view: UIView) {
        if let scrollView = view as? UIScrollView { restoreSpeed(of: scrollView) }
        for subview in view.subviews { restoreScrollViewSpeeds(in: subview) }
    }

    @MainActor
    fileprivate static func restoreSpeed(of scrollView: UIScrollView) {
        var product: Float = 1
        var layer = scrollView.layer.superlayer
        while let current = layer {
            product *= current.speed
            layer = current.superlayer
        }
        scrollView.layer.speed = 1 / product
    }

    /// Corrects a scroll view the moment it joins a window, such as the practice page's, which is
    /// made after its window is visible.
    @MainActor
    private static func keepScrollViewsAtNormalSpeed() {
        guard let original = class_getInstanceMethod(UIScrollView.self, #selector(UIView.didMoveToWindow)) else {
            preconditionFailure("UIView.didMoveToWindow is a method of UIScrollView.")
        }
        typealias Implementation = @convention(c) (UIScrollView, Selector) -> Void
        let previous = unsafeBitCast(method_getImplementation(original), to: Implementation.self)
        let replacement: @convention(block) (UIScrollView) -> Void = { scrollView in
            previous(scrollView, #selector(UIView.didMoveToWindow))
            if scrollView.window != nil {
                MainActor.assumeIsolated { restoreSpeed(of: scrollView) }
            }
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(UIScrollView.self, #selector(UIView.didMoveToWindow), implementation, method_getTypeEncoding(original)) {
            method_setImplementation(original, implementation)
        }
    }

    /// Speeds every window the app shows after launch, such as the edit menu's, which does not
    /// host the SwiftUI root.
    @MainActor private static var windowObserver: NSObjectProtocol?

    /// How many times faster a UI test plays a window animation. High enough that a one-shot
    /// animation finishes inside an XCTest idle check, low enough that the frames still land.
    static let uiTestAnimationSpeed: Float = 100

    /// The network and the Look listener of the app's scenario, kept while the app runs.
    @MainActor private static var network: DebugNetwork?
    @MainActor private static var look: DebugLook?
    /// The device owner of the app's scenario, kept while the app runs.
    @MainActor private static var deviceOwner: DebugDeviceOwner?

    /// How long a reply to a save takes in `DebugScenario.slowSaves`: long enough for a UI test to look
    /// at the screen and tap while it waits.
    static let slowSaveReplyDelay = Duration.seconds(4)

    struct UnknownScenario: Error, CustomStringConvertible {
        let name: String

        var description: String {
            let known = DebugScenarioCatalog.all.map(\.name).joined(separator: ", ")
            return "Unknown \(DebugLaunchScenario.scenarioKey) \"\(name)\"; known scenarios: \(known)"
        }
    }

    /// The device owner the environment asks for, or nil for the simulator's own. An unknown one
    /// stops the app, as an unknown scenario does.
    static func deviceOwnerKind(in environment: [String: String]) -> DebugDeviceOwner.Kind? {
        guard let name = environment[deviceOwnerKey] else { return nil }
        guard let kind = DebugDeviceOwner.Kind(rawValue: name) else {
            fatalError("Unknown \(deviceOwnerKey) \"\(name)\"")
        }
        return kind
    }

    /// The scenario the environment asks for, or nil for a normal launch.
    static func scenario(in environment: [String: String]) throws(UnknownScenario) -> DebugScenario? {
        guard let name = environment[scenarioKey] else { return nil }
        guard let scenario = DebugScenarioCatalog.scenario(named: name) else { throw UnknownScenario(name: name) }
        return scenario
    }

    /// The model for the requested scenario, or nil for a normal launch. An
    /// unknown scenario stops the app so a test never silently runs against
    /// the default state.
    ///
    /// - Parameter phoneFolder: Where saved courses and unsent answers go; unit
    ///   tests give each model its own.
    @MainActor
    static func makeModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        phoneFolder: URL? = nil
    ) -> AppModel? {
        let scenario: DebugScenario?
        do {
            scenario = try self.scenario(in: environment)
        } catch {
            fatalError(error.description)
        }
        guard let scenario else { return nil }
        let defaults = phoneSettings(keep: environment[keepPhoneSettingsKey] == "1")
        if environment[aiConsentKey] == "allowed" {
            defaults.set(true, forKey: AIConsentStore.key)
        }
        let folder = phoneFolder ?? defaultPhoneFolder
        let storage = phoneData(in: folder, keep: environment[keepPhoneDataKey] == "1")
        let answersFile = serverAnswers(beside: folder, keep: environment[keepServerAnswersKey] == "1")
        let context = DebugScenarioContext(
            defaults: defaults, storage: storage, banks: .files(root: folder), answersFile: answersFile, isOnline: environment[networkKey] != "offline",
            owner: deviceOwner(deviceOwnerKind(in: environment)), appleSignIn: DebugScriptedAppleSignIn(environment: environment), store: DebugFakeStore()
        )
        return scenario.make(context)
    }

    static var defaultPhoneFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("QBankUITest", isDirectory: true)
    }

    /// The scenario's own folder for saved courses and unsent answers, emptied unless kept.
    static func phoneData(in folder: URL, keep: Bool) -> PhoneStorage {
        if !keep {
            try? FileManager.default.removeItem(at: folder)
        }
        return .files(root: folder)
    }

    /// The file the fake server keeps her answers in, beside the phone's folder and so apart from it,
    /// emptied unless kept.
    static func serverAnswers(beside folder: URL, keep: Bool) -> URL {
        let file = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-server-answers.json")
        if !keep {
            try? FileManager.default.removeItem(at: file)
        }
        return file
    }

    /// The scenario's own defaults suite, so a test never sees the developer's settings or
    /// another test's.
    static func phoneSettings(keep: Bool) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            preconditionFailure("The UI test defaults suite name is valid.")
        }
        if !keep {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        return defaults
    }

    /// The scenario's device owner: the test's fake, listening for its notifications, or the
    /// simulator's own.
    @MainActor
    private static func deviceOwner(_ kind: DebugDeviceOwner.Kind?) -> DeviceOwner {
        guard let kind else { return LocalDeviceOwner() }
        let owner = DebugDeviceOwner(kind)
        owner.listen()
        deviceOwner = owner
        return owner
    }

    /// The model a scenario's fake server and session make, wired to the launch's network, Look,
    /// lock and phone storage. Scenarios reach it through `DebugScenarioContext.model(server:session:)`.
    @MainActor
    static func assemble(server: FakeQBankServer, session: StoredSession?, context: DebugScenarioContext) -> AppModel {
        let connection = Connection(isOnline: context.isOnline)
        let network = DebugNetwork(server: server, connection: connection, isOnline: context.isOnline)
        network.listen()
        self.network = network
        let lookStore = LookStore(defaults: context.defaults)
        let look = DebugLook(store: lookStore)
        look.listen()
        self.look = look
        DebugWindows.listen()
        return AppModel(
            client: QBankClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://fake-qbank.invalid")!),
                transport: server,
                sessionStore: InMemorySessionStore(session)
            ),
            banks: context.banks,
            sampleSet: SampleSet.bundledSource(),
            appleSignIn: context.appleSignIn,
            look: lookStore,
            lock: AppLock(defaults: context.defaults, owner: context.owner),
            highlighter: HighlighterStore(defaults: context.defaults),
            aiConsent: AIConsentStore(defaults: context.defaults),
            drafts: WriteDraftStore(defaults: context.defaults),
            storage: context.storage,
            connection: connection
        )
    }
}
#endif
