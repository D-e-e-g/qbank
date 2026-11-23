#if DEBUG
import Foundation

/// The fake store of a launch scenario: the stand-in a UI test drives in place of StoreKit, so a
/// test never reaches the App Store or makes a purchase. It is the place the pull request that
/// adds Cloud plans fills in; until then it holds nothing and no scenario reads it. Reached from
/// `DebugScenarioContext.store`. Compiled only into Debug builds.
final class DebugFakeStore {
    /// The environment variable a test sets to script the store, read once the store exists.
    static let scriptKey = "QB_UITEST_STORE"
}
#endif
