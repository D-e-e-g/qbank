import QBankDesign
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.route {
            case .signedOut:
                WelcomeView(app: model)
                    .transition(.opacity)
            case .choosingPassword:
                ChoosePasswordView(app: model)
                    .transition(.opacity)
            case .signedIn(let account):
                SignedInView(app: model)
                    // A new sign-in starts from fresh screens, even one made while the screens of
                    // the same account's sign-out still fade. The server confirming a Sign in with
                    // Apple keeps them: the person, and so the phone's key, is the same. A bank that
                    // moved to QBank Cloud starts them afresh too, under the move's screen, so each
                    // reads the bank where it is now.
                    .id("\(model.phoneKey ?? account.id) \(model.signIns) \(model.kind.rawValue)")
                    .transition(.opacity)
            case .finishingDeletion:
                // This phone's copy of a store account is erased and the server has not deleted the
                // account yet: finishing the delete or signing out is offered.
                NavigationStack {
                    AppleDeleteAccountView(app: model)
                }
                .transition(.opacity)
            }
        }
        .animation(QBankMotion.reveal, value: model.route)
        // The move of the bank to QBank Cloud covers the app until its outcome is read.
        .fullScreenCover(isPresented: .constant(model.cloudMove.isShown)) {
            CloudMoveView(app: model)
        }
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
            // A move the app was closed during is finished before anything else.
            await model.cloudMove.finishLeftOpen()
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
