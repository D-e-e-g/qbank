import Foundation
import Observation
import QBankKit

/// The first screen's door for an account the owner set up: her QBank email and password, the same
/// as on the web.
@Observable
final class SignInModel {
    var email = ""
    var password = ""
    private(set) var isSigningIn = false
    private(set) var problem: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func signIn() async {
        guard !isSigningIn else { return }
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            problem = "Enter your email and password."
            return
        }
        isSigningIn = true
        problem = nil
        defer { isSigningIn = false }
        do {
            let signedIn = try await app.client.signIn(email: trimmedEmail, password: password)
            app.signedIn(signedIn, password: password)
        } catch {
            problem = Wording.problem(error)
            password = ""
        }
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
