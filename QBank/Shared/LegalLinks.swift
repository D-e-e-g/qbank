import Foundation

/// The three public addresses the app sends her to for its policies: the privacy policy and the
/// help page, which the site publishes on its own host (the one in `site/CNAME`), and Apple's
/// standard licensed application end user license agreement for the terms of use. Every screen
/// that shows one of them, Settings, the first screen and the plans sheet later, reads it here.
nonisolated enum LegalLinks {
    static let siteHost = "qbank-app.dimitrygallego.com"

    static let privacyPolicy = address("https://\(siteHost)/privacy")
    static let help = address("https://\(siteHost)/support")
    static let termsOfUse = address("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    /// A fixed address above, which the unit tests prove well formed; a malformed one stops the app
    /// at launch rather than leaving a row that opens nothing.
    private static func address(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("Not an address: \(text)") }
        return url
    }
}
