import QBankDesign
import QBankKit
import SwiftUI
import UIKit

// MARK: Matrix

/// One card per row with a pill for each column, never a cramped table on a phone.
struct MatrixList: View {
    let columns: [String]
    let rows: [MatrixRow]
    let selected: [String?]
    let revealed: Bool
    let isLocked: Bool
    let choose: (Int, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                let value = selected.indices.contains(row) ? selected[row] : nil
                AnswerCard(label: rows[row].text, part: .answer(row)) {
                    FlowLayout(spacing: QBankSpacing.space3, lineSpacing: QBankSpacing.space3) {
                        ForEach(columns, id: \.self) { column in
                            let picked = value == column
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answer == column) : nil
                            Button {
                                choose(row, column)
                            } label: {
                                MatrixPill(text: column, picked: picked, state: state)
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrix.\(row).\(column)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
    }
}

private struct MatrixPill: View {
    let text: String
    let picked: Bool
    let state: RevealState?

    var body: some View {
        HStack(spacing: QBankSpacing.space3) {
            mark
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(text)
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(state == .dim ? .text3 : .text1))
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(.qbank(fill), in: .capsule)
        .overlay { border }
        .animation(QBankMotion.select, value: picked)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .correct, .missed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.correct))
        case .wrong:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.wrong))
        case .dim, nil:
            Circle()
                .fill(.qbank(.surface))
                .overlay {
                    if picked && state == nil {
                        Circle().strokeBorder(.qbank(.tint), lineWidth: 7)
                    } else {
                        Circle().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.emphasis)
                    }
                }
        }
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            Capsule().strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            Capsule().strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            Capsule().strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            Capsule().strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            Capsule().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

// MARK: Matrix, check all that fit

/// One card of check pills on iPhone. On iPad the same rows form a grid, because the runner's
/// column is wide enough for a header row.
struct MatrixMultiList: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    var body: some View {
        if Device.isPad {
            MatrixMultiGrid(columns: columns, rows: rows, selected: selected, revealed: revealed, isLocked: isLocked, toggle: toggle)
        } else {
            MatrixMultiCards(columns: columns, rows: rows, selected: selected, revealed: revealed, isLocked: isLocked, toggle: toggle)
        }
    }
}

