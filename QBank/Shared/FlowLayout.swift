import SwiftUI

/// Lays its views out in rows like words in a paragraph: left to right, wrapping to a new row
/// when the next one does not fit. A view wider than the row gets the whole row and wraps inside.
/// A view marked `.flowLineBreak()` ends the row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// How the views of one row line up with each other.
    var rowAlignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews where subview[FlowLineBreak.self] {
            subview.place(at: bounds.origin, proposal: .zero)
        }
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                let offset: CGFloat =
                    switch rowAlignment {
                    case .top: 0
                    case .bottom: row.height - item.size.height
                    default: (row.height - item.size.height) / 2
                    }
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + offset),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let subview = subviews[index]
            if subview[FlowLineBreak.self] {
                rows.append(row)
                row = Row()
                continue
            }
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(Item(index: index, size: size))
        }
        if !row.items.isEmpty || rows.isEmpty {
            rows.append(row)
        }
        return rows
    }
}

private nonisolated struct FlowLineBreak: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Ends the current row of a `FlowLayout`. The view itself takes no space.
    func flowLineBreak() -> some View {
        layoutValue(key: FlowLineBreak.self, value: true)
    }
}
