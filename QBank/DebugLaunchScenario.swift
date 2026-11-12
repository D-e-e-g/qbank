#if DEBUG
import Foundation
import QBankKit

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
/// - `QB_UITEST_SCENARIO`: the scenario to start in, one of `Scenario`'s raw
///   values. Absent means a normal launch.
/// - `QB_UITEST_KEEP_PHONE_SETTINGS`: `1` keeps the suite from the previous
///   launch, to check that a setting survives a relaunch.
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

    /// The network and the Look listener of the app's scenario, kept while the app runs.
    @MainActor private static var network: DebugNetwork?
    @MainActor private static var look: DebugLook?
    /// The device owner of the app's scenario, kept while the app runs.
    @MainActor private static var deviceOwner: DebugDeviceOwner?

    enum Scenario: String, CaseIterable {
        /// No session on the phone: the sign-in screen. `FakeQBankServer.student`
        /// signs in normally; `FakeQBankServer.resetStudent` must choose a new password;
        /// `FakeQBankServer.signUpEmail` is on the owner's sign-up list and signs up.
        case signedOut = "signed-out"
        /// `FakeQBankServer.student` is signed in from an earlier launch and last
        /// used the Mental Health course. The server does not let her make questions.
        case signedIn = "signed-in"
        /// As `signedIn`, with an exam over Mental Health's Weeks 1-2 left in progress, so deleting
        /// what it asks is refused for now.
        case examInProgress = "exam-in-progress"
        /// As `examInProgress`, with every question of the exam but its last answered, and the
        /// connection lost for the first six requests to end it: her last answer lands, and the
        /// finish after it does not, for a while.
        case examFinishDrops = "exam-finish-drops"
        /// `FakeQBankServer.maker` is signed in: the server lets her make questions, with one set
        /// being written and the questions copied from two photos waiting for her check.
        case maker = "maker"
        /// `FakeQBankServer.maker` is signed in, but the server has no Claude key, so making
        /// questions is not set up yet.
        case makerNotSetUp = "maker-not-set-up"
        /// `FakeQBankServer.owner` is signed in, on Home, in the frozen view of `FakeQBankServer.student`.
        case owner = "owner"
        /// As `owner`, with the exam of `examInProgress` running on the account it looks at.
        case ownerExamInProgress = "owner-exam-in-progress"
        /// Signed in, with Weeks 1-3 holding one matrixmulti question instead of the mixed set.
        case matrixMulti = "matrix-multi"
        /// Signed in, with Weeks 1-3 holding one select-all question whose every option is correct.
        case sataAllCorrect = "sata-all-correct"
    }

    struct UnknownScenario: Error, CustomStringConvertible {
        let name: String

        var description: String {
            let known = Scenario.allCases.map(\.rawValue).joined(separator: ", ")
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
    static func scenario(in environment: [String: String]) throws(UnknownScenario) -> Scenario? {
        guard let name = environment[scenarioKey] else { return nil }
        guard let scenario = Scenario(rawValue: name) else { throw UnknownScenario(name: name) }
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
        let scenario: Scenario?
        do {
            scenario = try self.scenario(in: environment)
        } catch {
            fatalError(error.description)
        }
        guard let scenario else { return nil }
        let defaults = phoneSettings(keep: environment[keepPhoneSettingsKey] == "1")
        let folder = phoneFolder ?? defaultPhoneFolder
        let storage = phoneData(in: folder, keep: environment[keepPhoneDataKey] == "1")
        let answersFile = serverAnswers(beside: folder, keep: environment[keepServerAnswersKey] == "1")
        let isOnline = environment[networkKey] != "offline"
        let owner: DeviceOwner = deviceOwner(deviceOwnerKind(in: environment))
        switch scenario {
        case .signedOut:
            return model(server: FakeQBankServer(signedIn: false), session: nil, defaults: defaults, storage: storage, isOnline: isOnline, owner: owner)
        case .signedIn, .examInProgress:
            return model(
                server: FakeQBankServer(signedIn: true, examInProgress: scenario == .examInProgress, answersFile: answersFile),
                session: FakeQBankServer.storedStudentSession(),
                defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        case .examFinishDrops:
            return model(
                server: FakeQBankServer(
                    signedIn: true, examInProgress: true, examLastQuestionOpen: true, droppedFinishes: 6, answersFile: answersFile
                ),
                session: FakeQBankServer.storedStudentSession(),
                defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        case .maker, .makerNotSetUp:
            return model(
                server: FakeQBankServer(signedIn: true, as: FakeQBankServer.maker, makerIsSetUp: scenario == .maker),
                session: FakeQBankServer.storedMakerSession(), defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        case .owner, .ownerExamInProgress:
            return model(
                server: FakeQBankServer(signedIn: true, as: FakeQBankServer.owner, examInProgress: scenario == .ownerExamInProgress),
                session: FakeQBankServer.storedOwnerSession(), defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        case .matrixMulti:
            return model(
                server: FakeQBankServer(signedIn: true, matrixMultiSet: true, answersFile: answersFile),
                session: FakeQBankServer.storedStudentSession(),
                defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        case .sataAllCorrect:
            return model(
                server: FakeQBankServer(signedIn: true, sataAllCorrectSet: true, answersFile: answersFile),
                session: FakeQBankServer.storedStudentSession(),
                defaults: defaults, storage: storage, isOnline: isOnline, owner: owner
            )
        }
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
        let defaults = UserDefaults(suiteName: defaultsSuite)!
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

    @MainActor
    private static func model(
        server: FakeQBankServer, session: StoredSession?, defaults: UserDefaults, storage: PhoneStorage, isOnline: Bool,
        owner: DeviceOwner
    ) -> AppModel {
        let connection = Connection(isOnline: isOnline)
        let network = DebugNetwork(server: server, connection: connection, isOnline: isOnline)
        network.listen()
        self.network = network
        let lookStore = LookStore(defaults: defaults)
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
            look: lookStore,
            lock: AppLock(defaults: defaults, owner: owner),
            highlighter: HighlighterStore(defaults: defaults),
            storage: storage,
            connection: connection
        )
    }
}
#endif