/// One card per row, with a check pill for each column.
private struct MatrixMultiCards: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                let picks = selected.indices.contains(row) ? selected[row] : []
                AnswerCard(label: rows[row].text, part: .answer(row)) {
                    FlowLayout(spacing: QBankSpacing.space3, lineSpacing: QBankSpacing.space3) {
                        ForEach(columns.indices, id: \.self) { column in
                            let name = columns[column]
                            let picked = picks.contains(name)
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answers.contains(name)) : nil
                            Button {
                                toggle(row, name)
                            } label: {
                                MatrixMultiPill(text: name, picked: picked, state: state)
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrixmulti.\(row).\(name)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
    }
}

/// The wide table: column names wrap in a header between words, each column as wide as the longest
/// word in any column name, and each check cell stays 44 points unless the row the runner proposes
/// is too narrow for that, in which case the cells shrink so the row stays on screen. The width
/// comes from the layout proposal, so the cells exist on the first frame.
private struct MatrixMultiGrid: View {
    let columns: [String]
    let rows: [MatrixMultiRow]
    let selected: [[String]]
    let revealed: Bool
    let isLocked: Bool
    let toggle: (Int, String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MatrixColumnRow(columns: columns.count, column: column, pinsToBottom: true) {
                Color.clear.frame(height: 0).accessibilityHidden(true)
                ForEach(columns.indices, id: \.self) { column in
                    Text(columns[column])
                        .qbankFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.qbank(.tint))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("practice.matrixmulti.column.\(columns[column])")
                }
            }
            // The grid is answered, so its header takes the accent, as a choice's letter does.
            // The band reaches a little past the columns, so a name never touches its edge and the
            // names still line up with their checks.
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                    .fill(.qbank(.tintSoft))
                    .padding(.horizontal, -QBankSpacing.space3)
            }
            ForEach(rows.indices, id: \.self) { row in
                let picks = selected.indices.contains(row) ? selected[row] : []
                VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                    MatrixColumnRow(columns: columns.count, column: column) {
                        MarkableText(text: rows[row].text, part: .answer(row), style: .headline)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns.indices, id: \.self) { column in
                            let name = columns[column]
                            let picked = picks.contains(name)
                            let state = revealed ? RevealState(selected: picked, correct: rows[row].answers.contains(name)) : nil
                            Button {
                                toggle(row, name)
                            } label: {
                                // A clear fill takes the column the layout proposes, up to 44
                                // points, so the check stays a 44-point square in a column widened
                                // for its name instead of shrinking to the mark or stretching.
                                Color.clear
                                    .frame(maxWidth: QBankSpacing.rowMin, minHeight: QBankSpacing.rowMin, maxHeight: QBankSpacing.rowMin)
                                    .overlay {
                                        MatrixMultiCell(picked: picked, state: state)
                                    }
                            }
                            .buttonStyle(ChoicePressStyle())
                            .allowsHitTesting(!isLocked)
                            .accessibilityLabel("\(rows[row].text), \(name)")
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityValue(state?.tag ?? "")
                            .accessibilityIdentifier("practice.matrixmulti.\(row).\(name)")
                        }
                    }
                    if revealed, let why = rows[row].why {
                        Reason(text: why)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The column width a header needs to wrap only between words: its longest word in the header
    /// font, at the user's text size, and never less than a check cell.
    private var column: CGFloat {
        let size = UIFontMetrics(forTextStyle: .subheadline).scaledValue(
            for: QBankTextStyle.subheadline.size,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory)
        )
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        let widest = columns
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { ceil((String($0) as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        return max(QBankSpacing.rowMin, widest)
    }
}

/// One row of the wide table. The first view is the row label and the rest are the columns, so a
/// header and the check cells share one width and line up. Extra room goes to the label. Columns
/// take the width their names need when the label keeps room; when the row is tighter than a
/// 44-point cell plus a short label, the cells shrink instead of scrolling.
private struct MatrixColumnRow: SwiftUI.Layout {
    var columns: Int
    var column: CGFloat = QBankSpacing.rowMin
    var pinsToBottom = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? QBankLayout.contentMax
        let widths = columnWidths(available: available)
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: index == 0 ? widths.label : widths.cell, height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: available, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(available: bounds.width)
        var x = bounds.minX
        for index in subviews.indices {
            let slot = index == 0 ? widths.label : widths.cell
            let fitted = subviews[index].sizeThatFits(ProposedViewSize(width: slot, height: nil))
            let used = min(fitted.width, slot)
            // Columns are centered in the slot so a wrapping header lines up with its check cell.
            let inset = index == 0 ? 0 : (slot - used) / 2
            let y = pinsToBottom ? bounds.maxY - fitted.height : bounds.minY + (bounds.height - fitted.height) / 2
            subviews[index].place(
                at: CGPoint(x: x + inset, y: y),
                proposal: ProposedViewSize(width: used, height: fitted.height)
            )
            x += slot + QBankSpacing.space3
        }
    }

    /// Label width and check-cell width that add up to `available`, with one gap before each column.
    private func columnWidths(available: CGFloat) -> (label: CGFloat, cell: CGFloat) {
        guard columns > 0, available > 1 else { return (max(0, available), 0) }
        let gap = QBankSpacing.space3
        let room = max(0, available - CGFloat(columns) * gap)
        let minLabel: CGFloat = 96
        for cell in [max(column, QBankSpacing.rowMin), QBankSpacing.rowMin] where room >= minLabel + CGFloat(columns) * cell {
            return (room - CGFloat(columns) * cell, cell)
        }
        let label = min(minLabel, room * 0.5)
        return (max(0, label), max(0, (room - label) / CGFloat(columns)))
    }
}

/// The phone's check pill: the matrix pill, with a square box in place of the radio dot.
private struct MatrixMultiPill: View {
    let text: String
    let picked: Bool
    let state: RevealState?

    var body: some View {
        HStack(spacing: QBankSpacing.space3) {
            MatrixMultiMark(picked: picked, state: state)
                .frame(width: 22, height: 22)
            Text(text)
                .qbankFont(.subheadline, weight: .medium)
                .foregroundStyle(.qbank(state == .dim ? .text3 : .text1))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, QBankSpacing.space2)
        .frame(minHeight: QBankSpacing.rowMin)
        .background(.qbank(fill), in: .capsule)
        .overlay { border }
        .animation(QBankMotion.select, value: picked)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            Capsule().strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            Capsule().strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            Capsule().strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            Capsule().strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            Capsule().strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

/// One grid cell: the same fill and border as a check pill, held to a square.
private struct MatrixMultiCell: View {
    let picked: Bool
    let state: RevealState?

    var body: some View {
        MatrixMultiMark(picked: picked, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.qbank(fill), in: .rect(cornerRadius: QBankRadius.xs, style: .continuous))
            .overlay { border }
            .animation(QBankMotion.select, value: picked)
    }

    private var fill: QBankColorToken {
        switch state {
        case nil: picked ? .tintSoft : .surfaceRaised
        case .correct: .correctSoft
        case .wrong: .wrongSoft
        case .missed, .dim: .surfaceRaised
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case nil:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(picked ? .tint : .separatorStrong), lineWidth: picked ? QBankBorder.emphasis : QBankBorder.regular)
        case .correct:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.correct), lineWidth: QBankBorder.emphasis)
        case .wrong:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.wrong), lineWidth: QBankBorder.emphasis)
        case .missed:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.correct), style: StrokeStyle(lineWidth: QBankBorder.emphasis, dash: [5, 3]))
        case .dim:
            RoundedRectangle(cornerRadius: QBankRadius.xs, style: .continuous)
                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.regular)
        }
    }
}

/// The square box. Checked is a filled box; after Check answer it takes the same correct, wrong,
/// missed, and neutral marks as the radio, drawn as squares.
private struct MatrixMultiMark: View {
    let picked: Bool
    let state: RevealState?

    var body: some View {
        mark
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .correct, .missed:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.correct))
        case .wrong:
            Image(systemName: "xmark.square.fill")
                .font(.system(size: 20))
                .foregroundStyle(.qbank(.wrong))
        case .dim, nil:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.qbank(picked && state == nil ? .tint : .surface))
                .overlay {
                    if picked && state == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.qbank(.textOnTint))
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.emphasis)
                    }
                }
        }
    }
}
