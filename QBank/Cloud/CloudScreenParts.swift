import QBankDesign
import QBankKit
import SwiftUI

/// The screen over the app while the bank moves between this phone and QBank Cloud: the move to QBank
/// Cloud, taking QBank Cloud's bank, or bringing the bank back. One is shown at a time, the one under
/// way, and none can be closed while it runs, so nothing in the app changes the bank meanwhile.
struct CloudCoverView: View {
    let app: AppModel

    var body: some View {
        if app.cloudReturn.isShown {
            CloudReturnView(app: app)
        } else if app.cloudAdopt.isShown {
            CloudAdoptView(app: app)
        } else {
            CloudMoveView(app: app)
        }
    }
}

/// The page every Cloud screen is drawn on: one column that scrolls, on the screen's background.
struct CloudPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: QBankSpacing.space5) {
                content
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space10)
            .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .interactiveDismissDisabled()
    }
}

/// The round mark at the top of a Cloud screen, in the tone of how things stand.
struct CloudMark: View {
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

/// A Cloud screen's title, read as its header.
struct CloudHeading: View {
    let text: String
    let id: String

    init(_ text: String, id: String) {
        self.text = text
        self.id = id
    }

    var body: some View {
        Text(text)
            .qbankFont(.title1)
            .foregroundStyle(.qbank(.text1))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
    }
}

/// The lines under a Cloud screen's title.
struct CloudLead: View {
    let text: String
    var id: String?

    init(_ text: String, id: String? = nil) {
        self.text = text
        self.id = id
    }

    var body: some View {
        let lead = Text(text)
            .qbankFont(.callout)
            .foregroundStyle(.qbank(.text2))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
        if let id {
            lead.accessibilityIdentifier(id)
        } else {
            lead
        }
    }
}

/// A bank's sets, questions and answers, as the person counts them, each row identified as
/// `<prefix>.count.<key>`.
struct CloudCounts: View {
    let summary: BankSummary
    var header: String?
    let prefix: String

    var body: some View {
        if let header {
            QBankListGroup(header: header) { rows }
        } else {
            QBankListGroup { rows }
        }
    }

    private var rows: some View {
        ForEach(CloudMoveWording.shown(summary), id: \.key) { shown in
            QBankListRow(shown.label, value: shown.value.formatted())
                .accessibilityIdentifier("\(prefix).count.\(shown.key)")
        }
    }
}

/// A note with an icon at its side, such as where the safety copy is.
struct CloudNote: View {
    let text: String
    let systemImage: String
    let id: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .qbankFont(.subheadline)
            .foregroundStyle(.qbank(.text2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }
}

/// One step of a move, done, in progress or waiting, by its place among `order`.
struct CloudStepRow<Step: Hashable>: View {
    let title: String
    let step: Step
    let current: Step
    let order: [Step]
    let id: String

    var body: some View {
        let mine = order.firstIndex(of: step) ?? 0
        let now = order.firstIndex(of: current) ?? 0
        let state = mine < now ? "Done" : mine == now ? "In progress" : "Waiting"
        QBankListRow(title, accessibilityChildren: .ignore) {
            Group {
                if mine < now {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.qbank(.correct))
                } else if mine == now {
                    ProgressView()
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.qbank(.text4))
                }
            }
            .font(.title3)
            .frame(width: 24)
        }
        .accessibilityLabel(title)
        .accessibilityValue(state)
        .accessibilityIdentifier(id)
    }
}

/// Why a Cloud screen stopped, in a card, with what stayed as it was.
struct CloudProblemCard: View {
    let problem: String
    let unchanged: String
    let prefix: String

    var body: some View {
        QBankCard {
            VStack(alignment: .leading, spacing: QBankSpacing.space3) {
                Text(problem)
                    .qbankFont(.body)
                    .foregroundStyle(.qbank(.text1))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix).problem")
                Text(unchanged)
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix).unchanged")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
