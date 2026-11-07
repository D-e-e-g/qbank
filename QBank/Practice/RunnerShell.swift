import QBankDesign
import QBankKit
import SwiftUI

/// The runner's frame, shared by practice and exams: a leading action (✕, or End exam), the
/// question count over the title, a trailing item (the exam timer), the progress track, the
/// scrolling question, and the pinned footer actions. Content scrolls under both bars.
struct RunnerShell<Leading: View, Trailing: View, Content: View, Footer: View>: View {
    let count: String
    let title: String
    let progress: Double
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Above the top padding, so scrolling back to it shows the gap under the header.
                    Color.clear.frame(height: 0).id(RunnerScroll.top)
                    content
                        .padding(.top, 20)
                }
                .frame(maxWidth: QBankLayout.contentMax, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Device.gutter)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.never)
            .environment(\.runnerScroll, RunnerScroll(proxy: proxy))
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    footer
                }
                .frame(maxWidth: QBankLayout.contentMax)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Device.gutter)
                .padding(.vertical, QBankSpacing.space4)
                .background { RunnerBar(edge: .top) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            CenteredBar {
                leading
                VStack(spacing: 0) {
                    Text(count)
                        .qbankFont(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.qbank(.text1))
                    Text(title)
                        .qbankFont(.caption1)
                        .foregroundStyle(.qbank(.text3))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("practice.count")
                trailing
            }
            .padding(.horizontal, QBankSpacing.space3)
            .frame(minHeight: 48)
            QBankProgressBar(value: progress, height: 3, accessibilityTitle: "Progress")
                .padding(.horizontal, Device.gutter)
                .padding(.bottom, QBankSpacing.space3)
        }
        .background { RunnerBar(edge: .bottom) }
    }
}

extension RunnerShell where Leading == RunnerCloseButton, Trailing == EmptyBarItem {
    /// The practice runner's frame: ✕ on the left, nothing on the right.
    init(
        count: String,
        title: String,
        progress: Double,
        close: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(count: count, title: title, progress: progress) {
            RunnerCloseButton(action: close)
        } trailing: {
            EmptyBarItem()
        } content: {
            content()
        } footer: {
            footer()
        }
    }
}

/// The runner's ✕.
struct RunnerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .foregroundStyle(.qbank(.text2))
        .accessibilityLabel("Close")
        .accessibilityIdentifier("practice.close")
    }
}

/// Nothing, at a bar's trailing edge. The title stays centered either way.
struct EmptyBarItem: View {
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

/// Lays out three views as a bar: the first at the leading edge, the last at the trailing edge,
/// and the middle one centered on the bar, as wide as the wider side leaves it.
private struct CenteredBar: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: proposal.width ?? sizes.reduce(0) { $0 + $1.width }, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let side = max(leading.width, trailing.width)
        let middleWidth = max(0, bounds.width - 2 * side - 2 * QBankSpacing.space2)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: middleWidth, height: bounds.height)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
    }
}

/// The translucent bar behind the runner's header and footer, with a hairline on the side that
/// meets the question.
struct RunnerBar: View {
    let edge: VerticalEdge

    var body: some View {
        Rectangle()
            .fill(.qbank(.material))
            .background(.ultraThinMaterial)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle()
                    .fill(.qbank(.separator))
                    .frame(height: QBankBorder.hairline)
            }
            .ignoresSafeArea()
    }
}

/// Lets a question scroll the runner: back to the top for a new question, and to the verdict
/// when she checks.
struct RunnerScroll {
    static let top = "practice.top"
    static let feedback = "practice.feedback"

    var proxy: ScrollViewProxy?

    func scroll(to id: String, anchor: UnitPoint? = nil) {
        proxy?.scrollTo(id, anchor: anchor)
    }
}

extension EnvironmentValues {
    @Entry var runnerScroll = RunnerScroll()
}

/// A short line in place of the question: loading, a problem, or nothing to answer.
struct RunnerNote: View {
    /// Keeps a note floating over the runner clear of its pinned footer: a large button and its padding.
    static let footerClearance: CGFloat = 84

    let text: String

    var body: some View {
        Text(text)
            .qbankFont(.body)
            .foregroundStyle(.qbank(.text2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("practice.note")
    }
}

/// "No connection. Your answer is saved as soon as you are back online."
struct WaitingBanner: View {
    var body: some View {
        Label {
            Text("No connection. Your answer is saved as soon as you are back online.")
                .foregroundStyle(.qbank(.text1))
        } icon: {
            Image(systemName: "clock")
                .foregroundStyle(.qbank(.tint))
        }
        .qbankFont(.subheadline)
        .padding(.vertical, QBankSpacing.space4)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(.tintSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
        .accessibilityIdentifier("practice.waiting")
    }
}

/// The format in the tint, then the topic, over the stem: "Matrix   Phases of the relationship".
struct QuestionMeta<Extra: View>: View {
    let question: Question
    @ViewBuilder let extra: Extra

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: QBankSpacing.space2, rowAlignment: .firstTextBaseline) {
            Text(Wording.format(question.type))
                .foregroundStyle(.qbank(.tint))
            if !question.topic.isEmpty {
                Text(question.topic)
                    .foregroundStyle(.qbank(.text3))
            }
            extra
        }
        .qbankFont(.footnote, weight: .semibold)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("practice.meta")
    }
}

extension QuestionMeta where Extra == EmptyView {
    init(question: Question) {
        self.init(question: question) { EmptyView() }
    }
}

/// "I'm guessing · Flag for review": a guess stays in Review even when it was right.
struct GuessToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text("I'm guessing")
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                Text("Flag for review")
                    .qbankFont(.caption1)
                    .foregroundStyle(.qbank(.text3))
            }
        }
        .toggleStyle(GuessToggleStyle())
        .accessibilityIdentifier("practice.guess")
    }
}

private struct GuessToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: QBankSpacing.space4) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.qbank(configuration.isOn ? .guess : .surface))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.qbank(.textOnTint))
                        } else {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.emphasis)
                        }
                    }
                    .frame(width: 22, height: 22)
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(minHeight: QBankSpacing.rowMin)
            .background(.qbank(.guessSoft), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                    .strokeBorder(.qbank(.guessBorder), lineWidth: QBankBorder.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
