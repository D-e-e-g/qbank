#if DEBUG
import Foundation
import QBankKit

nonisolated extension DebugScenario {
    /// The phone of `FakeQBankServer.student` updated from the release before Sign in with Apple: the
    /// session that release kept is read from the very bytes it wrote, with no origin and no Apple id,
    /// as the Keychain hands them back. With `QB_UITEST_KEEP_PHONE_DATA=1` the courses and the answers
    /// still waiting from the launch before are kept too. Otherwise as `signedIn`.
    static let storedSessionBeforeUpdate = DebugScenario("stored-session-before-update") { context in
        context.model(
            server: FakeQBankServer(signedIn: true, answersFile: context.answersFile),
            session: StoredSession.keptBeforeSignInWithApple()
        )
    }
}

private nonisolated extension StoredSession {
    /// `student`'s session as the release before Sign in with Apple encoded it: its token, when it
    /// ends, and the account's id, email, name, role, temporary password and color, nothing more.
    static func keptBeforeSignInWithApple() -> StoredSession {
        let expiresAt = QBankJSON.formatDate(.now.addingTimeInterval(30 * 86_400))
        let bytes = Data(
            #"{"token":"\#(FakeQBankServer.sessionToken)","expiresAt":"\#(expiresAt)","account":{"id":"fake-student","email":"\#(FakeQBankServer.student.email)","name":"Sam Student","role":"student","mustChangePassword":false,"palette":"dusk"}}"#
                .utf8)
        guard let session = try? QBankJSON.decoder.decode(StoredSession.self, from: bytes) else {
            fatalError("This release reads the session the release before kept.")
        }
        return session
    }
}
#endif
