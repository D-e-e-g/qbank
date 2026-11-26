import Foundation

/// The short sample set that ships with the app, so a new person can practice at once.
///
/// It is a question file like any other (`SampleSet.json`, written for the purpose), and a free
/// account's new bank files it through the bank's own import into a topic made for it
/// (`LocalBank.fileSampleSet`). Once filed it is an ordinary set the person can open, replace or
/// delete. An invited or store account's bank is on the server and is never given it.
enum SampleSet {
    /// The topic the sample set is filed in.
    nonisolated static let topic = "Getting started"

    /// The question file as the app bundle carries it, or nil when the bundle has none.
    static func bundledSource(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "SampleSet", withExtension: "json") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
