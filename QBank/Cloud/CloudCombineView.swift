import QBankDesign
import QBankKit
import SwiftUI

/// The screen over the app while the bank on this iPhone is combined with the one QBank holds, and its
/// outcome: each step as it runs, then the one bank's counts with what this iPhone added, or why the
/// bank on this iPhone stays in use, with nothing removed. It cannot be closed while it runs, so
/// nothing in the app changes the bank meanwhile.
struct CloudCombineView: View {
    let app: AppModel

    private var combine: CloudCombineModel { app.cloudCombine }

    var body: some View {
        CloudPage {
            switch combine.phase {
            case .idle, .combining:
                combining(combine.phase)
            case .combined(let combined):
                done(combined)
            case .failed(let problem, let canRetry):
                failed(problem, canRetry: canRetry)
            }
        }
    }

    // MARK: Combining

    private func combining(_ phase: CloudCombineModel.Phase) -> some View {
        let current: CloudCombineModel.Step = if case .combining(let step) = phase { step } else { .reading }
        let steps = combine.direction == .up ? Self.upSteps : Self.downSteps
        return VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "arrow.triangle.merge", tone: .tint)
            CloudHeading(CloudCombineWording.combiningTitle, id: "cloudCombine.combining")
            if combine.direction == .up {
                CloudLead(CloudCombineWording.lead, id: "cloudCombine.lead")
            }
            QBankListGroup {
                ForEach(steps, id: \.self) { step in
                    CloudStepRow(title: CloudCombineWording.step(step), step: step, current: current, order: steps, id: "cloudCombine.step.\(step)")
                }
            }
            VStack(spacing: QBankSpacing.space3) {
                if combine.direction == .up {
                    CloudNote(text: CloudCombineWording.answersAdded, systemImage: "checkmark.circle", id: "cloudCombine.answers")
                }
                CloudNote(text: CloudCombineWording.safetyCopy, systemImage: Device.isPad ? "ipad" : "iphone", id: "cloudCombine.safetyCopy")
                CloudNote(text: CloudCombineWording.keepOpen, systemImage: "lock", id: "cloudCombine.keepOpen")
            }
        }
    }

    private static let upSteps: [CloudCombineModel.Step] = [.reading, .combining, .sending, .checking]
    private static let downSteps: [CloudCombineModel.Step] = [.reading, .combining, .checking]

    // MARK: Done

    private func done(_ combined: CloudCombineModel.Combined) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: combined.direction == .up ? "checkmark.icloud" : "checkmark.circle", tone: .correct)
            CloudHeading(CloudCombineWording.combinedTitle, id: "cloudCombine.combined")
            CloudLead(combined.direction == .up ? CloudCombineWording.combinedUpBody : CloudCombineWording.combinedDownBody, id: "cloudCombine.body")
            CloudCounts(summary: combined.summary, prefix: "cloudCombine")
            VStack(spacing: QBankSpacing.space3) {
                if combined.direction == .up {
                    CloudNote(
                        text: CloudCombineWording.added(sets: combined.addedSets, answers: combined.addedAnswers), systemImage: "plus.circle",
                        id: "cloudCombine.added")
                }
                if combined.changedInBoth {
                    CloudNote(text: CloudCombineWording.newerKept, systemImage: "clock.arrow.circlepath", id: "cloudCombine.newerKept")
                }
                if combined.namesKept {
                    CloudNote(text: CloudCombineWording.nameKept, systemImage: "character.cursor.ibeam", id: "cloudCombine.nameKept")
                }
            }
            Button("Done") { combine.close() }
                .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                .accessibilityIdentifier("cloudCombine.done")
                .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement(CloudCombineWording.combinedTitle).post()
        }
    }

    // MARK: Failed

    private func failed(_ problem: String, canRetry: Bool) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            CloudMark(systemImage: "exclamationmark.icloud", tone: .partial)
            CloudHeading(CloudCombineWording.failedTitle, id: "cloudCombine.failed")
            CloudProblemCard(problem: problem, unchanged: CloudCombineWording.unchanged, prefix: "cloudCombine")
            VStack(spacing: QBankSpacing.space2) {
                if canRetry {
                    Button(CloudMoveWording.tryAgain) {
                        Task { await combine.start() }
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("cloudCombine.retry")
                    Button(CloudMoveWording.ok) { combine.close() }
                        .buttonStyle(.qbank(.plain, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudCombine.later")
                } else {
                    Button(CloudMoveWording.ok) { combine.close() }
                        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                        .accessibilityIdentifier("cloudCombine.later")
                }
            }
            .padding(.top, QBankSpacing.space3)
        }
        .onAppear {
            AccessibilityNotification.Announcement("\(CloudCombineWording.failedTitle). \(problem)").post()
        }
    }
}
