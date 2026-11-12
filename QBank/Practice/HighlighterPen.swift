import QBankDesign
import SwiftUI

extension HighlightColor {
    /// The mark's fill, behind words.
    var fill: QBankColorToken {
        switch self {
        case .yellow: .highlight
        case .blue: .highlightBlue
        case .pink: .highlightPink
        }
    }

    /// The words on a mark: the normal text color in light, a pale tone of the mark in dark.
    var words: QBankColorToken {
        switch self {
        case .yellow: .highlightText
        case .blue: .highlightBlueText
        case .pink: .highlightPinkText
        }
    }
}

/// The pen at the right of the format line. It shows the current color; a tap opens the colors
/// beside it, so the question's words stay in view, with Clear highlights once the question has a
/// mark. The color it keeps is this device's.
struct HighlighterPen: View {
    let store: HighlighterStore
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "highlighter")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.qbank(.text1))
                .frame(width: 34, height: 34)
                .background(.qbank(store.color.fill), in: .rect(cornerRadius: 9, style: .continuous))
                .frame(width: QBankSpacing.rowMin, height: QBankSpacing.rowMin)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Highlighter")
        .accessibilityValue(store.color.name)
        .accessibilityHint(isOpen ? "Hides the colors." : "Shows the colors and Clear highlights.")
        .accessibilityIdentifier("practice.pen")
        .anchorPreference(key: PenAnchorKey.self, value: .bounds) { $0 }
    }
}

private struct PenAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Lets the user mark this question's words, and opens the pen's colors beside the pen while
    /// `isOpen`. A tap anywhere else on the question closes them.
    func highlighter(
        _ highlighting: Highlighting,
        store: HighlighterStore,
        isOpen: Binding<Bool>,
        clear: @escaping () -> Void
    ) -> some View {
        environment(\.highlighting, highlighting)
            .overlayPreferenceValue(PenAnchorKey.self) { anchor in
                if isOpen.wrappedValue, let anchor {
                    GeometryReader { proxy in
                        let pen = proxy[anchor]
                        let room = max(0, pen.minX - 2)
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture { isOpen.wrappedValue = false }
                                .accessibilityHidden(true)
                            PenMenu(current: store.color, hasMarks: !highlighting.highlights.isEmpty) { color in
                                store.color = color
                                isOpen.wrappedValue = false
                            } clear: {
                                clear()
                                isOpen.wrappedValue = false
                            }
                            .frame(width: room, alignment: .trailing)
                            .position(x: room / 2, y: pen.midY)
                        }
                    }
                    .transition(.opacity)
                }
            }
    }
}

/// The colors, the current one ringed, and Clear when the question has a mark.
private struct PenMenu: View {
    let current: HighlightColor
    let hasMarks: Bool
    let pick: (HighlightColor) -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button {
                    pick(color)
                } label: {
                    Circle()
                        .fill(.qbank(color.fill))
                        .overlay { Circle().strokeBorder(Color(red: 28 / 255, green: 27 / 255, blue: 24 / 255, opacity: 0.14), lineWidth: 1) }
                        .overlay {
                            if color == current {
                                Circle().strokeBorder(.qbank(.text1), lineWidth: 2).padding(-4)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(color == current ? .isSelected : [])
                .accessibilityIdentifier("practice.pen.\(color.rawValue)")
            }
            if hasMarks {
                Rectangle()
                    .fill(.qbank(.separatorStrong))
                    .frame(width: QBankBorder.hairline, height: 34)
                    .padding(.leading, 6)
                Button(action: clear) {
                    Text("Clear")
                        .qbankFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.qbank(.tint))
                        .padding(.leading, 12)
                        .padding(.trailing, 6)
                        .frame(height: 42)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear highlights")
                .accessibilityIdentifier("practice.pen.clear")
            }
        }
        .fixedSize()
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(.qbank(.surfaceRaised), in: .rect(cornerRadius: 16, style: .continuous))
        .qbankElevation(.popover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("practice.penMenu")
    }
}
