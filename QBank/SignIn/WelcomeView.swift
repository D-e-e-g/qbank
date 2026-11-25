import QBankDesign
import SwiftUI

/// The first screen: Sign in with Apple, and below it a small door to the email and password of an
/// account the owner set up. Signing up is on the web only.
struct WelcomeView: View {
    @State private var apple: AppleSignInModel
    @State private var password: SignInModel
    /// Whether the email and password door is open.
    @State private var showsPasswordDoor = false
    @State private var showsForgotPassword = false
    /// The privacy policy or the terms of use, open in the browser view.
    @State private var openPage: URL?
    /// Why the last session ended, said until she signs in another way.
    @State private var notice: String?
    @FocusState private var focus: Field?

    private enum Field {
        case email
        case password
    }

    init(app: AppModel) {
        _apple = State(initialValue: AppleSignInModel(app: app))
        _password = State(initialValue: SignInModel(app: app))
        _notice = State(initialValue: app.signedOutReason)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: QBankSpacing.space7) {
                header
                VStack(spacing: QBankSpacing.space4) {
                    AppleSignInButton(isWorking: apple.isSigningIn, identifier: "welcome.apple", action: signInWithApple)
                        .disabled(password.isSigningIn)
                    if let problem = apple.problem ?? notice {
                        ProblemText(text: problem)
                    }
                    if showsPasswordDoor {
                        passwordDoor
                            .transition(.opacity)
                    } else {
                        Button("Use an existing QBank account", action: openPasswordDoor)
                            .buttonStyle(.qbank(.plain))
                            .disabled(apple.isSigningIn)
                            .accessibilityIdentifier("welcome.useExistingAccount")
                    }
                }
                legal
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
        .webPageSheet($openPage)
        .onChange(of: apple.emailDoor) { _, door in
            // The account Apple's email belongs to signs in here.
            guard let door else { return }
            if !door.isEmpty { password.email = door }
            openPasswordDoor()
        }
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

    /// The account's email and password, the same as on the web.
    private var passwordDoor: some View {
        VStack(spacing: QBankSpacing.space4) {
            LabeledField(label: "Email") {
                TextField("Email", text: $password.email)
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
                SecureField("Password", text: $password.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(signInWithPassword)
                    .accessibilityIdentifier("signIn.password")
            }
            if let problem = password.problem {
                ProblemText(text: problem)
            }
            Button(action: signInWithPassword) {
                if password.isSigningIn {
                    ProgressView()
                        .tint(QBankColor(.textOnTint))
                        .accessibilityLabel("Signing in")
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(password.isSigningIn || apple.isSigningIn)
            .accessibilityIdentifier("signIn.submit")
            .padding(.top, 2)

            forgotPassword
        }
        .padding(.top, QBankSpacing.space3)
    }

    /// The privacy policy and the terms of use, readable before signing in, from the same
    /// addresses as Settings.
    private var legal: some View {
        HStack(spacing: QBankSpacing.space4) {
            Button("Privacy policy") { openPage = LegalLinks.privacyPolicy }
                .accessibilityIdentifier("welcome.privacy")
            Button("Terms of use") { openPage = LegalLinks.termsOfUse }
                .accessibilityIdentifier("welcome.terms")
        }
        .buttonStyle(.qbank(.plain, size: .small))
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

    private func openPasswordDoor() {
        withAnimation(QBankMotion.reveal) { showsPasswordDoor = true }
        focus = password.email.isEmpty ? .email : .password
    }

    private func signInWithApple(over window: UIWindow?) {
        notice = nil
        focus = nil
        Task { await apple.signIn(over: window) }
    }

    private func signInWithPassword() {
        notice = nil
        focus = nil
        Task { await password.signIn() }
    }
}
