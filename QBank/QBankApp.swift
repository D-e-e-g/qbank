import SwiftUI

@main
struct QBankApp: App {
    @State private var model = AppModel.launch()
    /// All of QBank's windows in one, as an iPad can have several: active while any of them is,
    /// and in the background only once every one of them is.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The lock locks once QBank is in the background, and asks for Face ID at launch and on
            // the way back. Another window opening or closing on an iPad changes nothing.
            switch phase {
            case .active:
                #if DEBUG
                DebugLaunchScenario.prepareForUITest()
                #endif
                Task { await model.becameActive() }
            case .background:
                model.lock.enteredBackground()
            default:
                break
            }
        }
    }
}
