#if DEBUG
import SwiftUI

/// What a UI test's launch shows in place of the system browser view: the address it was asked to
/// open and a Done button, so a test checks which page a row opens without a network. Compiled
/// only into Debug builds.
struct DebugWebPageStandIn: View {
    let url: URL
    let close: () -> Void

    /// Whether this launch runs a scenario, which every UI test does.
    static var isOn: Bool {
        ProcessInfo.processInfo.environment[DebugLaunchScenario.scenarioKey] != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(url.absoluteString)
                .accessibilityIdentifier("webpage.address")
            Button("Done", action: close)
                .accessibilityIdentifier("webpage.done")
        }
        .padding()
    }
}
#endif
