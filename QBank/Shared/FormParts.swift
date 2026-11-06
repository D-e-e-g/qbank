import QBankDesign
import SwiftUI

/// A labelled text field as the web's sign-in form draws it: the label above, the field in a
/// rounded box, an optional hint below.
struct LabeledField<Field: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qbankFont(.subheadline, weight: .semibold)
                .foregroundStyle(.qbank(.text2))
                .padding(.horizontal, QBankSpacing.space1)
                .accessibilityHidden(true)
            field
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .padding(.horizontal, QBankSpacing.space4)
                .frame(minHeight: QBankButtonStyle.Size.large.minHeight)
                .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                        .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
                }
            if let hint {
                Text(hint)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text3))
                    .padding(.horizontal, QBankSpacing.space1)
            }
        }
    }
}

/// A plain-words problem line, read out by VoiceOver when it appears.
struct ProblemText: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .qbankFont(.subheadline, weight: .medium)
            .foregroundStyle(.qbank(.wrong))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("problem")
            .onAppear {
                AccessibilityNotification.Announcement(text).post()
            }
    }
}

/// A plain-words line that something was saved, read out by VoiceOver when it appears.
struct SavedText: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle")
            .qbankFont(.subheadline, weight: .medium)
            .foregroundStyle(.qbank(.correct))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("saved")
            .onAppear {
                AccessibilityNotification.Announcement(text).post()
            }
    }
}

/// A screen whose first load failed: what happened, and a way to try again.
struct LoadFailed: View {
    let problem: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: QBankSpacing.space4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.qbank(.text3))
                .accessibilityHidden(true)
            Text(problem)
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text2))
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.qbank(.secondary))
                .accessibilityIdentifier("loadFailed.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, QBankSpacing.space7)
    }
}

/// A screen that is still loading.
struct Loading: View {
    let title: String

    var body: some View {
        ProgressView {
            Text(title)
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// An empty card with an icon and a sentence, such as a semester without courses, and under them
/// the next step when the card has one.
struct EmptyCard<Action: View>: View {
    let message: String
    var systemImage = "square.stack.3d.up"
    @ViewBuilder var action: Action

    var body: some View {
        QBankCard(padding: QBankSpacing.space4) {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                HStack(spacing: QBankSpacing.space4) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.qbank(.text3))
                        .frame(width: 28, height: 28)
                        .background(.qbank(.surfaceSunken), in: .circle)
                        .accessibilityHidden(true)
                    Text(message)
                        .qbankFont(.subheadline)
                        .foregroundStyle(.qbank(.text2))
                }
                action
                    .padding(.leading, 28 + QBankSpacing.space4)
            }
        }
    }
}

extension EmptyCard where Action == EmptyView {
    init(message: String, systemImage: String = "square.stack.3d.up") {
        self.init(message: message, systemImage: systemImage) { EmptyView() }
    }
}
