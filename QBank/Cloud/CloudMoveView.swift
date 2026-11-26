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
        ScrollView {
            VStack(spacing: QBankSpacing.space5) {
                switch move.phase {
                case .idle, .moving:
                    moving(move.phase)
                case .moved(let counts):
                    moved(counts)
                case .failed(let problem, let canRetry):
                    failed(problem, canRetry: canRetry)
                }
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space10)
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .interactiveDismissDisabled()
    }

    // MARK: Moving

    private func moving(_ phase: CloudMoveModel.Phase) -> some View {
        let current: BankMoveToCloud.Step = if case .moving(let step) = phase { step } else { .writing }
        return VStack(spacing: QBankSpacing.space5) {
            Mark(systemImage: "icloud.and.arrow.up", tone: .tint)
            heading(CloudMoveWording.movingTitle, id: "cloudMove.moving")
            lines(move.isResumed ? CloudMoveWording.resumedNote : CloudMoveWording.movingNote)
            QBankListGroup {
                ForEach(Self.steps, id: \.self) { step in
                    stepRow(step, current: current)
                }
            }
        }
    }

    private static let steps: [BankMoveToCloud.Step] = [.writing, .sending, .checking]

    private func stepRow(_ step: BankMoveToCloud.Step, current: BankMoveToCloud.Step) -> some View {
        let order = Self.steps.firstIndex(of: step) ?? 0
        let now = Self.steps.firstIndex(of: current) ?? 0
        let state = order < now ? "Done" : order == now ? "In progress" : "Waiting"
        return QBankListRow(CloudMoveWording.step(step), accessibilityChildren: .ignore) {
            Group {
                if order < now {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.qbank(.correct))
                } else if order == now {
                    ProgressView()
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.qbank(.text4))
                }
            }
            .font(.title3)
            .frame(width: 24)
        }
        .accessibilityLabel(CloudMoveWording.step(step))
        .accessibilityValue(state)
        .accessibilityIdentifier("cloudMove.step.\(step)")
    }

    // MARK: Moved

    private func moved(_ counts: BankCounts) -> some View {
        VStack(spacing: QBankSpacing.space5) {
            Mark(systemImage: "checkmark.icloud", tone: .correct)
            heading(CloudMoveWording.movedTitle, id: "cloudMove.moved")
            lines(CloudMoveWording.movedBody)
            QBankListGroup {
                ForEach(CloudMoveWording.shownCounts, id: \.table) { shown in
                    QBankListRow(shown.label, value: (counts[shown.table] ?? 0).formatted())
                        .accessibilityIdentifier("cloudMove.count.\(shown.table)")
                }
            }
            Label(CloudMoveWording.safetyCopy, systemImage: "iphone")
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloudMove.safetyCopy")
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
            Mark(systemImage: "exclamationmark.icloud", tone: .partial)
            heading(CloudMoveWording.failedTitle, id: "cloudMove.failed")
            QBankCard {
                VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                    Text(problem)
                        .qbankFont(.body)
                        .foregroundStyle(.qbank(.text1))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloudMove.problem")
                    Text(CloudMoveWording.unchanged)
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloudMove.unchanged")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    // MARK: Parts

    private func heading(_ text: String, id: String) -> some View {
        Text(text)
            .qbankFont(.title1)
            .foregroundStyle(.qbank(.text1))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
    }

    private func lines(_ text: String) -> some View {
        Text(text)
            .qbankFont(.callout)
            .foregroundStyle(.qbank(.text2))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
    }

    /// The round mark at the top of the screen, in the tone of how the move stands.
    private struct Mark: View {
        enum Tone {
            case tint, correct, partial
        }

        let systemImage: String
        let tone: Tone

        var body: some View {
            let (color, fill): (QBankColorToken, QBankColorToken) =
                switch tone {
                case .tint: (.tint, .tintSoft)
                case .correct: (.correct, .correctSoft)
                case .partial: (.partial, .partialSoft)
                }
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.qbank(color))
                .frame(width: 64, height: 64)
                .background(.qbank(fill), in: .circle)
                .accessibilityHidden(true)
        }
    }
}
