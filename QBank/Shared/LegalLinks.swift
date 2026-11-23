import Foundation

/// The three public addresses the app sends her to for its policies: the privacy policy and the
/// help page, which the site publishes on its own host (the one in `site/CNAME`), and Apple's
/// standard licensed application end user license agreement for the terms of use. Every screen
/// that shows one of them, Settings now and sign-in and the plans sheet later, reads it here.
nonisolated enum LegalLinks {
    static let siteHost = "qbank-app.dimitrygallego.com"

    static let privacyPolicy = URL(string: "https://\(siteHost)/privacy")!
    static let help = URL(string: "https://\(siteHost)/support")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static let all = [privacyPolicy, help, termsOfUse]
}
