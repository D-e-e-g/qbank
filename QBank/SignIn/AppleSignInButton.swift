import AuthenticationServices
import QBankDesign
import SwiftUI

/// Apple's own Sign in with Apple button, as Apple asks it be shown: black on a light screen, white
/// on a dark one, at the height and corners of QBank's large buttons. While `isWorking`, a spinner
/// takes the place of its words, as on QBank's own buttons, and it takes no taps.
struct AppleSignInButton: View {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    let isWorking: Bool
    let identifier: String
    /// Called with the window the button is in, for Apple's sheet to open over.
    let action: (UIWindow?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let size = QBankButtonStyle.Size.large

    var body: some View {
        let isDark = colorScheme == .dark
        AppleIDButton(type: type, style: isDark ? .white : .black, identifier: identifier, action: action)
            // The style is set when Apple's button is made, so a new look makes a new button.
            .id(isDark)
            .frame(maxWidth: .infinity, minHeight: Self.size.minHeight, maxHeight: Self.size.minHeight)
            .overlay {
                if isWorking {
                    RoundedRectangle(cornerRadius: Self.size.cornerRadius)
                        .fill(isDark ? Color.white : Color.black)
                    ProgressView()
                        .tint(isDark ? Color.black : Color.white)
                        .accessibilityLabel("Signing in")
                }
            }
            .allowsHitTesting(!isWorking)
    }
}

/// `ASAuthorizationAppleIDButton` in SwiftUI. Its look is Apple's; its tap is QBank's, so a Debug
/// launch scenario can answer in Apple's place.
private struct AppleIDButton: UIViewRepresentable {
    let type: ASAuthorizationAppleIDButton.ButtonType
    let style: ASAuthorizationAppleIDButton.Style
    let identifier: String
    let action: (UIWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: style)
        button.cornerRadius = QBankButtonStyle.Size.large.cornerRadius
        button.accessibilityIdentifier = identifier
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped(_:)), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var action: (UIWindow?) -> Void

        init(action: @escaping (UIWindow?) -> Void) {
            self.action = action
        }

        @objc func tapped(_ sender: UIView) {
            action(sender.window)
        }
    }
}
