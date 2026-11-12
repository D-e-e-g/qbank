import QBankDesign
import QBankKit
import SwiftUI
import UIKit
import WebKit

/// The table and images that go with the stem. Every screen that shows a stem draws these under it.
struct StemExhibits: View {
    let question: Question

    var body: some View {
        let images = question.images.filter { $0.placement == .stem }
        if question.table != nil || !images.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                if let table = question.table {
                    ExhibitTable(table: table)
                }
                ExhibitImages(images: images)
            }
        }
    }
}

/// The images that explain the answer. They show only once the rationale does.
struct RationaleImages: View {
    let question: Question

    var body: some View {
        ExhibitImages(images: question.images.filter { $0.placement == .rationale })
    }
}

/// Readings such as vital signs. A wide table scrolls sideways inside its own box instead of
/// squeezing; long cells wrap at a readable width. What is read takes teal, so it looks apart from
/// what is answered: the caption and the header band. Row labels are semibold. Color never says a
/// reading is abnormal, since spotting that is often the question. Every cell can be marked.
private struct ExhibitTable: View {
    let table: QuestionTable
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var cellMax: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = table.caption {
                MarkableText(text: caption, part: .tableCaption, style: .footnote, weight: .semibold, color: .exhibit)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    if !table.head.isEmpty {
                        GridRow {
                            ForEach(table.head.indices, id: \.self) { index in
                                cell(table.head[index], part: .tableHead(column: index), isHead: true)
                            }
                        }
                        .background(.qbank(.exhibitSoft))
                    }
                    ForEach(table.rows.indices, id: \.self) { row in
                        if row > 0 || !table.head.isEmpty {
                            Rectangle()
                                .fill(.qbank(.separator))
                                .frame(height: QBankBorder.hairline)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                        GridRow {
                            ForEach(table.rows[row].indices, id: \.self) { index in
                                cell(table.rows[row][index], part: .tableCell(row: row, column: index), isHead: false)
                            }
                        }
                    }
                }
                .frame(minWidth: width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(.qbank(.surface))
            .clipShape(.rect(cornerRadius: QBankRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
                    .strokeBorder(.qbank(.separatorStrong), lineWidth: QBankBorder.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(table.caption ?? "Table")
        }
        .accessibilityIdentifier("practice.table")
    }

    private func cell(_ text: String, part: MarkablePart, isHead: Bool) -> some View {
        var isRowLabel = false
        if case .tableCell(_, column: 0) = part { isRowLabel = true }
        return MarkableText(
            text: text, part: part, style: .subheadline, weight: isHead || isRowLabel ? .semibold : nil,
            color: isHead ? .exhibit : .text1, monospacedDigits: true, singleLine: isHead,
            markInset: MarkableText.tightInset, isHeader: isHead
        )
        .fixedSize(horizontal: isHead, vertical: true)
        .frame(maxWidth: isHead ? nil : cellMax, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Images under the stem or the rationale. A tap opens one full screen with pinch-zoom.
private struct ExhibitImages: View {
    let images: [QuestionImage]
    @State private var zoomed: ZoomedImage?

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(images.indices, id: \.self) { index in
                    let image = images[index]
                    VStack(spacing: 6) {
                        Button {
                            zoomed = ZoomedImage(image: image)
                        } label: {
                            // The picture is only shown here: the whole of it is the button.
                            ExhibitPicture(image: image, isZoomable: false)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                                .frame(maxHeight: 420)
                                .clipShape(.rect(cornerRadius: QBankRadius.sm, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: QBankRadius.sm, style: .continuous)
                                        .strokeBorder(.qbank(.separator), lineWidth: QBankBorder.hairline)
                                }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enlarge image: \(image.alt)")
                        .accessibilityIdentifier("practice.image")
                        if let caption = image.caption {
                            Text(caption)
                                .qbankFont(.footnote, weight: .semibold)
                                .foregroundStyle(.qbank(.text2))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .fullScreenCover(item: $zoomed) { zoomed in
                ImageViewer(image: zoomed.image)
            }
        }
    }
}

private struct ZoomedImage: Identifiable {
    let id = UUID()
    let image: QuestionImage
}

/// The image at full screen. Pinch to zoom further; Close goes back.
private struct ImageViewer: View {
    let image: QuestionImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: QBankSpacing.space4) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.qbank(.plain))
                .accessibilityIdentifier("imageViewer.close")
            }
            .padding(.horizontal, QBankSpacing.space3)
            ExhibitPicture(image: image, isZoomable: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let caption = image.caption {
                Text(caption)
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text2))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, QBankSpacing.gutterPhone)
            }
        }
        .padding(.bottom, QBankSpacing.space5)
        .qbankScreenBackground()
    }
}

/// An image's pixels on a white backing, since diagrams are usually drawn for a white page.
/// PNG, JPEG and WebP draw directly; SVG draws in a web view with scripts off, as the web app
/// draws it through an image tag.
private struct ExhibitPicture: View {
    let image: QuestionImage
    let isZoomable: Bool

