import QBankDesign
import SwiftUI

/// An exam's footer on a question: Skip for now, then Submit and continue or on the last one
/// Finish exam, as tall as each other and neither label wrapping.
struct ExamAnswerButtons: View {
    let submitTitle: String
    let canSkip: Bool
    let canSubmit: Bool
    let frozen: FrozenView
    let skip: () -> Void
    let submit: () -> Void

    var body: some View {
        ExamButtonsLayout {
            Button("Skip for now", action: skip)
                .buttonStyle(style(.quiet))
                .disabled(!canSkip)
                .accessibilityIdentifier("exam.skip")
            Button(submitTitle, action: submit)
                .buttonStyle(style(.primary))
                .disabled(!canSubmit)
                .answersWhenFrozen(frozen)
                .accessibilityIdentifier("exam.submit")
        }
    }

    /// Less room at the sides than a large button alone has, so both labels fit one row on the
    /// narrowest iPhone.
    private func style(_ variant: QBankButtonStyle.Variant) -> QBankButtonStyle {
        .qbank(variant, size: .large, fullWidth: true, horizontalPadding: QBankSpacing.space5)
    }
}

/// Places the first of two buttons, then the second: in equal halves of a row where each label
/// fits a half; else the first as wide as its label and the second the rest of the row, as on the
/// web; else, as at large text sizes, one above the other, the second on top.
private struct ExamButtonsLayout: Layout {
    private static let spacing = QBankSpacing.space3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(of: subviews, in: proposal.width).reduce(CGRect.zero) { $0.union($1) }.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(of: subviews, in: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// Each button's frame from the top leading corner, in the order of `subviews`.
    private func frames(of subviews: Subviews, in proposed: CGFloat?) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        let first = subviews[0].sizeThatFits(.unspecified).width
        let second = subviews[1].sizeThatFits(.unspecified).width
        let oneRow = first + Self.spacing + second
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? oneRow
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }

        guard oneRow <= width else {
            let top = height(1, width)
            return [
                CGRect(x: 0, y: top + Self.spacing, width: width, height: height(0, width)),
                CGRect(x: 0, y: 0, width: width, height: top),
            ]
        }
        let half = (width - Self.spacing) / 2
        let leading = max(first, second) <= half ? half : first
        let trailing = width - Self.spacing - leading
        let tallest = max(height(0, leading), height(1, trailing))
        return [
            CGRect(x: 0, y: 0, width: leading, height: tallest),
            CGRect(x: leading + Self.spacing, y: 0, width: trailing, height: tallest),
        ]
    }
}
