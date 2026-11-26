import QBankDesign
import QBankKit
import SwiftUI

/// The screen over the app while the bank comes back from QBank Cloud once Cloud has ended, and its
/// outcome: each step as it runs, then either the counts this iPhone holds, the same as QBank Cloud's,
/// or why QBank Cloud's bank stays in use, with nothing changed. It cannot be closed while it runs.
struct CloudReturnView: View {
    let app: AppModel

    private var handBack: CloudReturnModel { app.cloudReturn }

    var body: some View {
        CloudPage {
            switch handBack.phase {
            case .offered(let summary):
                offered(summary)
            case .idle, .returning:
                returning(handBack.phase)
            case .returned(let summary):
                returned(summary)
            case .failed(let problem, let canRetry):
                failed(problem, canRetry: canRetry)
            }
        }
    }

    // MARK: Offered

    private func offered(_ summary: BankSummary) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "icloud.and.arrow.down", tone: .tint)
            CloudHeading(CloudReturnWording.offeredTitle, id: "cloudReturn.offered")
            CloudLead(CloudReturnWording.offeredBody, id: "cloudReturn.offeredBody")
            CloudCounts(summary: summary, header: "In QBank", prefix: "cloudReturn")
            CloudNote(text: CloudReturnWording.offeredEarlierCopy, systemImage: "lock.iphone", id: "cloudReturn.earlierCopy")
            VStack(spacing: QBankSpacing.space2) {
                Button(CloudReturnWording.bringIt) {
                    Task { await handBack.start() }
                }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("cloudReturn.bring")
                Button(CloudReturnWording.notNow) { handBack.close() }
                    .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudReturn.later")
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudReturnWording.offeredTitle).post()
        }
    }

    // MARK: Returning

    private func returning(_ phase: CloudReturnModel.Phase) -> some View {
        let current: BankHandBack.Step = if case .returning(let step) = phase { step } else { .downloading }
        return VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "icloud.and.arrow.down", tone: .tint)
            CloudHeading(handBack.bringsHere ? CloudReturnWording.bringingTitle : CloudReturnWording.returningTitle, id: "cloudReturn.returning")
            CloudLead(handBack.bringsHere ? CloudReturnWording.bringingNote : CloudReturnWording.returningNote, id: "cloudReturn.note")
            QBankListGroup {
                ForEach(Self.steps, id: \.self) { step in
                    CloudStepRow(title: CloudReturnWording.step(step), step: step, current: current, order: Self.steps, id: "cloudReturn.step.\(step)")
                }
            }
        }
    }

    private static let steps: [BankHandBack.Step] = [.downloading, .writing, .checking]

    // MARK: Returned

    private func returned(_ summary: BankSummary?) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "checkmark.circle", tone: .correct)
            CloudHeading(CloudReturnWording.returnedTitle, id: "cloudReturn.returned")
            CloudLead(CloudReturnWording.returnedBody)
            if let summary { CloudCounts(summary: summary, prefix: "cloudReturn") }
            CloudNote(text: CloudReturnWording.cloudKept, systemImage: "icloud", id: "cloudReturn.cloudKept")
            if app.cloudAdopt.offeredCount > 0 {
                CloudNote(text: CloudReturnWording.earlierCopyOffered(app.cloudAdopt.offeredCount), systemImage: "plus.square.on.square", id: "cloudReturn.earlierCopy")
            }
            Button("Done") { handBack.close() }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("cloudReturn.done")
                .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudReturnWording.returnedTitle).post()
        }
    }

    // MARK: Failed

    private func failed(_ problem: String, canRetry: Bool) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "exclamationmark.icloud", tone: .partial)
            CloudHeading(handBack.bringsHere ? CloudReturnWording.notBroughtTitle : CloudReturnWording.failedTitle, id: "cloudReturn.failed")
            CloudProblemCard(problem: problem, unchanged: CloudReturnWording.unchanged, prefix: "cloudReturn")
            VStack(spacing: QBankSpacing.space2) {
                if canRetry {
                    Button(CloudMoveWording.tryAgain) {
                        Task { await handBack.start() }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudReturn.retry")
                    Button(CloudMoveWording.notNow) { handBack.close() }
                        .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudReturn.later")
                } else {
                    Button(CloudMoveWording.ok) { handBack.close() }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudReturn.later")
                }
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement("\(handBack.bringsHere ? CloudReturnWording.notBroughtTitle : CloudReturnWording.failedTitle). \(problem)").post()
        }
    }
}