    var body: some View {
        if let file = image.file {
            if file.mediaType == "image/svg+xml" {
                SVGPicture(markup: String(decoding: file.data, as: UTF8.self), isZoomable: isZoomable)
                    .accessibilityLabel(image.alt)
            } else if let picture = UIImage(data: file.data) {
                if isZoomable {
                    ZoomableImage(image: picture)
                        .accessibilityLabel(image.alt)
                } else {
                    // Its own size, smaller only when the screen is narrower, as the web draws it.
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .background(Color.white)
                        .frame(maxWidth: picture.size.width)
                        .accessibilityLabel(image.alt)
                }
            } else {
                missing
            }
        } else {
            missing
        }
    }

    private var missing: some View {
        Label(image.alt, systemImage: "photo")
            .qbankFont(.subheadline)
            .foregroundStyle(.qbank(.text3))
            .padding()
            .frame(maxWidth: .infinity)
            .background(.qbank(.surfaceSunken))
    }
}

/// A picture in a scroll view that zooms with a pinch and a double tap.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView(image: image)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {}
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1, let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        contentSize = bounds.size
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep a picture smaller than the screen centered while it zooms.
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// SVG markup drawn through an image tag in a web view, with page scripts and the network off.
/// Inline, it takes the image's own size, as the web draws it; full screen, it fits the screen and
/// zooms with a pinch.
private struct SVGPicture: View {
    let markup: String
    let isZoomable: Bool

    var body: some View {
        if isZoomable {
            SVGWebView(markup: markup, isZoomable: true)
        } else {
            let size = SVGSize.natural(of: markup)
            SVGWebView(markup: markup, isZoomable: false)
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .frame(maxWidth: size.width)
        }
    }
}

/// The size a browser gives an SVG image of its own: its `width` and `height`, or its `viewBox`
/// when one is missing, or 300 by 150.
nonisolated enum SVGSize {
    static func natural(of markup: String) -> CGSize {
        guard let tag = markup.firstMatch(of: /<svg\b[^>]*>/.ignoresCase())?.output else { return fallback }
        func attribute(_ name: String) -> String? {
            let pattern = try? Regex<(Substring, Substring)>("\\s\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
            return pattern.flatMap { tag.firstMatch(of: $0) }.map { String($0.output.1) }
        }
        func length(_ name: String) -> Double? {
            guard let value = attribute(name), let match = value.wholeMatch(of: /\s*([0-9]*\.?[0-9]+)\s*(px)?\s*/) else { return nil }
            return Double(match.output.1).flatMap { $0 > 0 ? $0 : nil }
        }
        let box = attribute("viewBox")?
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        let boxSize = box.flatMap { $0.count == 4 && $0[2] > 0 && $0[3] > 0 ? CGSize(width: $0[2], height: $0[3]) : nil }
        switch (length("width"), length("height"), boxSize) {
        case let (width?, height?, _):
            return CGSize(width: width, height: height)
        case let (width?, nil, box?):
            return CGSize(width: width, height: width * box.height / box.width)
        case let (nil, height?, box?):
            return CGSize(width: height * box.width / box.height, height: height)
        case let (nil, nil, box?):
            return box
        default:
            return fallback
        }
    }

    private static let fallback = CGSize(width: 300, height: 150)
}

private struct SVGWebView: UIViewRepresentable {
    let markup: String
    let isZoomable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = isZoomable
        view.scrollView.bounces = isZoomable
        view.isUserInteractionEnabled = isZoomable
        // Inline, the enlarge button speaks for the picture.
        view.accessibilityElementsHidden = !isZoomable
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    private var html: String {
        let source = "data:image/svg+xml;base64,\(Data(markup.utf8).base64EncodedString())"
        let viewport = isZoomable
            ? "width=device-width, initial-scale=1, maximum-scale=5"
            : "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"
        // Inline, the view already has the picture's shape, so the image fills it exactly.
        let fit = isZoomable
            ? "html,body{height:100%;display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%}"
            : "img{width:100%}"
        return """
        <!doctype html><html><head><meta name="viewport" content="\(viewport)">
        <style>html,body{margin:0;padding:0;background:transparent}img{display:block;height:auto;background:#fff}\(fit)</style>
        </head><body><img src="\(source)" alt=""></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // Nothing inside the picture may open another page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}
