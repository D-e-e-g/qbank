import QBankDesign
import SwiftUI

struct SignInView: View {
    @State private var model: SignInModel
    @State private var showsForgotPassword = false
    @FocusState private var focus: Field?
    /// To the Sign up screen.
    private let signUp: () -> Void

    private enum Field {
        case email
        case password
    }

    /// - Parameter handoff: The email and sentence sign-up left, when it made the account but
    ///   could not sign it in.
    init(app: AppModel, handoff: SignInHandoff? = nil, signUp: @escaping () -> Void) {
        _model = State(initialValue: SignInModel(app: app, handoff: handoff))
        self.signUp = signUp
    }

    var body: some View {
        ScrollView {
            VStack(spacing: QBankSpacing.space7) {
                header
                form
            }
            .padding(.horizontal, QBankSpacing.gutterPhone)
            .padding(.vertical, QBankSpacing.space7)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
    }

    private var header: some View {
        VStack(spacing: 8) {
            QBankMark()
                .padding(.bottom, QBankSpacing.space2)
            Text("QBank")
                .qbankFont(.largeTitle)
                .foregroundStyle(.qbank(.text1))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("signIn.title")
            Text(Wording.firstScreenLine)
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .multilineTextAlignment(.center)
        }
    }

    private var form: some View {
        VStack(spacing: QBankSpacing.space4) {
            LabeledField(label: "Email") {
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("signIn.email")
            }
            LabeledField(label: "Password") {
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(signIn)
                    .accessibilityIdentifier("signIn.password")
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            Button(action: signIn) {
                if model.isSigningIn {
                    ProgressView()
                        .tint(QBankColor(.textOnTint))
                        .accessibilityLabel("Signing in")
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(model.isSigningIn)
            .accessibilityIdentifier("signIn.submit")
            .padding(.top, 2)

            forgotPassword

            Button("Sign up", action: signUp)
                .buttonStyle(.qbank(.plain))
                .disabled(model.isSigningIn)
                .accessibilityIdentifier("signIn.signUp")
        }
    }

    private var forgotPassword: some View {
        VStack(spacing: QBankSpacing.space2) {
            Button("Forgot password?") {
                withAnimation(QBankMotion.reveal) { showsForgotPassword.toggle() }
            }
            .buttonStyle(.qbank(.plain))
            .accessibilityIdentifier("signIn.forgot")
            if showsForgotPassword {
                Text("This app doesn't send email. Ask the owner to reset your password from his admin account. He'll give you a temporary password, and you'll choose your own the next time you sign in.")
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, QBankSpacing.space3)
                    .transition(.opacity)
            }
        }
    }

    private func signIn() {
        focus = nil
        Task { await model.signIn() }
    }
}
