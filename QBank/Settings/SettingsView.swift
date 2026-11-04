import QBankDesign
import QBankKit
import SwiftUI

/// Where a Settings row leads.
enum SettingsRoute: Hashable {
    case changePassword
    case connectAgent
    case deleteAccount
    case semester(String)
    case savedForOffline
}

/// The Settings tab, as the web's Settings for a user account: her account, which she can sign out
/// of here or on every device, or delete, with her agent keys, her semesters by name and dates, and
/// Look and Color, then what is saved on this phone.
/// Home's + adds a semester, a course or a topic, and holding one on Home renames, moves or
/// archives it. Export stays on the web.
struct SettingsView: View {
    let app: AppModel
    @State private var catalog: CatalogModel
    @State private var path = NavigationPath()
    @State private var isSigningOut = false
    @State private var asksToSignOut = false
    @State private var isSigningOutEverywhere = false
    @State private var asksToSignOutEverywhere = false
    /// Said under Account when signing out everywhere did not work, so no device was signed out.
    @State private var signOutEverywhereProblem: String?
    @State private var savedCourses: [SavedCourse]?

    init(app: AppModel) {
        self.app = app
        _catalog = State(initialValue: CatalogModel(app: app))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: QBankSpacing.space7) {
                    account
                    lock
                    if catalog.isEditable {
                        semesters
                    }
                    look
                    onThisPhone
                    Text(Self.version)
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("settings.version")
                }
                .screenColumn()
                .padding(.top, QBankSpacing.space3)
                .padding(.bottom, QBankSpacing.space7)
            }
            .qbankScreenBackground()
            .navigationTitle("Settings")
            .screenColumnTitle()
            .refreshable {
                await catalog.load()
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .changePassword:
                    ChangePasswordView(app: app)
                case .connectAgent:
                    ConnectAgentView(app: app)
                case .deleteAccount:
                    DeleteAccountView(app: app)
                case .semester(let id):
                    SemesterView(catalog: catalog, id: id)
                case .savedForOffline:
                    SavedForOfflineView(app: app)
                }
            }
        }
        .task {
            guard catalog.isEditable else { return }
            await catalog.load()
        }
        .task(id: app.offline?.savedRevision) {
            savedCourses = await app.offline?.savedCourses()
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            accountRows
            if let problem = signOutEverywhereProblem {
                ProblemText(text: problem)
                    .padding(.horizontal, QBankSpacing.space5)
            }
        }
    }

    private var accountRows: some View {
        QBankListGroup(header: "Account") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed in as")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                Text(app.account?.email ?? "")
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
            }
            .frame(maxWidth: .infinity, minHeight: QBankSpacing.rowMin, alignment: .leading)
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.account")
            NavigationLink(value: SettingsRoute.changePassword) {
                QBankListRow("Change password", showsChevron: true)
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("settings.changePassword")
            NavigationLink(value: SettingsRoute.connectAgent) {
                QBankListRow("Connect an agent", detail: AgentWording.settingsDetail, showsChevron: true)
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("settings.connectAgent")
            Button {
                if app.offline?.waiting.isEmpty == false {
                    asksToSignOut = true
                } else {
                    signOut()
                }
            } label: {
                QBankListRow("Sign out", isDestructive: true) {
                    if isSigningOut {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.qbankRow)
            .disabled(isLeaving)
            .accessibilityIdentifier("settings.signOut")
            .confirmationDialog(
                "Sign out with answers still on this \(Device.noun)?",
                isPresented: $asksToSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out and delete", role: .destructive, action: signOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(waitingWarning)
            }
            // Always asked, as on the web: it signs her out of every device, this one included.
            Button {
                asksToSignOutEverywhere = true
            } label: {
                QBankListRow("Sign out everywhere", isDestructive: true) {
                    if isSigningOutEverywhere {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.qbankRow)
            .disabled(isLeaving)
            .accessibilityIdentifier("settings.signOutEverywhere")
            .confirmationDialog(
                "Sign out of QBank on every device, including this one?",
                isPresented: $asksToSignOutEverywhere,
                titleVisibility: .visible
            ) {
                let isWaiting = app.offline?.waiting.isEmpty == false
                Button(isWaiting ? "Sign out everywhere and delete" : "Sign out everywhere", role: .destructive, action: signOutEverywhere)
                Button("Cancel", role: .cancel) {}
            } message: {
                if app.offline?.waiting.isEmpty == false {
                    Text(waitingWarning)
                }
            }
            if DeleteAccountModel.isOffered(to: app.account) {
                NavigationLink(value: SettingsRoute.deleteAccount) {
                    QBankListRow("Delete account", showsChevron: true, isDestructive: true)
                }
                .buttonStyle(.qbankRow)
                .disabled(isLeaving)
                .accessibilityIdentifier("settings.deleteAccount")
            }
        }
    }

    /// While she signs out here or everywhere, nothing else on her account can start.
    private var isLeaving: Bool {
        isSigningOut || isSigningOutEverywhere
    }

    /// What a sign-out, here or everywhere, deletes from this phone: her answers not yet sent.
    private var waitingWarning: String {
        let waiting = app.offline?.waiting.count ?? 0
        return "\(Wording.count(waiting, "answer")) \(waiting == 1 ? "has" : "have") not reached QBank yet. Signing out deletes \(waiting == 1 ? "it" : "them") from this \(Device.noun)."
    }

    private func signOut() {
        isSigningOut = true
        Task { await app.signOut() }
    }

    /// Signs her out on every device, then goes to sign-in as a sign-out does. When QBank does not
    /// answer, she stays signed in here and the problem says why.
    private func signOutEverywhere() {
        isSigningOutEverywhere = true
        signOutEverywhereProblem = nil
        Task { await endEverySession() }
    }

    private func endEverySession() async {
        do {
            try await app.signOutEverywhere()
        } catch {
            signOutEverywhereProblem = Wording.problem(error)
        }
        isSigningOutEverywhere = false
    }

    /// The Face ID lock: on asks for Face ID first, so she sees it work; off needs nothing. A
    /// device with no passcode cannot lock, and says how to change that.
    private var lock: some View {
        let lock = app.lock
        let method = lock.method
        let isOn = Binding {
            lock.isEnabled || lock.isChecking
        } set: { on in
            if on {
                Task { await lock.turnOn() }
            } else {
                lock.turnOff()
            }
        }
        let footer = if let method {
            method == .passcode
                ? "QBank asks for your passcode when it opens and each time you come back to it."
                : "QBank asks for \(method.name) when it opens and each time you come back to it. Your passcode works too."
        } else {
            "Set a passcode for this \(Device.model) in the Settings app to lock QBank."
        }
        return QBankListGroup(header: "Lock", footer: footer) {
            Toggle(isOn: isOn) {
                Text("Lock with \(method?.name ?? "Face ID")")
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
            }
            .disabled(lock.isChecking || (method == nil && !lock.isEnabled))
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 11)
            .frame(minHeight: QBankSpacing.rowMin)
            .accessibilityIdentifier("settings.lock")
        }
        .onAppear { lock.refresh() }
    }

    private var semesters: some View {
        QBankListGroup(
            header: "Semesters and courses",
            footer: "Open a semester for its name and dates. Add from Home's +; rename, move or archive a course by holding it on Home."
        ) {
            if let semesters = catalog.semesters {
                if semesters.isEmpty {
                    Text("No semesters yet. Add one from Home's +.")
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text3))
                        .frame(maxWidth: .infinity, minHeight: QBankSpacing.rowMin, alignment: .leading)
                        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
                        .padding(.vertical, 11)
                }
                ForEach(semesters) { semester in
                    NavigationLink(value: SettingsRoute.semester(semester.id)) {
                        QBankListRow(semester.name, detail: CatalogModel.summary(of: semester), showsChevron: true)
                    }
                    .buttonStyle(.qbankRow)
                    .accessibilityIdentifier("settings.semester.\(semester.number)")
                }
            } else if let problem = catalog.loadProblem {
                QBankListRow(problem, accessibilityChildren: .contain) {
                    Button("Try again") {
                        Task { await catalog.load() }
                    }
                    .buttonStyle(.qbank(.secondary, size: .small))
                    .accessibilityIdentifier("settings.semesters.retry")
                }
            } else {
                QBankListRow("Loading your semesters") {
                    ProgressView()
                }
            }
        }
    }

    /// Look, kept on this phone, and Color, which goes with her account to every device, as on the web.
    private var look: some View {
        @Bindable var store = app.look
        let palette = Binding {
            app.palette
        } set: { palette in
            Task { await app.pickPalette(palette) }
        }
        return VStack(alignment: .leading, spacing: QBankSpacing.space3) {
            QBankListGroup(
                header: "Look",
                footer: "Match device follows this device's light or dark setting. Color goes with your account to every device."
            ) {
                field("Look") {
                    QBankSegmentedControl("Look", selection: $store.look, options: Look.allCases.map { .init($0, $0.label) })
                        .accessibilityIdentifier("settings.look")
                }
                field("Color") {
                    QBankSegmentedControl("Color", selection: palette, options: Account.Palette.allCases.map { .init($0, $0.label) })
                        .accessibilityIdentifier("settings.color")
                }
            }
            if let problem = app.paletteProblem {
                ProblemText(text: problem)
                    .padding(.horizontal, QBankSpacing.space5)
            }
        }
    }

    /// A control with its name above it, as the web's labeled fields.
    private func field(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space2) {
            Text(label)
                .qbankFont(.footnote)
                .foregroundStyle(.qbank(.text3))
                // In line with the rows' text, 16pt in from the card.
                .padding(.horizontal, QBankSpacing.rowPaddingHorizontal - QBankSpacing.space3)
                .accessibilityHidden(true)
            control()
        }
        .padding(QBankSpacing.space3)
    }

    private var onThisPhone: some View {
        let waiting = app.offline?.waiting.count ?? 0
        return QBankListGroup(header: "On this \(Device.noun)") {
            NavigationLink(value: SettingsRoute.savedForOffline) {
                QBankListRow(
                    "Saved for offline",
                    detail: savedCourses.map { Wording.savedCourses($0) },
                    value: waiting > 0 ? "\(waiting) waiting" : nil,
                    showsChevron: true
                )
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("settings.savedForOffline")
        }
    }

    /// "QBank 0.1.0 (1)": the version and build, as Settings shows it.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "QBank \(version) (\(build))"
    }
}
