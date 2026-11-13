import QBankDesign
import SwiftUI
import UIKit

/// What marking needs from the question on screen: its marks, the pen's color, and where a new mark
/// or an erase goes. Nil where text cannot be marked, as on a result, so the text is drawn plain.
struct Highlighting {
    let highlights: Highlights
    let color: HighlightColor
    let paint: (Range<Int>, MarkablePart) -> Void
    let erase: (Int, MarkablePart) -> Void
}

extension EnvironmentValues {
    @Entry var highlighting: Highlighting? = nil
}

/// A question's words that the user can mark: touch and hold a word, drag, lift, and the words take
/// the pen's color; a tap on a mark erases it. A quick swipe still scrolls, because the hold comes
/// first, and a plain tap passes through, so a choice under it is still picked. Without
/// `highlighting` in the environment it is plain text in the same style.
struct MarkableText: View {
    let text: String
    let part: MarkablePart
    var style: QBankTextStyle = .body
    var weight: QBankTextStyle.Weight?
    var color: QBankColorToken = .text1
    /// A struck choice: crossed out and dimmed, its marks faded with it.
    var isStruck = false
    var monospacedDigits = false
    /// One line that never wraps, as a table header.
    var singleLine = false
    /// Room a mark takes around its words: 2 points in tables and choices, as the web draws them.
    var markInset = CGSize(width: 1, height: 3)
    /// Read by VoiceOver on its own. False inside a control that speaks for it, such as a choice.
    var isAccessibilityElement = true
    var identifier: String?
    var isHeader = false

    /// The room a mark takes in a table cell or a choice.
    static let tightInset = CGSize(width: 2, height: 2)
    @Environment(\.highlighting) private var highlighting
    @Environment(\.qbankPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.self) private var environment

    var body: some View {
        if let highlighting {
            MarkableTextRepresentable(
                content: MarkableTextView.Content(
                    text: text,
                    font: font,
                    lineHeight: scaled(style.lineHeight),
                    textColor: ui(isStruck ? .text3 : color),
                    isStruck: isStruck,
                    singleLine: singleLine,
                    markInset: markInset,
                    marks: highlighting.highlights[part].map { paint(for: $0.color, range: $0.range) },
                    pen: paint(for: highlighting.color, range: 0..<0),
                    liveRing: colorScheme == .dark ? UIColor(red: 247 / 255, green: 235 / 255, blue: 190 / 255, alpha: 0.55)
                        : UIColor(red: 28 / 255, green: 27 / 255, blue: 24 / 255, alpha: 0.4),
                    spokenMarks: Self.spoken(text, highlighting.highlights[part]),
                    isAccessibilityElement: isAccessibilityElement,
                    identifier: identifier,
                    isHeader: isHeader
                ),
                paint: { highlighting.paint($0, part) },
                erase: { highlighting.erase($0, part) }
            )
        } else {
            Text(text)
                .qbankFont(style, weight: weight)
                .modifier(MonospacedDigits(isOn: monospacedDigits))
                .strikethrough(isStruck, color: Color(QBankColor(.text3).resolve(in: environment)))
                .foregroundStyle(.qbank(isStruck ? .text3 : color))
                .lineLimit(singleLine ? 1 : nil)
                .accessibilityAddTraits(isHeader ? .isHeader : [])
                .modifier(OptionalIdentifier(identifier: identifier))
        }
    }

    /// "Yellow highlight: cloudy and dark amber. Blue highlight: 90 mL", for VoiceOver and UI tests.
    nonisolated static func spoken(_ text: String, _ marks: [Highlight]) -> String {
        let string = text as NSString
        return marks.compactMap { mark in
            guard mark.range.lowerBound >= 0, mark.range.upperBound <= string.length else { return nil }
            let words = string.substring(with: NSRange(location: mark.range.lowerBound, length: mark.range.count))
            return "\(mark.color.name) highlight: \(words)"
        }.joined(separator: ". ")
    }

    private var appearance: QBankAppearance { QBankAppearance(colorScheme) }

    private func ui(_ token: QBankColorToken) -> UIColor {
        token.value(palette: palette, appearance: appearance).uiColor
    }

