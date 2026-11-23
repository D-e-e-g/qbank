import Foundation
import Testing
@testable import QBank

struct LegalLinksTests {
    @Test func everyAddressIsHTTPS() {
        for url in [LegalLinks.privacyPolicy, LegalLinks.help, LegalLinks.termsOfUse] {
            #expect(url.scheme == "https", "\(url)")
        }
    }

    @Test func privacyAndHelpAreOnTheSitesHost() throws {
        #expect(LegalLinks.privacyPolicy.host == LegalLinks.siteHost)
        #expect(LegalLinks.help.host == LegalLinks.siteHost)
        #expect(LegalLinks.privacyPolicy.path == "/privacy")
        #expect(LegalLinks.help.path == "/support")
    }

    @Test func theSiteHostIsTheOneTheSitePublishes() throws {
        let cname = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "site/CNAME")
        let host = try String(contentsOf: cname, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(LegalLinks.siteHost == host)
    }

    @Test func termsAreApplesStandardAgreement() {
        #expect(LegalLinks.termsOfUse.host == "www.apple.com")
        #expect(LegalLinks.termsOfUse.path.hasPrefix("/legal/internet-services/itunes/dev/stdeula"))
    }
}
