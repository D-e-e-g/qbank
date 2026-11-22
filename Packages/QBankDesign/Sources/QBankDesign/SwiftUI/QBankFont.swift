#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension QBankTextStyle {
    /// The Dynamic Type style this style scales with.
    public var textStyle: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title1: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body, .reading, .readingLarge, .readingSmall: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption1: .caption
        case .caption2: .caption2
        }
    }

    /// The font at the reader's text size, without the extra line spacing.
    /// Prefer ``SwiftUICore/View/qbankFont(_:weight:design:trackingEm:)``, which also sets the line height.
    public var font: Font {
        Font.system(textStyle, design: design.fontDesign, weight: weight.fontWeight)
    }
}

extension QBankTextStyle.Weight {
    public var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension QBankTextStyle.Design {
    public var fontDesign: Font.Design {
        switch self {
        case .default: .default
        case .monospaced: .monospaced
        }
    }
}

extension View {
    /// Sets a QBank text style: its size, weight, face, tracking and line height,
    /// all scaled with Dynamic Type. As with CSS `line-height`, the extra leading is
    /// split above and below each line, so one-line text is as tall as the web's.
    /// - Parameters:
    ///   - weight: Overrides the style's weight, as the web does for semibold labels.
    ///   - design: Overrides the style's face, for example SF Pro at footnote size.
    ///   - trackingEm: Overrides the style's letter spacing, in em of the scaled size,
    ///     for example ``QBankTextStyle/capsTrackingEm`` for small uppercase labels.
    public func qbankFont(
        _ style: QBankTextStyle,
        weight: QBankTextStyle.Weight? = nil,
        design: QBankTextStyle.Design? = nil,
        trackingEm: Double? = nil
    ) -> some View {
        modifier(
            QBankFontModifier(
                style: style,
                weight: weight ?? style.weight,
                design: design ?? style.design,
                trackingEm: trackingEm
            ))
    }
}

private struct QBankFontModifier: ViewModifier {
    let style: QBankTextStyle
    let weight: QBankTextStyle.Weight
    let design: QBankTextStyle.Design
    let trackingEm: Double?
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var lineHeight: CGFloat

    init(style: QBankTextStyle, weight: QBankTextStyle.Weight, design: QBankTextStyle.Design, trackingEm: Double?) {
        self.style = style
        self.weight = weight
        self.design = design
        self.trackingEm = trackingEm
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.textStyle)
        _lineHeight = ScaledMetric(wrappedValue: style.lineHeight, relativeTo: style.textStyle)
    }

    func body(content: Content) -> some View {
        let leading = max(0, lineHeight - naturalLineHeight)
        content
            .font(.system(size: size, weight: weight.fontWeight, design: design.fontDesign))
            .tracking(trackingEm.map { size * $0 } ?? style.tracking)
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
    }

    /// The system font's own line height at this size; line spacing adds the rest.
    private var naturalLineHeight: CGFloat {
        #if canImport(UIKit)
        let font =
            design == .monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight.platformWeight)
            : UIFont.systemFont(ofSize: size, weight: weight.platformWeight)
        return font.lineHeight
        #elseif canImport(AppKit)
        let font =
            design == .monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight.platformWeight)
            : NSFont.systemFont(ofSize: size, weight: weight.platformWeight)
        return font.ascender - font.descender + font.leading
        #else
        return size * 1.2
        #endif
    }
}

#if canImport(UIKit)
private extension QBankTextStyle.Weight {
    var platformWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
#elseif canImport(AppKit)
private extension QBankTextStyle.Weight {
    var platformWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
#endif

#Preview("Type scale") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(QBankTextStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(style.rawValue) · \(Int(style.size))/\(Int(style.lineHeight))")
                        .qbankFont(.caption2)
                        .foregroundStyle(.qbank(.text3))
                    Text(
                        style.rawValue.hasPrefix("reading")
                            ? "A 27-year-old client admitted involuntarily refuses his scheduled oral antipsychotic."
                            : "Check answer"
                    )
                    .qbankFont(style)
                    .foregroundStyle(.qbank(.text1))
                }
            }
        }
        .padding(QBankSpacing.gutterPhone)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .qbankScreenBackground()
}
#endif