    private func paint(for color: HighlightColor, range: Range<Int>) -> MarkableTextView.Mark {
        MarkableTextView.Mark(range: range, fill: ui(color.fill), text: ui(isStruck ? .text3 : color.words))
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: style.uiTextStyle)
            .scaledValue(for: value, compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory))
    }

    private var font: UIFont {
        let size = scaled(style.size)
        let weight = (weight ?? style.weight).uiWeight
        if style.design == .monospaced {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct MonospacedDigits: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

private struct MarkableTextRepresentable: UIViewRepresentable {
    let content: MarkableTextView.Content
    let paint: (Range<Int>) -> Void
    let erase: (Int) -> Void

    func makeUIView(context: Context) -> MarkableTextView {
        let view = MarkableTextView()
        update(view)
        return view
    }

    func updateUIView(_ view: MarkableTextView, context: Context) {
        update(view)
    }

    private func update(_ view: MarkableTextView) {
        view.content = content
        view.onPaint = paint
        view.onErase = erase
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkableTextView, context: Context) -> CGSize? {
        uiView.content = content
        return uiView.fittingSize(width: content.singleLine ? nil : proposal.width)
    }
}

/// Draws text with TextKit so a finger maps to a character, and paints each mark behind its words
/// as a rounded band per line, as the web's `mark` does.
final class MarkableTextView: UIView, UIGestureRecognizerDelegate {
    struct Mark: Equatable {
        var range: Range<Int>
        var fill: UIColor
        var text: UIColor
    }

    struct Content: Equatable {
        var text = ""
        var font = UIFont.systemFont(ofSize: 17)
        var lineHeight: CGFloat = 22
        var textColor = UIColor.label
        var isStruck = false
        var singleLine = false
        var markInset = CGSize(width: 1, height: 3)
        var marks: [Mark] = []
        /// The pen's color, for the mark that follows the finger.
        var pen = Mark(range: 0..<0, fill: .clear, text: .label)
        var liveRing = UIColor.clear
        var spokenMarks = ""
        var isAccessibilityElement = true
        var identifier: String?
        var isHeader = false
    }

    var content = Content() {
        didSet {
            guard content != oldValue else { return }
            if content.text != oldValue.text || content.font != oldValue.font || content.lineHeight != oldValue.lineHeight
                || content.singleLine != oldValue.singleLine {
                invalidateIntrinsicContentSize()
            }
            restyle()
        }
    }

    var onPaint: ((Range<Int>) -> Void)?
    var onErase: ((Int) -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var lineHeights = LineHeights(lineHeight: 22, font: .systemFont(ofSize: 17))
    /// The character the hold began on, and the words the finger covers now.
    private var anchor: Int?
    private var live: Range<Int>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.delegate = lineHeights
        storage.addLayoutManager(layoutManager)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        hold.delegate = self
        addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        // A hold that starts on a mark repaints it; only a quick tap erases.
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
        accessibilityTraits = .staticText
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Layout

    /// The size the text takes at a width: its widest line, never wider than offered, and a line
    /// height per line. No width means one unbroken line.
    func fittingSize(width: CGFloat?) -> CGSize {
        layOut(width: width ?? .greatestFiniteMagnitude)
        let used = layoutManager.usedRect(for: container)
        let height = storage.length == 0 ? content.lineHeight : used.height
        let fitted = CGSize(width: ceil(min(used.width, width ?? .greatestFiniteMagnitude)), height: ceil(height))
        return fitted
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(width: content.singleLine ? nil : (bounds.width > 0 ? bounds.width : nil))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    private func layOut(width: CGFloat) {
        let size = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        if container.size != size {
            container.size = size
        }
        layoutManager.ensureLayout(for: container)
    }

    private func restyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = content.singleLine ? .byClipping : .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: content.font,
            .foregroundColor: content.textColor,
            .paragraphStyle: paragraph,
        ]
        if content.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = content.textColor
        }
        let text = NSMutableAttributedString(string: content.text, attributes: attributes)
        for mark in shownMarks where mark.range.upperBound <= text.length {
            text.addAttribute(.foregroundColor, value: mark.text, range: NSRange(location: mark.range.lowerBound, length: mark.range.count))
        }
        lineHeights = LineHeights(lineHeight: content.lineHeight, font: content.font)
        layoutManager.delegate = lineHeights
        container.maximumNumberOfLines = content.singleLine ? 1 : 0
        storage.setAttributedString(text)
        isAccessibilityElement = content.isAccessibilityElement
        accessibilityIdentifier = content.identifier
        accessibilityTraits = content.isHeader ? [.staticText, .header] : .staticText
        accessibilityLabel = content.text
        accessibilityValue = content.spokenMarks.isEmpty ? nil : content.spokenMarks
        setNeedsDisplay()
    }

    /// The saved marks with the one under the finger painted over them, as it will be on lifting.
    private var shownMarks: [Mark] {
        guard let live else { return content.marks }
        var marks: [Mark] = []
        for mark in content.marks {
            if mark.range.lowerBound < live.lowerBound {
                marks.append(Mark(range: mark.range.lowerBound..<min(mark.range.upperBound, live.lowerBound), fill: mark.fill, text: mark.text))
            }
            if mark.range.upperBound > live.upperBound {
                marks.append(Mark(range: max(mark.range.lowerBound, live.upperBound)..<mark.range.upperBound, fill: mark.fill, text: mark.text))
            }
        }
        marks.append(Mark(range: live, fill: content.pen.fill, text: content.pen.text))
        return marks
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        layOut(width: content.singleLine ? .greatestFiniteMagnitude : bounds.width)
        let fade: CGFloat = content.isStruck ? 0.55 : 1
        for mark in shownMarks {
            let isLive = live == mark.range
            for band in bands(for: mark.range) {
                let path = UIBezierPath(roundedRect: band, cornerRadius: 3)
                mark.fill.withAlphaComponent(fade).setFill()
                path.fill()
                if isLive {
                    content.liveRing.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// One rounded band per line a run covers: the font's height and a little room around the words.
    private func bands(for range: Range<Int>) -> [CGRect] {
        guard range.lowerBound >= 0, range.upperBound <= storage.length, !range.isEmpty else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.lowerBound, length: range.count), actualCharacterRange: nil)
        var rects: [CGRect] = []
        let fontHeight = content.font.lineHeight
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            rects.append(CGRect(
                x: rect.minX - self.content.markInset.width,
                y: rect.midY - fontHeight / 2 - self.content.markInset.height,
                width: rect.width + 2 * self.content.markInset.width,
                height: fontHeight + 2 * self.content.markInset.height
            ))
        }
        return rects
    }

    // MARK: Touch

    /// The character nearest a point, on the line under it.
    private func character(at point: CGPoint) -> Int? {
        layOut(width: content.singleLine ? .greatestFiniteMagnitude : bounds.width)
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// The character under a press. A finger on the space between two words means the nearer one,
    /// so the press takes the letter on that side.
    private func pressed(at point: CGPoint) -> Int? {
        layOut(width: content.singleLine ? .greatestFiniteMagnitude : bounds.width)
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let text = storage.string as NSString
        guard index < text.length, let held = Unicode.Scalar(text.character(at: index)),
              CharacterSet.whitespaces.contains(held) else { return index }
        return fraction < 0.5 ? max(0, index - 1) : min(text.length - 1, index + 1)
    }

    /// The mark whose band is under a point, if any.
    private func mark(at point: CGPoint) -> Mark? {
        layOut(width: content.singleLine ? .greatestFiniteMagnitude : bounds.width)
        return content.marks.first { mark in
            bands(for: mark.range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard let index = pressed(at: point) else { return }
            anchor = index
            live = WordSpan.covering(content.text, from: index, to: index)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            restyle()
        case .changed:
            guard let anchor, let index = character(at: point) else { return }
            let covered = WordSpan.covering(content.text, from: anchor, to: index)
            if covered != live {
                live = covered
                restyle()
            }
        case .ended:
            let covered = live
            anchor = nil
            live = nil
            restyle()
            if let covered {
                onPaint?(covered)
            }
        default:
            anchor = nil
            live = nil
            restyle()
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let mark = mark(at: recognizer.location(in: self)) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onErase?(mark.range.lowerBound)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A tap belongs to the text only on a mark; anywhere else it picks the choice under it.
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        return mark(at: touch.location(in: self)) != nil
    }

}

/// Gives every line the style's line height, with the extra leading split above and below the
/// words, as `qbankFont` does in SwiftUI.
private nonisolated final class LineHeights: NSObject, NSLayoutManagerDelegate {
    let lineHeight: CGFloat
    let ascender: CGFloat
    let leading: CGFloat

    init(lineHeight: CGFloat, font: UIFont) {
        self.lineHeight = max(lineHeight, font.lineHeight)
        ascender = font.ascender
        leading = max(0, lineHeight - font.lineHeight)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = leading / 2 + ascender
        return true
    }
}

extension QBankRGBA {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}

extension QBankTextStyle {
    /// The UIKit Dynamic Type style this style scales with.
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title1: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body, .reading, .readingLarge, .readingSmall: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption1: .caption1
        case .caption2: .caption2
        }
    }
}

extension QBankTextStyle.Weight {
    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
