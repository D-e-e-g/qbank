import Observation
import SwiftUI

/// Whether this phone may send her material to Anthropic, kept on this phone. Making questions and
/// exam twins send what she gives them (her notes, photos, files, or practice questions) to the
/// QBank server, which passes it to Anthropic's Claude. Nothing is sent until she allows it here,
/// and she can take it back in Settings. Like Look it is a device setting: it is not sent to the
/// server, and it stays when she signs out.
@Observable
final class AIConsentStore {
    static let key = "qbank-ai-consent"

    var isAllowed: Bool {
        didSet { defaults.set(isAllowed, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isAllowed = defaults.bool(forKey: Self.key)
    }
}

/// The words of the permission screen and of its row in Settings.
nonisolated enum AIConsentWording {
    static let title = "Share your material with Anthropic?"

    static let message =
        "Making questions and writing exam twins use Claude, an AI model made by Anthropic. If you allow it, QBank sends what you give it to the QBank server: the notes you paste, your photos, a file you choose, or the practice questions you pick for exam twins. The server passes it to Anthropic's Claude to read your material and to write and check the questions.\n\nNothing is sent until you allow it. Not now leaves both unused. You can change this any time in Settings."

    static let allow = "Allow"
    static let notNow = "Not now"

    static let settingsHeader = "Anthropic"
    static let settingsTitle = "Share with Anthropic"
    static let settingsFooter =
        "Making questions and exam twins send your notes, photos, files or questions to Anthropic's Claude through the QBank server. When this is off, QBank asks before you use either. A set already being made carries on; stop it from Add."

    /// Said when something that sends her material is started without her permission.
    static let needed = "Allow sharing with Anthropic first. Turn it on in Settings, or choose Allow when QBank asks."
}

extension View {
    /// The one-time permission screen: a sheet that says what is sent, to whom and why, with Allow
    /// and Not now. Allow remembers the choice on this phone and, once the sheet is down, runs
    /// `onAllow`; Not now, or swiping the sheet down, sends nothing and leaves the feature unused.
    func aiPermissionSheet(isPresented: Binding<Bool>, store: AIConsentStore, onAllow: @escaping () -> Void) -> some View {
        modifier(AIPermissionSheet(isPresented: isPresented, store: store, onAllow: onAllow))
    }
}

private struct AIPermissionSheet: ViewModifier {
    @Binding var isPresented: Bool
    let store: AIConsentStore
    let onAllow: () -> Void
    @State private var allowed = false

    func body(content: Content) -> some View {
        // What Allow opens waits for the sheet to be down: a screen pushed while a sheet is still
        // leaving can be dropped.
        content.sheet(
            isPresented: $isPresented,
            onDismiss: {
                guard allowed else { return }
                allowed = false
                onAllow()
            },
            content: {
                ConfirmSheet(
                    title: AIConsentWording.title,
                    message: AIConsentWording.message,
                    messageMaxHeight: 360,
                    confirm: AIConsentWording.allow,
                    isDestructive: false,
                    cancel: AIConsentWording.notNow,
                    identifier: "ai.permission"
                ) { answer in
                    if answer {
                        store.isAllowed = true
                        allowed = true
                    }
                    isPresented = false
                }
            }
        )
    }
}
