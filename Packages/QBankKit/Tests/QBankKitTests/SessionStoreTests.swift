import Foundation
import Testing
@testable import QBankKit

@Suite("Session stores")
struct SessionStoreTests {
    static let session = StoredSession(
        token: "synthetic-session-token",
        expiresAt: Date(timeIntervalSince1970: 1_820_000_000),
        account: Account(id: "u1", email: "student@example.com", name: "Sam Student", role: .student, mustChangePassword: false)
    )

    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySessionStore()
        #expect(try store.load() == nil)
        try store.save(Self.session)
        #expect(try store.load() == Self.session)
        try store.clear()
        #expect(try store.load() == nil)
    }

    #if canImport(Security)
    /// Whether this test host may use the Keychain at all. A package's test bundle run on the iOS
    /// Simulator has no host app and so no entitlements (errSecMissingEntitlement, -34018); there the
    /// app's own tests cover the Keychain. A process outside the login session, such as a CI runner
    /// service with its own security session, finds the login keychain locked and may not ask to
    /// unlock it (errSecInteractionNotAllowed, -25308). Otherwise these tests write real items on macOS.
    static let keychainUsable: Bool = {
        let probe = KeychainSessionStore(service: "QBankKitTests.probe.\(UUID().uuidString).session")
        defer { try? probe.clear() }
        do {
            try probe.save(StoredSession(token: "probe"))
            return true
        } catch let error as StorageError {
            return error.status != -34018 && error.status != -25308
        } catch {
            return true
        }
    }()

    @Test func defaultKeychainServiceIsTheBundleIDDotSession() {
        #expect(KeychainSessionStore().service.hasSuffix(".session"))
        #expect(KeychainSessionStore.defaultService(bundle: .main) == "\(Bundle.main.bundleIdentifier ?? "QBank").session")
    }

    /// Writes a real Keychain item under a service used only by this test, and removes it.
    @Test(.enabled(if: keychainUsable, "This test host has no Keychain access (no app entitlements on the iOS Simulator, or a login keychain locked in this session, as on a CI runner)"))
    func keychainRoundTrip() throws {
        let store = KeychainSessionStore(service: "QBankKitTests.\(UUID().uuidString).session")
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        try store.save(Self.session)
        #expect(try store.load() == Self.session)
        let replaced = StoredSession(token: "synthetic-session-token-2", expiresAt: nil, account: nil)
        try store.save(replaced)
        #expect(try store.load() == replaced)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test(.enabled(if: keychainUsable, "This test host has no Keychain access (no app entitlements on the iOS Simulator, or a login keychain locked in this session, as on a CI runner)"))
    func keychainItemsAreSeparatePerService() throws {
        let first = KeychainSessionStore(service: "QBankKitTests.\(UUID().uuidString).session")
        let second = KeychainSessionStore(service: "QBankKitTests.\(UUID().uuidString).session")
        defer {
            try? first.clear()
            try? second.clear()
        }
        try first.save(Self.session)
        #expect(try second.load() == nil)
    }
    #endif
}
