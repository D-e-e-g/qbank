/// The three kinds of account the app knows, and what each can do (`docs/cloud.md`).
///
/// What a screen offers follows what the account can do, never its role: an invited admin and an
/// invited student differ in what they may change, but neither kind of store account has a password
/// or an agent, whatever its role.
public enum AccountKind: String, Codable, Sendable, CaseIterable {
    /// An account the owner set up: email and password, with the bank on the server, as before the
    /// store release.
    case invited
    /// An account made by Sign in with Apple whose bank moved to QBank Cloud: the bank is on the
    /// server, and the bank file this phone held before the move stays on it, unused, as a safety copy.
    case store
    /// An account made by Sign in with Apple with no Cloud: the bank is on this phone, which is its
    /// only authority and answers every bank request itself.
    case free

    /// Whether the bank is on the phone, so the bank's requests are answered here and no screen
    /// waits for a connection to reach it.
    public var bankIsOnPhone: Bool { self == .free }

    /// Whether the account has a password to change.
    public var hasPassword: Bool { self == .invited }

    /// Whether Connect an agent is offered. Agent keys are shown to invited accounts only.
    public var connectsAgents: Bool { self == .invited }

    /// Whether Make questions and exam twins are offered, which send material to Anthropic. The
    /// server lets only an account the owner listed use them, and only an invited one can be.
    public var makesQuestions: Bool { self == .invited }

    /// Whether courses are saved on the phone for offline study and answers wait there to be sent.
    /// A bank on the phone has no need of either, since all of it is already here.
    public var savesForOffline: Bool { !bankIsOnPhone }

    /// Whether the account is deleted with its password. A store account, free or Cloud, has none,
    /// and is deleted with a fresh Sign in with Apple instead.
    public var deletesWithPassword: Bool { self == .invited }
}
