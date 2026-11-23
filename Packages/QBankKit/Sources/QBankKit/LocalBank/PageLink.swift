import Foundation

/// A page's primer link: what the server accepts, and what it stores. Text with no `scheme://` is
/// stored with `http://` for a tailnet or local host and `https://` otherwise.
enum PageLink {
    private static let maxLength = 2000
    private static let notALink = "A link has to be a web address, such as https://example.com/primer."

    /// The link to store, or nil for none (null or blank text).
    static func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let address = text.contains(/(?i)^[a-z][a-z0-9+.-]*:\/\//) ? text : "\(try isLocal(text) ? "http" : "https")://\(text)"
        if address.utf16.count > maxLength { throw BankRefusal.refused(400, "That link is too long.") }
        guard let components = URLComponents(string: address), let host = components.host, !host.isEmpty else { throw BankRefusal.refused(400, notALink) }
        let scheme = components.scheme?.lowercased()
        if scheme != "https" && scheme != "http" { throw BankRefusal.refused(400, "A link has to start with https:// or http://.") }
        return address
    }

    /// True when schemeless text names a tailnet or local host: a name ending in `.ts.net`, a
    /// single-label host, an IP address, `localhost`, or any address with a port.
    private static func isLocal(_ text: String) throws -> Bool {
        guard let components = URLComponents(string: "http://\(text)") else { throw BankRefusal.refused(400, notALink) }
        if components.port != nil { return true }
        guard var host = components.host else { throw BankRefusal.refused(400, notALink) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { throw BankRefusal.refused(400, notALink) }
        return host == "localhost" || host.hasSuffix(".ts.net") || !host.contains(".") || isIPAddress(host)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in Int(part).map { (0...255).contains($0) && String($0) == part } ?? false }
    }
}
