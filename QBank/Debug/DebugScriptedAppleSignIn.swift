#if DEBUG
import Foundation

/// The scripted Sign in with Apple of a launch scenario: the stand-in a UI test drives in place of
/// Apple's sheet, so a test never reaches Apple or uses a real Apple Account. It is the place the
/// pull request that adds Sign in with Apple fills in; until then it holds nothing and no scenario
/// reads it. Reached from `DebugScenarioContext.appleSignIn`. Compiled only into Debug builds.
final class DebugScriptedAppleSignIn {
    /// The environment variable a test sets to script the sheet's answer, read once Sign in with
    /// Apple exists.
    static let scriptKey = "QB_UITEST_APPLE"
}
#endif
