import QBankDesign
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.route {
            case .signedOut:
                SignedOutView(app: model)
                    .transition(.opacity)
            case .choosingPassword:
                ChoosePasswordView(app: model)
                    .transition(.opacity)
            case .signedIn(let account):
                SignedInView(app: model)
                    // A new sign-in starts from fresh screens, even one made while the screens of
                    // the same account's sign-out still fade.
                    .id("\(account.id) \(model.signIns)")
                    .transition(.opacity)
            }
        }
        .animation(QBankMotion.reveal, value: model.route)
        .tint(QBankColor(.tint))
        // Her account's color scheme, on every screen and sheet; Dusk on the sign-in screen.
        .qbankPalette(model.palette.design)
        .background(WindowLook(look: model.look.look))
        .background(
            LockWindow(
                lock: model.lock, look: model.look.look, palette: model.palette.design, hasAccount: model.account != nil,
                isLocked: model.account != nil && model.lock.isLocked
            )
        )
        .task {
            // A session kept from an earlier launch: check the server still accepts it.
            await model.refreshSession()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back to the front: answers left waiting may go now.
            if phase == .active {
                model.offline?.sendIfWaiting()
            }
        }
    }
}

/// The three tabs: Home, Add (make or import questions), and Settings.
struct SignedInView: View {
    let app: AppModel
    @State private var tabs = TabNavigator()

    var body: some View {
        TabView(selection: $tabs.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView(app: app, navigator: tabs.home)
            }
            Tab("Add", systemImage: "plus.circle", value: AppTab.add) {
                AddView(app: app)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(app: app)
            }
        }
        .overlay(alignment: .top) {
            FrozenLine(frozen: app.frozen)
        }
        .environment(tabs)
    }
}
