import SafariServices
import SwiftUI

/// A web page, shown in the system browser view over the screen that opened it, so she reads it
/// without leaving QBank and closes it with Done.
struct WebPageSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension View {
    /// Shows `page` in the system browser view while it is set. A launch from a UI test shows a
    /// stand-in that names the address instead, so no test waits on a network.
    func webPageSheet(_ page: Binding<URL?>) -> some View {
        sheet(item: page) { url in
            #if DEBUG
            if DebugWebPageStandIn.isOn {
                DebugWebPageStandIn(url: url) { page.wrappedValue = nil }
            } else {
                WebPageSheet(url: url).ignoresSafeArea()
            }
            #else
            WebPageSheet(url: url).ignoresSafeArea()
            #endif
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
