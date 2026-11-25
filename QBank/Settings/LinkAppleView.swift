import QBankDesign
import SwiftUI

/// Settings' Sign in with Apple for an account with a password: what linking does, in plain words,
/// her current password, and Apple's button. Once Sign in with Apple opens her account, from here or
/// another device, the screen says so and what it means instead.
struct LinkAppleView: View {
    @State private var model: LinkAppleModel
    @FocusState private var isFocused: Bool

    init(app: AppModel) {
        _model = State(initialValue: LinkAppleModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                if model.isLinked {
                    linked
                } else {
                    form
                }
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space3)
            .padding(.bottom, QBankSpacing.space7)
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle("Sign in with Apple")
        .screenColumnTitle()
        .task(id: model.lockedUntil) {
            guard let lockedUntil = model.lockedUntil else { return }
            try? await Task.sleep(for: .seconds(max(0, lockedUntil.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            model.lockEnded()
        }
    }

    private var form: some View {
        Group {
            Text("Link your Apple Account to sign in with Apple on a new \(Device.model), with no password. Your courses, sets and progress stay as they are, and your email and password keep working.")
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("linkApple.message")
            LabeledField(label: "Current password") {
                SecureField("Current password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
                    .accessibilityIdentifier("linkApple.password")
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            AppleSignInButton(type: .continue, isWorking: model.isLinking, identifier: "linkApple.apple") { window in
                isFocused = false
                Task { await model.link(over: window) }
            }
            .disabled(!model.canLink)
            .padding(.top, 2)
        }
    }

    private var linked: some View {
        Group {
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            SavedText(text: "Sign in with Apple is linked to your account.")
                .accessibilityIdentifier("linkApple.linked")
            Text("On a new \(Device.model), tap Sign in with Apple on QBank's first screen with the Apple Account you linked: it opens this account, with the same courses, sets and progress. Your email and password keep working too.")
                .qbankFont(.body)
                .foregroundStyle(.qbank(.text1))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("linkApple.linkedMessage")
        }
    }
}
