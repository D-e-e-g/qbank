#if DEBUG
import Foundation
import UIKit

/// The scripted Sign in with Apple of a launch scenario: the stand-in a UI test drives in place of
/// Apple's sheet, so a test never reaches Apple or uses a real Apple Account. Reached from
/// `DebugScenarioContext.appleSignIn`. Compiled only into Debug builds.
///
/// It answers at once, as Apple would after the person agreed, with an identity token the fake server
/// reads (`FakeQBankServer.appleToken`): Apple's id of the person, the email Apple shares, and the
/// nonce's hash the app asked with, so the fake server checks the nonce as the real one does.
/// `QB_UITEST_APPLE` picks who answers:
/// - absent or `new-person`: someone new to QBank, whom the server gives a store account.
/// - `returning-person`: the person who already has the fake server's store account,
///   `FakeQBankServer.applePerson`.
/// - `password-email`: someone whose Apple email is the fake server's password account's, which the
///   server refuses to make a second account for, until that account links this Apple identity in
///   Settings: then Sign in with Apple opens it.
/// - `cancel`: she closes Apple's sheet.
final class DebugScriptedAppleSignIn: AppleSignInProvider {
    /// The environment variable a test sets to script the sheet's answer.
    static let scriptKey = "QB_UITEST_APPLE"

    enum Script: String {
        case newPerson = "new-person"
        case returningPerson = "returning-person"
        case passwordEmail = "password-email"
        case cancel
    }

    /// Apple's id of the person new to QBank, and the relay email Apple shares for them.
    static let newPerson = (user: "002468.fakeapple0000000000000000000002.0002", email: "new.person@privaterelay.appleid.com")

    let script: Script
    /// How many times Apple's sheet was asked for, for a test of the model.
    private(set) var asks = 0

    init(script: Script = .newPerson) {
        self.script = script
    }

    /// The script the environment asks for. An unknown one stops the app, as an unknown scenario does.
    convenience init(environment: [String: String]) {
        guard let name = environment[Self.scriptKey] else {
            self.init()
            return
        }
        guard let script = Script(rawValue: name) else { fatalError("Unknown \(Self.scriptKey) \"\(name)\"") }
        self.init(script: script)
    }

    func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential {
        asks += 1
        let (user, email): (String, String?)
        switch script {
        case .cancel:
            throw .canceled
        case .newPerson:
            (user, email) = Self.newPerson
        case .returningPerson:
            // Apple names the email in the credential at the first sign-in only.
            (user, email) = (FakeQBankServer.applePerson.user, nil)
        case .passwordEmail:
            (user, email) = ("003579.fakeapple0000000000000000000003.0003", FakeQBankServer.student.email)
        }
        let token = FakeQBankServer.appleToken(user: user, email: email ?? FakeQBankServer.applePerson.email, hashedNonce: hashedNonce)
        return AppleCredential(user: user, identityToken: token, email: email)
    }
}
#endif
