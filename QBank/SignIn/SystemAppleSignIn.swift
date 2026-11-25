import AuthenticationServices
import UIKit

/// The system's Sign in with Apple: Apple's own sheet, which asks the person and answers with Apple's
/// identity token. It needs the app's Sign in with Apple entitlement (`QBank/QBank.entitlements`).
final class SystemAppleSignIn: NSObject, AppleSignInProvider {
    private var answer: CheckedContinuation<Result<AppleCredential, AppleSignInFailure>, Never>?
    /// Kept while Apple's sheet is up: the controller tells its delegate only while something holds it.
    private var controller: ASAuthorizationController?
    private weak var window: UIWindow?

    func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential {
        // One sheet at a time: a second ask while one is up is the first one's.
        guard answer == nil else { throw .failed }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // The email lets the server tell a person who already has a QBank account with a password,
        // and send them to that door rather than make a second account. The name is never used.
        request.requestedScopes = [.email]
        request.nonce = hashedNonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        self.window = window
        let result = await withCheckedContinuation { continuation in
            answer = continuation
            controller.performRequests()
        }
        return try result.get()
    }

    private func finish(_ result: Result<AppleCredential, AppleSignInFailure>) {
        controller = nil
        window = nil
        answer?.resume(returning: result)
        answer = nil
    }
}

extension SystemAppleSignIn: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
        else {
            finish(.failure(.failed))
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        finish(.success(AppleCredential(user: credential.user, identityToken: token, email: credential.email, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let canceled = (error as? ASAuthorizationError)?.code == .canceled
        finish(.failure(canceled ? .canceled : .failed))
    }
}

extension SystemAppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window { return window }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}
