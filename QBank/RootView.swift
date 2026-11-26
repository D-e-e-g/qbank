import QBankDesign
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A stack, so a screen the route left keeps its place in front while it fades out.
        ZStack {
            switch model.route {
            case .signedOut:
                WelcomeView(app: model)
                    .routeScreen(of: model)
            case .choosingPassword:
                ChoosePasswordView(app: model)
                    .routeScreen(of: model)
            case .signedIn:
                SignedInView(app: model)
                    .routeScreen(of: model)
            case .finishingDeletion:
                // This phone's copy of a store account is erased and the server has not deleted the
                // account yet: finishing the delete or signing out is offered.
                NavigationStack {
                    AppleDeleteAccountView(app: model)
                }
                .routeScreen(of: model)
            }
        }
        .animation(QBankMotion.reveal, value: model.route)
        // The bank moving between this phone and QBank Cloud covers the app until the outcome is read.
        .fullScreenCover(isPresented: .constant(model.cloudScreenIsShown)) {
            CloudCoverView(app: model)
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
        // Each screen the route shows runs it once.
        .task(id: model.screen) {
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

private extension View {
    /// Shows this as the screen of the route, `AppModel.screen`. When the route changes, the screen
    /// coming in is drawn at once, under the screen going out, which fades away over it and takes no
    /// touches, so a tap during the fade, such as Sign in with Apple right after a sign-out or a
    /// delete, reaches the screen coming in. Fading the screen coming in instead would leave its UIKit
    /// views, the scroll view and the Sign in with Apple button among them, deaf to touches until the
    /// fade ends.
    func routeScreen(of app: AppModel) -> some View {
        RouteScreen(app: app) { self }
            .id(app.screen)
            .transition(RouteChange())
            // Lower with each change, so the screens fading out stay in front of the one coming in.
            .zIndex(-Double(app.routeChanges))
    }
}

/// One screen of the route, which takes touches only while it is the screen the route shows.
private struct RouteScreen<Content: View>: View {
    let app: AppModel
    /// The screen this is: the app's screen when the route showed it, kept while it fades out.
    private let screen: String
    private let content: Content

    init(app: AppModel, @ViewBuilder content: () -> Content) {
        self.app = app
        screen = app.screen
        self.content = content()
    }

    var body: some View {
        // A screen fading out still follows the app, so it stops taking touches as soon as the route
        // leaves it.
        content
            .allowsHitTesting(app.screen == screen)
    }
}

/// The screen coming in shows at once; the screen going out fades away.
private struct RouteChange: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase == .didDisappear ? 0 : 1)
    }
}

private extension AppModel {
    /// Which screen the route shows: one for each route, and for a signed-in account one for each
    /// sign-in, kind of account, phone key and bank revision. A new sign-in starts from fresh screens,
    /// even one made while the screens of the same account's sign-out still fade. The server
    /// confirming a Sign in with Apple keeps them: the person, and so the phone's key, is the same. A
    /// bank that moved to QBank Cloud starts them afresh too, under the move's screen, so each reads
    /// the bank where it is now, and so does a bank that another file took the place of, or that sets
    /// were added to under a screen over the app.
    var screen: String {
        switch route {
        case .signedOut: "signed out"
        case .choosingPassword: "choosing password"
        case .signedIn(let account): "signed in \(phoneKey ?? account.id) \(signIns) \(kind.rawValue) \(bankRevision)"
        case .finishingDeletion: "finishing deletion"
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
