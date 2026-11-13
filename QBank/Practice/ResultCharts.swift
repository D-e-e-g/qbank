import QBankDesign
import SwiftUI

/// The result's split bar: fully right, partly right and missed side by side, each as wide as its
/// share, in the chart colors. The counts are in the tiles under it, which carry the same colors.
struct ResultSplitBar: View {
    struct Segment: Equatable {
        let count: Int
        let color: QBankColorToken
    }

    let segments: [Segment]

    var body: some View {
        let shown = segments.filter { $0.count > 0 }
        let total = shown.reduce(0) { $0 + $1.count }
        GeometryReader { proxy in
            let room = max(0, proxy.size.width - CGFloat(max(0, shown.count - 1)) * 2)
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, segment in
                    UnevenRoundedRectangle(
                        topLeadingRadius: index == 0 ? 4 : 0,
                        bottomLeadingRadius: index == 0 ? 4 : 0,
                        bottomTrailingRadius: index == shown.count - 1 ? 4 : 0,
                        topTrailingRadius: index == shown.count - 1 ? 4 : 0,
                        style: .continuous
                    )
                    .fill(.qbank(segment.color))
                    .frame(width: total == 0 ? 0 : room * CGFloat(segment.count) / CGFloat(total))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A count with its label under it and a dot of its chart color: "8 ● Fully right".
struct ResultTile: View {
    let value: Int
    let label: String
    let dot: QBankColorToken
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .qbankFont(.title3, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.qbank(.text1))
            HStack(spacing: 6) {
                Circle()
                    .fill(.qbank(dot))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(label)
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(QBankSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.qbank(.surface), in: .rect(cornerRadius: QBankRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// A breakdown row: its label and "3 of 4", with a meter of the share right under them.
struct ResultStepRow: View {
    let label: String
    var detail: String?
    let right: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: QBankSpacing.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .qbankFont(.subheadline, weight: .medium)
                        .foregroundStyle(.qbank(.text1))
                    if let detail {
                        Text(detail)
                            .qbankFont(.footnote)
                            .foregroundStyle(.qbank(.text2))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(right) of \(total)")
                    .qbankFont(.subheadline, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.qbank(.text1))
            }
            Capsule()
                .fill(.qbank(.tintSoftBorder))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.qbank(.tint))
                            .frame(width: total == 0 ? 0 : proxy.size.width * CGFloat(min(right, total)) / CGFloat(total))
                    }
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, QBankSpacing.rowPaddingVertical)
        .frame(minHeight: QBankSpacing.rowMin)
        .accessibilityElement(children: .combine)
    }
}
