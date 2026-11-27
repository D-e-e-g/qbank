import QBankDesign
import QBankKit
import SwiftUI

/// The screen over the app while the bank moves to QBank Cloud, and its outcome: each step as it runs,
/// then either the counts QBank Cloud holds, the same as this iPhone's, or why the bank stays on this
/// iPhone, unchanged. It cannot be closed while the move runs, so nothing in the app changes the bank.
struct CloudMoveView: View {
    let app: AppModel

    private var move: CloudMoveModel { app.cloudMove }

    var body: some View {
        CloudPage {
            switch move.phase {
            case .idle, .moving:
                moving(move.phase)
            case .moved(let counts):
                moved(counts)
            case .failed(let problem, let canRetry):
                failed(problem, canRetry: canRetry)
            }
        }
    }

    // MARK: Moving

    private func moving(_ phase: CloudMoveModel.Phase) -> some View {
        let current: BankMoveToCloud.Step = if case .moving(let step) = phase { step } else { .writing }
        return VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "icloud.and.arrow.up", tone: .tint)
            CloudHeading(CloudMoveWording.movingTitle, id: "cloudMove.moving")
            CloudLead(move.isResumed ? CloudMoveWording.resumedNote : CloudMoveWording.movingNote)
            QBankListGroup {
                ForEach(Self.steps, id: \.self) { step in
                    CloudStepRow(title: CloudMoveWording.step(step), step: step, current: current, order: Self.steps, id: "cloudMove.step.\(step)")
                }
            }
        }
    }

    private static let steps: [BankMoveToCloud.Step] = [.writing, .sending, .checking]

    // MARK: Moved

    private func moved(_ summary: BankSummary?) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "checkmark.icloud", tone: .correct)
            CloudHeading(CloudMoveWording.movedTitle, id: "cloudMove.moved")
            CloudLead(CloudMoveWording.movedBody)
            if let summary { CloudCounts(summary: summary, prefix: "cloudMove") }
            CloudNote(text: CloudMoveWording.safetyCopy, systemImage: "iphone", id: "cloudMove.safetyCopy")
            Button("Done") { move.close() }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("cloudMove.done")
                .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudMoveWording.movedTitle).post()
        }
    }

    // MARK: Failed

    private func failed(_ problem: String, canRetry: Bool) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "exclamationmark.icloud", tone: .partial)
            CloudHeading(CloudMoveWording.failedTitle, id: "cloudMove.failed")
            CloudProblemCard(problem: problem, unchanged: CloudMoveWording.unchanged, prefix: "cloudMove")
            VStack(spacing: QBankSpacing.space2) {
                if canRetry {
                    Button(CloudMoveWording.tryAgain) {
                        Task { await move.start() }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudMove.retry")
                    Button(CloudMoveWording.notNow) { move.close() }
                        .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudMove.later")
                } else {
                    Button(CloudMoveWording.ok) { move.close() }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudMove.later")
                }
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement("\(CloudMoveWording.failedTitle). \(problem)").post()
        }
    }
}
