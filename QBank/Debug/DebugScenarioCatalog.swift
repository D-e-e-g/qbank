#if DEBUG
import Foundation

/// Every scenario the Debug launch seam knows. A new scenario is a new file under
/// `QBank/Debug/Scenarios/` with a `DebugScenario` static member, and one line here; neither
/// `DebugLaunchScenario` nor the UI test helpers change.
nonisolated enum DebugScenarioCatalog {
    static let all: [DebugScenario] = [
        .signedOut,
        .signedIn,
        .examInProgress,
        .examFinishDrops,
        .examTimeRunningOut,
        .slowSaves,
        .maker,
        .makerNotSetUp,
        .owner,
        .ownerExamInProgress,
        .matrixMulti,
        .sataAllCorrect,
        .freeNewBank,
        .freeFirstLaunch,
        .storedSessionBeforeUpdate,
        .cloudMoveLeftOpen,
        .cloudMoveRefused,
    ]

    /// The scenario named `name`, or nil when none is.
    static func scenario(named name: String) -> DebugScenario? {
        all.first { $0.name == name }
    }
}
#endif
